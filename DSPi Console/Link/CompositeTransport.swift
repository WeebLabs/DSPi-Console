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
    /// Set while autoSelectRemoteIfIdle runs: connecting subscribes to the
    /// remote's device list, which emits at once and recomputes re-entrantly.
    private var autoSelecting = false

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
    }

    // MARK: - Hubs

    /// The browser's current view of the network; devices listed in a hub's
    /// TXT record appear in the picker before any connection is made.
    func updateHubs(_ hubs: [DiscoveredHub]) {
        stateLock.lock(); knownHubs = hubs; stateLock.unlock()
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
        stateLock.lock(); remotes[hub.id] = transport; stateLock.unlock()
        remoteDeviceCancellables[hub.id] = transport.availableDevicesPublisher
            .sink { [weak self] _ in self?.recomputeDevices() }
        transport.connect(to: url)
        return transport
    }

    // MARK: - Device list

    private func recomputeDevices() {
        stateLock.lock()
        var merged = localDevices
        let hubs = knownHubs
        let connected = remotes
        stateLock.unlock()
        var seen = Set(merged.map { $0.serial })
        for hub in hubs {
            if let t = connected[hub.id], !t.availableDevices.isEmpty {
                for d in t.availableDevices where !seen.contains(d.serial) {
                    merged.append(d); seen.insert(d.serial)
                }
            } else {
                // Not connected yet: what the TXT record advertises.
                for serial in hub.serials where !seen.contains(serial) {
                    merged.append(DSPiDevice(serial: serial, locationID: 0,
                                             hub: RemoteHubRef(hubID: hub.id, hubName: hub.name, handle: 255),
                                             remoteName: nil))
                    seen.insert(serial)
                }
            }
        }
        devicesSubject.send(merged)
        autoSelectRemoteIfIdle(merged, hubs: hubs)
    }

    /// USBDevice selects the first local board on its own; nothing did the
    /// same for a remote one, so with only a shared device on the network the
    /// picker showed it but never connected.  Pick it when no local board is
    /// present or selected, and only on a hub that will not stop to ask for a
    /// PIN: a pairing prompt nobody asked for at launch is worse than a click.
    private func autoSelectRemoteIfIdle(_ merged: [DSPiDevice], hubs: [DiscoveredHub]) {
        guard !autoSelecting, active === local, local.selectedDevice == nil else { return }
        stateLock.lock(); let noLocal = localDevices.isEmpty; stateLock.unlock()
        guard noLocal else { return }
        let candidate = merged.first { device in
            guard let ref = device.hub, let hub = hubs.first(where: { $0.id == ref.hubID }) else { return false }
            return hub.authMode == "none" || tokens.token(forHub: hub.id) != nil
        }
        guard let device = candidate else { return }
        autoSelecting = true
        defer { autoSelecting = false }
        selectDevice(device)
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

    func selectDevice(_ device: DSPiDevice) {
        guard let ref = device.hub else {
            if active !== local { attach(to: local) }
            local.selectDevice(device)
            return
        }
        stateLock.lock(); let hub = knownHubs.first { $0.id == ref.hubID }; stateLock.unlock()
        guard let hub = hub else {
            errorSubject.send("Hub \(ref.hubName) is no longer on the network.")
            return
        }
        guard let transport = remoteConnecting(to: hub) else {
            errorSubject.send("Hub \(ref.hubName) has an address Console cannot connect to (\(hub.displayAddress)).")
            return
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

    /// True while the view model is driving a device on another hub.
    var isRemoteActive: Bool { active !== local }
}
