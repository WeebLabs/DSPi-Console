//
//  LinkClientTests.swift
//  DSPi ConsoleTests
//
//  End-to-end tests of LinkClient against the real LinkServer over loopback:
//  a hub with a fake device, a WebSocket on an ephemeral port, and the whole
//  session lifecycle (hello, pairing, token reconnect, commands, notification
//  relay, snapshot, revocation, reconnect).  Nothing is mocked below the
//  socket, so these cover the wire format as well as the client's logic.
//

import XCTest
import Combine
@testable import DSPi_Console

final class LinkClientTests: XCTestCase {

    private var hub: LinkHub!
    private var auth: LinkAuthStore!
    private var server: LinkServer!
    private var device: LinkFakeDevice!
    private var port = 0
    private var clients: [LinkClient] = []
    private var storeURL: URL!

    /// The four bytes the fake answers every GET but the bulk read with.
    private let shortPayload = Data([0x11, 0x22, 0x33, 0x44])

    override func setUpWithError() throws {
        try super.setUpWithError()

        let usb = USBDevice(startMonitoring: false)
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lct-\(UUID().uuidString).json")
        auth = LinkAuthStore(storeURL: storeURL)
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        hub = LinkHub(usb: usb, policy: policy, auth: auth)

        device = LinkFakeDevice()
        device.responsePayload = shortPayload
        // The hub warms its snapshot with a bulk read the moment the device
        // attaches, so the responder has to answer 0xA0 with a real blob.
        let bulk = Self.makeBulkBlob()
        let short = shortPayload
        device.responder = { request in
            if request.bRequest == REQ_GET_ALL_PARAMS {
                return LinkCmdResponse(tag: request.tag, status: .ok, payload: bulk)
            }
            return LinkCmdResponse(tag: request.tag, status: .ok,
                                   payload: request.direction == .get ? short : Data())
        }
        hub.attachDevice(device)

        server = LinkServer(hub: hub, auth: auth, policy: policy)
        try server.start(port: 0)
        port = try XCTUnwrap(server.boundPort)
    }

