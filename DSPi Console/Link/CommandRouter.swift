//
//  CommandRouter.swift
//  DSPi Console
//
//  Serialises tunnelled vendor commands per device across every session,
//  enforces role authorization and exclusive locks, caps in-flight work per
//  session, times the device out, and attributes each completed SET to the
//  session that issued it so notifications can be de-echoed.  Pure logic over
//  a HubDevice; no sockets, no IOKit.  See dspi_link_protocol_spec.md section
//  8.2 and networking_plan.md Phase 2.
//

import Foundation

/// What the caller must know about a session to route its command.  The hub
/// supplies the live role (it can change mid-session) and the session id.
struct RouterSession {
    let id: LinkSessionID
    var role: LinkRole
    /// The local UI issues fire-and-forget writes in bursts (a preset apply is
    /// dozens) and cannot retry a rejection, so it is never capped.  Remote
    /// sessions are, since they can and must retry RATE_LIMITED.
    var exemptFromInflightCap: Bool = false
}

/// Outcome of a completed command plus the attribution the notify relay needs.
struct RoutedResult {
    let response: LinkCmdResponse
    /// The session a successful SET should be attributed to for echo
    /// suppression, or 0 for a GET, a failure, or a command that changes
    /// nothing observable.
    let attributedTo: LinkSessionID
}

final class CommandRouter {
    /// Per-device serial queue: commands for one device run in submission
    /// order across all sessions; different devices run concurrently.
    private let handle: UInt8
    private weak var device: HubDevice?
    private let policy: LinkPolicy
    private let queue: DispatchQueue

    /// Live lock holder for this device, or nil.  Guarded by `stateLock`.
    private var lockHolder: LinkSessionID?
    private var lockDeadline: Date?
    /// In-flight command count per session, for the max-inflight cap.
    private var inflight: [LinkSessionID: Int] = [:]
    /// Recent writers in dispatch order, for notification attribution.  Each
    /// record is appended before its device call runs (commands are serialised
    /// per device, so the resulting notification cannot arrive first) and is
    /// consumed by the next host-sourced notification, oldest first.  A queue
    /// rather than "latest writer" so that B's write landing before A's
    /// notification is read does not steal A's attribution.  Best effort: the
    /// firmware coalesces repeated writes to one parameter, so the queue can
    /// run ahead; expired entries are dropped.
    private struct WriterEntry {
        let token: UInt64
        let session: LinkSessionID
        let command: UInt16
        let param: UInt32
        let at: Date
    }

    /// Which parameter a write targets, so repeats merge exactly where the
    /// firmware coalesces.  Every paged command carries its address in
    /// wValue (FILTER.BAND included), so the address is the key.
    static func parameterKey(_ request: LinkCmdRequest) -> UInt32 {
        UInt32(request.wValue)
    }
    private var recentWriters: [WriterEntry] = []
    private var nextWriterToken: UInt64 = 0
    /// Set by `shutdown()`: every command still queued, and any submitted
    /// later, answers NO_DEVICE without touching the device.
    private var isShutDown = false
    private let stateLock = NSLock()

    /// Last time each session read analyser bands or bins or sent RTA START
    /// (spec 7.15).  STOP is per session: it reaches the device only when no
    /// other session watched within `rtaWatchWindow`.  Guarded by `stateLock`.
    private var rtaWatchers: [LinkSessionID: Date] = [:]
    /// The firmware's own idle timeout, so a swallowed STOP never keeps the
    /// analyser running longer than an unread one would.
    static let rtaWatchWindow: TimeInterval = 5.0
    static let rtaWatchCodes: Set<UInt16> = [VC.MEAS.RTA_BANDS.id, VC.MEAS.RTA_BINS.id, VC.MEAS.RTA_BANDS_ALL.id]
    /// Whether a session other than the given one holds a poll subscription
    /// for one of the codes.  Scheduler polls bypass the router, so the hub
    /// wires this to its PollScheduler.
    var otherSessionPolls: ((_ commands: Set<UInt16>, _ excluding: LinkSessionID) -> Bool)?
    /// Injected so tests can age a watcher past the window without sleeping.
    var now: () -> Date = Date.init

    /// How long to wait for the device before giving up.  Bulk gets longer.
    var commandTimeout: TimeInterval = 2.0
    var bulkTimeout: TimeInterval = 5.0
    var maxInflightPerSession: Int = 8

    /// Bulk commands (the registry's BULK flag) get the longer timeout and,
    /// for a full set or get, are the ones a lock is really meant to protect.
    private static func isBulk(_ request: LinkCmdRequest) -> Bool {
        VendorCommandRegistry.info(for: VendorCommand(request.commandID))?.flags.contains(.bulk) ?? false
    }

