//
//  LinkRtaArbitrationTests.swift
//  DSPi ConsoleTests
//
//  The hub's analyser STOP rule (dspi_link_protocol_spec.md section 7.15): a
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

    private func get(_ command: VendorCommand, _ value: UInt16 = 0, tag: UInt16 = 1, length: UInt16 = 82) -> LinkCmdRequest {
        LinkCmdRequest(tag: tag, handle: 0, direction: .get, bRequest: command.number,
                       wValue: value, wIndex: command.usbIndex, wLength: length)
    }

    private func bands(_ ch: UInt16 = 0) -> LinkCmdRequest { get(VC.MEAS.RTA_BANDS, ch) }

    /// MEAS.RTA_START, _STOP and _RESET are zero-length SETs.
    private func control(_ command: VendorCommand) -> LinkCmdRequest {
        LinkCmdRequest(tag: 2, handle: 0, direction: .set, bRequest: command.number,
                       wIndex: command.usbIndex)
    }

    private static let controls: Set<UInt16> = [VC.MEAS.RTA_START.id, VC.MEAS.RTA_STOP.id, VC.MEAS.RTA_RESET.id]

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
        device.executed.filter { $0.commandID == VC.MEAS.RTA_STOP.id }.count
    }

    func testStopForwardedWhenAlone() {
        let dev = LinkFakeDevice(); dev.responsePayload = Data([0x01])
        let router = makeRouter(dev)
        run(router, bands(), from: 10)
        let r = run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(stopsReachingDevice(dev), 1, "the stopping session's own reads do not hold it")
    }

    func testStopSwallowedWhileAnotherSessionReadBandsRecently() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        clock += 4.9
        let r = run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.payload, Data(), "a zero-length SET's ACK carries nothing")
        XCTAssertEqual(r.tag, 2)
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testBandReadQueuedAheadOfStopCounts() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        let e = expectation(description: "both"); e.expectedFulfillmentCount = 2
        var stop: LinkCmdResponse?
        router.submit(bands(), session: session(11)) { _ in e.fulfill() }
        router.submit(control(VC.MEAS.RTA_STOP), session: session(10)) { stop = $0.response; e.fulfill() }
        wait(for: [e], timeout: 2)
        XCTAssertEqual(stop?.status, .ok)
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testStopForwardedOnceTheOtherReadIsOlderThanFiveSeconds() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        clock += 5.1
        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }

    func testStartAndBinReadsCountAsWatching() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, control(VC.MEAS.RTA_START), from: 11)
        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        run(router, get(VC.MEAS.RTA_BINS, tag: 3, length: 64), from: 12)
        clock += 6
        run(router, get(VC.MEAS.RTA_BANDS_ALL, tag: 3, length: 64), from: 13)
        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 0)
    }

    func testStopSwallowedWhileAnotherSessionPollsBands() {
        let dev = LinkFakeDevice()
        let scheduler = PollScheduler(device: dev, policy: LinkPolicy.bundled!, driveWithTimer: false)
        let router = makeRouter(dev, scheduler: scheduler)
        let spec = PollScheduler.PollSpec(handle: 0, req: VC.MEAS.RTA_BANDS.number, wValue: 0,
                                          wIndex: VC.MEAS.RTA_BANDS.usbIndex, len: 82)
        let granted = scheduler.subscribe(session: 11, role: .control, requests: [(slot: 0, spec: spec, hz: 10)])
        XCTAssertGreaterThan(granted.first?.grantedHz ?? 0, 0)

        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 0)

        // The stopping session's own subscription does not hold it.
        scheduler.unsubscribeAll(session: 11)
        _ = scheduler.subscribe(session: 10, role: .control, requests: [(slot: 0, spec: spec, hz: 10)])
        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
        scheduler.stop()
    }

    func testWatcherForgottenOnSessionClose() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        router.sessionDidClose(11)
        XCTAssertTrue(dev.executed.allSatisfy { !Self.controls.contains($0.commandID) },
                      "closing a session sends nothing to the device")
        run(router, control(VC.MEAS.RTA_STOP), from: 10)
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }

    func testStartAndResetAlwaysForwarded() {
        let dev = LinkFakeDevice()
        let router = makeRouter(dev)
        run(router, bands(), from: 11)
        run(router, control(VC.MEAS.RTA_START), from: 10)
        run(router, control(VC.MEAS.RTA_RESET), from: 10)
        let ops = dev.executed.filter { Self.controls.contains($0.commandID) }.map { $0.commandID }
        XCTAssertEqual(ops, [VC.MEAS.RTA_START.id, VC.MEAS.RTA_RESET.id])
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
        let remote = hub.openSession(role: .admin)
        let spec = PollScheduler.PollSpec(handle: hub.currentHandle, req: VC.MEAS.RTA_BANDS.number,
                                          wValue: 0, wIndex: VC.MEAS.RTA_BANDS.usbIndex, len: 82)
        _ = hub.subscribePolls(session: remote.id, requests: [(slot: 0, spec: spec, hz: 10)])

        func stop() -> LinkCmdResponse {
            let e = expectation(description: "stop")
            var out: LinkCmdResponse?
            let req = LinkCmdRequest(tag: 7, handle: hub.currentHandle, direction: .set,
                                     bRequest: VC.MEAS.RTA_STOP.number, wIndex: VC.MEAS.RTA_STOP.usbIndex)
            hub.submit(req, from: local.id) { out = $0; e.fulfill() }
            wait(for: [e], timeout: 2)
            return out!
        }
        XCTAssertEqual(stop().status, .ok)
        XCTAssertEqual(stopsReachingDevice(dev), 0)

        hub.closeSession(remote.id)
        _ = stop()
        XCTAssertEqual(stopsReachingDevice(dev), 1)
    }

    /// A legacy board is listed for remote clients but takes nothing paged:
    /// every command answers UNSUPPORTED and no poll is granted (spec 7.4).
    func testALegacyBoardIsListedButTakesNothing() {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rta-arb-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
        let info = HubDeviceInfo(serial: "OLD1", platform: 1, firmware: "1.1.6", firmwareBeta: 0,
                                 outputs: 9, inputs: nil, wireVersion: nil, link: .usb)
        hub.listLegacy(info)
        let listed = hub.registry.device(serial: "OLD1")
        XCTAssertNotNil(listed)
        XCTAssertNil(listed?.info.protocolVersion, "a legacy board carries no protocol")
        let handle = listed!.handle
        XCTAssertTrue(hub.isLegacy(handle: handle))

        let remote = hub.openSession(role: .admin)
        let e = expectation(description: "cmd")
        let req = LinkCmdRequest(tag: 3, handle: handle, direction: .get,
                                 bRequest: VC.SYS.PLATFORM.number, wIndex: VC.SYS.PLATFORM.usbIndex, wLength: 7)
        hub.submit(req, from: remote.id) { r in XCTAssertEqual(r.status, .unsupported); e.fulfill() }
        wait(for: [e], timeout: 2)
    }
}