    override func tearDown() {
        clients.forEach { $0.disconnect() }
        clients = []
        server?.stop()
        server = nil
        hub = nil
        auth = nil
        device = nil
        if let storeURL = storeURL { try? FileManager.default.removeItem(at: storeURL) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private static func makeBulkBlob() -> Data {
        var blob = Data(count: Int(BULK_PARAMS_SIZE))
        blob[0] = UInt8(WIRE_FORMAT_VERSION)
        return blob
    }

    private var hubURL: URL { URL(string: "ws://127.0.0.1:\(port)/dspi/v1")! }

    private func makeClient() -> LinkClient {
        let client = LinkClient()
        clients.append(client)
        return client
    }

    // MARK: - Waiting helpers

    @discardableResult
    private func waitForState(_ client: LinkClient, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ predicate: @escaping (LinkClientState) -> Bool) -> LinkClientState? {
        let done = expectation(description: "state")
        var seen: LinkClientState?
        // CurrentValueSubject replays its current value, so a state already
        // reached is caught rather than waited for forever.
        let cancellable = client.statePublisher.sink { state in
            guard seen == nil, predicate(state) else { return }
            seen = state
            done.fulfill()
        }
        let result = XCTWaiter.wait(for: [done], timeout: timeout)
        cancellable.cancel()
        if result != .completed {
            XCTFail("state never satisfied the predicate (last: \(client.state))", file: file, line: line)
        }
        return seen
    }

    private func waitForDevices(_ client: LinkClient, timeout: TimeInterval = 5,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ predicate: @escaping ([LinkDeviceInfo]) -> Bool) {
        let done = expectation(description: "devices")
        var fulfilled = false
        let cancellable = client.devicesPublisher.sink { devices in
            guard !fulfilled, predicate(devices) else { return }
            fulfilled = true
            done.fulfill()
        }
        let result = XCTWaiter.wait(for: [done], timeout: timeout)
        cancellable.cancel()
        if result != .completed {
            XCTFail("device list never matched (last: \(client.devices))", file: file, line: line)
        }
    }

    /// Connect, pair with a fresh PIN, and wait until the session is ready.
    @discardableResult
    private func connectAndPair(name: String, role: LinkRole = .control,
                                file: StaticString = #filePath, line: UInt = #line)
        throws -> (client: LinkClient, token: String) {
        let client = makeClient()
        client.connect(to: hubURL, clientName: name, token: nil)
        waitForState(client, file: file, line: line) { $0 == .awaitingAuth(needsPairing: true) }

        let pin = auth.beginPairing()
        let paired = expectation(description: "paired")
        var token: String?
        client.pair(pin: pin, clientName: name, role: role) { result in
            token = try? result.get()
            paired.fulfill()
        }
        wait(for: [paired], timeout: 5)
        waitForState(client, file: file, line: line) { $0 == .ready }
        return (client, try XCTUnwrap(token, file: file, line: line))
    }

    private func run(_ client: LinkClient, _ request: LinkCmdRequest,
                     timeout: TimeInterval = 5) throws -> LinkCmdResponse {
        let done = expectation(description: "command")
        var response: LinkCmdResponse?
        client.command(request) { r in
            response = r
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return try XCTUnwrap(response)
    }

    // MARK: - Pairing

    func testPairingReachesReadyAndListsDevices() throws {
        let client = makeClient()
        client.connect(to: hubURL, clientName: "Pairing Test", token: nil)

        waitForState(client) { $0 == .awaitingAuth(needsPairing: true) }
        XCTAssertEqual(client.hubInfo?.kind, .console)
        XCTAssertTrue(client.capabilities.contains(LinkCapability.cmd.rawValue))
        XCTAssertEqual(client.limits?.maxPayload, LinkSessionHandler.maxPayload)

        let pin = auth.beginPairing()
        let paired = expectation(description: "paired")
        var token: String?
        client.pair(pin: pin, clientName: "Pairing Test", role: .control) { result in
            switch result {
            case .success(let t): token = t
            case .failure(let e): XCTFail("pairing failed: \(e)")
            }
            paired.fulfill()
        }
        wait(for: [paired], timeout: 5)

        XCTAssertFalse(token?.isEmpty ?? true)
        waitForState(client) { $0 == .ready }
        XCTAssertNotEqual(client.sessionID, 0)
        XCTAssertEqual(client.role, .control)
        waitForDevices(client) { $0.count == 1 }
        XCTAssertEqual(client.devices.first?.serial, device.info.serial)
    }

    func testWrongPINIsRejectedAndLeavesTheClientAwaitingAuth() throws {
        let client = makeClient()
        client.connect(to: hubURL, clientName: "Bad PIN", token: nil)
        waitForState(client) { $0 == .awaitingAuth(needsPairing: true) }

        auth.beginPairing()
        let done = expectation(description: "rejected")
        var failure: LinkClientError?
        client.pair(pin: "000001", clientName: "Bad PIN", role: .control) { result in
            if case .failure(let e) = result { failure = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        guard case .rejected(let code, _)? = failure else {
            return XCTFail("expected a rejection, got \(String(describing: failure))")
        }
        XCTAssertEqual(code, LinkErrorCode.unauthenticated)
        XCTAssertEqual(client.state, .awaitingAuth(needsPairing: true))
        XCTAssertEqual(client.sessionID, 0)
    }

    // MARK: - Token reconnect

    func testTokenReconnectSkipsPairing() throws {
        let (first, token) = try connectAndPair(name: "Token Test")
        first.disconnect()

        let second = makeClient()
        second.connect(to: hubURL, clientName: "Token Test", token: token)
        waitForState(second) { $0 == .ready }
        XCTAssertNotEqual(second.sessionID, 0)
        XCTAssertEqual(second.role, .control)
        waitForDevices(second) { $0.count == 1 }
    }

    // MARK: - Commands

    func testCommandsTunnelGetsAndSetsAndHonourTheRole() throws {
        let (client, _) = try connectAndPair(name: "Command Test")

        let get = try run(client, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                                 bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertEqual(get.status, .ok)
        XCTAssertEqual(get.payload, shortPayload)

        let set = try run(client, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .set,
                                                 bRequest: REQ_SET_MASTER_VOLUME, wValue: 0, wIndex: 0,
                                                 payload: Data([0xEC])))
        XCTAssertEqual(set.status, .ok)

        // A viewer may read but not write; the hub answers DENIED (spec 8.1).
        let (viewer, _) = try connectAndPair(name: "Viewer Test", role: .viewer)
        XCTAssertEqual(viewer.role, .viewer)
        let denied = try run(viewer, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .set,
                                                    bRequest: REQ_SET_MASTER_VOLUME, wValue: 0, wIndex: 0,
                                                    payload: Data([0xEC])))
        XCTAssertEqual(denied.status, .denied)

        let viewerGet = try run(viewer, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                                       bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertEqual(viewerGet.status, .ok)
    }

    func testCommandBeforeReadyAnswersNoDevice() throws {
        let client = makeClient()
        let response = try run(client, LinkCmdRequest(tag: 7, handle: 0, direction: .get,
                                                      bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertEqual(response.status, .noDevice)
        XCTAssertEqual(response.tag, 7)
    }

    // MARK: - Notification relay

    func testNotificationsReachEverySessionWithTheWriterAsOrigin() throws {
        let (a, _) = try connectAndPair(name: "Writer")
        let (b, _) = try connectAndPair(name: "Listener")

        let notifiedA = expectation(description: "A notified")
        let notifiedB = expectation(description: "B notified")
        var frameA: LinkNotifyFrame?
        var frameB: LinkNotifyFrame?
        a.onNotify = { frame in
            guard frameA == nil else { return }
            frameA = frame
            notifiedA.fulfill()
        }
        b.onNotify = { frame in
            guard frameB == nil else { return }
            frameB = frame
            notifiedB.fulfill()
        }

        let set = try run(a, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .set,
                                            bRequest: REQ_SET_MASTER_VOLUME, wValue: 0, wIndex: 0,
                                            payload: Data([0xEC])))
        XCTAssertEqual(set.status, .ok)

        // Source 1 is PARAM_SRC_HOST_SET, which is what the hub attributes to
        // the session that just wrote.
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1),
                                    origin: 1, receivedAt: Date()))

        wait(for: [notifiedA, notifiedB], timeout: 5)
        XCTAssertEqual(frameA?.origin, a.sessionID)
        XCTAssertEqual(frameB?.origin, a.sessionID)
        XCTAssertEqual(frameA?.packet.first, 0x02)
        XCTAssertEqual(frameB?.packet, frameA?.packet)
    }

    // MARK: - Snapshot

    func testSnapshotReturnsTheCachedBulkBlob() throws {
        let (client, _) = try connectAndPair(name: "Snapshot Test")

        var body: LinkSnapshotBody?
        // The hub warms the cache asynchronously on attach; give it a few
        // tries rather than assuming the first read is warm.
        for _ in 0..<10 {
            let done = expectation(description: "snapshot")
            client.snapshot(handle: hub.currentHandle) { result in
                if case .success(let b) = result { body = b }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            if body != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let snapshot = try XCTUnwrap(body)
        XCTAssertEqual(snapshot.handle, Int(hub.currentHandle))
        XCTAssertEqual(snapshot.wireVersion, WIRE_FORMAT_VERSION)
        let bulk = try XCTUnwrap(snapshot.bulkB64.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(bulk.count, Int(BULK_PARAMS_SIZE))
        XCTAssertEqual(bulk.first, UInt8(WIRE_FORMAT_VERSION))
    }

    // MARK: - Open access

    func testOpenAccessHubNeedsNoPairing() throws {
        auth.authMode = .none

        let client = makeClient()
        client.connect(to: hubURL, clientName: "Open Access", token: nil)
        waitForState(client) { $0 == .ready }

        XCTAssertNotEqual(client.sessionID, 0)
        XCTAssertEqual(client.role, .admin)
        waitForDevices(client) { $0.count == 1 }

        let response = try run(client, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                                      bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.payload, shortPayload)
    }

    // MARK: - Revocation

    func testRevokedClientFailsAndStopsCommanding() throws {
        let (client, _) = try connectAndPair(name: "Revoked")
        let cid = try XCTUnwrap(auth.clients.last?.id)

        auth.revoke(cid: cid)

        let failure = waitForState(client) { if case .failed = $0 { return true }; return false }
        guard case .failed(let reason)? = failure else {
            return XCTFail("expected a failed state, got \(String(describing: failure))")
        }
        XCTAssertTrue(reason.lowercased().contains("revok"), "unexpected reason: \(reason)")

        let response = try run(client, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                                      bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertNotEqual(response.status, .ok)
    }

    // MARK: - Reuse

    func testDisconnectThenReconnectOnTheSameClient() throws {
        let (client, token) = try connectAndPair(name: "Reusable")

        client.disconnect()
        waitForState(client) { $0 == .disconnected }

        client.connect(to: hubURL, clientName: "Reusable", token: token)
        waitForState(client) { $0 == .ready }
        waitForDevices(client) { $0.count == 1 }

        let response = try run(client, LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                                      bRequest: REQ_GET_STATUS, wValue: 9, wIndex: 2, wLength: 4))
        XCTAssertEqual(response.status, .ok)
    }
}
