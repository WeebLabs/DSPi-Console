//
//  USBHubDevice.swift
//  DSPi Console
//
//  Adapts the currently-open USB device to the hub's HubDevice interface, so
//  the CommandRouter drives a real DSPi with the same code it drives a fake
//  one.  It reads the device's identity once on connect (serial, platform,
//  firmware, output count) and executes a tunnelled request as the matching
//  USB control transfer.  See networking_plan.md Phase 2.
//

import Foundation

final class USBHubDevice: HubDevice {
    private let usb: USBDevice
    private var cachedInfo: HubDeviceInfo
    private let infoLock = NSLock()

    init(usb: USBDevice, info: HubDeviceInfo) {
        self.usb = usb
        self.cachedInfo = info
    }

    var info: HubDeviceInfo {
        infoLock.lock(); defer { infoLock.unlock() }
        return cachedInfo
    }

    func updateInfo(_ info: HubDeviceInfo) {
        infoLock.lock(); cachedInfo = info; infoLock.unlock()
    }

    var generation: UInt64 { usb.generation }
    var isConnected: Bool { usb.isConnected }

    /// A GET is an IN transfer; a SET is an OUT transfer.  Write-as-read
    /// commands are GETs at the wire level and the client sends them as such,
    /// so the direction the client states is the transfer we make: the hub
    /// does not reinterpret it.
    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse {
        switch request.direction {
        case .get:
            let result = usb.getControlResult(request: request.bRequest, value: request.wValue,
                                              index: request.wIndex, length: request.wLength)
            switch result {
            case .success(let data):
                return LinkCmdResponse(tag: request.tag, status: .ok, payload: data)
            case .failure(let status):
                return LinkCmdResponse(tag: request.tag, status: status)
            }
        case .set:
            let status = usb.sendControlResult(request: request.bRequest, value: request.wValue,
                                              index: request.wIndex, data: request.payload)
            return LinkCmdResponse(tag: request.tag, status: status)
        }
    }

    /// Read a device's identity over USB for the registry.  Platform and
    /// firmware come from REQ_GET_PLATFORM (6 bytes, full-width minor/patch),
    /// the serial from REQ_GET_SERIAL.  Returns nil if the device does not
    /// answer, which the caller treats as "not ready yet".
    static func readInfo(from usb: USBDevice, serialFallback: String) -> HubDeviceInfo? {
        let serial: String
        if let s = usb.getControlRequest(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16),
           let str = String(data: s.prefix(while: { $0 != 0 }), encoding: .ascii), !str.isEmpty {
            serial = str
        } else {
            serial = serialFallback
        }
        guard let p = usb.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 6),
              p.count >= 4 else { return nil }
        let platform = p[0]
        let major = p[1]
        let minor = p.count >= 6 ? p[4] : p[2] >> 4
        let patch = p.count >= 6 ? p[5] : p[2] & 0x0F
        let outputs = Int(p[3])
        let link: LinkDeviceLink = .usb
        return HubDeviceInfo(serial: serial, platform: platform,
                             firmware: "\(major).\(minor).\(patch)",
                             outputs: outputs, inputs: nil, wireVersion: nil, link: link)
    }
}
