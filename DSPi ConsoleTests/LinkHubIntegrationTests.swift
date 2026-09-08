//
//  LinkHubIntegrationTests.swift
//  DSPi ConsoleTests
//
//  The hub with a fake device attached, and the local transport on top of it:
//  the defects found in review.  A burst of local writes must not be dropped;
//  a host-sourced notification must carry the session that wrote it; the
//  transport reports connected only once the hub can route; a resync reaches
//  the local UI as a re-read; the snapshot warms through the router.
//

import XCTest
import Combine
@testable import DSPi_Console

final class LinkHubIntegrationTests: XCTestCase {

    private func makeHub() -> (LinkHub, USBDevice) {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hubint-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
        return (hub, usb)
    }

    private func bulkBlob() -> Data {
        var d = Data(count: Int(BULK_PARAMS_SIZE)); d[0] = UInt8(WIRE_FORMAT_VERSION); return d
    }

    // MARK: Defect 1: local burst must not be rate limited

    func testLocalBurstOfWritesAllReachTheDevice() {
        let (hub, usb) = makeHub()
        let device = LinkFakeDevice()
        hub.attachDevice(device)
        let transport = HubTransport(hub: hub, usb: usb)

        for i in 0..<50 {
            transport.sendControlRequest(request: 0xD2, value: UInt16(i), index: 2, data: Data([0,0,0,0]))
        }
        // Drain: a final synchronous GET is ordered behind all the SETs.
        _ = transport.getControlRequest(request: 0x50, value: 9, index: 2, length: 4)

        let sets = device.executed.filter { $0.bRequest == 0xD2 }
        XCTAssertEqual(sets.count, 50, "every fire-and-forget local write must reach the device")
        XCTAssertEqual(sets.map { $0.wValue }, (0..<50).map { UInt16($0) }, "and in order")
    }

