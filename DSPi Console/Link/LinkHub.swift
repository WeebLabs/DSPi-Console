//
//  LinkHub.swift
//  DSPi Console
//
//  The gateway.  It owns the one USB device, drives it through the
//  CommandRouter, keeps the DeviceRegistry, SnapshotCache, NotifyRelay and
//  PollScheduler, and holds the sessions (the local UI and, in Phase 3, remote
//  WebSocket clients) that talk to it.  The decisive property is that the local
//  UI is a session like any other, so ordering, attribution and locks are the
//  same for everyone.  See networking_plan.md Phase 1-3.
//
//  v1 shares the single device Console currently opens, at handle 0.  Multiple
//  concurrently-open USB devices are a deeper USBDevice change and are out of
//  scope; the registry and router are already keyed by handle so that grows in
//  without a redesign here.
//

import Foundation
import Combine

/// A session on the hub: an id, a live role, and the closures that deliver
/// notifications and poll frames to it.  The local UI registers one of these;
/// the WebSocket server will register one per connection.
final class LinkHubSession {
    let id: LinkSessionID
    var role: LinkRole
    /// Delivered on an arbitrary queue.
    var onNotify: ((LinkNotifyFrame) -> Void)?
    var onResync: ((LinkResyncFrame) -> Void)?
    var onPoll: ((LinkPollFrame) -> Void)?
    var onDeviceEvent: ((DeviceRegistryEvent) -> Void)?

    init(id: LinkSessionID, role: LinkRole) {
        self.id = id
        self.role = role
    }
}

final class LinkHub {
    let policy: LinkPolicy
    let auth: LinkAuthStore
    let registry: DeviceRegistry

    private let usb: USBDevice
    private let snapshot = SnapshotCache()
    private let relay = NotifyRelay()
    private var router: CommandRouter?
    private var scheduler: PollScheduler?
    private var hubDevice: USBHubDevice?

    /// Sessions by id.  The local UI is always session 1; remote sessions get
    /// ids from 2 up.
    private var sessions: [LinkSessionID: LinkHubSession] = [:]
    private var nextSessionID: LinkSessionID = 2
    private let sessionLock = NSLock()

    private var notifyCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    /// The handle of the one device this v1 hub exposes.
    static let localHandle: UInt8 = 0

    /// Called after any device event, so the network service can refresh the
    /// DNS-SD TXT record (device count / serials) without polling.
    var onRegistryChange: (() -> Void)?

    /// Serials of the devices currently shared, for the advertisement.
    var sharedDeviceSerials: [String] { registry.devices.map { $0.info.serial } }

    /// Number of open sessions, for hub stats and the settings status line.
    var sessionCount: Int {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions.count
    }

    init(usb: USBDevice, policy: LinkPolicy, auth: LinkAuthStore) {
        self.usb = usb
        self.policy = policy
        self.auth = auth
        self.registry = DeviceRegistry()

        registry.onEvent = { [weak self] event in self?.broadcastDeviceEvent(event) }

        // Relay the device's notification stream: patch the snapshot cache,
        // then fan the packet out to every session with its attributed origin.
        notifyCancellable = usb.addNotificationObserver { [weak self] note in
            self?.handleNotification(note)
        }

        // Follow the USB connection: build the per-device machinery on connect,
        // tear it down on disconnect.
        usb.isConnectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                if connected { self?.deviceDidConnect() } else { self?.deviceDidDisconnect() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Device lifecycle

    private func deviceDidConnect() {
        // Read identity off the main thread; the control transfers block.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fallback = self.usb.selectedDevice?.serial ?? "unknown"
            guard let info = USBHubDevice.readInfo(from: self.usb, serialFallback: fallback) else { return }
            let device = USBHubDevice(usb: self.usb, info: info)
            let router = CommandRouter(handle: Self.localHandle, device: device, policy: self.policy)
            let scheduler = PollScheduler(device: device, policy: self.policy)
            scheduler.onPoll = { [weak self] session, slot, handle, payload in
                self?.deliverPoll(session: session, slot: slot, handle: handle, payload: payload)
            }
            self.hubDevice = device
            self.router = router
            self.scheduler = scheduler
            self.registry.deviceOnline(info)
            // Warm the snapshot so the first client screen is one reply.
            if let blob = self.usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0,
                                                     index: 2, length: BULK_PARAMS_SIZE) {
                self.snapshot.setBulk(blob)
            }
        }
    }

    private func deviceDidDisconnect() {
        if let serial = hubDevice?.info.serial { registry.deviceOffline(serial: serial) }
        scheduler?.stop()
        scheduler = nil
        router = nil
        hubDevice = nil
        snapshot.invalidate()
        relay.resyncAll(handle: Self.localHandle, reason: 1)
    }

