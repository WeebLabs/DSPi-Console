import Foundation
import IOKit
import IOKit.usb
import IOKit.serial

// MARK: - Device Model

struct DSPiDevice: Identifiable {
    let serial: String      // IORegistry "USB Serial Number"
    let locationID: UInt32  // IORegistry "locationID" (stable per port)
    var id: String { serial }
    var displayName: String {
        let short = String(serial.suffix(8))
        return "DSPi (\(short))"
    }
}

extension DSPiDevice: Hashable {
    static func == (lhs: DSPiDevice, rhs: DSPiDevice) -> Bool {
        lhs.serial == rhs.serial
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(serial)
    }
}

// MARK: - Global C-Convention Callbacks

// Triggered when a matching device is plugged in (or found at startup)
private func handleDeviceMatched(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else { return }
    let device = Unmanaged<USBDevice>.fromOpaque(refCon).takeUnretainedValue()
    device.onMatched(iterator: iterator)
}

// Triggered when the specific device we are monitoring is unplugged
private func handleDeviceTerminated(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else { return }
    let device = Unmanaged<USBDevice>.fromOpaque(refCon).takeUnretainedValue()
    device.onTerminated(iterator: iterator)
}

class USBDevice: ObservableObject {
    typealias DeviceInterface = IOUSBDeviceInterface500
    typealias DeviceInterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<DeviceInterface>?>?

    private var deviceInterface: DeviceInterfacePtr = nil
    private let vendorID: UInt16 = 0x2e8a
    private let productID: UInt16 = 0xfeaa

    // Serial queue for thread-safe IOKit operations
    private let serialQueue = DispatchQueue(label: "com.foxdac.usb.serial")

    // Notification Resources
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var availableDevices: [DSPiDevice] = []
    @Published var selectedDevice: DSPiDevice? = nil

    // UUID Constants
    private let kIOUSBDeviceUserClientTypeID_UUID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                                   0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4,
                                                                                   0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    private let kIOCFPlugInInterfaceID_UUID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                             0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                                             0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    private let kIOUSBDeviceInterfaceID500_UUID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                                 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xd4,
                                                                                 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    init() {
        // Just setting up monitoring triggers the initial scan automatically
        setupMonitoring()
    }

    deinit {
        if let port = notificationPort {
            IONotificationPortDestroy(port)
        }
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
    }

    // MARK: - IORegistry Property Readers

