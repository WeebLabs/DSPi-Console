//
//  LinkRtaArbitrationTests.swift
//  DSPi ConsoleTests
//
//  The hub's analyser STOP rule (dspi_link_protocol_spec.md section 7.10): a
//  session's RTA STOP reaches the device only when no other session is
//  watching, by recent band/bin reads, START, or a band/bin poll subscription.
//

import XCTest
@testable import DSPi_Console

final class LinkRtaArbitrationTests: XCTestCase {

    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeRouter(_ device: LinkFakeDevice,
                            scheduler: PollScheduler? = nil) -> CommandRouter {
        let router = CommandRouter(handle: 0, device: device, policy: LinkPolicy.bundled!)
        router.now = { [unowned self] in self.clock }
        if let scheduler = scheduler {
            router.otherSessionPolls = { [weak scheduler] codes, excluding in
                scheduler?.sessionsSubscribed(toAnyOf: codes, excluding: excluding) ?? false
            }
        }
        return router
    }

    private func session(_ id: LinkSessionID) -> RouterSession { RouterSession(id: id, role: .control) }

    private func bands(_ ch: UInt16 = 0) -> LinkCmdRequest {
        LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: REQ_RTA_GET_BANDS,
                       wValue: ch, wIndex: 2, wLength: 82)
    }

    private func control(_ op: UInt16) -> LinkCmdRequest {
        LinkCmdRequest(tag: 2, handle: 0, direction: .get, bRequest: REQ_RTA_CONTROL,
                       wValue: op, wIndex: 2, wLength: 1)
    }

    /// Submit and wait, so each call lands in a known order against the clock.
    @discardableResult
    private func run(_ router: CommandRouter, _ req: LinkCmdRequest, from id: LinkSessionID) -> LinkCmdResponse {
        let e = expectation(description: "done")
        var out: LinkCmdResponse?
        router.submit(req, session: session(id)) { out = $0.response; e.fulfill() }
        wait(for: [e], timeout: 2)
        return out!
    }

    private func stopsReachingDevice(_ device: LinkFakeDevice) -> Int {
        device.executed.filter { $0.bRequest == REQ_RTA_CONTROL && $0.wValue == RTA_CTL_STOP }.count
    }

    func testStopForwardedWhenAlone() {
        let dev = LinkFakeDevice(); dev.responsePayload = Data([0x01])
        let router = makeRouter(dev)
        run(router, bands(), from: 10)
        let r = run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(stopsReachingDevice(dev), 1, "the stopping session's own reads do not hold it")
    }

    func testStopSwallowedWhileAnotherSessionReadBandsRecently() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        clock += 4.9
        let r = run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.payload, Data([0x01]), "the ack the device would have sent")
        XCTAssertEqual(r.tag, 2)
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testBandReadQueuedAheadOfStopCounts() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        let e = expectation(description: "both"); e.expectedFulfillmentCount = 2
        var stop: LinkCmdResponse?
        router.submit(bands(), session: session(11)) { _ in e.fulfill() }
        router.submit(control(RTA_CTL_STOP), session: session(10)) { stop = $0.response; e.fulfill() }
        wait(for: [e], timeout: 2)
        XCTAssertEqual(stop?.payload, Data([0x01]))
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testStopForwardedOnceTheOtherReadIsOlderThanFiveSeconds() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        clock += 5.1
        run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }

    func testStartAndBinReadsCountAsWatching() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, control(RTA_CTL_START), from: 11)
        run(router, control(RTA_CTL_STOP), from: 10)
        run(router, LinkCmdRequest(tag: 3, handle: 0, direction: .get, bRequest: REQ_RTA_GET_BINS,
                                   wValue: 0, wIndex: 2, wLength: 64), from: 12)
        clock += 6
        run(router, LinkCmdRequest(tag: 3, handle: 0, direction: .get, bRequest: REQ_RTA_GET_BANDS_ALL,
                                   wValue: 0, wIndex: 2, wLength: 64), from: 13)
        run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testStopSwallowedWhileAnotherSessionPollsBands() {
        let dev = LinkFakeDevice()
        let scheduler = PollScheduler(device: dev, policy: LinkPolicy.bundled!, driveWithTimer: false)
        let router = makeRouter(dev, scheduler: scheduler)
        let spec = PollScheduler.PollSpec(handle: 0, req: REQ_RTA_GET_BANDS, wValue: 0, wIndex: 2, len: 82)
        let granted = scheduler.subscribe(session: 11, role: .control, requests: [(slot: 0, spec: spec, hz: 10)])
        XCTAssertGreaterThan(granted.first?.grantedHz ?? 0, 0)

        run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 0)

        // The stopping session's own subscription does not hold it.
        scheduler.unsubscribeAll(session: 11)
        _ = scheduler.subscribe(session: 10, role: .control, requests: [(slot: 0, spec: spec, hz: 10)])
        run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
        scheduler.stop()
    }

    func testWatcherForgottenOnSessionClose() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        router.sessionDidClose(11)
        XCTAssertTrue(dev.executed.allSatisfy { $0.bRequest != REQ_RTA_CONTROL },
                      "closing a session sends nothing to the device")
        run(router, control(RTA_CTL_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }

    func testStartAndResetAlwaysForwarded() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        run(router, control(RTA_CTL_START), from: 10)
        run(router, control(RTA_CTL_RESET_AVG), from: 10)
        let ops = dev.executed.filter { $0.bRequest == REQ_RTA_CONTROL }.map { $0.wValue }
        XCTAssertEqual(ops, [RTA_CTL_START, RTA_CTL_RESET_AVG])
    }

    /// The hub wires its own scheduler into the router, and the local UI
    /// (session 1) is held by a remote session's poll like anyone else.
    func testHubWiresSchedulerIntoStopRule() {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rta-arb-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
        let dev = LinkFakeDevice()
        hub.attachDevice(dev)
        let local = hub.openSession(role: .admin, id: LinkHub.localSessionID)
        let remote = hub.openSession(role: .control)
        let spec = PollScheduler.PollSpec(handle: hub.currentHandle, req: REQ_RTA_GET_BANDS,
                                          wValue: 0, wIndex: 2, len: 82)
        _ = hub.subscribePolls(session: remote.id, requests: [(slot: 0, spec: spec, hz: 10)])

        func stop() -> LinkCmdResponse {
            let e = expectation(description: "stop")
            var out: LinkCmdResponse?
            let req = LinkCmdRequest(tag: 7, handle: hub.currentHandle, direction: .get,
                                     bRequest: REQ_RTA_CONTROL, wValue: RTA_CTL_STOP, wIndex: 2, wLength: 1)
            hub.submit(req, from: local.id) { out = $0; e.fulfill() }
            wait(for: [e], timeout: 2)
            return out!
        }
        XCTAssertEqual(stop().payload, Data([0x01]))
        XCTAssertEqual(stopsReachingDevice(dev), 0)

        hub.closeSession(remote.id)
        _ = stop()
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }
}