    func testRemoteSessionIsStillCapped() {
        let (hub, _) = makeHub()
        let device = LinkFakeDevice()
        hub.attachDevice(device)
        let remote = hub.openSession(role: .control)
        hub.closeSession(999)   // no-op, keeps the API honest

        var statuses = [LinkStatus]()
        let lock = NSLock()
        let done = expectation(description: "20 replies"); done.expectedFulfillmentCount = 20
        for i in 0..<20 {
            let req = LinkCmdRequest(tag: UInt16(i), handle: 0, direction: .set, bRequest: 0xD2,
                                     wIndex: 2, payload: Data([0,0,0,0]))
            hub.submit(req, from: remote.id) { r in
                lock.lock(); statuses.append(r.status); lock.unlock(); done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(statuses.contains(.rateLimited), "a remote burst past the cap is rate limited")
    }

    // MARK: Defect 2: attribution

    func testHostSourcedNotificationCarriesTheWritersSession() {
        let (hub, _) = makeHub()
        let device = LinkFakeDevice()
        hub.attachDevice(device)
        let a = hub.openSession(role: .control)
        let b = hub.openSession(role: .control)

        var originSeenByA: LinkSessionID?
        var originSeenByB: LinkSessionID?
        let gotA = expectation(description: "a"), gotB = expectation(description: "b")
        a.onNotify = { f in originSeenByA = f.origin; gotA.fulfill() }
        b.onNotify = { f in originSeenByB = f.origin; gotB.fulfill() }

        let wrote = expectation(description: "set done")
        let req = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                                 wIndex: 2, payload: Data([0,0,0,0]))
        hub.submit(req, from: a.id) { r in XCTAssertEqual(r.status, .ok); wrote.fulfill() }
        wait(for: [wrote], timeout: 3)

        // The device reports the change as a host write; the hub knows whose.
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1), origin: 1, receivedAt: Date()))
        wait(for: [gotA, gotB], timeout: 3)
        XCTAssertEqual(originSeenByA, a.id, "the writer sees its own session, so it drops the echo")
        XCTAssertEqual(originSeenByB, a.id, "the other session sees who wrote it, so it applies the change")
    }

    func testKnobSourcedNotificationHasNoOrigin() {
        let (hub, _) = makeHub()
        hub.attachDevice(LinkFakeDevice())
        let a = hub.openSession(role: .control)
        var origin: LinkSessionID = 99
        let got = expectation(description: "got")
        a.onNotify = { f in origin = f.origin; got.fulfill() }
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 5 /* GPIO */),
                                    origin: 0, receivedAt: Date()))
        wait(for: [got], timeout: 3)
        XCTAssertEqual(origin, 0)
    }

    func testAttributionExpiresAndReadsDoNotAttribute() {
        let (hub, _) = makeHub()
        let device = LinkFakeDevice()
        hub.attachDevice(device)
        let a = hub.openSession(role: .control)
        let done = expectation(description: "get done")
        let get = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                                 wValue: 9, wIndex: 2, wLength: 4)
        hub.submit(get, from: a.id) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        var origin: LinkSessionID = 99
        let got = expectation(description: "got")
        a.onNotify = { f in origin = f.origin; got.fulfill() }
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1), origin: 1, receivedAt: Date()))
        wait(for: [got], timeout: 3)
        XCTAssertEqual(origin, 0, "a read never claims a following host-sourced change")
    }

    // MARK: Defect 5: connected means routable

    func testTransportConnectedFollowsHubAttachment() {
        let (hub, usb) = makeHub()
        let transport = HubTransport(hub: hub, usb: usb)
        var states = [Bool]()
        let c = transport.isConnectedPublisher.sink { states.append($0) }
        XCTAssertFalse(transport.isConnected)
        hub.attachDevice(LinkFakeDevice())
        XCTAssertTrue(transport.isConnected, "connected only once the hub can route")
        hub.detachDevice()
        XCTAssertFalse(transport.isConnected)
        XCTAssertEqual(states, [false, true, false])
        c.cancel()
    }

    func testGetThroughTransportReturnsDeviceBytes() {
        let (hub, usb) = makeHub()
        let device = LinkFakeDevice(); device.responsePayload = Data([9, 8, 7, 6])
        hub.attachDevice(device)
        let transport = HubTransport(hub: hub, usb: usb)
        XCTAssertEqual(transport.getControlRequest(request: 0x50, value: 9, index: 2, length: 4),
                       Data([9, 8, 7, 6]))
    }

    // MARK: Defect 6: resync reaches the local UI

    func testResyncArrivesAsBulkInvalidated() {
        let (hub, usb) = makeHub()
        hub.attachDevice(LinkFakeDevice())
        let transport = HubTransport(hub: hub, usb: usb)
        let got = expectation(description: "bulk invalidated")
        var seen: LinkNotification?
        let token = transport.addNotificationObserver { n in
            if n.eventID == 0x03 { seen = n; got.fulfill() }
        }
        hub.detachDevice()   // sends RESYNC reason 1 to every session
        wait(for: [got], timeout: 3)
        XCTAssertEqual(seen?.origin, 0)
        token.cancel()
    }

    // MARK: Defect 4: snapshot warms through the router

    func testSnapshotWarmsThroughTheRouterOnAttach() {
        let (hub, _) = makeHub()
        let device = LinkFakeDevice()
        let blob = bulkBlob()
        device.responder = { req in
            LinkCmdResponse(tag: req.tag, status: .ok,
                            payload: req.bRequest == REQ_GET_ALL_PARAMS ? blob : Data())
        }
        hub.attachDevice(device)
        let deadline = Date().addingTimeInterval(3)
        while hub.currentSnapshot() == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(hub.currentSnapshot()?.wireVersion, WIRE_FORMAT_VERSION)
        XCTAssertTrue(device.executedCodes.contains(REQ_GET_ALL_PARAMS),
                      "the bulk read went through the device via the router, not a side channel")
    }

    // MARK: Review round 2

    /// P1: a revoked client is cut off while connected, not at its next login.
    func testRevokeClosesTheLiveSession() {
        let (hub, _) = makeHub()
        hub.attachDevice(LinkFakeDevice())
        let pin = hub.auth.beginPairing()
        guard case .success(let paired) = hub.auth.pair(pin: pin, clientName: "Phone",
                                                        requestedRole: .admin, from: "10.0.0.9") else {
            return XCTFail("pair")
        }
        let s = hub.openSession(role: .admin)
        s.clientID = paired.client.id
        var closedByHub = false
        s.onClosedByHub = { closedByHub = true }
        let before = hub.sessionCount

        hub.auth.revoke(cid: paired.client.id)

        XCTAssertTrue(closedByHub, "the session learns it was closed so the socket can go")
        XCTAssertEqual(hub.sessionCount, before - 1)
        let e = expectation(description: "refused")
        let req = LinkCmdRequest(tag: 1, handle: hub.currentHandle, direction: .set, bRequest: 0xD2,
                                 wIndex: 2, payload: Data([0,0,0,0]))
        hub.submit(req, from: s.id) { r in XCTAssertEqual(r.status, .noDevice); e.fulfill() }
        wait(for: [e], timeout: 3)
    }

    /// P1: a role change applies to the live session on its next command.
    func testRoleChangeAppliesToTheLiveSession() {
        let (hub, _) = makeHub()
        hub.attachDevice(LinkFakeDevice())
        let pin = hub.auth.beginPairing()
        guard case .success(let paired) = hub.auth.pair(pin: pin, clientName: "TV",
                                                        requestedRole: .viewer, from: "10.0.0.9") else {
            return XCTFail("pair")
        }
        let s = hub.openSession(role: .viewer)
        s.clientID = paired.client.id
        let req = LinkCmdRequest(tag: 1, handle: hub.currentHandle, direction: .set, bRequest: 0xD2,
                                 wIndex: 2, payload: Data([0,0,0,0]))

        let denied = expectation(description: "denied")
        hub.submit(req, from: s.id) { r in XCTAssertEqual(r.status, .denied); denied.fulfill() }
        wait(for: [denied], timeout: 3)

        hub.auth.setRole(cid: paired.client.id, role: .control)

        let ok = expectation(description: "ok")
        hub.submit(req, from: s.id) { r in XCTAssertEqual(r.status, .ok); ok.fulfill() }
        wait(for: [ok], timeout: 3)
    }

    /// P1: a replacement board plugged in during the old one's offline grace
    /// gets the next handle, and routing follows it.
    func testReplacementDeviceIsRoutableOnItsOwnHandle() {
        let (hub, _) = makeHub()
        hub.attachDevice(LinkFakeDevice(serial: "AAAA0000AAAA0000"))
        XCTAssertEqual(hub.currentHandle, 0)
        hub.detachDevice()
        let b = LinkFakeDevice(serial: "BBBB0000BBBB0000")
        hub.attachDevice(b)
        XCTAssertEqual(hub.currentHandle, 1, "A keeps handle 0 through its grace; B is 1")
        XCTAssertEqual(hub.registry.device(serial: "BBBB0000BBBB0000")?.handle, 1)

        let s = hub.openSession(role: .control)
        let onB = expectation(description: "B answers on 1"), onOld = expectation(description: "0 is dead")
        hub.submit(LinkCmdRequest(tag: 1, handle: 1, direction: .get, bRequest: 0x50, wValue: 9,
                                  wIndex: 2, wLength: 4), from: s.id) { r in
            XCTAssertEqual(r.status, .ok); onB.fulfill()
        }
        hub.submit(LinkCmdRequest(tag: 2, handle: 0, direction: .get, bRequest: 0x50, wValue: 9,
                                  wIndex: 2, wLength: 4), from: s.id) { r in
            XCTAssertEqual(r.status, .noDevice); onOld.fulfill()
        }
        wait(for: [onB, onOld], timeout: 3)
        XCTAssertEqual(b.executedCodes.filter { $0 == 0x50 }.count, 1)
    }

    /// P1: switching boards is a new USB generation with no `false` between
    /// the two `true`s; the hub must re-attach to the new board.
    func testUSBSwitchReattachesToTheNewBoard() {
        let (hub, _) = makeHub()
        let a = LinkFakeDevice(serial: "AAAA0000AAAA0000")
        let b = LinkFakeDevice(serial: "BBBB0000BBBB0000")
        var next: HubDevice = a
        hub.usbDeviceFactory = { _ in next }

        hub.usbConnectionChanged(connected: true, generation: 1)
        XCTAssertEqual(hub.registry.device(serial: a.info.serial)?.state, .online)
        hub.usbConnectionChanged(connected: true, generation: 1)   // repeat: same open
        XCTAssertEqual(hub.registry.devices.count, 1, "a repeated true for the same open attaches nothing new")

        next = b
        hub.usbConnectionChanged(connected: true, generation: 2)   // switch, no false between
        XCTAssertEqual(hub.registry.device(serial: b.info.serial)?.state, .online)
        XCTAssertEqual(hub.registry.device(serial: a.info.serial)?.state, .offline)
        XCTAssertEqual(hub.currentHandle, 1)

        hub.usbConnectionChanged(connected: false, generation: 2)
        XCTAssertFalse(hub.isDeviceAttached)
        hub.usbConnectionChanged(connected: false, generation: 2)  // the flag's stray false: no-op
        XCTAssertFalse(hub.isDeviceAttached)
    }

    /// P2: attribution follows dispatch order, so B writing before A's
    /// notification is read does not turn A's change into B's echo.
    func testAttributionFollowsWriteOrderNotLatestWriter() {
        let (hub, _) = makeHub()
        hub.attachDevice(LinkFakeDevice())
        let a = hub.openSession(role: .control), b = hub.openSession(role: .control)
        var origins = [LinkSessionID]()
        let got = expectation(description: "two"); got.expectedFulfillmentCount = 2
        a.onNotify = { f in origins.append(f.origin); got.fulfill() }

        let wrote = expectation(description: "both wrote"); wrote.expectedFulfillmentCount = 2
        let req = LinkCmdRequest(tag: 1, handle: hub.currentHandle, direction: .set, bRequest: 0xD2,
                                 wIndex: 2, payload: Data([0,0,0,0]))
        hub.submit(req, from: a.id) { _ in wrote.fulfill() }
        hub.submit(req, from: b.id) { _ in wrote.fulfill() }
        wait(for: [wrote], timeout: 3)

        // Both notifications arrive after both writes: still A then B.
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1, seq: 1), origin: 1, receivedAt: Date()))
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1, seq: 2), origin: 1, receivedAt: Date()))
        wait(for: [got], timeout: 3)
        XCTAssertEqual(origins, [a.id, b.id])
    }

    // MARK: Review round 3

    /// A refused write must not leave an attribution behind: 7's write fails,
    /// 9's succeeds, and the one notification belongs to 9.
    func testFailedWriteDoesNotStealTheNextAttribution() {
        let (hub, _) = makeHub()
        let device = LinkFakeDevice()
        // Refuse the write whose payload starts with 0xFF.
        device.responder = { req in
            LinkCmdResponse(tag: req.tag, status: req.payload.first == 0xFF ? .error : .ok)
        }
        hub.attachDevice(device)
        let seven = hub.openSession(role: .control), nine = hub.openSession(role: .control)
        var origin: LinkSessionID = 0
        let got = expectation(description: "notified")
        nine.onNotify = { f in origin = f.origin; got.fulfill() }

        let wrote = expectation(description: "both"); wrote.expectedFulfillmentCount = 2
        hub.submit(LinkCmdRequest(tag: 1, handle: hub.currentHandle, direction: .set, bRequest: 0xD2,
                                  wIndex: 2, payload: Data([0xFF, 0, 0, 0])), from: seven.id) { r in
            XCTAssertEqual(r.status, .error); wrote.fulfill()
        }
        hub.submit(LinkCmdRequest(tag: 2, handle: hub.currentHandle, direction: .set, bRequest: 0xD2,
                                  wIndex: 2, payload: Data([0, 0, 0, 0])), from: nine.id) { r in
            XCTAssertEqual(r.status, .ok); wrote.fulfill()
        }
        wait(for: [wrote], timeout: 3)
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 1), origin: 1, receivedAt: Date()))
        wait(for: [got], timeout: 3)
        XCTAssertEqual(origin, nine.id, "the failed write left nothing in the queue")
    }

    /// Closing a session clears the callbacks it owns, so a callback that
    /// captured the session cannot keep it alive.
    func testClosedSessionDeallocates() {
        let (hub, _) = makeHub()
        var s: LinkHubSession? = hub.openSession(role: .control)
        weak var weakSession = s
        s!.onClosedByHub = { [s] in _ = s }      // the cycle the review found
        hub.closeSession(s!.id)
        s = nil
        XCTAssertNil(weakSession, "a closed session is released once the hub drops its callbacks")
    }
}
