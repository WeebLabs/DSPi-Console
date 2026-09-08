//
//  PollScheduler.swift
//  DSPi Console
//
//  The hub's poll engine (spec 7.6, 8.4).  Meters, RTA and other transient
//  state are not notified by the firmware, so a session subscribes a set of
//  GET commands with a requested rate and the hub polls them and pushes the
//  verbatim responses back as POLL frames.  This class owns that scheduling
//  for one device: it deduplicates identical polls so a shared meter is read
//  once and fanned out, enforces a per-session bandwidth budget, and stops
//  polling a spec the instant its last subscriber leaves (RTA and some meters
//  switch themselves off when unread, so a zombie poll costs device CPU).
//
//  Threading: every public method and the internal tick take one lock, so the
//  class is safe to call from any thread.  The device's `execute` is blocking
//  and is called under that lock off the main thread (the internal timer runs
//  on a private serial queue); `onPoll`/`onPollError` are invoked after the
//  lock is dropped so a callback can freely call back in.  The device is held
//  strongly: the scheduler is owned per-device by the hub, which calls
//  `stop()` and releases it when the device goes away, so there is no cycle to
//  break and a strong reference keeps the device alive across an in-flight tick.
//

import Foundation

final class PollScheduler {

    /// One poll's full identity.  Two subscriptions with the same tuple are
    /// the same physical read and are executed once (spec 7.6).
    struct PollSpec: Hashable {
        var handle: UInt8
        var req: UInt8
        var wValue: UInt16
        var wIndex: UInt16
        var len: UInt16
    }

    // MARK: - Delivery callbacks

    /// A successful poll's verbatim payload, fanned out per subscribing
    /// session/slot at that session's granted rate.
    var onPoll: ((_ session: LinkSessionID, _ slot: Int, _ handle: UInt8, _ payload: Data) -> Void)?
    /// Fired once per failure episode per subscriber after three consecutive
    /// failed executions of a spec (spec 8.4).
    var onPollError: ((_ session: LinkSessionID, _ slot: Int, _ handle: UInt8, _ status: LinkStatus) -> Void)?

    // MARK: - Budget knobs

    /// Ceiling on any single granted rate, before the budget is applied.
    let pollMaxHz: Double
    /// Per-session total poll bandwidth, estimated as sum(len * grantedHz).
    let pollBudgetBps: Double
    /// Base timer period.  Injected so a test can drive ticks quickly and the
    /// production timer can be coarse.
    let tickResolution: TimeInterval

    // MARK: - Internal state

    /// A single subscriber's view of one spec.  A reference type so the tick
    /// loop can advance its accumulator in place.
    private final class Sub {
        let session: LinkSessionID
        let slot: Int
        /// What the client asked for, kept so the session can be re-scaled
        /// stably when its set of polls changes.
        let requestedHz: Double
        /// requestedHz clamped to pollMaxHz, before the budget scale.
        let cappedHz: Double
        /// cappedHz after the session's budget scale; this is what was granted.
        var grantedHz: Double = 0
        /// Fraction-of-executions accumulator for fan-out (see `runTick`).
        var deliverAcc: Double = 0

        init(session: LinkSessionID, slot: Int, requestedHz: Double, cappedHz: Double) {
            self.session = session
            self.slot = slot
            self.requestedHz = requestedHz
            self.cappedHz = cappedHz
        }
    }

    /// Everything the scheduler tracks for one deduplicated spec.
    private final class SpecState {
        let spec: PollSpec
        /// Subscribers keyed by (session, slot).
        var subs: [SubKey: Sub] = [:]
        /// Execution-rate accumulator; when it crosses 1 the spec is executed.
        var execAcc: Double = 0
        var consecutiveFailures: Int = 0
        /// True once onPollError has fired for the current failure episode, so
        /// it fires once and not every tick.
        var errorReported = false
        /// 1.0 normally; 0.5 while degraded after three failures (spec 8.4).
        var rateFactor: Double = 1

        init(spec: PollSpec) { self.spec = spec }
    }

    private struct SubKey: Hashable {
        let session: LinkSessionID
        let slot: Int
    }

