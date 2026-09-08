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
}