    private func readSerialNumber(from service: io_service_t) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue() as? String
    }

    private func readLocationID(from service: io_service_t) -> UInt32? {
        guard let cf = IORegistryEntryCreateCFProperty(service, "locationID" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (cf.takeRetainedValue() as? NSNumber)?.uint32Value
    }

    // MARK: - Device Open/Close Helpers

    /// Opens a USB device from its IOKit service. Returns true on success.
    /// Does NOT release the service — caller is responsible.
    private func openDevice(service: io_service_t) -> Bool {
        var score: Int32 = 0
        var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?

        let plugInResult = IOCreatePlugInInterfaceForService(
            service,
            kIOUSBDeviceUserClientTypeID_UUID,
            kIOCFPlugInInterfaceID_UUID,
            &interface,
            &score
        )

        guard plugInResult == kIOReturnSuccess, let interface = interface else { return false }

        var tempDeviceInterface: UnsafeMutableRawPointer? = nil
        let res = interface.pointee!.pointee.QueryInterface(
            interface,
            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500_UUID),
            &tempDeviceInterface
        )

        _ = interface.pointee!.pointee.Release(interface)

        guard res == kIOReturnSuccess else { return false }

        let devPtr = tempDeviceInterface?.assumingMemoryBound(to: UnsafeMutablePointer<DeviceInterface>?.self)
        guard let dev = devPtr else { return false }

        let openRes = dev.pointee!.pointee.USBDeviceOpen(dev)
        if openRes == kIOReturnSuccess {
            self.deviceInterface = devPtr
            return true
        } else if openRes == kIOReturnExclusiveAccess {
            DispatchQueue.main.async { self.errorMessage = "Device busy." }
        }
        return false
    }

    /// Closes the current device interface without updating published state.
    private func closeDevice() {
        if let dev = self.deviceInterface {
            _ = dev.pointee!.pointee.USBDeviceClose(dev)
            _ = dev.pointee!.pointee.Release(dev)
            self.deviceInterface = nil
        }
    }

    /// Scan currently connected DSPi devices and return their serial numbers.
    private func scanAvailableSerials() -> Set<String> {
        var serials = Set<String>()
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? NSMutableDictionary else { return serials }
        matchingDict[kUSBVendorID] = NSNumber(value: vendorID)
        matchingDict[kUSBProductID] = NSNumber(value: productID)

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict as CFDictionary, &iterator)
        guard kr == KERN_SUCCESS else { return serials }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if let serial = readSerialNumber(from: service) {
                serials.insert(serial)
            }
            IOObjectRelease(service)
        }
        return serials
    }

    // MARK: - Monitoring Setup

    private func setupMonitoring() {
        serialQueue.async {
            // 1. Clean up old port if exists
            if let port = self.notificationPort {
                IONotificationPortDestroy(port)
                self.notificationPort = nil
            }

            // 2. Create new Notification Port
            guard let notifyPort = IONotificationPortCreate(kIOMasterPortDefault) else { return }
            self.notificationPort = notifyPort

            // 3. Add to RunLoop
            if let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            }

            // 4. Define Matching Dictionary
            guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? NSMutableDictionary else { return }
            matchingDict[kUSBVendorID] = NSNumber(value: self.vendorID)
            matchingDict[kUSBProductID] = NSNumber(value: self.productID)

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            // 5. Register for Match (Connection/Startup)
            // Note: Retain matchingDict because IOServiceAddMatchingNotification consumes a reference
            let matchDictRef = matchingDict.copy() as! CFDictionary
            IOServiceAddMatchingNotification(
                notifyPort,
                kIOMatchedNotification,
                matchDictRef,
                handleDeviceMatched,
                selfPtr,
                &self.matchedIterator
            )

            // 6. Register for Termination (Disconnection)
            let termDictRef = matchingDict.copy() as! CFDictionary
            IOServiceAddMatchingNotification(
                notifyPort,
                kIOTerminatedNotification,
                termDictRef,
                handleDeviceTerminated,
                selfPtr,
                &self.terminatedIterator
            )

            // 7. Clear device list (will be repopulated by onMatched)
            DispatchQueue.main.async { self.availableDevices = [] }

            // 8. Prime the iterators to handle existing devices
            self.onMatched(iterator: self.matchedIterator)

            // Note: terminatedIterator is usually empty at start, but we must "drain" it to arm it.
            self.consumeIterator(self.terminatedIterator)
        }
    }

    // Just drain an iterator without action (helper)
    private func consumeIterator(_ iterator: io_iterator_t) {
        while IOIteratorNext(iterator) != 0 {}
    }

    // MARK: - Event Handlers

    fileprivate func onMatched(iterator: io_iterator_t) {
        var newDevices: [DSPiDevice] = []
        // Retain service handles for devices we may auto-connect to,
        // so we can open them directly without a second IOKit scan.
        var serviceForSerial: [String: io_service_t] = [:]

        while case let service = IOIteratorNext(iterator), service != 0 {
            guard let serial = readSerialNumber(from: service) else {
                IOObjectRelease(service)
                continue
            }
            let locationID = readLocationID(from: service) ?? 0
            newDevices.append(DSPiDevice(serial: serial, locationID: locationID))
            // Keep the service alive (caller will release after auto-connect decision)
            serviceForSerial[serial] = service
        }

        guard !newDevices.isEmpty else { return }

        DispatchQueue.main.async {
            // Add new devices, avoiding duplicates
            for device in newDevices {
                if !self.availableDevices.contains(where: { $0.serial == device.serial }) {
                    self.availableDevices.append(device)
                }
            }

            // Auto-connect logic — open directly from the retained service handle
            var deviceToConnect: DSPiDevice?
            if self.selectedDevice == nil && !self.availableDevices.isEmpty {
                deviceToConnect = self.availableDevices[0]
            } else if let selected = self.selectedDevice,
                      newDevices.contains(where: { $0.serial == selected.serial }),
                      self.deviceInterface == nil {
                deviceToConnect = selected
            }

            if let device = deviceToConnect, let service = serviceForSerial[device.serial] {
                self.serialQueue.async {
                    self.closeDevice()
                    if self.openDevice(service: service) {
                        DispatchQueue.main.async {
                            self.selectedDevice = device
                            self.isConnected = true
                            self.errorMessage = nil
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.isConnected = false
                            if self.errorMessage == nil {
                                self.errorMessage = "Could not open device"
                            }
                        }
                    }
                    // Release all retained services
                    for (_, svc) in serviceForSerial { IOObjectRelease(svc) }
                }
            } else {
                // No auto-connect — release all retained services
                for (_, svc) in serviceForSerial { IOObjectRelease(svc) }
            }
        }
    }

    fileprivate func onTerminated(iterator: io_iterator_t) {
        var terminatedSerials: [String] = []
        var hasUnreadable = false

        while case let service = IOIteratorNext(iterator), service != 0 {
            if let serial = readSerialNumber(from: service) {
                terminatedSerials.append(serial)
            } else {
                hasUnreadable = true
            }
            IOObjectRelease(service)
        }

        // If serial was unreadable (device yanked), diff against fresh scan
        let currentSerials = hasUnreadable ? scanAvailableSerials() : nil

        DispatchQueue.main.async {
            if let currentSerials = currentSerials {
                // Remove devices not found in fresh scan
                self.availableDevices.removeAll { !currentSerials.contains($0.serial) }
            } else {
                self.availableDevices.removeAll { terminatedSerials.contains($0.serial) }
            }

            // Check if selected device was removed
            if let selected = self.selectedDevice {
                let wasTerminated = terminatedSerials.contains(selected.serial) ||
                    (currentSerials != nil && !self.availableDevices.contains(where: { $0.serial == selected.serial }))

                if wasTerminated {
                    self.serialQueue.sync {
                        self.closeDevice()
                    }
                    self.isConnected = false
                    self.errorMessage = "Device Removed"
                    // Don't clear selectedDevice — allows auto-reconnect on re-plug
                }
            }

            // Clear selectedDevice if all devices are gone
            if self.availableDevices.isEmpty {
                self.selectedDevice = nil
            }
        }
    }

    // MARK: - Device Selection

    func selectDevice(_ device: DSPiDevice) {
        serialQueue.async {
            // Close current device if open
            self.closeDevice()

            // Find matching device by serial
            guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? NSMutableDictionary else {
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.errorMessage = "Could not find device"
                }
                return
            }
            matchingDict[kUSBVendorID] = NSNumber(value: self.vendorID)
            matchingDict[kUSBProductID] = NSNumber(value: self.productID)

            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict as CFDictionary, &iterator)
            guard kr == KERN_SUCCESS else {
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.errorMessage = "Could not find device"
                }
                return
            }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                let serial = self.readSerialNumber(from: service)
                if serial != device.serial {
                    IOObjectRelease(service)
                    continue
                }
                defer { IOObjectRelease(service) }

                if self.openDevice(service: service) {
                    DispatchQueue.main.async {
                        self.selectedDevice = device
                        self.isConnected = true
                        self.errorMessage = nil
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isConnected = false
                        if self.errorMessage == nil {
                            self.errorMessage = "Could not open device"
                        }
                    }
                }
                return
            }

            // Device not found in scan
            DispatchQueue.main.async {
                self.isConnected = false
                self.errorMessage = "Device not found"
            }
        }
    }

    // MARK: - Connection Management

    func disconnect() {
        serialQueue.sync {
            closeDevice()
        }
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    /// Disconnect and rescan for devices.
    func reconnect() {
        disconnect()
        setupMonitoring()
    }

    // MARK: - Control Transfers

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        serialQueue.async {
            guard let dev = self.deviceInterface else { return }

            var requestPtr = IOUSBDevRequest(
                bmRequestType: 0x41, // Host to Device | Vendor | Interface
                bRequest: request,
                wValue: value,
                wIndex: index,
                wLength: UInt16(data.count),
                pData: UnsafeMutableRawPointer(mutating: (data as NSData).bytes),
                wLenDone: 0
            )

            _ = dev.pointee!.pointee.DeviceRequest(dev, &requestPtr)
        }
    }

    func getControlRequest(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Data? {
        return serialQueue.sync {
            guard let dev = self.deviceInterface else { return nil }

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: 1)
            defer { buffer.deallocate() }

            var requestPtr = IOUSBDevRequest(
                bmRequestType: 0xC1, // Device to Host | Vendor | Interface
                bRequest: request,
                wValue: value,
                wIndex: index,
                wLength: length,
                pData: buffer,
                wLenDone: 0
            )

            let result = dev.pointee!.pointee.DeviceRequest(dev, &requestPtr)

            if result == kIOReturnSuccess {
                return Data(bytes: buffer, count: Int(length))
            }
            return nil
        }
    }
}