    init(handle: UInt8, device: HubDevice, policy: LinkPolicy) {
        self.handle = handle
        self.device = device
        self.policy = policy
        self.queue = DispatchQueue(label: "com.foxdac.link.router.\(handle)")
        self.execQueue = DispatchQueue(label: "com.foxdac.link.exec.\(handle)")
    }

    /// One persistent queue runs the blocking device call, off the router's
    /// ordering queue, so the timeout guard does not create a queue per
    /// command on the high-rate local poll path.
    private let execQueue: DispatchQueue

    /// Submit one command.  The completion runs on an arbitrary queue with the
    /// routed result.  Rejections (auth, lock, rate) complete synchronously
    /// before the device is ever touched.
    func submit(_ request: LinkCmdRequest,
                session: RouterSession,
                completion: @escaping (RoutedResult) -> Void) {
        let direction: LinkCommandDirection = request.direction == .set ? .set : .get

        // 1. Authorization: the role must permit this command.  Fails safe:
        // an unclassified command is config, admin-only.
        guard policy.isAllowed(role: session.role, id: request.commandID, direction: direction) else {
            return completion(reject(request, .denied))
        }

        // 2. Lock: while another session holds the device, only that session's
        // commands run.  An expired lock is treated as released.
        stateLock.lock()
        if isShutDown {
            stateLock.unlock()
            return completion(reject(request, .noDevice))
        }
        if let holder = lockHolder, holder != session.id {
            if let dl = lockDeadline, dl < Date() {
                lockHolder = nil; lockDeadline = nil
            } else {
                stateLock.unlock()
                return completion(reject(request, .locked))
            }
        }

        // 3. In-flight cap per session (remote sessions only).
        let count = inflight[session.id, default: 0]
        if !session.exemptFromInflightCap, count >= maxInflightPerSession {
            stateLock.unlock()
            return completion(reject(request, .rateLimited))
        }
        inflight[session.id] = count + 1
        stateLock.unlock()

        let timeout = Self.isBulk(request) ? bulkTimeout : commandTimeout

        // Bind the command to the attachment that is current now, as USBDevice
        // binds its own transfers: a switch (close/open) landing before the
        // queue reaches this command fails it instead of delivering it to the
        // board that replaced the one it was issued for.
        let gen = device?.generation

        // The block holds the router: a caller blocked on `completion` (the
        // local transport's synchronous GET) must hear back even if the hub has
        // already dropped the router, so a queued command can never be
        // discarded unanswered.
        queue.async {
            defer {
                self.stateLock.lock()
                self.inflight[session.id, default: 1] -= 1
                if self.inflight[session.id] == 0 { self.inflight[session.id] = nil }
                self.stateLock.unlock()
            }

            self.stateLock.lock(); let shutDown = self.isShutDown; self.stateLock.unlock()
            guard !shutDown, let device = self.device, device.isConnected, device.generation == gen else {
                return completion(self.reject(request, .noDevice))
            }

            // Decided here, in queue order, so a band read queued ahead of a
            // STOP counts as watching.
            if self.rtaStopIsSwallowed(request, session: session.id) {
                // MEAS.RTA_STOP is a zero-length SET, so its ACK carries nothing.
                return completion(RoutedResult(response: LinkCmdResponse(tag: request.tag, status: .ok),
                                               attributedTo: 0))
            }

            // Every SET is a write for attribution and every GET a read
            // (spec 1.3: firmware 1.1.7 has no write-as-reads).
            var writerToken: UInt64?
            var previousWriter: WriterEntry?
            if direction == .set {
                let param = Self.parameterKey(request)
                self.stateLock.lock()
                // A repeat of the same parameter by the same session is one entry,
                // merged in place wherever it sits, as the firmware coalesces into
                // any unsent ring slot; a drag alternating linked bands stays aligned.
                if let i = self.recentWriters.lastIndex(where: {
                    $0.session == session.id && $0.command == request.commandID && $0.param == param }) {
                    let last = self.recentWriters[i]
                    previousWriter = last
                    self.recentWriters[i] = WriterEntry(token: last.token, session: last.session,
                                                        command: last.command, param: last.param, at: Date())
                    writerToken = last.token
                } else {
                    let token = self.nextWriterToken; self.nextWriterToken &+= 1
                    self.recentWriters.append(WriterEntry(token: token, session: session.id,
                                                          command: request.commandID,
                                                          param: param, at: Date()))
                    if self.recentWriters.count > 64 { self.recentWriters.removeFirst() }
                    writerToken = token
                }
                self.stateLock.unlock()
            }
            let response = self.runWithTimeout(request, on: device, timeout: timeout)

            // Roll back only this write's attribution. A failed repeat must
            // preserve the earlier successful write and its original expiry.
            // If its notification already consumed the entry during execute,
            // leave it consumed rather than resurrecting it.
            if let token = writerToken, response.status != .ok {
                self.stateLock.lock()
                if let index = self.recentWriters.firstIndex(where: { $0.token == token }) {
                    if let previous = previousWriter {
                        self.recentWriters[index] = previous
                    } else {
                        self.recentWriters.remove(at: index)
                    }
                }
                self.stateLock.unlock()
            }

            // A device that was replaced while the command ran cannot have its
            // result attributed to this session; treat as a soft failure the
            // client will re-read past.
            guard device.generation == gen else {
                return completion(RoutedResult(response: LinkCmdResponse(tag: request.tag, status: .noDevice),
                                               attributedTo: 0))
            }

            let attributed: LinkSessionID =
                (request.direction == .set && response.status == .ok) ? session.id : 0
            completion(RoutedResult(response: response, attributedTo: attributed))
        }
    }