    private func handleNotification(_ note: LinkNotification) {
        // BULK_INVALIDATED (event 0x03) means re-read; a PARAM_CHANGED patches
        // the cache in place.  Either way, fan it out verbatim.
        if note.eventID == 0x03 {
            snapshot.invalidate()
            refreshSnapshotSoon()
        } else {
            snapshot.applyParamChange(packet: note.packet)
        }
        relay.publish(handle: Self.localHandle, notification: note)
    }

    /// Re-read the bulk blob a moment after an invalidation so the cache is
    /// warm again without racing the firmware's own settle.
    private func refreshSnapshotSoon() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.usb.isConnected,
                  let blob = self.usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0,
                                                        index: 2, length: BULK_PARAMS_SIZE) else { return }
            self.snapshot.setBulk(blob)
        }
    }

    // MARK: - Sessions

    /// Register a session.  The local UI passes id 1; remote sessions omit it
    /// and get the next free id.
    func openSession(role: LinkRole, id: LinkSessionID? = nil) -> LinkHubSession {
        sessionLock.lock()
        let sid = id ?? { let n = nextSessionID; nextSessionID &+= 1; return n }()
        let session = LinkHubSession(id: sid, role: role)
        sessions[sid] = session
        sessionLock.unlock()

        relay.addSession(sid,
                         deliver: { [weak session] frame in session?.onNotify?(frame) },
                         resync: { [weak session] frame in session?.onResync?(frame) })
        return session
    }

    func closeSession(_ id: LinkSessionID) {
        sessionLock.lock(); sessions[id] = nil; sessionLock.unlock()
        relay.removeSession(id)
        scheduler?.unsubscribeAll(session: id)
        router?.sessionDidClose(id)
        registry.setLockHolder(handle: Self.localHandle, session: router?.currentLockHolder)
    }

    private func session(_ id: LinkSessionID) -> LinkHubSession? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions[id]
    }

    // MARK: - Command submission

    /// Submit one command on behalf of a session.  The completion runs on an
    /// arbitrary queue.  A command for a handle the hub does not have, or while
    /// no device is attached, answers NO_DEVICE.
    func submit(_ request: LinkCmdRequest, from sessionID: LinkSessionID,
                completion: @escaping (LinkCmdResponse) -> Void) {
        guard let session = session(sessionID) else {
            return completion(LinkCmdResponse(tag: request.tag, status: .noDevice))
        }
        guard request.handle == Self.localHandle, let router = router else {
            return completion(LinkCmdResponse(tag: request.tag, status: .noDevice))
        }
        router.submit(request, session: RouterSession(id: session.id, role: session.role)) { result in
            completion(result.response)
        }
    }

    // MARK: - Snapshot, polls, locks

    func currentSnapshot() -> DeviceSnapshot? { snapshot.snapshot() }

    func subscribePolls(session: LinkSessionID,
                        requests: [(slot: Int, spec: PollScheduler.PollSpec, hz: Double)])
        -> [(slot: Int, grantedHz: Double)] {
        guard let s = self.session(session), let scheduler = scheduler else {
            return requests.map { ($0.slot, 0) }
        }
        return scheduler.subscribe(session: session, role: s.role, requests: requests)
    }

    func unsubscribePolls(session: LinkSessionID, slots: [Int]) {
        scheduler?.unsubscribe(session: session, slots: slots)
    }

    @discardableResult
    func acquireLock(session: LinkSessionID, timeout: TimeInterval) -> Bool {
        guard let router = router else { return false }
        let ok = router.acquireLock(session: session, timeout: timeout)
        if ok { registry.setLockHolder(handle: Self.localHandle, session: session) }
        return ok
    }

    func releaseLock(session: LinkSessionID) {
        router?.releaseLock(session: session)
        registry.setLockHolder(handle: Self.localHandle, session: router?.currentLockHolder)
    }

    // MARK: - Fan-out helpers

    private func deliverPoll(session: LinkSessionID, slot: Int, handle: UInt8, payload: Data) {
        guard let s = self.session(session) else { return }
        s.onPoll?(LinkPollFrame(tag: 0, handle: handle, slot: UInt8(slot), payload: payload))
    }

    private func broadcastDeviceEvent(_ event: DeviceRegistryEvent) {
        sessionLock.lock(); let all = Array(sessions.values); sessionLock.unlock()
        for s in all { s.onDeviceEvent?(event) }
        onRegistryChange?()
    }
}
