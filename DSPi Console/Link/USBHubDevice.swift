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

    /// Read a device's identity over USB for the registry.  The protocol probe
    /// runs first, as the first request a new connection ever sees, and
    /// decides which requests may follow.  nil means not ready (probed again
    /// by the caller) or a protocol this Console cannot drive.
    static func readInfo(from usb: USBDevice, serialFallback: String) -> HubDeviceInfo? {
        switch usb.probeProtocol() {
        case .paged:
            return readIdentity(serialFallback: serialFallback,
                                serial: usb.getData(VC.SYS.SERIAL, length: 16),
                                platform: usb.getData(VC.SYS.PLATFORM, length: 7)) {
                usb.getData(VC.SYS.DEVICE_NAME, length: UInt16(DEVICE_NAME_LEN))
            }
        case .legacy(let platformReply):
            // Phase 2 of the paged-protocol port still attaches a legacy board
            // and reads it with its old opcodes; phase 3 stops attaching it.
            return readIdentity(serialFallback: serialFallback,
                                serial: usb.getControlRequest(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16),
                                platform: platformReply) {
                usb.getControlRequest(request: REQ_GET_DEVICE_NAME, value: 0, index: 2,
                                      length: UInt16(DEVICE_NAME_LEN))
            }
        case .unsupported, .notReady:
            return nil
        }
    }

    /// `SYS.PLATFORM` keeps the old GET_PLATFORM layout, so both generations
    /// share one decoder.
    private static func readIdentity(serialFallback: String, serial s: Data?, platform p: Data?,
                                     readName: () -> Data?) -> HubDeviceInfo? {
        let serial: String
        if let s, let str = String(data: s.prefix(while: { $0 != 0 }), encoding: .ascii), !str.isEmpty {
            serial = str
        } else {
            serial = serialFallback
        }
        guard let p, let reply = FirmwareVersion.fromPlatformReply([UInt8](p)) else { return nil }
        let v = reply.version
        // A STALL or a short reply (older firmware) means no board name.  One
        // retry, so a transient miss does not treat a capable board as old.
        var boardName: String?
        for _ in 0..<2 where boardName == nil {
            if let n = readName(), n.count == DEVICE_NAME_LEN {
                boardName = DSPViewModel.decodeInputSourceName(n)
            }
        }
        // fw_beta reports only what byte 6 says; a short reply leaves it unknown
        // even where FirmwareVersion can infer more (spec 7.4).
        return HubDeviceInfo(serial: serial, platform: reply.platform,
                             firmware: "\(v.major).\(v.minor).\(v.patch)",
                             firmwareBeta: p.count >= 7 ? Int(p[p.startIndex + 6]) : nil,
                             outputs: Int(p[p.startIndex + 3]), inputs: nil, wireVersion: nil, link: .usb,
                             boardName: boardName)
    }
}
