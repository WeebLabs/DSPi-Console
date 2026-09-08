import XCTest
@testable import DSPi_Console

/// Tests for the DSPi Link JSON control plane (dspi_link_protocol_spec.md
/// section 7).  The spelling tests matter most: every other implementation
/// keys off these exact strings, and Swift's snake-case key strategy is not
/// trusted to produce them.
final class LinkMessageTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip(_ message: LinkMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try message.encoded()
        let back = try LinkMessage.decode(data)
        XCTAssertEqual(back, message, String(data: data, encoding: .utf8) ?? "", file: file, line: line)
    }

    /// Top-level keys of the encoded message, as they appear on the wire.
    private func wireKeys(_ message: LinkMessage) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any]
        return Set((object ?? [:]).keys)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func decode(_ json: String) throws -> LinkMessage {
        try LinkMessage.decode(Data(json.utf8))
    }

    // MARK: - Envelope

    func testTypeNames() {
        let expected: [(LinkMessage, String)] = [
            (.helloClient(LinkHelloClient(client: LinkClientInfo(name: "a"))), "hello"),
            (.helloHub(LinkHelloHub(hub: LinkHubInfo(id: "u", name: "h", kind: .console), auth: .pin)), "hello"),
            (.authToken(LinkAuthToken(id: 1, token: "t")), "auth.token"),
            (.authPair(LinkAuthPair(id: 1, pin: "482913", name: "n")), "auth.pair"),
            (.authList(LinkAuthList(id: 2)), "auth.list"),
            (.authRevoke(LinkAuthRevoke(id: 3, cid: 3)), "auth.revoke"),
            (.authSetRole(LinkAuthSetRole(id: 4, cid: 3, role: .viewer)), "auth.set_role"),
            (.deviceList(LinkDeviceListRequest(id: 5)), "device.list"),
            (.deviceAdded(LinkDeviceEvent(device: LinkDeviceInfo(handle: 0, serial: "S"))), "device.added"),
            (.deviceRemoved(LinkDeviceRemoved(handle: 0, serial: "S")), "device.removed"),
            (.deviceChanged(LinkDeviceEvent(device: LinkDeviceInfo(handle: 0, serial: "S"))), "device.changed"),
            (.deviceRename(LinkDeviceRename(id: 6, handle: 0, name: "Living room")), "device.rename"),
            (.deviceSnapshot(LinkDeviceSnapshotRequest(id: 6, handle: 0)), "device.snapshot"),
            (.pollSubscribe(LinkPollSubscribe(id: 8, handle: 0, polls: [])), "poll.subscribe"),
            (.pollUnsubscribe(LinkPollUnsubscribe(id: 9, handle: 0, slots: [1])), "poll.unsubscribe"),
            (.pollError(LinkPollError(handle: 0)), "poll.error"),
            (.lockAcquire(LinkLockAcquire(id: 10, handle: 0)), "lock.acquire"),
            (.lockRelease(LinkLockRelease(id: 11, handle: 0)), "lock.release"),
            (.fwInstall(LinkFwInstall(id: 12, handle: 0, size: 1, sha256: "ab")), "fw.install"),
            (.fwProgress(LinkFwProgress(handle: 0, phase: .uploading)), "fw.progress"),
            (.fwDone(LinkFwDone(handle: 0, ok: true)), "fw.done"),
            (.hubStats(LinkHubStatsRequest(id: 13)), "hub.stats"),
            (.hubRename(LinkHubRename(id: 14, name: "Studio Mac")), "hub.rename"),
            (.ok(LinkOk(id: 1)), "ok"),
            (.err(LinkErr(id: 1, code: LinkErrorCode.denied)), "err"),
        ]
        for (message, name) in expected {
            XCTAssertEqual(message.typeName, name)
        }
    }

    func testEveryMessageTypeRoundTrips() throws {
        let device = LinkDeviceInfo(handle: 0, serial: "E46058388B1A2E2C", name: "Living room",
                                    platform: 1, fw: "1.1.7", outputs: 9, inputs: 8,
                                    wireVersion: 30, state: .online, link: .usb, lockedBy: nil)
        let messages: [LinkMessage] = [
            .helloClient(LinkHelloClient(client: LinkClientInfo(name: "Troy's iPhone",
                                                               app: "DSPi Mobile", version: "0.1"))),
            .helloHub(LinkHelloHub(hub: LinkHubInfo(id: "9d1b", name: "Studio Mac",
                                                    kind: .console, version: "1.1.7"),
                                   auth: .pin,
                                   caps: ["cmd", "notify", "poll", "snapshot", "lock",
                                          "fw_install", "web", "rename"],
                                   limits: LinkLimits(maxFrame: 65536, maxPayload: 8192,
                                                      maxInflight: 8, pollMaxHz: 20,
                                                      pollBudgetBps: 200000))),
            .authToken(LinkAuthToken(id: 1, token: "dG9rZW4")),
            .authPair(LinkAuthPair(id: 1, pin: "482913", name: "Troy's iPhone", role: .control)),
            .authList(LinkAuthList(id: 2)),
            .authRevoke(LinkAuthRevoke(id: 3, cid: 3)),
            .authSetRole(LinkAuthSetRole(id: 4, cid: 3, role: .viewer)),
            .deviceList(LinkDeviceListRequest(id: 5)),
            .deviceAdded(LinkDeviceEvent(device: device)),
            .deviceChanged(LinkDeviceEvent(device: device)),
            .deviceRemoved(LinkDeviceRemoved(handle: 0, serial: "E46058388B1A2E2C")),
            .deviceRename(LinkDeviceRename(id: 6, handle: 0, name: "Living room")),
            .deviceSnapshot(LinkDeviceSnapshotRequest(id: 6, handle: 0)),
            .pollSubscribe(LinkPollSubscribe(id: 8, handle: 0, polls: [
                LinkPollSpec(slot: 0, req: 80, val: 9, idx: 2, len: 27, hz: 10),
                LinkPollSpec(slot: 1, req: 11, val: 3, idx: 2, len: 80, hz: 15),
            ])),
            .pollUnsubscribe(LinkPollUnsubscribe(id: 9, handle: 0, slots: [1])),
            .pollError(LinkPollError(handle: 0, slot: 1, code: LinkErrorCode.busy, msg: "device busy")),
            .lockAcquire(LinkLockAcquire(id: 10, handle: 0, reason: "Applying configuration",
                                         timeoutMs: 10000)),
            .lockRelease(LinkLockRelease(id: 11, handle: 0)),
            .fwInstall(LinkFwInstall(id: 12, handle: 0, size: 393216, sha256: "deadbeef",
                                     version: "1.1.8")),
            .fwProgress(LinkFwProgress(handle: 0, phase: .verifying, pct: 42)),
            .fwDone(LinkFwDone(handle: 0, ok: true, fw: "1.1.8")),
            .hubStats(LinkHubStatsRequest(id: 13)),
            .hubRename(LinkHubRename(id: 14, name: "Studio Mac")),
            .err(LinkErr(id: 7, code: LinkErrorCode.denied, msg: "admin role required")),
            .unknown(type: "future.thing", id: 42),
        ]
        XCTAssertEqual(messages.count, 25)
        for message in messages { try roundTrip(message) }
    }

    func testOkRepliesRoundTrip() throws {
        let bodies: [LinkMessage] = [
            .ok(try LinkOk(id: 1, body: LinkAuthOkBody(session: 12, role: .control,
                                                       token: "dG9rZW4",
                                                       policy: LinkPolicyDescriptor(denied: [[240, 1], [83, 1]])))),
            .ok(try LinkOk(id: 5, body: LinkDeviceListBody(devices: [
                LinkDeviceInfo(handle: 0, serial: "E46058388B1A2E2C", name: "Living room",
                               platform: 1, fw: "1.1.7", outputs: 9, wireVersion: 30,
                               state: .online, link: .usb)]))),
            .ok(try LinkOk(id: 6, body: LinkSnapshotBody(handle: 0, wireVersion: 30, ageMs: 120,
                                                         bulkB64: "AAEC", statusB64: "AwQF"))),
            .ok(try LinkOk(id: 8, body: LinkPollSubscribeBody(granted: [LinkPollGrant(slot: 0, hz: 10),
                                                                        LinkPollGrant(slot: 1, hz: 12)]))),
            .ok(try LinkOk(id: 12, body: LinkFwInstallBody(xfer: 3))),
            .ok(try LinkOk(id: 13, body: LinkHubStatsBody(sessions: 3, uptimeS: 8812, devices: [
                LinkHubDeviceStats(handle: 0, cmds: 18233, errors: 2, avgRttMs: 1.4,
                                   notifyDropped: 0)]))),
            .ok(LinkOk(id: 10)),
        ]
        for message in bodies { try roundTrip(message) }
    }

    // MARK: - Wire spellings

    /// Every key whose Swift name carries a digit or an acronym, pinned to
    /// the exact spelling in the spec.
    func testSnakeCaseKeySpellings() throws {
        let hello = LinkMessage.helloHub(LinkHelloHub(
            hub: LinkHubInfo(id: "u", name: "h", kind: .console, version: "1.1.7"),
            auth: .pin, caps: ["cmd"],
            limits: LinkLimits(maxFrame: 65536, maxPayload: 8192, maxInflight: 8,
                               pollMaxHz: 20, pollBudgetBps: 200000)))
        let limits = try object(String(data: hello.encoded(), encoding: .utf8)!)["limits"] as! [String: Any]
        XCTAssertEqual(Set(limits.keys), ["max_frame", "max_payload", "max_inflight",
                                          "poll_max_hz", "poll_budget_bps"])

        let snapshot = try LinkOk(id: 6, body: LinkSnapshotBody(handle: 0, wireVersion: 30,
                                                                ageMs: 120, bulkB64: "AAEC",
                                                                statusB64: "AwQF"))
        XCTAssertEqual(try wireKeys(.ok(snapshot)),
                       ["t", "id", "handle", "wire_version", "age_ms", "bulk_b64", "status_b64"])

        let stats = try LinkOk(id: 13, body: LinkHubStatsBody(sessions: 3, uptimeS: 8812, devices: [
            LinkHubDeviceStats(handle: 0, cmds: 1, errors: 0, avgRttMs: 1.4, notifyDropped: 0)]))
        XCTAssertEqual(try wireKeys(.ok(stats)), ["t", "id", "sessions", "uptime_s", "devices"])
        let statsObject = try object(String(data: LinkMessage.ok(stats).encoded(), encoding: .utf8)!)
        let deviceStats = (statsObject["devices"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(deviceStats.keys), ["handle", "cmds", "errors", "avg_rtt_ms", "notify_dropped"])

        let lock = LinkMessage.lockAcquire(LinkLockAcquire(id: 10, handle: 0, reason: "r",
                                                           timeoutMs: 10000))
        XCTAssertEqual(try wireKeys(lock), ["t", "id", "handle", "reason", "timeout_ms"])

        let install = LinkMessage.fwInstall(LinkFwInstall(id: 12, handle: 0, size: 1,
                                                          sha256: "abc", version: "1.1.8"))
        XCTAssertEqual(try wireKeys(install), ["t", "id", "handle", "size", "sha256", "version"])

        let device = LinkMessage.deviceAdded(LinkDeviceEvent(device: LinkDeviceInfo(
            handle: 0, serial: "S", name: "n", platform: 1, fw: "1.1.7", outputs: 9, inputs: 8,
            wireVersion: 30, state: .online, link: .usb, lockedBy: 12)))
        let deviceObject = try object(String(data: device.encoded(), encoding: .utf8)!)["device"] as! [String: Any]
        XCTAssertEqual(Set(deviceObject.keys), ["handle", "serial", "name", "platform", "fw",
                                                "outputs", "inputs", "wire_version", "state",
                                                "link", "locked_by"])

        let clients = try LinkOk(id: 2, body: LinkAuthListBody(clients: [
            LinkAuthClient(cid: 3, name: "Troy's iPhone", role: .control,
                           created: Date(timeIntervalSince1970: 0),
                           lastSeen: Date(timeIntervalSince1970: 60), online: true)]))
        let clientsObject = try object(String(data: LinkMessage.ok(clients).encoded(), encoding: .utf8)!)
        let first = (clientsObject["clients"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(first.keys), ["cid", "name", "role", "created", "last_seen", "online"])
        XCTAssertEqual(first["created"] as? String, "1970-01-01T00:00:00Z")
    }

    /// The exact spellings must also decode, which is the half a key
    /// conversion strategy silently gets wrong.
    func testSnakeCaseKeysDecode() throws {
        let json = """
        {"t":"ok","id":6,"handle":0,"wire_version":30,"age_ms":120,
         "bulk_b64":"AAEC","status_b64":"AwQF"}
        """
        guard case .ok(let ok) = try decode(json) else { return XCTFail("expected ok") }
        let body = try ok.decodeBody(LinkSnapshotBody.self)
        XCTAssertEqual(body.handle, 0)
        XCTAssertEqual(body.wireVersion, 30)
        XCTAssertEqual(body.ageMs, 120)
        XCTAssertEqual(body.bulk, Data([0, 1, 2]))
        XCTAssertEqual(body.status, Data([3, 4, 5]))

        // The bag keeps the wire spellings, so a caller that does not know
        // the request type can still read a field by name.
        XCTAssertEqual(ok.body["wire_version"]?.intValue, 30)
        XCTAssertEqual(ok.body["bulk_b64"]?.stringValue, "AAEC")
        XCTAssertNil(ok.body["t"], "the type is not part of the body")
        XCTAssertNil(ok.body["id"], "the id is not part of the body")
    }

    // MARK: - Spec examples

    func testSpecExampleHelloExchange() throws {
        let client = """
        {"t": "hello", "proto": {"major": 1, "minor": 0},
         "client": {"name": "Troy's iPhone", "app": "DSPi Mobile", "version": "0.1"}}
        """
        guard case .helloClient(let c) = try decode(client) else {
            return XCTFail("a hello without hub or auth is the client's")
        }
        XCTAssertEqual(c.proto, LinkProtoVersion(major: 1, minor: 0))
        XCTAssertEqual(c.client.name, "Troy's iPhone")

        let hub = """
        {"t": "hello", "proto": {"major": 1, "minor": 0},
         "hub": {"id": "9d1b", "name": "Studio Mac", "kind": "console", "version": "1.1.7"},
         "auth": "pin",
         "caps": ["cmd", "notify", "poll", "snapshot", "lock", "fw_install", "web", "rename"],
         "limits": {"max_frame": 65536, "max_payload": 8192, "max_inflight": 8,
                    "poll_max_hz": 20, "poll_budget_bps": 200000}}
        """
        guard case .helloHub(let h) = try decode(hub) else {
            return XCTFail("a hello with hub and auth is the hub's")
        }
        XCTAssertEqual(h.hub.kind, .console)
        XCTAssertEqual(h.auth, .pin)
        XCTAssertTrue(h.supports(.fwInstall))
        XCTAssertTrue(h.supports(.cmd))
        XCTAssertEqual(h.limits?.maxFrame, 65536)
        XCTAssertEqual(h.limits?.pollBudgetBps, 200000)
    }

    func testSpecExampleAuthReply() throws {
        let json = """
        {"t": "ok", "id": 1, "session": 12, "role": "control",
         "policy": {"denied": [[240, 1], [83, 1]]}}
        """
        guard case .ok(let ok) = try decode(json) else { return XCTFail("expected ok") }
        XCTAssertEqual(ok.id, 1)
        let body = try ok.decodeBody(LinkAuthOkBody.self)
        XCTAssertEqual(body.session, 12)
        XCTAssertEqual(body.role, .control)
        XCTAssertNil(body.token)
        let denied = body.policy?.deniedCommands ?? []
        XCTAssertEqual(denied.count, 2)
        XCTAssertEqual(denied.first?.bRequest, 0xF0)
        XCTAssertEqual(denied.first?.direction, .get)
    }

    func testSpecExampleDeviceList() throws {
        let json = """
        {"t": "ok", "id": 5, "devices": [
          {"handle": 0, "serial": "E46058388B1A2E2C", "name": "Living room",
           "platform": 1, "fw": "1.1.7", "outputs": 9, "inputs": 8,
           "wire_version": 30, "state": "online", "link": "usb",
           "locked_by": null}]}
        """
        guard case .ok(let ok) = try decode(json) else { return XCTFail("expected ok") }
        let body = try ok.decodeBody(LinkDeviceListBody.self)
        XCTAssertEqual(body.devices.count, 1)
        let device = body.devices[0]
        XCTAssertEqual(device.serial, "E46058388B1A2E2C")
        XCTAssertEqual(device.wireVersion, 30)
        XCTAssertEqual(device.state, .online)
        XCTAssertEqual(device.link, .usb)
        XCTAssertNil(device.lockedBy, "an explicit null means unlocked")
    }

    func testSpecExamplePollSubscribe() throws {
        let json = """
        {"t": "poll.subscribe", "id": 8, "handle": 0, "polls": [
          {"slot": 0, "req": 80,  "val": 9, "idx": 2, "len": 27, "hz": 10},
          {"slot": 1, "req": 11,  "val": 3, "idx": 2, "len": 80, "hz": 15}]}
        """
        guard case .pollSubscribe(let m) = try decode(json) else {
            return XCTFail("expected poll.subscribe")
        }
        XCTAssertEqual(m.polls.count, 2)
        XCTAssertEqual(m.polls[0], LinkPollSpec(slot: 0, req: 80, val: 9, idx: 2, len: 27, hz: 10))

        guard case .ok(let ok) = try decode(#"{"t":"ok","id":8,"granted":[{"slot":0,"hz":10},{"slot":1,"hz":12}]}"#) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(try ok.decodeBody(LinkPollSubscribeBody.self).granted,
                       [LinkPollGrant(slot: 0, hz: 10), LinkPollGrant(slot: 1, hz: 12)])
    }

    func testSpecExampleFirmwareInstall() throws {
        guard case .fwInstall(let m) = try decode(#"{"t":"fw.install","id":12,"handle":0,"size":393216,"sha256":"abc","version":"1.1.8"}"#) else {
            return XCTFail("expected fw.install")
        }
        XCTAssertEqual(m.size, 393216)
        XCTAssertEqual(m.sha256, "abc")

        guard case .ok(let ok) = try decode(#"{"t":"ok","id":12,"xfer":3}"#) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(try ok.decodeBody(LinkFwInstallBody.self).xfer, 3)

        guard case .fwProgress(let p) = try decode(#"{"t":"fw.progress","handle":0,"phase":"copying","pct":42}"#) else {
            return XCTFail("expected fw.progress")
        }
        XCTAssertEqual(p.phase, .copying)
        XCTAssertEqual(p.pct, 42)

        guard case .fwDone(let d) = try decode(#"{"t":"fw.done","handle":0,"ok":true,"fw":"1.1.8"}"#) else {
            return XCTFail("expected fw.done")
        }
        XCTAssertTrue(d.ok)
    }

    func testSpecExampleHubStats() throws {
        let json = """
        {"t": "ok", "id": 13, "sessions": 3, "uptime_s": 8812,
         "devices": [{"handle": 0, "cmds": 18233, "errors": 2, "avg_rtt_ms": 1.4,
                      "notify_dropped": 0}]}
        """
        guard case .ok(let ok) = try decode(json) else { return XCTFail("expected ok") }
        let body = try ok.decodeBody(LinkHubStatsBody.self)
        XCTAssertEqual(body.uptimeS, 8812)
        XCTAssertEqual(body.devices?.first?.avgRttMs, 1.4)
        XCTAssertEqual(body.devices?.first?.notifyDropped, 0)
    }

    // MARK: - Forward compatibility

    func testUnknownTypeDecodesToUnknown() throws {
        let message = try decode(#"{"t":"device.teleport","id":9,"handle":0}"#)
        XCTAssertEqual(message, .unknown(type: "device.teleport", id: 9))
        XCTAssertEqual(message.requestID, 9)

        let event = try decode(#"{"t":"hub.aurora","colour":"green"}"#)
        XCTAssertEqual(event, .unknown(type: "hub.aurora", id: nil))
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {"t":"device.rename","id":6,"handle":0,"name":"Living room",
         "colour":"green","nested":{"a":[1,2,{"b":null}]},"future_flag":true}
        """
        guard case .deviceRename(let m) = try decode(json) else {
            return XCTFail("expected device.rename")
        }
        XCTAssertEqual(m, LinkDeviceRename(id: 6, handle: 0, name: "Living room"))

        // Including inside nested objects of a known type.
        let hub = """
        {"t":"hello","proto":{"major":1,"minor":0,"patch":7},
         "hub":{"id":"u","name":"h","kind":"console","serial":"x"},
         "auth":"pin","caps":["cmd","time_travel"],
         "limits":{"max_frame":16384,"max_frames_per_fortnight":3}}
        """
        guard case .helloHub(let h) = try decode(hub) else { return XCTFail("expected hub hello") }
        XCTAssertEqual(h.limits?.maxFrame, 16384)
        XCTAssertEqual(h.caps, ["cmd", "time_travel"])
    }

    func testMissingTypeIsADecodeFailure() {
        XCTAssertThrowsError(try decode(#"{"id":1,"handle":0}"#))
    }

    // MARK: - err

    func testErrDecodesCodeAndOptionalMessage() throws {
        guard case .err(let e) = try decode(#"{"t":"err","id":7,"code":"denied","msg":"admin role required"}"#) else {
            return XCTFail("expected err")
        }
        XCTAssertEqual(e.id, 7)
        XCTAssertEqual(e.code, LinkErrorCode.denied)
        XCTAssertEqual(e.msg, "admin role required")

        guard case .err(let bare) = try decode(#"{"t":"err","code":"unknown_type"}"#) else {
            return XCTFail("expected err")
        }
        XCTAssertNil(bare.id, "an err about an unparseable frame has no id to echo")
        XCTAssertEqual(bare.code, LinkErrorCode.unknownType)
        XCTAssertNil(bare.msg)
        XCTAssertEqual(try wireKeys(.err(bare)), ["t", "code"])
    }

    func testErrorCodeVocabulary() {
        XCTAssertEqual(LinkErrorCode.unauthenticated, "unauthenticated")
        XCTAssertEqual(LinkErrorCode.badRequest, "bad_request")
        XCTAssertEqual(LinkErrorCode.unknownType, "unknown_type")
        XCTAssertEqual(LinkErrorCode.noDevice, "no_device")
        XCTAssertEqual(LinkErrorCode.rateLimited, "rate_limited")
        XCTAssertEqual(LinkErrorCode.internalError, "internal")
    }

    // MARK: - Vocabularies

    func testStringEnums() throws {
        XCTAssertEqual(LinkRole.viewer.rawValue, "viewer")
        XCTAssertEqual(LinkRole.control.rawValue, "control")
        XCTAssertEqual(LinkRole.admin.rawValue, "admin")
        XCTAssertEqual(LinkAuthMode.none.rawValue, "none")
        XCTAssertEqual(LinkAuthMode.pin.rawValue, "pin")
        XCTAssertEqual(LinkHubKind.console.rawValue, "console")
        XCTAssertEqual(LinkHubKind.bridge.rawValue, "bridge")
        XCTAssertEqual(LinkDeviceState.updating.rawValue, "updating")
        XCTAssertEqual(LinkDeviceLinkKind.uart.rawValue, "uart")
        XCTAssertEqual(LinkCapability.fwInstall.rawValue, "fw_install")
        XCTAssertEqual(LinkFwPhase.rebooting.rawValue, "rebooting")
    }

    // MARK: - JSONValue

    func testJSONValueRoundTripsEveryShape() throws {
        let value = JSONValue.object([
            "s": .string("x"),
            "n": .number(12),
            "f": .number(1.5),
            "b": .bool(true),
            "z": .null,
            "a": .array([.number(1), .string("two"), .null]),
            "o": .object(["nested": .bool(false)]),
        ])
        let data = try LinkJSON.encoder().encode(value)
        XCTAssertEqual(try LinkJSON.decoder().decode(JSONValue.self, from: data), value)
        // Whole numbers must not gain a fractional part on the way out.
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"n\":12"))
    }
}
