import XCTest
@testable import DSPi_Console

/// Behavioural tests for the notification relay (spec section 8.3 NOTIFY and
/// 8.6 RESYNC): verbatim fan-out, per-session Link sequencing, and the
/// bounded-queue backpressure that turns a slow reader into a single RESYNC
/// instead of a stalled publisher.
final class LinkNotifyRelayTests: XCTestCase {

    // MARK: - Helpers

    /// Thread-safe collector: `deliver` runs on each session's own serial queue.
    private final class FrameSink {
        private let lock = NSLock()
        private var store: [LinkNotifyFrame] = []
        func add(_ f: LinkNotifyFrame) { lock.lock(); store.append(f); lock.unlock() }
        var frames: [LinkNotifyFrame] { lock.lock(); defer { lock.unlock() }; return store }
        var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    }

    private final class ResyncSink {
        private let lock = NSLock()
        private var store: [LinkResyncFrame] = []
        func add(_ f: LinkResyncFrame) { lock.lock(); store.append(f); lock.unlock() }
        var frames: [LinkResyncFrame] { lock.lock(); defer { lock.unlock() }; return store }
        var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    }

    private func notification(_ packet: [UInt8], origin: LinkSessionID) -> LinkNotification {
        LinkNotification(packet: Data(packet), origin: origin, receivedAt: Date())
    }

    // MARK: - Fan-out and verbatim packet

    func testPublishReachesEverySessionWithVerbatimPacketAndOrigin() {
        let relay = NotifyRelay()
        let a = FrameSink(), b = FrameSink()
        let expA = expectation(description: "a receives")
        let expB = expectation(description: "b receives")
        relay.addSession(1, deliver: { a.add($0); expA.fulfill() }, resync: { _ in })
        relay.addSession(2, deliver: { b.add($0); expB.fulfill() }, resync: { _ in })

        let packet: [UInt8] = [0x02, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x01]
        relay.publish(handle: 0, notification: notification(packet, origin: 12))

        wait(for: [expA, expB], timeout: 3)
        for sink in [a, b] {
            XCTAssertEqual(sink.count, 1)
            let f = sink.frames[0]
            XCTAssertEqual(Array(f.packet), packet, "packet must be relayed verbatim")
            XCTAssertEqual(f.origin, 12, "origin must be preserved")
            XCTAssertEqual(f.handle, 0)
        }
    }

    // MARK: - Independent per-session tags

    func testTagsAreIndependentPerSessionAndDoNotInherit() {
        let relay = NotifyRelay()
        let a = FrameSink(), b = FrameSink()
        let expA = expectation(description: "a five frames")
        expA.expectedFulfillmentCount = 5
        relay.addSession(1, deliver: { a.add($0); expA.fulfill() }, resync: { _ in })

        // Three published before B exists: A's tags 0,1,2.
        for i in 0..<3 { relay.publish(handle: 0, notification: notification([0x02, UInt8(i)], origin: 0)) }

        let expB = expectation(description: "b two frames")
        expB.expectedFulfillmentCount = 2
        relay.addSession(2, deliver: { b.add($0); expB.fulfill() }, resync: { _ in })

        // Two more: A's tags 3,4 and B's tags 0,1 (B does not inherit A's counter).
        for i in 3..<5 { relay.publish(handle: 0, notification: notification([0x02, UInt8(i)], origin: 0)) }

        wait(for: [expA, expB], timeout: 3)
        XCTAssertEqual(a.frames.map(\.tag), [0, 1, 2, 3, 4])
        XCTAssertEqual(b.frames.map(\.tag), [0, 1], "a later session starts its own sequence at 0")
    }

    // MARK: - Backpressure

    func testSlowSessionResyncsAndDoesNotBlockFast() {
        let relay = NotifyRelay(capacity: 4)
        let fast = FrameSink()
        let slow = FrameSink()
        let slowResync = ResyncSink()
        let gate = DispatchSemaphore(value: 0)

        let fastExp = expectation(description: "fast gets all 10")
        fastExp.expectedFulfillmentCount = 10
        let slowEntered = expectation(description: "slow blocked in first delivery")
        let resyncExp = expectation(description: "slow resynced")

        relay.addSession(1, deliver: { fast.add($0); fastExp.fulfill() }, resync: { _ in })

        var firstSlowCall = true
        relay.addSession(2, deliver: { frame in
            slow.add(frame)
            if firstSlowCall {
                firstSlowCall = false
                slowEntered.fulfill()
                gate.wait()          // stall this session only
            }
        }, resync: { r in slowResync.add(r); resyncExp.fulfill() })

        // Pace the publishes so the (unblocked) fast consumer drains each frame
        // before the next arrives and never overflows its own cap; the blocked
        // slow session accumulates regardless and overflows.
        for i in 0..<10 {
            relay.publish(handle: 7, notification: notification([0x02, UInt8(i)], origin: 0))
            usleep(5_000)
        }

        // Fast drains fully while slow is parked on the semaphore.
        wait(for: [fastExp, slowEntered], timeout: 3)
        XCTAssertEqual(fast.frames.map(\.tag), Array(0..<10).map(UInt16.init),
                       "fast session receives every frame in order")
        XCTAssertEqual(slow.count, 1, "slow is still stuck on its first frame")
        XCTAssertEqual(slowResync.count, 0, "no resync until the slow queue drains")

        gate.signal()                // let slow catch up
        wait(for: [resyncExp], timeout: 3)
        XCTAssertEqual(slowResync.count, 1, "exactly one resync for the drop episode")
        XCTAssertEqual(slowResync.frames[0].reason, LinkResyncFrame.Reason.notificationsDropped.rawValue)
        XCTAssertEqual(slowResync.frames[0].handle, 7, "resync carries the dropped device's handle")
        XCTAssertLessThan(slow.count, 10, "the slow session dropped frames it never saw")
    }