    private let device: HubDevice
    private let policy: LinkPolicy
    private let lock = NSRecursiveLock()

    private var specs: [PollSpec: SpecState] = [:]
    /// Reverse index: each session's slot -> the spec it maps to.  Drives
    /// unsubscribe, grantedHz lookups and per-session budget scaling.
    private var sessionSlots: [LinkSessionID: [Int: PollSpec]] = [:]

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.dspi.link.poll")
    private var stopped = false

    /// - Parameter driveWithTimer: when true (production) an internal timer
    ///   drives `runTick` at `tickResolution`.  Tests pass false and call
    ///   `tick()` directly, which is deterministic and free of wall-clock waits.
    init(device: HubDevice, policy: LinkPolicy,
         pollMaxHz: Double = 20, pollBudgetBps: Double = 200_000,
         tickResolution: TimeInterval = 0.05, driveWithTimer: Bool = true) {
        self.device = device
        self.policy = policy
        self.pollMaxHz = pollMaxHz
        self.pollBudgetBps = pollBudgetBps
        self.tickResolution = tickResolution
        if driveWithTimer { startTimer() }
    }

    deinit { stop() }

    // MARK: - Subscription

    /// Subscribe a session to a batch of polls.  Returns the granted rate for
    /// each requested slot, in request order.  A poll is rejected (granted
    /// 0 hz and never started) when its command is not classed `.read`, or the
    /// session's role does not permit it.  Otherwise the rate is capped to
    /// `pollMaxHz` and then the whole session is scaled to fit `pollBudgetBps`.
    func subscribe(session: LinkSessionID, role: LinkRole,
                   requests: [(slot: Int, spec: PollSpec, hz: Double)]) -> [(slot: Int, grantedHz: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return requests.map { ($0.slot, 0) } }

        for req in requests {
            // Polls always travel as GET transfers; a command the table does
            // not class `read` for that direction must not be pollable, and
            // the role must permit it (spec 7.6).
            let cls = policy.classify(code: req.spec.req, direction: .get)
            guard cls == .read, role.permits(cls) else { continue }
            guard req.slot >= 0, req.slot <= 15 else { continue }

            let capped = min(max(req.hz, 0), pollMaxHz)
            guard capped > 0 else { continue }

            // Drop any prior subscription on this (session, slot) first so a
            // re-subscribe replaces rather than duplicates.
            removeSlot(session: session, slot: req.slot)

            let state = specs[req.spec] ?? {
                let s = SpecState(spec: req.spec); specs[req.spec] = s; return s
            }()
            let sub = Sub(session: session, slot: req.slot, requestedHz: req.hz, cappedHz: capped)
            state.subs[SubKey(session: session, slot: req.slot)] = sub
            sessionSlots[session, default: [:]][req.slot] = req.spec
        }

        rescale(session: session)

        return requests.map { req in
            (req.slot, grantedLocked(session: session, slot: req.slot) ?? 0)
        }
    }

    func unsubscribe(session: LinkSessionID, slots: [Int]) {
        lock.lock(); defer { lock.unlock() }
        for slot in slots { removeSlot(session: session, slot: slot) }
        rescale(session: session)
    }

    func unsubscribeAll(session: LinkSessionID) {
        lock.lock(); defer { lock.unlock() }
        let slots = sessionSlots[session].map { Array($0.keys) } ?? []
        for slot in slots { removeSlot(session: session, slot: slot) }
        sessionSlots[session] = nil
    }

    // MARK: - Introspection (for tests and diagnostics)

    /// Number of specs currently being polled.  A spec with no subscribers is
    /// removed, so this reflects real device traffic.
    var activeSpecCount: Int {
        lock.lock(); defer { lock.unlock() }
        return specs.count
    }

    func grantedHz(session: LinkSessionID, slot: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return grantedLocked(session: session, slot: slot)
    }

    // MARK: - Lifecycle

