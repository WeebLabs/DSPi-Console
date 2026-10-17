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
    /// Written by a role change on the main thread, read by every command on
    /// the connection's event loop, hence the lock.
    var role: LinkRole {
        get { roleLock.lock(); defer { roleLock.unlock() }; return storedRole }
        set { roleLock.lock(); storedRole = newValue; roleLock.unlock() }
    }
    private var storedRole: LinkRole
    private let roleLock = NSLock()
    /// The paired client this session authenticated as (`cid`), so a
    /// revocation or role change reaches it while it is connected.  nil for
    /// the local UI and for open-access sessions.  Set before the session is
    /// registered, so a revocation can never miss it.
    let clientID: Int?
    /// Fired when the hub closes the session itself (revocation), so the
    /// transport can close the socket with the right code.
    var onClosedByHub: (() -> Void)?
    /// Delivered on an arbitrary queue.
    var onNotify: ((LinkNotifyFrame) -> Void)?
    var onResync: ((LinkResyncFrame) -> Void)?
    var onPoll: ((LinkPollFrame) -> Void)?
    var onDeviceEvent: ((DeviceRegistryEvent) -> Void)?

    init(id: LinkSessionID, role: LinkRole, clientID: Int? = nil) {
        self.id = id
        self.storedRole = role
        self.clientID = clientID
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
    /// The registry handle of the attached device.  Not a constant: a
    /// replacement board plugged in while the old one is still inside its
    /// offline grace gets the next handle, and routing must follow it.
    private var attachedHandle: UInt8 = 0
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
    /// Next id to try.  Internal so tests can start it near the wrap.
    var nextSessionID: LinkSessionID = 2
    private let sessionLock = NSLock()

    private var notifyCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    /// Handle of the attached device, or 0 when none is attached.  Clients
    /// and the local transport address commands to this.
    var currentHandle: UInt8 {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return attachedHandle
    }
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

        // A revoked client is cut off at once; a re-roled one is re-roled at
        // once.  The router reads the session's role on every command.
        auth.onClientRevoked = { [weak self] cid in self?.closeSessions(forClient: cid) }
        auth.onClientRoleChanged = { [weak self] cid, role in self?.setRole(forClient: cid, role) }

        notifyCancellable = usb.addNotificationObserver { [weak self] note in
            self?.ingest(note)
        }

        // Follow the USB connection.  Every successful open publishes `true`,
        // including a switch from one board to another, which never publishes
        // `false` in between; so the trigger is the connection generation
        // changing, not the flag flipping.  Only a device the USB path attached
        // is detached on a USB drop.
        usb.isConnectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.usbConnectionChanged(connected: connected, generation: self.usb.generation)
            }
            .store(in: &cancellables)

        // Devices past their offline grace leave the registry.
        reaper = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.registry.reapOffline()
        }
    }

    deinit { reaper?.invalidate() }

    private var reaper: Timer?

    /// Generation of the USB connection the hub is attached to, or still
    /// probing for its identity; nil when USB reports none (or the attached
    /// device did not come from USB, as in tests).  Written on the main queue,
    /// read by the probe loop, hence the lock.
    private var usbGenerationStore: UInt64?
    private let usbGenerationLock = NSLock()
    private var usbGeneration: UInt64? {
        get { usbGenerationLock.lock(); defer { usbGenerationLock.unlock() }; return usbGenerationStore }
        set { usbGenerationLock.lock(); usbGenerationStore = newValue; usbGenerationLock.unlock() }
    }

    /// Builds the HubDevice for the current USB connection; nil means the
    /// device did not answer and is probed again.  Tests replace it to drive
    /// the switch and retry logic without hardware.
    var usbDeviceFactory: ((USBDevice) -> HubDevice?)?

    /// Pauses before each identity probe, first one immediate: about 2.5 s in
    /// all, the same patience fetchAll(afterConnect:) has for a board that is
    /// still booting after re-enumeration.  Internal so tests can shorten it.
    var identityRetryDelays: [TimeInterval] = [0, 0.1, 0.2, 0.4, 0.8, 1.0]

    /// The USB connection changed.  `generation` identifies the open; a switch
    /// between boards is a new generation with no `false` in between.  Internal
    /// so tests can drive it.
    func usbConnectionChanged(connected: Bool, generation: UInt64) {
        if connected {
            guard usbGeneration != generation else { return }   // same open
            usbGeneration = generation
            usbDidConnect(generation: generation)
        } else if usbGeneration != nil {
            usbGeneration = nil
            detachDevice()
        }
    }

    // MARK: - Device lifecycle

    /// Read the new connection's identity and attach it.  A board that STALLs
    /// or ignores its first REQ_GET_PLATFORM (still booting after a firmware
    /// flash) is probed again with backoff; the loop stops as soon as the
    /// connection it was started for is gone or replaced.
    private func usbDidConnect(generation: UInt64) {
        let usb = self.usb
        let probe: (USBDevice) -> HubDevice? = usbDeviceFactory ?? { usb in
            let fallback = usb.selectedDevice?.serial ?? "unknown"
            return USBHubDevice.readInfo(from: usb, serialFallback: fallback)
                .map { USBHubDevice(usb: usb, info: $0) }
        }
        let delays = identityRetryDelays
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for delay in delays {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                guard let self = self, self.usbGeneration == generation else { return }
                guard let device = probe(usb) else { continue }
                DispatchQueue.main.async {
                    guard self.usbGeneration == generation else { return }
                    self.attachDevice(device)
                }
                return
            }
        }
    }

    /// Attach a device: build its router and scheduler, register it, publish
    /// "attached", then warm the snapshot through the router.  Internal so
    /// tests can attach a fake device without USB.
    func attachDevice(_ device: HubDevice) {
        // A switch replaces the device: the old one goes offline (its handle
        // survives the grace window) and every session gets a resync.
        if self.device != nil { detachDevice() }

        let registered = registry.deviceOnline(device.info)
        let router = CommandRouter(handle: registered.handle, device: device, policy: policy)
        let scheduler = PollScheduler(device: device, policy: policy)
        scheduler.onPoll = { [weak self] session, slot, handle, payload in
            self?.deliverPoll(session: session, slot: slot, handle: handle, payload: payload)
        }
        deviceLock.lock()
        self.device = device
        self.router = router
        self.scheduler = scheduler
        self.attachedHandle = registered.handle
        deviceLock.unlock()

        attachedSubject.send(true)
        warmSnapshot()
    }

    /// Detach the current device.  A no-op when nothing is attached, so a
    /// stray disconnect does not send every session a resync for nothing.
    func detachDevice() {
        deviceLock.lock()
        guard device != nil else { deviceLock.unlock(); return }
        let serial = device?.info.serial
        let handle = attachedHandle
        scheduler?.stop()
        scheduler = nil
        // Queued commands answer NO_DEVICE; a local GET blocked on one of them
        // returns instead of waiting on a router nobody will run.
        router?.shutdown()
        router = nil
        device = nil
        attachedHandle = 0
        deviceLock.unlock()

        if let serial = serial { registry.deviceOffline(serial: serial) }
        snapshot.invalidate()
        attachedSubject.send(false)
        relay.resyncAll(handle: handle, reason: 1)
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
            ? (currentRouter?.consumeAttribution(within: Self.attributionWindow) ?? 0)
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
        relay.publish(handle: currentHandle, notification: attributed)
    }

    // MARK: - Snapshot

    /// Read the bulk blob through the router as the hub's internal session, so
    /// it takes its turn in the device's order and respects locks like any
    /// other command, and store it in the cache.
    private func warmSnapshot() {
        guard let router = currentRouter else { return }
        let req = LinkCmdRequest(tag: 0, handle: currentHandle, direction: .get,
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
    func openSession(role: LinkRole, id: LinkSessionID? = nil, clientID: Int? = nil) -> LinkHubSession {
        sessionLock.lock()
        let sid = id ?? allocateSessionIDLocked()
        let session = LinkHubSession(id: sid, role: role, clientID: clientID)
        sessions[sid] = session
        sessionLock.unlock()

        relay.addSession(sid,
                         deliver: { [weak session] frame in session?.onNotify?(frame) },
                         resync: { [weak session] frame in session?.onResync?(frame) })
        return session
    }

    /// Caller holds `sessionLock`.  The counter wraps, and one socket can
    /// re-authenticate indefinitely, so skip the reserved ids and any still
    /// open: landing on 1 would replace the local UI's entry.
    private func allocateSessionIDLocked() -> LinkSessionID {
        while true {
            let n = nextSessionID
            nextSessionID &+= 1
            if n == 0 || n == Self.localSessionID || n == Self.internalSessionID { continue }
            if sessions[n] == nil { return n }
        }
    }

    func closeSession(_ id: LinkSessionID) {
        sessionLock.lock()
        let closing = sessions.removeValue(forKey: id)
        sessionLock.unlock()
        // Callbacks are owned by the session and can capture it (or the
        // transport that owns it); clearing them here is what lets a closed
        // session deallocate.
        closing?.onNotify = nil
        closing?.onResync = nil
        closing?.onPoll = nil
        closing?.onDeviceEvent = nil
        closing?.onClosedByHub = nil
        relay.removeSession(id)
        currentScheduler?.unsubscribeAll(session: id)
        currentRouter?.sessionDidClose(id)
        registry.setLockHolder(handle: currentHandle, session: currentRouter?.currentLockHolder)
    }

    /// Close every session that authenticated as this client, telling each
    /// one so its socket closes with the revocation code.
    func closeSessions(forClient cid: Int) {
        sessionLock.lock()
        let victims = sessions.values.filter { $0.clientID == cid }
        sessionLock.unlock()
        for s in victims {
            let tellTransport = s.onClosedByHub   // closeSession clears it
            closeSession(s.id)
            tellTransport?()
        }
    }

    /// Apply a role change to every live session of this client.  Takes
    /// effect on the next command, since the router reads the role each time.
    func setRole(forClient cid: Int, _ role: LinkRole) {
        sessionLock.lock()
        for s in sessions.values where s.clientID == cid { s.role = role }
        sessionLock.unlock()
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
              request.handle == currentHandle,
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
        if ok { registry.setLockHolder(handle: currentHandle, session: session) }
        return ok
    }

    func releaseLock(session: LinkSessionID) {
        currentRouter?.releaseLock(session: session)
        registry.setLockHolder(handle: currentHandle, session: currentRouter?.currentLockHolder)
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
