//
//  LinkHub.swift
//  DSPi Console
//
//  The gateway.  It owns the one USB device, drives it through the
//  CommandRouter, keeps the DeviceRegistry, SnapshotCache, NotifyRelay and
//  PollScheduler, and holds the sessions (the local UI and remote WebSocket
//  clients) that talk to it.  The decisive property is that the local UI is a
//  session like any other, so ordering, attribution and locks are the same for
//  everyone.  See networking_plan.md Phase 1-3.
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
/// the WebSocket server registers one per connection.
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

    /// The attached device and its machinery.  Written only through
    /// attachDevice/detachDevice under `deviceLock`; read from any thread.
    private var router: CommandRouter?
    private var scheduler: PollScheduler?
    private var device: HubDevice?
    private let deviceLock = NSLock()

    /// True once a device is attached and its router exists.  This, not the USB
    /// layer's own flag, is what the local transport reports as "connected", so
    /// the view model never sees a device it cannot yet send to.
    private let attachedSubject = CurrentValueSubject<Bool, Never>(false)
    var isDeviceAttached: Bool { attachedSubject.value }
    var isDeviceAttachedPublisher: AnyPublisher<Bool, Never> { attachedSubject.eraseToAnyPublisher() }

    /// Sessions by id.  The local UI is always session 1; remote sessions get
    /// ids from 2 up.  Session 0xFFFF is the hub's own internal session, used
    /// for the snapshot reads it issues on its own behalf.
    private var sessions: [LinkSessionID: LinkHubSession] = [:]
    private var nextSessionID: LinkSessionID = 2
    private let sessionLock = NSLock()

    private var notifyCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    /// The handle of the one device this v1 hub exposes.
    static let localHandle: UInt8 = 0
    static let localSessionID: LinkSessionID = 1
    static let internalSessionID: LinkSessionID = 0xFFFF

    /// How long after a write a host-sourced notification is attributed to
    /// that writer.  USB round trips are milliseconds; this is generous.
    static let attributionWindow: TimeInterval = 0.5

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

        notifyCancellable = usb.addNotificationObserver { [weak self] note in
            self?.ingest(note)
        }

        // Follow the USB connection: read the device's identity off the main
        // thread, then attach synchronously on main so "attached" is published
        // only once the router exists.  Only a device the USB path attached is
        // detached on a USB drop; the published value's initial `false` (and
        // any repeat) must not tear down a device attached another way.
        usb.isConnectedPublisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                if connected {
                    self.usbDidConnect()
                } else if self.attachedViaUSB {
                    self.attachedViaUSB = false
                    self.detachDevice()
                }
            }
            .store(in: &cancellables)
    }

    /// True while the attached device came from the USB path, so a USB drop
    /// is the right reason to detach it.
    private var attachedViaUSB = false

    // MARK: - Device lifecycle

    private func usbDidConnect() {
        let usb = self.usb
        let generation = usb.generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fallback = usb.selectedDevice?.serial ?? "unknown"
            guard let info = USBHubDevice.readInfo(from: usb, serialFallback: fallback) else { return }
            DispatchQueue.main.async {
                guard let self = self, usb.isConnected, usb.generation == generation else { return }
                self.attachedViaUSB = true
                self.attachDevice(USBHubDevice(usb: usb, info: info))
            }
        }
    }

    /// Attach a device: build its router and scheduler, register it, publish
    /// "attached", then warm the snapshot through the router.  Internal so
    /// tests can attach a fake device without USB.
    func attachDevice(_ device: HubDevice) {
        let router = CommandRouter(handle: Self.localHandle, device: device, policy: policy)
        let scheduler = PollScheduler(device: device, policy: policy)
        scheduler.onPoll = { [weak self] session, slot, handle, payload in
            self?.deliverPoll(session: session, slot: slot, handle: handle, payload: payload)
        }
        deviceLock.lock()
        self.scheduler?.stop()
        self.device = device
        self.router = router
        self.scheduler = scheduler
        deviceLock.unlock()

        registry.deviceOnline(device.info)
        attachedSubject.send(true)
        warmSnapshot()
    }

    /// Detach the current device.  A no-op when nothing is attached, so a
    /// stray disconnect does not send every session a resync for nothing.
    func detachDevice() {
        deviceLock.lock()
        guard device != nil else { deviceLock.unlock(); return }
        let serial = device?.info.serial
        scheduler?.stop()
        scheduler = nil
        router = nil
        device = nil
        deviceLock.unlock()

        if let serial = serial { registry.deviceOffline(serial: serial) }
        snapshot.invalidate()
        attachedSubject.send(false)
        relay.resyncAll(handle: Self.localHandle, reason: 1)
    }

    private var currentRouter: CommandRouter? {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return router
    }

    private var currentScheduler: PollScheduler? {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return scheduler
    }

    // MARK: - Notifications

    /// Take one notification from the device: attribute it, patch the cache,
    /// fan it out.  Internal so tests can feed packets without USB.
    func ingest(_ note: LinkNotification) {
        // The USB reader marks a packet as host-written; only the hub knows
        // which session that host write belonged to.
        let origin: LinkSessionID = note.isHostSourced
            ? (currentRouter?.attribution(within: Self.attributionWindow) ?? 0)
            : 0
        let attributed = LinkNotification(packet: note.packet, origin: origin, receivedAt: note.receivedAt)

        // BULK_INVALIDATED (event 0x03) means re-read; a PARAM_CHANGED patches
        // the cache in place.  Either way, fan it out verbatim.
        if note.eventID == 0x03 {
            snapshot.invalidate()
            refreshSnapshotSoon()
        } else {
            snapshot.applyParamChange(packet: note.packet)
        }
        relay.publish(handle: Self.localHandle, notification: attributed)
    }

    // MARK: - Snapshot

    /// Read the bulk blob through the router as the hub's internal session, so
    /// it takes its turn in the device's order and respects locks like any
    /// other command, and store it in the cache.
    private func warmSnapshot() {
        guard let router = currentRouter else { return }
        let req = LinkCmdRequest(tag: 0, handle: Self.localHandle, direction: .get,
                                 bRequest: REQ_GET_ALL_PARAMS, wValue: 0, wIndex: 2,
                                 wLength: BULK_PARAMS_SIZE)
        let internalSession = RouterSession(id: Self.internalSessionID, role: .admin,
                                            exemptFromInflightCap: true)
        router.submit(req, session: internalSession) { [weak self] result in
            guard result.response.status == .ok, !result.response.payload.isEmpty else { return }
            self?.snapshot.setBulk(result.response.payload)
        }
    }

    /// Re-read the bulk blob a moment after an invalidation so the cache is
    /// warm again without racing the firmware's own settle.
    private func refreshSnapshotSoon() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.warmSnapshot()
        }
    }

    func currentSnapshot() -> DeviceSnapshot? { snapshot.snapshot() }

    // MARK: - Sessions

    /// Register a session.  The local UI passes `localSessionID`; remote
    /// sessions omit the id and get the next free one.
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
        currentScheduler?.unsubscribeAll(session: id)
        currentRouter?.sessionDidClose(id)
        registry.setLockHolder(handle: Self.localHandle, session: currentRouter?.currentLockHolder)
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
        guard let session = session(sessionID),
              request.handle == Self.localHandle,
              let router = currentRouter else {
            return completion(LinkCmdResponse(tag: request.tag, status: .noDevice))
        }
        let routerSession = RouterSession(id: session.id, role: session.role,
                                          exemptFromInflightCap: session.id == Self.localSessionID)
        router.submit(request, session: routerSession) { result in
            completion(result.response)
        }
    }

    // MARK: - Polls and locks

    func subscribePolls(session: LinkSessionID,
                        requests: [(slot: Int, spec: PollScheduler.PollSpec, hz: Double)])
        -> [(slot: Int, grantedHz: Double)] {
        guard let s = self.session(session), let scheduler = currentScheduler else {
            return requests.map { ($0.slot, 0) }
        }
        return scheduler.subscribe(session: session, role: s.role, requests: requests)
    }

    func unsubscribePolls(session: LinkSessionID, slots: [Int]) {
        currentScheduler?.unsubscribe(session: session, slots: slots)
    }

    @discardableResult
    func acquireLock(session: LinkSessionID, timeout: TimeInterval) -> Bool {
        guard let router = currentRouter else { return false }
        let ok = router.acquireLock(session: session, timeout: timeout)
        if ok { registry.setLockHolder(handle: Self.localHandle, session: session) }
        return ok
    }

    func releaseLock(session: LinkSessionID) {
        currentRouter?.releaseLock(session: session)
        registry.setLockHolder(handle: Self.localHandle, session: currentRouter?.currentLockHolder)
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
