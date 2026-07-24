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
    private let vendorID: UInt16 = 0x2e8b
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

    // kIOUSBInterfaceUserClientTypeID — 2d9786c6-9ef3-11d4-ad51-000a27052861
    private let kIOUSBInterfaceUserClientTypeID_UUID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                                      0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xd4,
                                                                                      0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    // kIOUSBInterfaceInterfaceID500 — 6C0D38C3-B093-4EA7-809B-09FB5DDDAC16
    private let kIOUSBInterfaceInterfaceID500_UUID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                                     0x6c, 0x0d, 0x38, 0xc3, 0xb0, 0x93, 0x4e, 0xa7,
                                                                                     0x80, 0x9b, 0x09, 0xfb, 0x5d, 0xdd, 0xac, 0x16)

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

    // MARK: - Connection Generation

    /// Monotonic counter bumped on every device open and close. Control
    /// transfers capture it when the caller invokes them and re-check it when
    /// their block actually runs on `serialQueue`, so a command issued while
    /// device A was selected is dropped instead of being delivered to a
    /// different device that was opened in the meantime (e.g. the auto-switch
    /// to a surviving device when the selected one is unplugged).
    private var connectionGeneration: UInt64 = 0
    private let generationLock = NSLock()

    /// Current connection generation (thread-safe snapshot).
    var generation: UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return connectionGeneration
    }

    private func bumpGeneration() {
        generationLock.lock()
        defer { generationLock.unlock() }
        connectionGeneration &+= 1
    }

    // MARK: - Device Open/Close Helpers

    /// Opens a USB device from its IOKit service. Returns `kIOReturnSuccess` on
    /// success, otherwise the failing IOKit status.
    /// Does NOT release the service — caller is responsible.
    private func openDevice(service: io_service_t) -> IOReturn {
        var score: Int32 = 0
        var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?

        let plugInResult = IOCreatePlugInInterfaceForService(
            service,
            kIOUSBDeviceUserClientTypeID_UUID,
            kIOCFPlugInInterfaceID_UUID,
            &interface,
            &score
        )

        guard plugInResult == kIOReturnSuccess, let interface = interface else {
            return plugInResult == kIOReturnSuccess ? kIOReturnNoResources : plugInResult
        }

        var tempDeviceInterface: UnsafeMutableRawPointer? = nil
        let res = interface.pointee!.pointee.QueryInterface(
            interface,
            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500_UUID),
            &tempDeviceInterface
        )

        _ = interface.pointee!.pointee.Release(interface)

        guard res == kIOReturnSuccess else { return res }

        let devPtr = tempDeviceInterface?.assumingMemoryBound(to: UnsafeMutablePointer<DeviceInterface>?.self)
        guard let dev = devPtr else { return kIOReturnNoResources }

        let openRes = dev.pointee!.pointee.USBDeviceOpen(dev)
        if openRes == kIOReturnSuccess {
            self.deviceInterface = devPtr
            bumpGeneration()
        } else {
            // Release the handle we just created; retries build a fresh one,
            // and leaking it here would pile up an interface per attempt.
            _ = dev.pointee!.pointee.Release(dev)
        }
        return openRes
    }

    /// Delays between open attempts, in seconds. IOKit publishes the device
    /// service before the composite driver has opened it to set the
    /// configuration, so a device-level open right after enumeration can
    /// transiently fail (typically `kIOReturnExclusiveAccess`). This is most
    /// visible on the re-enumeration that follows a firmware flash, where the
    /// device is also still initialising. Without retries that single failure
    /// is permanent - nothing else ever attempts a connect.
    private static let openRetryDelays: [TimeInterval] = [0.1, 0.2, 0.4, 0.8, 1.0]

    /// Opens `service` on `serialQueue`, retrying with backoff, and publishes
    /// the resulting connection state. Takes ownership of `service`: it is
    /// released once the attempt sequence finishes.
    /// Must be called on `serialQueue`.
    private func openWithRetry(service: io_service_t, device: DSPiDevice, attempt: Int = 0) {
        let result = openDevice(service: service)

        if result == kIOReturnSuccess {
            IOObjectRelease(service)
            DispatchQueue.main.async {
                self.selectedDevice = device
                self.isConnected = true
                self.errorMessage = nil
            }
            return
        }

        if attempt < USBDevice.openRetryDelays.count {
            // asyncAfter rather than sleeping: serialQueue also serves the
            // synchronous control reads, so blocking it would stall the UI.
            serialQueue.asyncAfter(deadline: .now() + USBDevice.openRetryDelays[attempt]) { [weak self] in
                guard let self = self else {
                    IOObjectRelease(service)
                    return
                }
                // Another path (user switch, a later match) got a device open
                // while we were waiting - abandon rather than steal it.
                guard self.deviceInterface == nil else {
                    IOObjectRelease(service)
                    return
                }
                self.openWithRetry(service: service, device: device, attempt: attempt + 1)
            }
            return
        }

        IOObjectRelease(service)
        DispatchQueue.main.async {
            self.isConnected = false
            self.errorMessage = result == kIOReturnExclusiveAccess
                ? "Device busy (another app has it open)"
                : "Could not open device"
        }
    }

    /// Closes the current device interface without updating published state.
    private func closeDevice() {
        if let dev = self.deviceInterface {
            _ = dev.pointee!.pointee.USBDeviceClose(dev)
            _ = dev.pointee!.pointee.Release(dev)
            self.deviceInterface = nil
            bumpGeneration()
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
            if self.selectedDevice == nil {
                // Connect to a device from this batch: we hold its service
                // handle, whereas availableDevices[0] can be an older entry we
                // have no handle for, which silently skipped the connect and
                // left the picker showing a device we never opened.
                deviceToConnect = newDevices.first(where: { serviceForSerial[$0.serial] != nil })
            } else if let selected = self.selectedDevice,
                      let rematched = newDevices.first(where: { $0.serial == selected.serial }),
                      self.deviceInterface == nil || rematched.locationID == selected.locationID {
                // A match is a *new* instance of the device, so any handle we
                // still hold for it belongs to the dead one (a termination we
                // haven't processed yet) - reopen instead of sitting on it.
                // The locationID check keeps a same-serial unit on another
                // port from stealing a healthy connection.
                deviceToConnect = rematched
            }

            if let device = deviceToConnect, let service = serviceForSerial[device.serial] {
                // Release every service except the one handed to openWithRetry,
                // which owns it until its retry sequence finishes.
                for (serial, svc) in serviceForSerial where serial != device.serial {
                    IOObjectRelease(svc)
                }
                self.serialQueue.async {
                    self.closeDevice()
                    self.openWithRetry(service: service, device: device)
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

            // Check if selected device was removed.
            //
            // We treat the selected device as terminated whenever it's no
            // longer in `availableDevices`, regardless of whether *this*
            // callback's batch contained its serial.  This catches the race
            // where two devices are unplugged near-simultaneously and IOKit
            // delivers two separate `onTerminated` callbacks: the first
            // removes the selected device A and dispatches a switch to B,
            // and the second removes B before the switch lands.  Without
            // this broader check the second callback would see selected==A
            // (the in-flight switch hasn't updated it yet) and A wouldn't
            // be in *its* terminatedSerials, so wasTerminated would be
            // false and the user would end up stuck on dead A with C
            // unselected.
            if let selected = self.selectedDevice {
                let wasTerminated = terminatedSerials.contains(selected.serial) ||
                    !self.availableDevices.contains(where: { $0.serial == selected.serial })

                if wasTerminated {
                    self.serialQueue.sync {
                        self.closeDevice()
                    }
                    self.isConnected = false
                    self.errorMessage = "Device Removed"
                    // Don't clear selectedDevice — allows auto-reconnect on re-plug.

                    // If another DSPi is still connected, automatically switch
                    // to it so the user isn't stranded on a phantom selection
                    // with a disabled dropdown (count==1 hides the picker
                    // affordance, leaving them unable to pick the survivor).
                    if let next = self.availableDevices.first {
                        self.selectDevice(next)
                    }
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

            // Collect serial matches, preferring the one at the expected USB
            // location. Serials are normally unique, but units flashed with a
            // duplicate/default serial would otherwise collapse onto whichever
            // service the iterator yields first.
            var chosen: io_service_t = 0
            var fallback: io_service_t = 0
            while case let service = IOIteratorNext(iterator), service != 0 {
                guard self.readSerialNumber(from: service) == device.serial else {
                    IOObjectRelease(service)
                    continue
                }
                if self.readLocationID(from: service) == device.locationID {
                    chosen = service
                    break
                }
                if fallback == 0 {
                    fallback = service
                } else {
                    IOObjectRelease(service)
                }
            }
            if chosen == 0 {
                chosen = fallback
            } else if fallback != 0 {
                IOObjectRelease(fallback)
            }

            if chosen != 0 {
                // openWithRetry takes ownership of `chosen` and publishes the
                // connection state once it succeeds or exhausts its attempts.
                self.openWithRetry(service: chosen, device: device)
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
        // Bind the command to the device that was open when the caller issued
        // it; if a switch (close/open) intervenes before the block runs, drop
        // the command rather than deliver it to the wrong device.
        let expectedGeneration = generation
        serialQueue.async {
            guard expectedGeneration == self.generation,
                  let dev = self.deviceInterface else { return }

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
        // Same device-binding as sendControlRequest: a read that was issued
        // for the previously-open device fails (nil) instead of returning
        // another device's data.
        let expectedGeneration = generation
        return serialQueue.sync {
            guard expectedGeneration == self.generation,
                  let dev = self.deviceInterface else { return nil }

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
                return Data(bytes: buffer, count: Int(requestPtr.wLenDone))
            }
            return nil
        }
    }

    // MARK: - Interface-level Access (for interrupt endpoints)

    typealias InterfaceInterface = IOUSBInterfaceInterface500
    typealias InterfaceInterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<InterfaceInterface>?>

    /// Find and open the vendor interface (class 0xFF) on the currently-open
    /// device.  The interrupt IN endpoint (EP 0x83) for notifications lives
    /// on this interface.
    ///
    /// Returns an opened interface handle the caller is responsible for
    /// closing via `USBInterfaceClose` + `Release`.  The interface is
    /// independent of the device handle held by `deviceInterface`; closing
    /// the device does NOT implicitly close the interface, and vice versa.
    func openVendorInterface() -> InterfaceInterfacePtr? {
        return serialQueue.sync { [self] in
            guard let dev = deviceInterface else { return nil }

            var request = IOUSBFindInterfaceRequest(
                bInterfaceClass: 0xFF,
                bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
                bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare)
            )

            var iterator: io_iterator_t = 0
            let res = dev.pointee!.pointee.CreateInterfaceIterator(dev, &request, &iterator)
            guard res == kIOReturnSuccess else { return nil }
            defer { IOObjectRelease(iterator) }

            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }

            var score: Int32 = 0
            var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            let plugInResult = IOCreatePlugInInterfaceForService(
                service,
                kIOUSBInterfaceUserClientTypeID_UUID,
                kIOCFPlugInInterfaceID_UUID,
                &plugin,
                &score
            )
            guard plugInResult == kIOReturnSuccess, let plugin = plugin else { return nil }

            var tempPtr: UnsafeMutableRawPointer?
            let qiRes = plugin.pointee!.pointee.QueryInterface(
                plugin,
                CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500_UUID),
                &tempPtr
            )
            _ = plugin.pointee!.pointee.Release(plugin)

            guard qiRes == kIOReturnSuccess, let tempPtr = tempPtr else { return nil }

            let interfacePtr = tempPtr.assumingMemoryBound(to: UnsafeMutablePointer<InterfaceInterface>?.self)

            let openRes = interfacePtr.pointee!.pointee.USBInterfaceOpen(interfacePtr)
            if openRes != kIOReturnSuccess {
                _ = interfacePtr.pointee!.pointee.Release(interfacePtr)
                return nil
            }
            return interfacePtr
        }
    }
}
