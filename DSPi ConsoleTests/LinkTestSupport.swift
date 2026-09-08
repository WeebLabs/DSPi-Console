//
//  LinkTestSupport.swift
//  DSPi ConsoleTests
//
//  A controllable HubDevice shared by the hub-level tests.
//

import Foundation
@testable import DSPi_Console

final class LinkFakeDevice: HubDevice {
    var info: HubDeviceInfo
    var generation: UInt64 = 0
    var isConnected: Bool = true

    private let lock = NSLock()
    private var log: [LinkCmdRequest] = []
    var status: LinkStatus = .ok
    /// Payload returned for every GET, unless `responder` overrides it.
    var responsePayload: Data = Data()
    /// Optional per-request answer, for a device that answers 0xA0 with a blob
    /// and everything else with something short.
    var responder: ((LinkCmdRequest) -> LinkCmdResponse)?

    init(serial: String = "E46058388B1A2E2C") {
        info = HubDeviceInfo(serial: serial, platform: 1, firmware: "1.1.7",
                             outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
    }

    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse {
        lock.lock(); log.append(request); lock.unlock()
        if let r = responder { return r(request) }
        return LinkCmdResponse(tag: request.tag, status: status,
                               payload: request.direction == .get ? responsePayload : Data())
    }

    var executed: [LinkCmdRequest] { lock.lock(); defer { lock.unlock() }; return log }
    var executedCodes: [UInt8] { executed.map { $0.bRequest } }
}

/// A v2 PARAM_CHANGED packet with the given source byte, 4-byte value at
/// offset 16 (global preamp), for feeding hubs in tests.
func makeParamChangedPacket(source: UInt8, seq: UInt8 = 1) -> Data {
    var p = Data(count: 16)
    p[0] = 0x02; p[1] = 0x02; p[3] = seq
    p[4] = 16; p[5] = 0           // offset 16
    p[6] = 4;  p[7] = 0           // size 4
    p[8] = source
    return p
}
