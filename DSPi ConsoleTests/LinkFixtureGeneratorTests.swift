//
//  LinkFixtureGeneratorTests.swift
//  DSPi ConsoleTests
//
//  Writes the shared DSPi Link fixtures (spec 9.3) from this implementation's
//  codec, plus a real capture from an attached board.  Runs only when the
//  global default DSPiFixtureDir names a directory, so an ordinary test run
//  never writes files:
//
//    defaults write -g DSPiFixtureDir /path/to/DSPi-Link/fixtures
//

import XCTest
@testable import DSPi_Console

final class LinkFixtureGeneratorTests: XCTestCase {

    private var root: URL? {
        guard let path = UserDefaults.standard.string(forKey: "DSPiFixtureDir"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func write(_ data: Data, _ rel: String) throws {
        let url = root!.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeJSON(_ obj: Any, _ rel: String) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try write(data, rel)
    }

    func testWriteFrameFixtures() throws {
        guard root != nil else { throw XCTSkip("DSPiFixtureDir not set") }
        let cmdReq = LinkCmdRequest(tag: 7, handle: 0, direction: .set, bRequest: 0xD2,
                                    wValue: 0, wIndex: 2, payload: Data([0x00, 0x00, 0xA0, 0xC1]))
        let cmdGet = LinkCmdRequest(tag: 8, handle: 1, direction: .get, bRequest: 0x7F,
                                    wValue: 0, wIndex: 2, wLength: 6)
        let cmdResp = LinkCmdResponse(tag: 8, status: .ok, payload: Data([1, 1, 0x17, 9, 1, 7]))
        let denied = LinkCmdResponse(tag: 9, status: .denied)
        let notify = LinkNotifyFrame(tag: 3, handle: 0, origin: 12, packet: makeParamChangedPacket(source: 1, seq: 41))
        let poll = LinkPollFrame(tag: 100, handle: 0, slot: 2, payload: Data((0..<27).map { UInt8($0) }))
        let fw = LinkFwDataFrame(tag: 3, offset: 65536, data: Data([0xAA, 0xBB, 0xCC]))
        let ack = LinkFwDataAck(tag: 3, offset: 65536, status: .ok)
        let resync = LinkResyncFrame(handle: 0, reason: 1)
        let frames: [(String, LinkFrame, [String: Any])] = [
            ("cmd_request_set_master_volume", .cmdRequest(cmdReq),
             ["type": "cmd_request", "tag": 7, "handle": 0, "direction": "set", "bRequest": 0xD2,
              "wValue": 0, "wIndex": 2, "wLength": 4, "payload_hex": "0000a0c1",
              "note": "spec 11.1: master volume -20.0 dB, session 12"]),
            ("cmd_request_get_platform", .cmdRequest(cmdGet),
             ["type": "cmd_request", "tag": 8, "handle": 1, "direction": "get", "bRequest": 0x7F,
              "wValue": 0, "wIndex": 2, "wLength": 6]),
            ("cmd_response_platform", .cmdResponse(cmdResp),
             ["type": "cmd_response", "tag": 8, "status": 0, "payload_hex": "01011709010" + "7",
              "note": "RP2350, firmware 1.1.7, 9 outputs"]),
            ("cmd_response_denied", .cmdResponse(denied),
             ["type": "cmd_response", "tag": 9, "status": 0x81]),
            ("notify_param_changed", .notify(notify),
             ["type": "notify", "tag": 3, "handle": 0, "origin": 12,
              "packet": ["version": 2, "event": 2, "seq": 41, "wire_offset": 16, "wire_size": 4, "source": 1]]),
            ("poll_status", .poll(poll),
             ["type": "poll", "tag": 100, "handle": 0, "slot": 2, "payload_length": 27]),
            ("fwdata_chunk", .fwData(fw),
             ["type": "fwdata", "tag": 3, "offset": 65536, "data_hex": "aabbcc"]),
            ("fwdata_ack", .fwDataAck(ack),
             ["type": "fwdata_ack", "tag": 3, "offset": 65536, "status": 0]),
            ("resync_reattached", .resync(resync),
             ["type": "resync", "handle": 0, "reason": 1]),
        ]
        var index: [[String: Any]] = []
        for (name, frame, meaning) in frames {
            let bytes = frame.encode()
            try write(bytes, "frames/\(name).bin")
            // Round trip through our own decoder is the invariant every
            // implementation must also satisfy.
            XCTAssertEqual(try LinkFrame.decode(bytes), frame, name)
            var entry = meaning
            entry["file"] = "\(name).bin"
            entry["hex"] = bytes.map { String(format: "%02x", $0) }.joined()
            index.append(entry)
        }
        try writeJSON(["spec_version": "1.0", "frames": index], "frames/frames.json")
    }

    func testWriteMessageFixtures() throws {
        guard root != nil else { throw XCTSkip("DSPiFixtureDir not set") }
        let hubInfo = LinkHubInfo(id: "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b", name: "Studio Mac", kind: .console, version: "1.1.7")
        let limits = LinkLimits(maxFrame: 65536, maxPayload: 8192, maxInflight: 8, pollMaxHz: 20, pollBudgetBps: 200000)
        let samples: [(String, LinkMessage)] = [
            ("hello_client", .helloClient(LinkHelloClient(client: LinkClientInfo(name: "Troy's iPhone", app: "DSPi Mobile", version: "0.1")))),
            ("hello_hub", .helloHub(LinkHelloHub(hub: hubInfo, auth: .pin,
                                                caps: ["cmd", "notify", "poll", "snapshot", "lock", "rename"], limits: limits))),
            ("auth_token", .authToken(LinkAuthToken(id: 1, token: "Zm9vYmFyYmF6cXV4"))),
            ("auth_pair", .authPair(LinkAuthPair(id: 1, pin: "482913", name: "Troy's iPhone", role: .control))),
            ("auth_ok", .ok(try LinkOk(id: 1, body: LinkAuthOkBody(session: 12, role: .control, token: "Zm9vYmFyYmF6cXV4",
                                                                     policy: LinkPolicyDescriptor(denied: [[240, 1], [83, 1]]))))),
            ("device_list", .deviceList(LinkDeviceListRequest(id: 5))),
            ("device_list_ok", .ok(try LinkOk(id: 5, body: LinkDeviceListBody(devices: [
                LinkDeviceInfo(handle: 0, serial: "E46058388B1A2E2C", name: "Living room", platform: 1, fw: "1.1.7",
                               outputs: 9, inputs: 8, wireVersion: 30, state: .online, link: .usb, lockedBy: nil)])))),
            ("device_added", .deviceAdded(LinkDeviceEvent(device: LinkDeviceInfo(handle: 1, serial: "4BA1DDB9D1443D6A", name: "Bench", state: .online, link: .usb)))),
            ("device_removed", .deviceRemoved(LinkDeviceRemoved(handle: 1, serial: "4BA1DDB9D1443D6A"))),
            ("device_snapshot", .deviceSnapshot(LinkDeviceSnapshotRequest(id: 6, handle: 0))),
            ("poll_subscribe", .pollSubscribe(LinkPollSubscribe(id: 8, handle: 0, polls: [
                LinkPollSpec(slot: 0, req: 80, val: 9, idx: 2, len: 27, hz: 10),
                LinkPollSpec(slot: 1, req: 11, val: 3, idx: 2, len: 80, hz: 15)]))),
            ("poll_subscribe_ok", .ok(try LinkOk(id: 8, body: LinkPollSubscribeBody(granted: [LinkPollGrant(slot: 0, hz: 10), LinkPollGrant(slot: 1, hz: 12)])))),
            ("poll_unsubscribe", .pollUnsubscribe(LinkPollUnsubscribe(id: 9, handle: 0, slots: [1]))),
            ("lock_acquire", .lockAcquire(LinkLockAcquire(id: 10, handle: 0, reason: "Applying configuration", timeoutMs: 10000))),
            ("lock_release", .lockRelease(LinkLockRelease(id: 11, handle: 0))),
            ("err_denied", .err(LinkErr(id: 7, code: "denied", msg: "admin role required"))),
            ("err_unauthenticated", .err(LinkErr(id: 2, code: "unauthenticated"))),
        ]
        for (name, message) in samples {
            let data = try message.encoded()
            XCTAssertEqual(try LinkMessage.decode(data), message, name)
            // Re-serialise pretty and key-sorted so the fixtures are diffable.
            let obj = try JSONSerialization.jsonObject(with: data)
            try writeJSON(obj, "messages/\(name).json")
        }
    }

    func testCaptureDeviceFixtures() throws {
        guard root != nil else { throw XCTSkip("DSPiFixtureDir not set") }
        let usb = try HardwareTest.requireDevice()
        HardwareTest.settle()
        guard let bulk = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              bulk.count == Int(BULK_PARAMS_SIZE),
              let platform = usb.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 6),
              let serial = usb.getControlRequest(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16) else {
            return XCTFail("device did not answer the capture reads")
        }
        let numCh = Int(bulk[2])
        let statusLen = UInt16(numCh * 2 + 2 + 4 + 1)
        guard let status = usb.getControlRequest(request: REQ_GET_STATUS, value: 9, index: 0, length: statusLen) else {
            return XCTFail("no status")
        }
        let wire = Int(bulk[0])
        try write(bulk, "device/bulk_v\(wire).bin")
        try write(status, "device/status_wvalue9.bin")
        try write(platform, "device/platform.bin")
        let masterVol: Float = bulk.withUnsafeBytes { $0.load(fromByteOffset: BULK_MASTER_VOLUME_OFFSET, as: Float.self) }
        let sidecar: [String: Any] = [
            "captured": ISO8601DateFormatter().string(from: Date()),
            "serial": String(data: serial.prefix(while: { $0 != 0 }), encoding: .ascii) ?? "",
            "platform": ["raw_hex": platform.map { String(format: "%02x", $0) }.joined(),
                         "platform": Int(platform[0]), "fw": "\(platform[1]).\(platform.count >= 6 ? platform[4] : platform[2] >> 4).\(platform.count >= 6 ? platform[5] : platform[2] & 0x0F)",
                         "outputs": Int(platform[3])],
            "bulk": ["file": "bulk_v\(wire).bin", "wire_version": wire, "size": bulk.count,
                     "num_channels": numCh, "num_output_channels": Int(bulk[3]), "num_input_channels": Int(bulk[4]),
                     "master_volume_db": masterVol,
                     "note": "WireBulkParams as REQ_GET_ALL_PARAMS (0xA0) returned it; decode per the firmware's bulk_params.h for this wire version"],
            "status": ["file": "status_wvalue9.bin", "size": status.count,
                       "layout": "peaks[num_channels] u16, cpu0 u8, cpu1 u8, clip_flags u32, active_input_channels u8"],
        ]
        try writeJSON(sidecar, "device/capture.json")
    }
}
