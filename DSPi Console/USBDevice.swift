import Foundation
import IOKit
import IOKit.usb
import IOKit.serial

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
            
            // 7. Prime the iterators to handle existing devices
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
        // Iterate over devices (usually just one, but handles multiple)
        while case let device = IOIteratorNext(iterator), device != 0 {
            
            // If we are already connected, ignore new ones (or handle multiple devices logic here)
            if deviceInterface != nil {
                IOObjectRelease(device)
                continue
            }
            
            var score: Int32 = 0
            var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            
            // Create Plugin Interface
            let plugInResult = IOCreatePlugInInterfaceForService(
                device,
                kIOUSBDeviceUserClientTypeID_UUID,
                kIOCFPlugInInterfaceID_UUID,
                &interface,
                &score
            )
            
            // We can release the device object now that we have the plugin
            IOObjectRelease(device)
            
            guard plugInResult == kIOReturnSuccess, let interface = interface else { continue }
            
            // Query for the Device Interface (IOUSBDeviceInterface500)
            var tempDeviceInterface: UnsafeMutableRawPointer? = nil
            let res = interface.pointee!.pointee.QueryInterface(
                interface,
                CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500_UUID),
                &tempDeviceInterface
            )
            
            // Release the Plugin Interface
            _ = interface.pointee!.pointee.Release(interface)
            
            if res == kIOReturnSuccess {
                let devPtr = tempDeviceInterface?.assumingMemoryBound(to: UnsafeMutablePointer<DeviceInterface>?.self)
                
                if let dev = devPtr {
                    let openRes = dev.pointee!.pointee.USBDeviceOpen(dev)
                    if openRes == kIOReturnSuccess {
                        // Success!
                        self.deviceInterface = devPtr
                        DispatchQueue.main.async {
                            self.isConnected = true
                            self.errorMessage = nil
                        }
                    } else if openRes == kIOReturnExclusiveAccess {
                        DispatchQueue.main.async { self.errorMessage = "Device busy." }
                    }
                }
            }
        }
    }
    
    fileprivate func onTerminated(iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 {
            IOObjectRelease(device)
            
            // Since we match by VID/PID, any termination of our device type should trigger a disconnect/cleanup
            // This covers the case where the device we held open is pulled.
            disconnect()
            
            DispatchQueue.main.async {
                self.errorMessage = "Device Removed"
            }
        }
    }
    
    // MARK: - Connection Management
    
    func disconnect() {
        serialQueue.sync {
            if let dev = self.deviceInterface {
                _ = dev.pointee!.pointee.USBDeviceClose(dev)
                _ = dev.pointee!.pointee.Release(dev)
                self.deviceInterface = nil
            }
        }
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    // Manual connect is now just a reset of the monitoring system
    func connect() {
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
