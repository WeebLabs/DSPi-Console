//
//  CompositeTransport.swift
//  DSPi Console
//
//  The one transport the view model sits on.  It presents local USB devices
//  (through the hub's local session) and devices shared by other hubs on the
//  network as a single list, routes device selection to whichever transport
//  owns the device, and re-points the connection, selection, error and
//  notification streams at that transport.  The view model subscribes once
//  and never learns whether its device is local or remote.  See
//  networking_plan.md Phase 5.
//

import Foundation
import Combine

final class CompositeTransport: DeviceTransport {
    private let local: HubTransport
    private let tokens: LinkTokenStore
    private let clientName: String
    /// Builds a fresh client connection; injected so tests use a fake.
    private let makeClient: () -> LinkClientProtocol
    /// Asks the user for a hub's pairing code.  nil means pairing cannot be
    /// offered (headless), and connecting to a pin hub without a token fails.
    var pairingPrompt: ((String) -> String?)?
    /// Called on the main thread with a hub id when its connection fails, so
    /// the browser can look the hub's address up again.
    var hubUnreachable: ((String) -> Void)?

    private var remotes: [String: NetworkTransport] = [:]      // by hub id
    private var knownHubs: [DiscoveredHub] = []
    private var active: any DeviceTransport
    private let stateLock = NSLock()

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let devicesSubject = CurrentValueSubject<[DSPiDevice], Never>([])
    private let selectedSubject = CurrentValueSubject<DSPiDevice?, Never>(nil)
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)
    private let notifyFanout = NotificationFanout()

    private var activeCancellables = Set<AnyCancellable>()
    private var activeNotifyToken: AnyCancellable?
    private var remoteDeviceCancellables: [String: AnyCancellable] = [:]
    private var localDevicesCancellable: AnyCancellable?
    /// The local list as last emitted.  USBDevice publishes from @Published,
    /// which fires before the property is stored, so reading
    /// `local.availableDevices` inside the sink would see the previous list.
    private var localDevices: [DSPiDevice] = []
    /// The local selection as last emitted, for the same reason.  USBDevice
    /// empties its list on unplug before it clears the selection, so the
    /// auto-select must run again when the selection clears, not only when
    /// the list changes.
    private var localSelected: DSPiDevice?
    private var localSelectedCancellable: AnyCancellable?
    /// Set while autoSelectRemoteIfIdle runs: connecting subscribes to the
    /// remote's device list, which emits at once and recomputes re-entrantly.
    private var autoSelecting = false
    /// True while the active remote was picked by autoSelectRemoteIfIdle
    /// rather than by the user.  Such a remote yields to a local board that
    /// USBDevice opens, as it would have with no hub on the network.
    private var remoteWasAutoSelected = false

    init(local: HubTransport, tokens: LinkTokenStore, clientName: String,
         makeClient: @escaping () -> LinkClientProtocol) {
        self.local = local
        self.tokens = tokens
        self.clientName = clientName
        self.makeClient = makeClient
        self.active = local
        attach(to: local)
        localDevicesCancellable = local.availableDevicesPublisher
            .sink { [weak self] devices in
                guard let self = self else { return }
                self.stateLock.lock(); self.localDevices = devices; self.stateLock.unlock()
                self.recomputeDevices()
            }
        localSelectedCancellable = local.selectedDevicePublisher
            .sink { [weak self] device in self?.localSelectionChanged(device) }
    }

    /// A board USBDevice has opened takes back from a remote it picked on its
    /// own: a USB firmware flash unplugs the board for a moment, and the
    /// installer verifies whichever device the view model is on.  A cleared
    /// selection gives the auto-select its chance at a remote device.
    private func localSelectionChanged(_ device: DSPiDevice?) {
        stateLock.lock(); localSelected = device; stateLock.unlock()
        if device != nil {
            if remoteWasAutoSelected && active !== local {
                remoteWasAutoSelected = false
                attach(to: local)
                // Subscribing inside @Published's willSet replays the old
                // (nil) selection; publish the one being stored.
                selectedSubject.send(device)
            }
        } else {
            recomputeDevices()
        }
    }

    // MARK: - Hubs

    /// The browser's current view of the network; devices listed in a hub's
    /// TXT record appear in the picker before any connection is made.  A hub
    /// we already have a transport for is told its current address, so one
    /// that came back on a new lease is dialled there; a hub that has gone
    /// takes its unconnected transport with it.
    func updateHubs(_ hubs: [DiscoveredHub]) {
        stateLock.lock(); knownHubs = hubs; let existing = remotes; stateLock.unlock()
        for hub in hubs {
            if let remote = existing[hub.id], let url = hub.webSocketURL { remote.hubSeen(at: url) }
        }
        pruneRemotes()
        recomputeDevices()
    }

    private func remote(for hubID: String) -> NetworkTransport? {
        stateLock.lock(); defer { stateLock.unlock() }
        return remotes[hubID]
    }

    /// The transport for a hub, connecting on first use.
    private func remoteConnecting(to hub: DiscoveredHub) -> NetworkTransport? {
        if let existing = remote(for: hub.id) { return existing }
        guard let url = hub.webSocketURL else { return nil }
        let transport = NetworkTransport(client: makeClient(), hubID: hub.id, hubName: hub.name,
                                         tokens: tokens, clientName: clientName)
        transport.pairingPrompt = pairingPrompt
        let hubID = hub.id
        transport.onConnectionFailed = { [weak self] in self?.remoteFailed(hubID) }
        stateLock.lock(); remotes[hub.id] = transport; stateLock.unlock()
        remoteDeviceCancellables[hub.id] = transport.availableDevicesPublisher
            .sink { [weak self] _ in self?.recomputeDevices() }
        transport.connect(to: url)
        return transport
    }

    /// A remote's socket failed.  It reconnects with backoff on its own; here
    /// the browser is asked whether the hub moved, and a hub that has also
    /// left the browse list is given up on.
    private func remoteFailed(_ hubID: String) {
        hubUnreachable?(hubID)
        pruneRemotes()
        recomputeDevices()
    }

    /// Drop every transport whose hub is no longer listed and whose session is
    /// down.  A live session outlasts a Bonjour hiccup; a dead one with no hub
    /// to go back to would otherwise retry forever, and, if it was the active
    /// transport, hold the view model on a device nothing can reach.  That
    /// case hands the view model back to the local transport.
    private func pruneRemotes() {
        stateLock.lock()
        let hubIDs = Set(knownHubs.map { $0.id })
        let gone = remotes.filter { !hubIDs.contains($0.key) && !$0.value.isConnected }
        for id in gone.keys { remotes[id] = nil }
        stateLock.unlock()
        guard !gone.isEmpty else { return }
        for (id, remote) in gone {
            remoteDeviceCancellables[id] = nil
            if remote === active {
                remoteWasAutoSelected = false
                attach(to: local)
            }
            remote.disconnect()
        }
    }

    // MARK: - Device list

    private func recomputeDevices() {
        stateLock.lock()
        var merged = localDevices
        let hubs = knownHubs
        let connected = remotes
        stateLock.unlock()
        var seen = Set(merged.map { $0.serial })
        func append(_ device: DSPiDevice) {
            guard !seen.contains(device.serial) else { return }
            merged.append(device); seen.insert(device.serial)
        }
        var listed = Set<String>()
        for hub in hubs {
            if let t = connected[hub.id], !t.availableDevices.isEmpty {
                t.availableDevices.forEach(append)
                listed.insert(hub.id)
            } else {
                // Not connected yet: what the TXT record advertises.
                for serial in hub.serials {
                    append(DSPiDevice(serial: serial, locationID: 0,
                                      hub: RemoteHubRef(hubID: hub.id, hubName: hub.name, handle: 255),
                                      remoteName: nil))
                }
            }
        }
        // A session that is up lists its devices whether or not Bonjour shows
        // the hub right now; the device being driven must not vanish from the
        // picker on a missed announcement.
        for (id, t) in connected.sorted(by: { $0.key < $1.key }) where !listed.contains(id) {
            t.availableDevices.forEach(append)
        }
        // The device the view model is on stays listed while its hub cannot
        // be reached, so the picker keeps showing what is selected.
        if active !== local, let selected = active.selectedDevice { append(selected) }
        devicesSubject.send(merged)
        autoSelectRemoteIfIdle(merged, hubs: hubs)
    }

    /// USBDevice selects the first local board on its own; nothing did the
    /// same for a remote one, so with only a shared device on the network the
    /// picker showed it but never connected.  Pick it when no local board is
    /// present or selected, and only on a hub that will not stop to ask for a
    /// PIN: a pairing prompt nobody asked for at launch is worse than a click.
    private func autoSelectRemoteIfIdle(_ merged: [DSPiDevice], hubs: [DiscoveredHub]) {
        guard !autoSelecting, active === local else { return }
        stateLock.lock(); let noLocal = localDevices.isEmpty && localSelected == nil; stateLock.unlock()
        guard noLocal else { return }
        let candidate = merged.first { device in
            guard let ref = device.hub, let hub = hubs.first(where: { $0.id == ref.hubID }) else { return false }
            return hub.authMode == "none" || tokens.token(forHub: hub.id) != nil
        }
        guard let device = candidate else { return }
        autoSelecting = true
        defer { autoSelecting = false }
        select(device)
        remoteWasAutoSelected = active !== local
    }

    // MARK: - Switching

    private func attach(to transport: any DeviceTransport) {
        activeCancellables.removeAll()
        activeNotifyToken = nil
        active = transport
        transport.isConnectedPublisher.sink { [weak self] in self?.connectedSubject.send($0) }
            .store(in: &activeCancellables)
        transport.selectedDevicePublisher.sink { [weak self] in self?.selectedSubject.send($0) }
            .store(in: &activeCancellables)
        transport.errorMessagePublisher.sink { [weak self] in self?.errorSubject.send($0) }
            .store(in: &activeCancellables)
        activeNotifyToken = transport.addNotificationObserver { [weak self] in self?.notifyFanout.publish($0) }
    }

    // MARK: - DeviceTransport

    var session: LinkSessionID { active.session }
    var generation: UInt64 { active.generation }
    var isConnected: Bool { connectedSubject.value }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] { devicesSubject.value }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { devicesSubject.eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? { selectedSubject.value }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { selectedSubject.eraseToAnyPublisher() }
    var errorMessage: String? { errorSubject.value }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }

    /// The user's choice: a remote picked here stays put when a local board
    /// appears.
    func selectDevice(_ device: DSPiDevice) {
        remoteWasAutoSelected = false
        select(device)
    }

    private func select(_ device: DSPiDevice) {
        guard let ref = device.hub else {
            if active !== local { attach(to: local) }
            local.selectDevice(device)
            return
        }
        // A hub with a transport already (its session may be up while Bonjour
        // has lost sight of it) is used as is.
        let transport: NetworkTransport
        if let existing = remote(for: ref.hubID) {
            transport = existing
        } else {
            stateLock.lock(); let hub = knownHubs.first { $0.id == ref.hubID }; stateLock.unlock()
            guard let hub = hub else {
                errorSubject.send("Hub \(ref.hubName) is no longer on the network.")
                return
            }
            guard let connecting = remoteConnecting(to: hub) else {
                errorSubject.send("Hub \(ref.hubName) has an address Console cannot connect to (\(hub.displayAddress)).")
                return
            }
            transport = connecting
        }
        transport.bind(serial: device.serial)
        if active !== transport { attach(to: transport) }
    }

    func reconnect() { active.reconnect() }
    func disconnect() { active.disconnect() }
    func markDisconnected() { active.markDisconnected() }

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        active.sendControlRequest(request: request, value: value, index: index, data: data)
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16)
        -> Result<Data, LinkStatus> {
        active.getControlResult(request: request, value: value, index: index, length: length)
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        notifyFanout.add(handler)
    }

    /// The transport a lock was taken on, so a device switch mid-flow still
    /// releases it where it was granted.  Guarded by `stateLock`.
    private var lockedTransport: (any DeviceTransport)?

    func acquireDeviceLock(reason: String, timeout: TimeInterval) -> Bool {
        let transport = active
        guard transport.acquireDeviceLock(reason: reason, timeout: timeout) else { return false }
        stateLock.lock(); lockedTransport = transport; stateLock.unlock()
        return true
    }

    func releaseDeviceLock() {
        stateLock.lock(); let transport = lockedTransport; lockedTransport = nil; stateLock.unlock()
        transport?.releaseDeviceLock()
    }

    /// True while the view model is driving a device on another hub.
    var isRemoteActive: Bool { active !== local }
}