    /// A second RESYNC is withheld until the session has caught up and fallen
    /// behind a second time, so two overflow episodes yield exactly two RESYNCs
    /// (and nothing in between).
    func testOnlyOneResyncPerEpisodeAndAgainAfterRecovery() {
        let relay = NotifyRelay(capacity: 2)
        let sink = FrameSink()
        let resyncs = ResyncSink()

        // Blocking is armed by the test between episodes; the deliver closure
        // and the test thread both touch it, so it is lock-guarded.
        final class Ctrl {
            let lock = NSLock()
            var armed = false
            var gate: DispatchSemaphore?
            var entered: XCTestExpectation?
        }
        let ctrl = Ctrl()

        let firstResync = expectation(description: "resync after episode 1")
        let secondResync = expectation(description: "resync after episode 2")

        relay.addSession(1, deliver: { frame in
            sink.add(frame)
            ctrl.lock.lock()
            let gate = ctrl.armed ? ctrl.gate : nil
            if gate != nil { ctrl.armed = false; ctrl.entered?.fulfill() }
            ctrl.lock.unlock()
            gate?.wait()   // stall the first delivery of the armed episode
        }, resync: { r in
            resyncs.add(r)
            if resyncs.count == 1 { firstResync.fulfill() }
            if resyncs.count == 2 { secondResync.fulfill() }
        })

        // Episode 1.
        let entered1 = expectation(description: "blocked, episode 1")
        let gate1 = DispatchSemaphore(value: 0)
        ctrl.lock.lock(); ctrl.gate = gate1; ctrl.entered = entered1; ctrl.armed = true; ctrl.lock.unlock()
        for i in 0..<8 { relay.publish(handle: 0, notification: notification([0x02, UInt8(i)], origin: 0)) }
        wait(for: [entered1], timeout: 3)
        gate1.signal()
        wait(for: [firstResync], timeout: 3)
        XCTAssertEqual(resyncs.count, 1, "exactly one resync for the first episode")

        // Episode 2: the session had drained, so overflowing again earns a
        // second, separate resync.
        let entered2 = expectation(description: "blocked, episode 2")
        let gate2 = DispatchSemaphore(value: 0)
        ctrl.lock.lock(); ctrl.gate = gate2; ctrl.entered = entered2; ctrl.armed = true; ctrl.lock.unlock()
        for i in 8..<16 { relay.publish(handle: 0, notification: notification([0x02, UInt8(i)], origin: 0)) }
        wait(for: [entered2], timeout: 3)
        gate2.signal()
        wait(for: [secondResync], timeout: 3)
        XCTAssertEqual(resyncs.count, 2, "a fresh fall-behind produces one more resync, not more")
    }

    // MARK: - resyncAll

    func testResyncAllReachesEverySessionWithReason() {
        let relay = NotifyRelay()
        let ra = ResyncSink(), rb = ResyncSink()
        let expA = expectation(description: "a resync")
        let expB = expectation(description: "b resync")
        relay.addSession(1, deliver: { _ in }, resync: { ra.add($0); expA.fulfill() })
        relay.addSession(2, deliver: { _ in }, resync: { rb.add($0); expB.fulfill() })

        relay.resyncAll(handle: 3, reason: LinkResyncFrame.Reason.deviceReattached.rawValue)

        wait(for: [expA, expB], timeout: 3)
        for sink in [ra, rb] {
            XCTAssertEqual(sink.count, 1)
            XCTAssertEqual(sink.frames[0].handle, 3)
            XCTAssertEqual(sink.frames[0].reason, LinkResyncFrame.Reason.deviceReattached.rawValue)
        }
    }

    // MARK: - Removal and count

    func testRemoveSessionStopsDeliveryAndUpdatesCount() {
        let relay = NotifyRelay()
        XCTAssertEqual(relay.sessionCount, 0)

        let kept = FrameSink()
        let removed = FrameSink()
        let keptExp = expectation(description: "kept receives after removal")
        relay.addSession(1, deliver: { kept.add($0); keptExp.fulfill() }, resync: { _ in })
        relay.addSession(2, deliver: { removed.add($0); XCTFail("removed session must not receive") },
                         resync: { _ in })
        XCTAssertEqual(relay.sessionCount, 2)

        relay.removeSession(2)
        XCTAssertEqual(relay.sessionCount, 1)

        relay.publish(handle: 0, notification: notification([0x02, 0x00], origin: 0))
        wait(for: [keptExp], timeout: 3)
        XCTAssertEqual(removed.count, 0)
        XCTAssertEqual(kept.count, 1)
    }

    // MARK: - No sessions

    func testPublishWithNoSessionsIsNoOp() {
        let relay = NotifyRelay()
        // Must simply return without touching anything.
        relay.publish(handle: 0, notification: notification([0x02, 0x00], origin: 0))
        XCTAssertEqual(relay.sessionCount, 0)
    }
}
