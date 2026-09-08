//
//  LinkPollSchedulerTests.swift
//  DSPi ConsoleTests
//
//  Behaviour tests for PollScheduler (spec 7.6, 8.4): read-only gating,
//  rate capping, dedup of identical polls, per-session bandwidth budget,
//  unsubscribe teardown and the failure back-off.  Time is driven with the
//  scheduler's manual `tick()` (driveWithTimer: false) rather than wall-clock
//  waits, so the assertions are exact rather than timing-dependent.
//

import XCTest
@testable import DSPi_Console

/// A thread-safe fake device that returns a fixed payload and counts how many
/// times each spec was executed.
private final class FakePollDevice: HubDevice {
    var info: HubDeviceInfo
    var generation: UInt64 = 0
    var isConnected: Bool = true

    private let lock = NSLock()
    private var counts: [UInt8: Int] = [:]   // keyed by bRequest
    private var total = 0
    var status: LinkStatus = .ok
    var payload = Data([0xAA, 0xBB, 0xCC])

    init() {
        info = HubDeviceInfo(serial: "E46058388B1A2E2C", platform: 1, firmware: "1.1.7",
                             outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
    }

    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse {
        lock.lock()
        counts[request.bRequest, default: 0] += 1
        total += 1
        let st = status
        lock.unlock()
        return LinkCmdResponse(tag: request.tag, status: st,
                               payload: request.direction == .get ? payload : Data())
    }

    func executeCount(req: UInt8) -> Int { lock.lock(); defer { lock.unlock() }; return counts[req] ?? 0 }
    var totalExecuted: Int { lock.lock(); defer { lock.unlock() }; return total }
}

final class LinkPollSchedulerTests: XCTestCase {

    private func policy() -> LinkPolicy { LinkPolicy.bundled! }

    private func scheduler(_ dev: FakePollDevice,
                           maxHz: Double = 20, budget: Double = 200_000) -> PollScheduler {
        // driveWithTimer:false so tick() is the only clock; tickResolution 0.05
        // means a 20 hz poll executes on every tick (20 * 0.05 == 1).
        PollScheduler(device: dev, policy: policy(),
                      pollMaxHz: maxHz, pollBudgetBps: budget,
                      tickResolution: 0.05, driveWithTimer: false)
    }

    // 0x50 GET_STATUS wValue 9 is a read poll; 0xD2 SET_MASTER_VOLUME is control.
    private let statusSpec = PollScheduler.PollSpec(handle: 0, req: 0x50, wValue: 9, wIndex: 2, len: 27)

    func testViewerReceivesPayloadsForReadPoll() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)
        defer { sched.stop() }

        var received: [Data] = []
        sched.onPoll = { _, slot, _, payload in
            XCTAssertEqual(slot, 0)
            received.append(payload)
        }

        let granted = sched.subscribe(session: 1, role: .viewer,
                                      requests: [(slot: 0, spec: statusSpec, hz: 10)])
        XCTAssertEqual(granted.first?.grantedHz, 10)
        XCTAssertEqual(sched.activeSpecCount, 1)

