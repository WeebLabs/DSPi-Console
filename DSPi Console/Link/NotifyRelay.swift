//
//  NotifyRelay.swift
//  DSPi Console
//
//  Fans one device's notification packets out to every authenticated Link
//  session (spec section 8.3 NOTIFY).  Each session gets its own Link sequence
//  counter (`tag`) and its own bounded outbound queue, so a slow reader cannot
//  stall the publisher or any other session.  When a session falls behind, its
//  oldest frames are dropped and it is told to re-read state with a single
//  RESYNC (spec 8.6), rather than being fed a truncated stream.
//

import Foundation

/// Thread-safe notification fan-out for one hub.  `publish` is cheap and may be
/// called from the main thread (that is where the transport delivers a
/// `LinkNotification`); the actual per-session delivery happens off that thread
/// on each session's own serial queue.
final class NotifyRelay {

    /// Per-session delivery state.  Everything mutable here is guarded by the
    /// relay's `lock`; the closures are invoked only outside it.
    private final class Session {
        let deliver: (LinkNotifyFrame) -> Void
        let resync: (LinkResyncFrame) -> Void
        /// Serial queue that drains this session's buffer one frame at a time,
        /// so a blocking `deliver` blocks only this session.
        let queue: DispatchQueue
        /// Next Link sequence number; wraps at UInt16 max.  Independent of the
        /// firmware's own 8-bit `seq` inside the packet, and of other sessions.
        var nextTag: UInt16 = 0
        /// Frames assigned a tag but not yet handed to `deliver`.
        var buffer: [LinkNotifyFrame] = []
        /// True once we have dropped at least one frame in the current episode;
        /// cleared when the buffer next empties, after one RESYNC is sent.
        var behind = false
        /// A drain block is scheduled or running on `queue`.
        var draining = false
        /// Handle of the most recently published notification, used as the
        /// handle for a drop-triggered RESYNC.
        var lastHandle: UInt8 = 0

        init(deliver: @escaping (LinkNotifyFrame) -> Void,
             resync: @escaping (LinkResyncFrame) -> Void,
             queue: DispatchQueue) {
            self.deliver = deliver
            self.resync = resync
            self.queue = queue
        }
    }

    private let lock = NSLock()
    private var sessions: [LinkSessionID: Session] = [:]
    private let capacity: Int

    /// - Parameter capacity: outbound queue depth per session before the oldest
    ///   undelivered frames are dropped.  256 by default.
    init(capacity: Int = 256) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    var sessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    // MARK: - Registration

    func addSession(_ id: LinkSessionID,
                    deliver: @escaping (LinkNotifyFrame) -> Void,
                    resync: @escaping (LinkResyncFrame) -> Void) {
        let queue = DispatchQueue(label: "com.weeblabs.dspi.notifyrelay.\(id)")
        let session = Session(deliver: deliver, resync: resync, queue: queue)
        lock.lock()
        sessions[id] = session
        lock.unlock()
    }

    func removeSession(_ id: LinkSessionID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
        // Anything already dispatched onto that session's queue drops on the
        // floor once the last reference to the Session goes away.
    }

    // MARK: - Publishing

    /// Build a per-session NOTIFY frame for `notification` and enqueue it for
    /// every session.  Returns quickly: no `deliver` closure runs inline.
    func publish(handle: UInt8, notification: LinkNotification) {
        lock.lock()
        let targets = Array(sessions.values)
        for session in targets {
            session.lastHandle = handle
            let tag = session.nextTag
            session.nextTag = session.nextTag &+ 1   // wraps at UInt16 max
            let frame = LinkNotifyFrame(tag: tag,
                                        handle: handle,
                                        origin: notification.origin,
                                        packet: notification.packet)
            session.buffer.append(frame)
            // Enforce the bound: drop the oldest undelivered frames and remember
            // that this session missed events so it gets exactly one RESYNC.
            while session.buffer.count > capacity {
                session.buffer.removeFirst()
                session.behind = true
            }
            scheduleDrainLocked(session)
        }
        lock.unlock()
    }

    // MARK: - Resync

    /// Send a RESYNC to every session, e.g. on device reattach (reason 1) or a
    /// hub cache rebuild (reason 2).  Ordered behind each session's pending
    /// deliveries so a client does not re-read state before seeing queued events.
    func resyncAll(handle: UInt8, reason: UInt8) {
        lock.lock()
        let targets = Array(sessions.values)
        lock.unlock()
        let frame = LinkResyncFrame(handle: handle, reason: reason)
        for session in targets {
            let resync = session.resync
            session.queue.async { resync(frame) }
        }
    }

    // MARK: - Tests

    /// Undelivered frames currently buffered for a session (in-flight frame
    /// excluded).  Exposed for tests.
    func pendingDepth(_ id: LinkSessionID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]?.buffer.count ?? 0
    }

    // MARK: - Draining

    /// Caller must hold `lock`.  Kick off a drain if one is not already running.
    private func scheduleDrainLocked(_ session: Session) {
        guard !session.draining else { return }
        session.draining = true
        session.queue.async { [weak self] in self?.drain(session) }
    }

    /// Runs on `session.queue`.  Delivers buffered frames one at a time; when
    /// the buffer empties after a drop episode, sends a single RESYNC (reason 0)
    /// in place of the frames that were dropped.
    private func drain(_ session: Session) {
        while true {
            lock.lock()
            if session.buffer.isEmpty {
                if session.behind {
                    // Queue drained after a drop: tell the client to re-read
                    // state once, then keep draining in case more arrived while
                    // the resync closure ran.
                    session.behind = false
                    let resync = session.resync
                    let handle = session.lastHandle
                    lock.unlock()
                    resync(LinkResyncFrame(handle: handle, reason: 0))
                    continue
                }
                session.draining = false
                lock.unlock()
                return
            }
            let frame = session.buffer.removeFirst()
            let deliver = session.deliver
            lock.unlock()
            deliver(frame)   // may block; blocks only this session's queue
        }
    }
}