    /// Cancel the timer and forget every subscription.
    func stop() {
        lock.lock()
        stopped = true
        specs.removeAll()
        sessionSlots.removeAll()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    // MARK: - Ticking

    /// Advance one tick synchronously.  Exposed so tests can drive scheduling
    /// deterministically; the production timer simply calls this.
    func tick() { runTick() }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickResolution, repeating: tickResolution)
        t.setEventHandler { [weak self] in self?.runTick() }
        timer = t
        t.resume()
    }

    private func runTick() {
        // Collect side effects under the lock, fire them after releasing it so
        // a callback that re-enters (subscribe/unsubscribe) cannot deadlock.
        var deliveries: [(LinkSessionID, Int, UInt8, Data)] = []
        var errors: [(LinkSessionID, Int, UInt8, LinkStatus)] = []

        lock.lock()
        if !stopped {
            for state in specs.values {
                // The spec runs at the highest rate any subscriber was granted;
                // slower subscribers just receive a subset of the results.
                let maxGranted = state.subs.values.map { $0.grantedHz }.max() ?? 0
                guard maxGranted > 0 else { continue }

                state.execAcc += maxGranted * state.rateFactor * tickResolution
                guard state.execAcc >= 1 else { continue }
                state.execAcc -= 1

                let request = LinkCmdRequest(tag: 0, handle: state.spec.handle, direction: .get,
                                             bRequest: state.spec.req, wValue: state.spec.wValue,
                                             wIndex: state.spec.wIndex, wLength: state.spec.len)
                let response = device.execute(request)

                if response.status == .ok {
                    state.consecutiveFailures = 0
                    state.errorReported = false
                    state.rateFactor = 1
                    for sub in state.subs.values {
                        // Deliver this result to the subscriber with probability
                        // grantedHz/maxGranted, so a half-rate subscriber sees
                        // every other successful poll.
                        sub.deliverAcc += sub.grantedHz / maxGranted
                        if sub.deliverAcc >= 1 {
                            sub.deliverAcc -= 1
                            deliveries.append((sub.session, sub.slot, state.spec.handle, response.payload))
                        }
                    }
                } else {
                    state.consecutiveFailures += 1
                    if state.consecutiveFailures >= 3 && !state.errorReported {
                        state.errorReported = true
                        state.rateFactor = 0.5   // back off until the device recovers
                        for sub in state.subs.values {
                            errors.append((sub.session, sub.slot, state.spec.handle, response.status))
                        }
                    }
                }
            }
        }
        lock.unlock()

        for d in deliveries { onPoll?(d.0, d.1, d.2, d.3) }
        for e in errors { onPollError?(e.0, e.1, e.2, e.3) }
    }

    // MARK: - Helpers (call with the lock held)

    private func grantedLocked(session: LinkSessionID, slot: Int) -> Double? {
        guard let spec = sessionSlots[session]?[slot],
              let sub = specs[spec]?.subs[SubKey(session: session, slot: slot)] else { return nil }
        return sub.grantedHz
    }

    private func removeSlot(session: LinkSessionID, slot: Int) {
        guard let spec = sessionSlots[session]?[slot] else { return }
        sessionSlots[session]?[slot] = nil
        if sessionSlots[session]?.isEmpty == true { sessionSlots[session] = nil }
        guard let state = specs[spec] else { return }
        state.subs[SubKey(session: session, slot: slot)] = nil
        // Last subscriber gone: stop polling this spec entirely.
        if state.subs.isEmpty { specs[spec] = nil }
    }

    /// Recompute every granted rate for one session so its total estimated
    /// bandwidth (sum of len * grantedHz) stays within the budget, scaling all
    /// of the session's polls down by one common factor.
    private func rescale(session: LinkSessionID) {
        guard let slots = sessionSlots[session] else { return }
        // Pair each of the session's subs with its spec's payload length.
        var subs: [(sub: Sub, len: UInt16)] = []
        for (slot, spec) in slots {
            if let sub = specs[spec]?.subs[SubKey(session: session, slot: slot)] {
                subs.append((sub, spec.len))
            }
        }
        let total = subs.reduce(0.0) { $0 + Double($1.len) * $1.sub.cappedHz }
        let scale = total > pollBudgetBps && total > 0 ? pollBudgetBps / total : 1
        for entry in subs { entry.sub.grantedHz = entry.sub.cappedHz * scale }
    }
}