    /// Record analyser watching, and answer whether this request is an RTA
    /// STOP that must not reach the device because another session watches.
    /// Call on the router queue.
    private func rtaStopIsSwallowed(_ request: LinkCmdRequest, session: LinkSessionID) -> Bool {
        let id = request.commandID
        let isStart = id == VC.MEAS.RTA_START.id, isStop = id == VC.MEAS.RTA_STOP.id
        guard Self.rtaWatchCodes.contains(id) || isStart || isStop else { return false }
        let t = now()
        if !isStop {
            stateLock.lock(); rtaWatchers[session] = t; stateLock.unlock()
            return false
        }

        stateLock.lock()
        rtaWatchers[session] = nil
        rtaWatchers = rtaWatchers.filter { t.timeIntervalSince($0.value) <= Self.rtaWatchWindow }
        let othersWatching = !rtaWatchers.isEmpty
        stateLock.unlock()
        // Queried outside stateLock: the scheduler holds its own lock across
        // blocking device reads.
        return othersWatching || (otherSessionPolls?(Self.rtaWatchCodes, session) ?? false)
    }

    /// Run the blocking device call but do not let it wedge the queue past the
    /// timeout: the device call itself is bounded (USBDevice's control transfer
    /// has its own completion timeout), so this guards the pathological case by
    /// running the call on a helper and abandoning a late reply.
    private func runWithTimeout(_ request: LinkCmdRequest, on device: HubDevice,
                                timeout: TimeInterval) -> LinkCmdResponse {
        let sem = DispatchSemaphore(value: 0)
        var result: LinkCmdResponse?
        execQueue.async {
            let r = device.execute(request)
            result = r
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return LinkCmdResponse(tag: request.tag, status: .timeout)
        }
        return result ?? LinkCmdResponse(tag: request.tag, status: .error)
    }

    private func reject(_ request: LinkCmdRequest, _ status: LinkStatus) -> RoutedResult {
        RoutedResult(response: LinkCmdResponse(tag: request.tag, status: status), attributedTo: 0)
    }

    /// Tear the router down: commands still queued complete with NO_DEVICE
    /// instead of running against a device that is gone (or replaced), and so
    /// does anything submitted afterwards.  A command already inside the
    /// device finishes on its own; its result is reported as usual.
    func shutdown() {
        stateLock.lock(); isShutDown = true; stateLock.unlock()
    }

    // MARK: - Locks

    /// Try to take the device lock.  Fails if another session holds a live one.
    @discardableResult
    func acquireLock(session: LinkSessionID, timeout: TimeInterval) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if let holder = lockHolder, holder != session {
            if let dl = lockDeadline, dl >= Date() { return false }
        }
        lockHolder = session
        lockDeadline = Date().addingTimeInterval(timeout)
        return true
    }

    /// Release the lock if this session holds it.
    func releaseLock(session: LinkSessionID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if lockHolder == session { lockHolder = nil; lockDeadline = nil }
    }

    /// Drop a session entirely (it disconnected): release its lock and clear
    /// its in-flight count.
    func sessionDidClose(_ session: LinkSessionID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if lockHolder == session { lockHolder = nil; lockDeadline = nil }
        inflight[session] = nil
        // Stops watching at once; nothing is sent, the firmware idles itself.
        rtaWatchers[session] = nil
    }

    /// Consume the oldest writer that wrote within `window`, for attributing
    /// one host-originated notification.  0 when nobody did.
    func consumeAttribution(within window: TimeInterval, now: Date = Date()) -> LinkSessionID {
        stateLock.lock(); defer { stateLock.unlock() }
        recentWriters.removeAll { now.timeIntervalSince($0.at) > window }
        guard !recentWriters.isEmpty else { return 0 }
        return recentWriters.removeFirst().session
    }

    var currentLockHolder: LinkSessionID? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let dl = lockDeadline, dl < Date() { return nil }
        return lockHolder
    }
}