        for _ in 0..<10 { sched.tick() }
        XCTAssertFalse(received.isEmpty, "the viewer should receive polled payloads")
        XCTAssertEqual(received.first, dev.payload)
    }

    func testNonReadPollIsRejectedAndNeverExecuted() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)
        defer { sched.stop() }

        // 0xD2 SET_MASTER_VOLUME is class control, never read -> refused.
        let setSpec = PollScheduler.PollSpec(handle: 0, req: 0xD2, wValue: 0, wIndex: 2, len: 4)
        let granted = sched.subscribe(session: 1, role: .admin,
                                      requests: [(slot: 0, spec: setSpec, hz: 10)])
        XCTAssertEqual(granted.first?.grantedHz, 0, "a non-read command must be granted 0 hz")
        XCTAssertEqual(sched.activeSpecCount, 0, "a refused poll must not start a spec")

        for _ in 0..<10 { sched.tick() }
        XCTAssertEqual(dev.executeCount(req: 0xD2), 0, "a refused poll must never be executed")
    }

    func testGrantedRateIsCappedAtPollMaxHz() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)   // maxHz 20
        defer { sched.stop() }

        let granted = sched.subscribe(session: 1, role: .control,
                                      requests: [(slot: 0, spec: statusSpec, hz: 100)])
        XCTAssertEqual(granted.first?.grantedHz, 20, "requested 100 hz must be capped to pollMaxHz")
    }

    func testIdenticalPollFromTwoSessionsExecutesOncePerTick() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)
        defer { sched.stop() }

        // Both at 20 hz so the deduped spec executes exactly once per tick.
        _ = sched.subscribe(session: 1, role: .viewer, requests: [(slot: 0, spec: statusSpec, hz: 20)])
        _ = sched.subscribe(session: 2, role: .viewer, requests: [(slot: 3, spec: statusSpec, hz: 20)])
        XCTAssertEqual(sched.activeSpecCount, 1, "identical specs must be deduplicated")

        let n = 40
        var s1 = 0, s2 = 0
        sched.onPoll = { session, _, _, _ in
            if session == 1 { s1 += 1 } else if session == 2 { s2 += 1 }
        }
        for _ in 0..<n { sched.tick() }

        // One execute per tick, not one per (session, tick).
        XCTAssertEqual(dev.executeCount(req: 0x50), n)
        // Each session still gets fanned every tick.
        XCTAssertEqual(s1, n)
        XCTAssertEqual(s2, n)
    }

    func testByteBudgetScalesDownAHeavySession() {
        let dev = FakePollDevice()
        let budget = 200_000.0
        let sched = scheduler(dev, budget: budget)
        defer { sched.stop() }

        // 10 large polls at the cap: 10 * 2000 * 20 = 400000 bps, twice budget.
        var requests: [(slot: Int, spec: PollScheduler.PollSpec, hz: Double)] = []
        for i in 0..<10 {
            let spec = PollScheduler.PollSpec(handle: 0, req: 0x50, wValue: UInt16(i), wIndex: 2, len: 2000)
            requests.append((slot: i, spec: spec, hz: 20))
        }
        let granted = sched.subscribe(session: 1, role: .viewer, requests: requests)

        let totalBandwidth = granted.reduce(0.0) { $0 + 2000.0 * $1.grantedHz }
        XCTAssertLessThanOrEqual(totalBandwidth, budget + 0.5, "session bandwidth must not exceed the budget")
        // Halved by the 2x overage.
        for g in granted { XCTAssertEqual(g.grantedHz, 10, accuracy: 0.01) }
    }

    func testUnsubscribeStopsDeliveryForThatSession() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)
        defer { sched.stop() }

        var count = 0
        sched.onPoll = { session, _, _, _ in if session == 1 { count += 1 } }
        _ = sched.subscribe(session: 1, role: .viewer, requests: [(slot: 0, spec: statusSpec, hz: 20)])

        for _ in 0..<5 { sched.tick() }
        XCTAssertEqual(count, 5)

        sched.unsubscribe(session: 1, slots: [0])
        let after = count
        for _ in 0..<5 { sched.tick() }
        XCTAssertEqual(count, after, "no deliveries after unsubscribe")
    }

    func testLastSubscriberLeavingStopsExecution() {
        let dev = FakePollDevice()
        let sched = scheduler(dev)
        defer { sched.stop() }

        _ = sched.subscribe(session: 1, role: .viewer, requests: [(slot: 0, spec: statusSpec, hz: 20)])
        for _ in 0..<5 { sched.tick() }
        let executedWhileSubscribed = dev.executeCount(req: 0x50)
        XCTAssertGreaterThan(executedWhileSubscribed, 0)

        sched.unsubscribeAll(session: 1)
        XCTAssertEqual(sched.activeSpecCount, 0, "the spec must be dropped once unread")

        for _ in 0..<10 { sched.tick() }
        XCTAssertEqual(dev.executeCount(req: 0x50), executedWhileSubscribed,
                       "execution must stop once no session subscribes")
    }

    func testThreeFailuresProduceOneErrorAndReduceRate() {
        let dev = FakePollDevice()
        dev.status = .busy   // every execution fails
        let sched = scheduler(dev)
        defer { sched.stop() }

        var errors: [(LinkSessionID, Int, LinkStatus)] = []
        sched.onPollError = { session, slot, _, status in errors.append((session, slot, status)) }
        sched.onPoll = { _, _, _, _ in XCTFail("a failing poll must not deliver a payload") }

        _ = sched.subscribe(session: 1, role: .viewer, requests: [(slot: 0, spec: statusSpec, hz: 20)])

        // First three ticks execute and fail; the third crosses the threshold.
        for _ in 0..<20 { sched.tick() }

        XCTAssertEqual(errors.count, 1, "exactly one poll.error per failure episode")
        XCTAssertEqual(errors.first?.2, .busy)

        // The spec backed off to half rate (0.5 * 20 * 0.05 == 0.5 per tick),
        // so it executes on roughly every other tick after the trip, far fewer
        // than the ~20 a full-rate poll would have run over 20 ticks.
        XCTAssertLessThan(dev.executeCount(req: 0x50), 18, "rate must drop after the failure episode")
    }
}
