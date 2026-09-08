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
        let code: UInt8
        let wValue: UInt16
        let at: Date
    }
    private var recentWriters: [WriterEntry] = []
    private var nextWriterToken: UInt64 = 0
    private let stateLock = NSLock()

    /// How long to wait for the device before giving up.  Bulk gets longer.
    var commandTimeout: TimeInterval = 2.0
    var bulkTimeout: TimeInterval = 5.0
    var maxInflightPerSession: Int = 8

    /// Bulk opcodes, which get the longer timeout and (for a full set/get)
    /// are the ones a lock is really meant to protect.
    private static let bulkOpcodes: Set<UInt8> = [0xA0, 0xA1, 0xA2, 0xA3]

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
        guard policy.isAllowed(role: session.role, code: request.bRequest, direction: direction) else {
            return completion(reject(request, .denied))
        }

        // 2. Lock: while another session holds the device, only that session's
        // commands run.  An expired lock is treated as released.
        stateLock.lock()
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

        let timeout = Self.bulkOpcodes.contains(request.bRequest) ? bulkTimeout : commandTimeout

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.inflight[session.id, default: 1] -= 1
                if self.inflight[session.id] == 0 { self.inflight[session.id] = nil }
                self.stateLock.unlock()
            }

            guard let device = self.device, device.isConnected else {
                return completion(self.reject(request, .noDevice))
            }

            let gen = device.generation
            // Anything that can change device state is a write for attribution,
            // whichever transfer direction carries it (write-as-read included).
            var writerToken: UInt64?
            if self.policy.classify(code: request.bRequest, direction: direction) != .read {
                self.stateLock.lock()
                // A repeat of the same parameter by the same session is one entry:
                // the firmware coalesces those into one notification, and the
                // queue must coalesce the same way to stay aligned with it.
                if let last = self.recentWriters.last, last.session == session.id,
                   last.code == request.bRequest, last.wValue == request.wValue {
                    self.recentWriters[self.recentWriters.count - 1] =
                        WriterEntry(token: last.token, session: last.session, code: last.code,
                                    wValue: last.wValue, at: Date())
                    writerToken = last.token
                } else {
                    let token = self.nextWriterToken; self.nextWriterToken &+= 1
                    self.recentWriters.append(WriterEntry(token: token, session: session.id,
                                                          code: request.bRequest,
                                                          wValue: request.wValue, at: Date()))
                    if self.recentWriters.count > 64 { self.recentWriters.removeFirst() }
                    writerToken = token
                }
                self.stateLock.unlock()
            }
            let response = self.runWithTimeout(request, on: device, timeout: timeout)

            // A write the device refused produced no notification; leaving its
            // entry would charge the next client's change to this session.
            if let token = writerToken, response.status != .ok {
                self.stateLock.lock()
                self.recentWriters.removeAll { $0.token == token }
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
