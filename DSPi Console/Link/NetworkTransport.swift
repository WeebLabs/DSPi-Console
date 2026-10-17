//
//  NetworkTransport.swift
//  DSPi Console
//
//  A DeviceTransport over a DSPi Link client connection: the view model drives
//  a device on another machine's hub exactly as it drives a local one.  Bound
//  to one remote device (a handle on the hub); commands tunnel as CMD frames,
//  notifications arrive as NOTIFY frames with the hub's session attribution,
//  a resync becomes the bulk re-read the view model already knows, and the
//  first bulk read uses the hub's snapshot when it offers one.  Reconnects
//  with backoff after a socket failure.  See networking_plan.md Phase 5.
//

import Foundation
import Combine

final class NetworkTransport: DeviceTransport {
    let client: LinkClientProtocol
    let hubID: String
    let hubName: String
    private let tokens: LinkTokenStore
    private let clientName: String

    private var url: URL?
    private var boundHandle: UInt8?
    private var boundSerial: String?
    private let notifyFanout = NotificationFanout()
    private var cancellables = Set<AnyCancellable>()

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let devicesSubject = CurrentValueSubject<[DSPiDevice], Never>([])
    private let selectedSubject = CurrentValueSubject<DSPiDevice?, Never>(nil)
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)

    /// Bumps on every connection that reaches ready, so work queued for one
    /// connection is not delivered over the next.
    private var generationValue: UInt64 = 0
    private let generationLock = NSLock()

    /// Reconnect state is touched on the main thread only; callers on GCD
    /// queues (the bulk-read failure paths) hop there first.
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var wantConnection = false

    /// Called on the main thread when the hub needs a PIN.  Returns the PIN
    /// or nil to give up.  The app installs a modal prompt.
    var pairingPrompt: ((String) -> String?)?
    /// True while the prompt is up.  The modal spins the run loop, so a
    /// reconnect can ask for a PIN again underneath it; that ask waits.
    private var pairingPromptShowing = false
    /// A PIN typed after the hub's auth deadline closed the socket: sent on
    /// the next connection that asks, instead of prompting again.
    private var pendingPIN: String?

    init(client: LinkClientProtocol, hubID: String, hubName: String,
         tokens: LinkTokenStore, clientName: String) {
        self.client = client
        self.hubID = hubID
        self.hubName = hubName
        self.tokens = tokens
        self.clientName = clientName

        client.statePublisher
            .sink { [weak self] state in self?.clientStateChanged(state) }
            .store(in: &cancellables)
        client.devicesPublisher
            .sink { [weak self] devices in self?.remoteDevicesChanged(devices) }
            .store(in: &cancellables)
        client.onNotify = { [weak self] frame in
            guard let self = self, frame.handle == self.boundHandle else { return }
            self.notifyFanout.publish(LinkNotification(packet: frame.packet, origin: frame.origin,
                                                       receivedAt: Date()))
        }
        client.onResync = { [weak self] frame in
            guard let self = self, frame.handle == self.boundHandle else { return }
            self.notifyFanout.publish(LinkNotification(packet: Self.syntheticBulkInvalidated,
                                                       origin: 0, receivedAt: Date()))
        }
    }

    private static let syntheticBulkInvalidated = Data([0x02, 0x03, 0, 0, 0, 0, 0, 0])

    // MARK: - Connection

    /// Open (or re-open) the connection to the hub.
    func connect(to url: URL) {
        onMain {
            self.url = url
            self.wantConnection = true
            self.reconnectAttempt = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.client.connect(to: url, clientName: self.clientName, token: self.tokens.token(forHub: self.hubID))
        }
    }

    /// Run now when already on the main thread (so tests and view actions see
    /// the effect synchronously), otherwise hop there.
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Bind to one of the hub's devices.  The device list may not have
    /// arrived yet, so bind by serial and resolve the handle when it does.
    /// Selecting a device again after the user cancelled pairing (which gave
    /// the connection up) is how they ask to try again.
    func bind(serial: String) {
        boundSerial = serial
        resolveBinding()
        publishConnected()
        if !wantConnection, let url = url { connect(to: url) }
    }

    private func resolveBinding() {
        guard let serial = boundSerial,
              let info = client.devices.first(where: { $0.serial == serial }) else {
            boundHandle = nil
            selectedSubject.send(nil)
            return
        }
        boundHandle = UInt8(truncatingIfNeeded: info.handle)
        selectedSubject.send(Self.device(from: info, hubID: hubID, hubName: hubName))
    }

    private func clientStateChanged(_ state: LinkClientState) {
        switch state {
        case .ready:
            reconnectAttempt = 0
            generationLock.lock(); generationValue &+= 1; generationLock.unlock()
            errorSubject.send(nil)
        case .awaitingAuth(let needsPairing) where needsPairing:
            if let pin = pendingPIN {
                pendingPIN = nil
                sendPIN(pin)
            } else {
                pair()
            }
        case .failed(let reason):
            errorSubject.send(reason)
            scheduleReconnect()
        case .disconnected:
            break
        default:
            break
        }
        publishConnected()
    }

    private func pair() {
        guard let prompt = pairingPrompt else {
            errorSubject.send("This hub needs pairing.")
            return
        }
        guard !pairingPromptShowing else { return }
        pairingPromptShowing = true
        let pin = prompt(hubName)
        pairingPromptShowing = false
        guard let pin = pin else {
            wantConnection = false
            reconnectWork?.cancel()
            reconnectWork = nil
            client.disconnect()
            return
        }
        // The hub gives a client 30 s to authenticate; a slower answer finds
        // the socket closed and a reconnect under way.  Hold the PIN for it.
        guard case .awaitingAuth = client.state else {
            pendingPIN = pin
            return
        }
        sendPIN(pin)
    }

    private func sendPIN(_ pin: String) {
        client.pair(pin: pin, clientName: clientName, role: .control) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let token):
                // An open-access hub grants a session without a token.
                if !token.isEmpty { self.tokens.setToken(token, forHub: self.hubID) }
            case .failure(let error):
                self.errorSubject.send("Pairing failed: \(error)")
                // A wrong PIN leaves the hub waiting; ask again.
                if case .rejected = error { self.pair() }
            }
        }
    }

    /// 1 s, 2 s, 4 s ... capped at 30 s (spec 5).  Main thread only: the
    /// delayed work is queued on the main queue, which every caller has a
    /// run loop for, unlike a Timer created on a GCD worker.
    private func scheduleReconnect() {
        guard wantConnection, let url = url else { return }
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantConnection else { return }
            self.reconnectWork = nil
            self.client.connect(to: url, clientName: self.clientName,
                                token: self.tokens.token(forHub: self.hubID))
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func remoteDevicesChanged(_ infos: [LinkDeviceInfo]) {
        devicesSubject.send(infos.map { Self.device(from: $0, hubID: hubID, hubName: hubName) })
        resolveBinding()
        publishConnected()
    }

    private func publishConnected() {
        let online = boundHandle != nil && client.devices.first { UInt8(truncatingIfNeeded: $0.handle) == boundHandle }?.state != .offline
        let value = client.state == .ready && online
        if connectedSubject.value != value { connectedSubject.send(value) }
    }

    static func device(from info: LinkDeviceInfo, hubID: String, hubName: String) -> DSPiDevice {
        DSPiDevice(serial: info.serial, locationID: 0,
                   hub: RemoteHubRef(hubID: hubID, hubName: hubName,
                                     handle: UInt8(truncatingIfNeeded: info.handle)),
                   remoteName: info.name)
    }

    // MARK: - DeviceTransport

    var session: LinkSessionID { client.sessionID }
    var generation: UInt64 { generationLock.lock(); defer { generationLock.unlock() }; return generationValue }

    var isConnected: Bool { connectedSubject.value }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] { devicesSubject.value }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { devicesSubject.eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? { selectedSubject.value }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { selectedSubject.eraseToAnyPublisher() }
    var errorMessage: String? { errorSubject.value }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }

    func selectDevice(_ device: DSPiDevice) { bind(serial: device.serial) }
    func reconnect() { if let url = url { connect(to: url) } }
    func disconnect() {
        onMain {
            self.wantConnection = false
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.client.disconnect()
        }
    }

    /// The command layer gave up on the link (a bulk read that never
    /// answered).  Drop the socket so the view model sees connected=false and
    /// re-runs its connect sequence on the next ready, then come back with
    /// backoff.  Called from GCD queues, so everything happens on main.
    func markDisconnected() {
        onMain {
            guard self.wantConnection else { return }
            self.client.disconnect()
            if self.connectedSubject.value { self.connectedSubject.send(false) }
            self.scheduleReconnect()
        }
    }

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        guard let handle = boundHandle else { return }
        let req = LinkCmdRequest(tag: 0, handle: handle, direction: .set, bRequest: request,
                                 wValue: value, wIndex: index, payload: data)
        client.command(req) { _ in }
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16)
        -> Result<Data, LinkStatus> {
        guard let handle = boundHandle else { return .failure(.noDevice) }
        // A main-thread caller cannot be left waiting on the network: with no
        // ready session the answer is known now, so give it without a wait.
        if Thread.isMainThread, client.state != .ready { return .failure(.noDevice) }

        // The bulk read is the one the hub can answer from its cache in a
        // single reply; use it when offered and fall through on any failure.
        if request == REQ_GET_ALL_PARAMS, client.capabilities.contains(LinkCapability.snapshot.rawValue),
           let blob = awaitSnapshot(handle: handle), blob.count >= Int(length) {
            return .success(blob)
        }

        let req = LinkCmdRequest(tag: 0, handle: handle, direction: .get, bRequest: request,
                                 wValue: value, wIndex: index, wLength: length)
        var out: Result<Data, LinkStatus> = .failure(.timeout)
        waitFor { done in
            self.client.command(req) { response in
                out = response.status == .ok ? .success(response.payload) : .failure(response.status)
                done()
            }
        }
        return out
    }

    private func awaitSnapshot(handle: UInt8) -> Data? {
        var blob: Data?
        waitFor { done in
            self.client.snapshot(handle: handle) { result in
                if case .success(let body) = result, let b64 = body.bulkB64 {
                    blob = Data(base64Encoded: b64)
                }
                done()
            }
        }
        return blob
    }

    /// Longest a main-thread caller is held.  Off main the hub's own limits
    /// apply; the client times a command out before this.
    static let mainThreadWait: TimeInterval = 1.0
    /// Non-zero while a main-thread wait is spinning the run loop.
    private var mainWaitDepth = 0

    /// Block the caller until `work` signals done.  The command layer calls
    /// the blocking GET off the main thread, where a semaphore is right.  The
    /// client completes on main, so a main-thread caller spins the run loop
    /// instead, for a short bounded time only: a hub that stops answering
    /// must not freeze the UI.  A timer that fires inside that spin and asks
    /// for another GET gets an immediate failure rather than nesting another
    /// spin, which is how a 60 ms poll once piled up 15 s waits.
    private func waitFor(_ work: (@escaping () -> Void) -> Void) {
        if Thread.isMainThread {
            guard mainWaitDepth == 0 else { return }
            mainWaitDepth += 1
            defer { mainWaitDepth -= 1 }
            var finished = false
            work { finished = true }
            let deadline = Date().addingTimeInterval(Self.mainThreadWait)
            while !finished && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            let sem = DispatchSemaphore(value: 0)
            work { sem.signal() }
            _ = sem.wait(timeout: .now() + 15)
        }
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        notifyFanout.add(handler)
    }
}
