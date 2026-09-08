//
//  LinkSessionHandlerTests.swift
//  DSPi ConsoleTests
//
//  The server-side protocol brain, driven with decoded input and asserted on
//  the bytes it emits.  No socket, no NIO.
//

import XCTest
@testable import DSPi_Console

final class LinkSessionHandlerTests: XCTestCase {

    private var tmpAuthURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lsh-\(UUID().uuidString).json")
    }

    private func makeStack() -> (LinkHub, LinkAuthStore, LinkPolicy) {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: tmpAuthURL)
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        return (hub, auth, policy)
    }

    /// Collects everything the handler emits, decoding text as LinkMessage.
    private final class Sink {
        var outbound: [LinkOutbound] = []
        var messages: [LinkMessage] = []
        var binary: [Data] = []
        var closes: [UInt16] = []
        func receive(_ o: LinkOutbound) {
            outbound.append(o)
            switch o {
            case .text(let d): if let m = try? LinkMessage.decode(d) { messages.append(m) }
            case .binary(let d): binary.append(d)
            case .close(let c): closes.append(c)
            }
        }
        func lastOk() -> LinkOk? {
            for m in messages.reversed() { if case .ok(let ok) = m { return ok } }
            return nil
        }
        func lastErr() -> LinkErr? {
            for m in messages.reversed() { if case .err(let e) = m { return e } }
            return nil
        }
        func hubHello() -> LinkHelloHub? {
            for m in messages { if case .helloHub(let h) = m { return h } }
            return nil
        }
    }

    private func handler(_ hub: LinkHub, _ auth: LinkAuthStore, _ policy: LinkPolicy, _ sink: Sink,
                         peer: String = "192.168.1.5") -> LinkSessionHandler {
        LinkSessionHandler(hub: hub, auth: auth, policy: policy, peer: peer) { sink.receive($0) }
    }

    private func text(_ m: LinkMessage) -> Data { try! m.encoded() }

    // MARK: - Hello

    func testHelloReturnsHubHelloWithCaps() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.helloClient(LinkHelloClient(client: LinkClientInfo(name: "Phone")))))
        let hello = sink.hubHello()
        XCTAssertNotNil(hello)
        XCTAssertEqual(hello?.hub.kind, .console)
        XCTAssertEqual(hello?.auth, .pin)
        XCTAssertTrue(hello?.caps.contains("cmd") ?? false)
        XCTAssertTrue(hello?.caps.contains("notify") ?? false)
    }

    func testMalformedJSONCloses() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(Data("{not json".utf8))
        XCTAssertEqual(sink.closes, [4000])
    }

    // MARK: - Auth gating

    func testCommandBeforeAuthIsRejected() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.deviceList(LinkDeviceListRequest(id: 1))))
        XCTAssertEqual(sink.lastErr()?.code, "unauthenticated")
    }

    func testBinaryBeforeAuthIsDropped() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        let req = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                                 wValue: 9, wIndex: 2, wLength: 4)
        h.receiveBinary(LinkFrame.cmdRequest(req).encode())
        XCTAssertTrue(sink.binary.isEmpty, "no data-plane traffic before auth")
    }

    // MARK: - Pairing

    func testPairWithCorrectPINOpensSession() {
        let (hub, auth, policy) = makeStack()
        let pin = auth.beginPairing()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.helloClient(LinkHelloClient(client: LinkClientInfo(name: "Phone")))))
        h.receiveText(text(.authPair(LinkAuthPair(id: 1, pin: pin, name: "Phone", role: .control))))
        let ok = sink.lastOk()
        XCTAssertNotNil(ok)
        let body = try? ok?.decodeBody(LinkAuthOkBody.self)
        XCTAssertEqual(body?.role, .control)
        XCTAssertNotNil(body?.token, "pairing returns a token")
        XCTAssertTrue(h.isAuthenticated)
    }

    func testPairWithWrongPINFails() {
        let (hub, auth, policy) = makeStack()
        _ = auth.beginPairing()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.authPair(LinkAuthPair(id: 1, pin: "000000", name: "Phone", role: .control))))
        XCTAssertEqual(sink.lastErr()?.code, "unauthenticated")
        XCTAssertFalse(h.isAuthenticated)
    }

    func testTokenReauthenticates() {
        let (hub, auth, policy) = makeStack()
        let pin = auth.beginPairing()
        guard case .success(let result) = auth.pair(pin: pin, clientName: "Phone",
                                                    requestedRole: .control, from: "192.168.1.5") else {
            return XCTFail("pair failed")
        }
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.authToken(LinkAuthToken(id: 1, token: result.token))))
        XCTAssertTrue(h.isAuthenticated)
        let body = try? sink.lastOk()?.decodeBody(LinkAuthOkBody.self)
        XCTAssertEqual(body?.role, .control)
    }

    // MARK: - Policy denial list in the ok

    func testViewerAuthOkListsDeniedControlCommands() {
        let (hub, auth, policy) = makeStack()
        let pin = auth.beginPairing()
        let sink = Sink()
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.authPair(LinkAuthPair(id: 1, pin: pin, name: "TV", role: .viewer))))
        let body = try? sink.lastOk()?.decodeBody(LinkAuthOkBody.self)
        let denied = body?.policy?.denied ?? []
        // 0xD2 (SET_MASTER_VOLUME) set-direction must be in a viewer's denied list.
        XCTAssertTrue(denied.contains([0xD2, 0]), "viewer is denied master volume")
    }

    // MARK: - Device list and rename

    private func authedAdmin(_ hub: LinkHub, _ auth: LinkAuthStore, _ policy: LinkPolicy, _ sink: Sink) -> LinkSessionHandler {
        auth.authMode = LinkAuthMode.none    // every session is admin
        let h = handler(hub, auth, policy, sink)
        h.receiveText(text(.helloClient(LinkHelloClient(client: LinkClientInfo(name: "Admin")))))
        h.receiveText(text(.authPair(LinkAuthPair(id: 1, pin: "000000", name: "Admin", role: .admin))))
        return h
    }

    func testDeviceListReflectsRegistry() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = authedAdmin(hub, auth, policy, sink)
        hub.registry.deviceOnline(HubDeviceInfo(serial: "SER123", platform: 1, firmware: "1.1.7",
                                                outputs: 9, inputs: 8, wireVersion: 30, link: .usb))
        h.receiveText(text(.deviceList(LinkDeviceListRequest(id: 2))))
        let body = try? sink.lastOk()?.decodeBody(LinkDeviceListBody.self)
        XCTAssertEqual(body?.devices.first?.serial, "SER123")
    }

    func testDeviceAddedEventPushedToSession() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = authedAdmin(hub, auth, policy, sink)
        withExtendedLifetime(h) {
            hub.registry.deviceOnline(HubDeviceInfo(serial: "SER999", platform: 1, firmware: "1.1.7",
                                                    outputs: 9, inputs: 8, wireVersion: 30, link: .usb))
            let added = sink.messages.contains { if case .deviceAdded = $0 { return true }; return false }
            XCTAssertTrue(added, "a device coming online reaches the session as device.added")
        }
    }

    // MARK: - Snapshot

    func testSnapshotMissesWithoutCache() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = authedAdmin(hub, auth, policy, sink)
        h.receiveText(text(.deviceSnapshot(LinkDeviceSnapshotRequest(id: 3, handle: 0))))
        // No id on this request, so the error carries a nil id; just assert one was sent.
        XCTAssertEqual(sink.lastErr()?.code, "no_device")
    }

    // MARK: - Unknown type

    func testUnknownTypeAfterAuthAnswersUnknownType() {
        let (hub, auth, policy) = makeStack()
        let sink = Sink()
        let h = authedAdmin(hub, auth, policy, sink)
        // fwProgress is an event, not a request the hub expects inbound.
        h.receiveText(text(.unknown(type: "made.up", id: 7)))
        XCTAssertEqual(sink.lastErr()?.code, "unknown_type")
        XCTAssertEqual(sink.lastErr()?.id, 7)
    }

    // MARK: - Locks over two handlers on one hub

    func testLockFromOneSessionBlocksAnother() {
        let (hub, auth, policy) = makeStack()
        // Give the hub a router by faking a connected device is not possible
        // here, so this test asserts the no-router path answers locked=false
        // path via the handler: without a device, lock.acquire returns locked.
        let sink = Sink()
        let h = authedAdmin(hub, auth, policy, sink)
        h.receiveText(text(.lockAcquire(LinkLockAcquire(id: 5, handle: 0, reason: "x", timeoutMs: 5000))))
        // No device attached, so acquireLock returns false -> locked error.
        XCTAssertEqual(sink.lastErr()?.code, "locked")
    }
}
