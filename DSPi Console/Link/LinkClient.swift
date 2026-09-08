//
//  LinkClient.swift
//  DSPi Console
//
//  The client half of DSPi Link: one URLSessionWebSocketTask to one hub, the
//  session lifecycle of spec section 5, the JSON control plane of section 7
//  and the binary data plane of section 8.  It owns no reconnect policy - the
//  transport above decides when to call connect again - but it is reusable, so
//  a connect after a failure starts a clean session on the same object.
//
//  Threading: every callback, publisher and state change is delivered on the
//  main thread; requests may be issued from any thread.  Internal state lives
//  behind one recursive lock, and completions are always invoked outside it.
//

import Foundation
import Combine

final class LinkClient: LinkClientProtocol {

    // MARK: - Tunables

    /// Sub-protocol the hub requires and echoes (spec 4).
    private static let subProtocol = "dspi-link-1"
    /// PIN sent by the `none`-mode probe.  The hub ignores its value there.
    private static let openAccessPIN = "000000"

    private static let requestTimeout: TimeInterval = 10
    /// Bulk transfers get longer: the hub itself waits 5 s for the device and
    /// the blob is thousands of bytes on the wire behind that.
    private static let bulkTimeout: TimeInterval = 15
    private static let bulkOpcodes: Set<UInt8> = [0xA0, 0xA1, 0xA2, 0xA3]
    private static let pingInterval: TimeInterval = 15
    /// A hub close frame and the receive failure it provokes race each other;
    /// when the failure wins, wait this long for the close code to land so the
    /// reason says "revoked" rather than "connection lost".
    private static let closeCodeGrace: TimeInterval = 0.3

    // MARK: - Published state

    private let stateSubject = CurrentValueSubject<LinkClientState, Never>(.disconnected)
    private let devicesSubject = CurrentValueSubject<[LinkDeviceInfo], Never>([])

    var state: LinkClientState { stateSubject.value }
    var statePublisher: AnyPublisher<LinkClientState, Never> { stateSubject.eraseToAnyPublisher() }
    var devices: [LinkDeviceInfo] { devicesSubject.value }
    var devicesPublisher: AnyPublisher<[LinkDeviceInfo], Never> { devicesSubject.eraseToAnyPublisher() }

    // MARK: - Guarded state

    /// Recursive so a handler that already holds the lock can call a helper
    /// that takes it; completions still run outside.
    private let lock = NSRecursiveLock()
    /// Timeout work items and the ping timer run here, never on the caller.
    private let queue = DispatchQueue(label: "com.foxdac.link.client")
    private let urlSession = URLSession.shared

    /// Where this connection is in the lifecycle.  Kept separately from the
    /// published state, which lags by one main-thread hop.
    private enum Phase { case idle, connecting, awaitingAuth, ready, closed }
    private var phase: Phase = .idle

    /// Bumped on every connect and teardown, so callbacks belonging to a
    /// previous socket (a late receive, a pending timeout) do nothing.
    private var generation = 0
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?

    private var clientName = "DSPi Console"
    /// The token to offer when the hub's hello says `auth: pin`.  Cleared
    /// once used, so a re-auth on the same socket cannot replay it.
    private var pendingToken: String?

    private var _hubInfo: LinkHubInfo?
    private var _capabilities: [String] = []
    private var _limits: LinkLimits?
    private var _sessionID: LinkSessionID = 0
    private var _role: LinkRole?

    private var _onNotify: ((LinkNotifyFrame) -> Void)?
    private var _onPoll: ((LinkPollFrame) -> Void)?
    private var _onResync: ((LinkResyncFrame) -> Void)?

    private var nextRequestID = 1
    /// Tags are ours to assign (spec 8.2); 0 is skipped so a zero tag in a log
    /// always means "unset" rather than "the first command".
    private var nextTag: UInt16 = 1

    private struct PendingJSON {
        let completion: (Result<LinkOk, LinkClientError>) -> Void
        let timeout: DispatchWorkItem
    }
    private struct PendingCommand {
        let tag: UInt16
        let completion: (LinkCmdResponse) -> Void
        let timeout: DispatchWorkItem
    }
    private var pendingJSON: [Int: PendingJSON] = [:]
    private var pendingCommands: [UInt16: PendingCommand] = [:]

    // MARK: - Protocol properties

    var hubInfo: LinkHubInfo? { sync { _hubInfo } }
    var capabilities: [String] { sync { _capabilities } }
    var limits: LinkLimits? { sync { _limits } }
    var sessionID: LinkSessionID { sync { _sessionID } }
    var role: LinkRole? { sync { _role } }

    var onNotify: ((LinkNotifyFrame) -> Void)? {
        get { sync { _onNotify } }
        set { sync { _onNotify = newValue } }
    }
    var onPoll: ((LinkPollFrame) -> Void)? {
        get { sync { _onPoll } }
        set { sync { _onPoll = newValue } }
    }
    var onResync: ((LinkResyncFrame) -> Void)? {
        get { sync { _onResync } }
        set { sync { _onResync = newValue } }
    }

    // MARK: - Connect

    func connect(to url: URL, clientName: String, token: String?) {
        let generation: Int = sync {
            // Reuse: whatever a previous session left behind goes now, with its
            // pending requests failed, before the new socket exists.
            resetLocked()
            self.generation &+= 1
            self.clientName = clientName
            // Stored before the socket exists: the hub's hello can arrive
            // before connect returns, and that is when the token is offered.
            pendingToken = token
            phase = .connecting
            return self.generation
        }
        publishState(.connecting)
        publishDevices([])

        var request = URLRequest(url: url)
        // URLSession offers a protocols: argument too, but the header is the
        // form that survives a caller-supplied URLRequest, and the hub refuses
        // an upgrade that does not ask for the sub-protocol.
        request.setValue(Self.subProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let task = urlSession.webSocketTask(with: request)
        sync { self.task = task }
        task.resume()
        receiveNext(task: task, generation: generation)
        startPing(task: task, generation: generation)

        let hello = LinkHelloClient(client: LinkClientInfo(name: clientName,
                                                           app: "DSPi Console",
                                                           version: Self.appVersion))
        send(.helloClient(hello), generation: generation)
    }

    func disconnect() {
        shutdown(generation: sync { generation }, newState: .disconnected, closeNormally: true)
    }

    // MARK: - Pairing

    func pair(pin: String, clientName: String, role: LinkRole,
              completion: @escaping (Result<String, LinkClientError>) -> Void) {
        sendRequest({ id in .authPair(LinkAuthPair(id: id, pin: pin, name: clientName, role: role)) },
                    requiresReady: false) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let ok):
                guard let body = try? ok.decodeBody(LinkAuthOkBody.self) else {
                    return completion(.failure(.protocolError("auth.pair reply had no session")))
                }
                self.becameReady(session: body.session, role: body.role)
                // A `none`-mode hub grants the session without issuing a
                // token; there is nothing to store, so the string is empty.
                completion(.success(body.token ?? ""))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Commands

    func command(_ request: LinkCmdRequest, completion: @escaping (LinkCmdResponse) -> Void) {
        var outbound = request
        var generation = 0
        var task: URLSessionWebSocketTask?

        let accepted: Bool = sync {
            guard phase == .ready, let live = self.task else { return false }
            let tag = nextTag
            nextTag = nextTag == UInt16.max ? 1 : nextTag &+ 1
            outbound.tag = tag
            generation = self.generation
            task = live

            let isBulk = Self.bulkOpcodes.contains(request.bRequest)
            let work = DispatchWorkItem { [weak self] in
                self?.timeOutCommand(tag: tag, generation: generation)
            }
            pendingCommands[tag] = PendingCommand(tag: tag, completion: completion, timeout: work)
            queue.asyncAfter(deadline: .now() + (isBulk ? Self.bulkTimeout : Self.requestTimeout),
                             execute: work)
            return true
        }

        guard accepted, let task = task else {
            // Before the session is ready there is no device the hub could
            // reach on our behalf, and NO_DEVICE is the status the data plane
            // has for exactly that (spec 8.1); it is also what the hub itself
            // answers with when nothing is attached, so callers need no second
            // code path.
            return main { completion(LinkCmdResponse(tag: request.tag, status: .noDevice)) }
        }

        let frame = LinkFrame.cmdRequest(outbound).encode()
        task.send(.data(frame)) { [weak self] error in
            if error != nil { self?.socketFailed(generation: generation, error: error) }
        }
    }

    // MARK: - Snapshot, polls and locks

    func snapshot(handle: UInt8,
                  completion: @escaping (Result<LinkSnapshotBody, LinkClientError>) -> Void) {
        sendRequest({ id in .deviceSnapshot(LinkDeviceSnapshotRequest(id: id, handle: Int(handle))) }) { result in
            completion(result.flatMap { ok in
                guard let body = try? ok.decodeBody(LinkSnapshotBody.self) else {
                    return .failure(.protocolError("device.snapshot reply was not a snapshot"))
                }
                return .success(body)
            })
        }
    }

    func subscribePolls(handle: UInt8, polls: [LinkPollSpec],
                        completion: @escaping (Result<[LinkPollGrant], LinkClientError>) -> Void) {
        sendRequest({ id in .pollSubscribe(LinkPollSubscribe(id: id, handle: Int(handle), polls: polls)) }) { result in
            completion(result.flatMap { ok in
                guard let body = try? ok.decodeBody(LinkPollSubscribeBody.self) else {
                    return .failure(.protocolError("poll.subscribe reply had no grants"))
                }
                return .success(body.granted)
            })
        }
    }

    func unsubscribePolls(handle: UInt8, slots: [Int]) {
        sendRequest({ id in .pollUnsubscribe(LinkPollUnsubscribe(id: id, handle: Int(handle), slots: slots)) },
                    completion: { _ in })
    }

    func acquireLock(handle: UInt8, reason: String?, timeoutMs: Int?,
                     completion: @escaping (Result<Void, LinkClientError>) -> Void) {
        sendRequest({ id in
            .lockAcquire(LinkLockAcquire(id: id, handle: Int(handle), reason: reason, timeoutMs: timeoutMs))
        }) { result in
            completion(result.map { _ in () })
        }
    }

    func releaseLock(handle: UInt8) {
        sendRequest({ id in .lockRelease(LinkLockRelease(id: id, handle: Int(handle))) },
                    completion: { _ in })
    }

    // MARK: - Request plumbing

    /// Send one JSON request and route its reply back by `id`.  `requiresReady`
    /// is false only for the auth exchange, which by definition runs before the
    /// session is ready.
    private func sendRequest(_ make: (Int) -> LinkMessage,
                             requiresReady: Bool = true,
                             completion: @escaping (Result<LinkOk, LinkClientError>) -> Void) {
        var generation = 0
        var message: LinkMessage?

        sync {
            let usable = requiresReady ? phase == .ready : (phase == .connecting || phase == .awaitingAuth || phase == .ready)
            guard usable, task != nil else { return }
            let id = nextRequestID
            nextRequestID += 1
            generation = self.generation
            message = make(id)

            let work = DispatchWorkItem { [weak self] in
                self?.timeOutRequest(id: id, generation: generation)
            }
            pendingJSON[id] = PendingJSON(completion: completion, timeout: work)
            queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: work)
        }

        guard let message = message else {
            return main { completion(.failure(.notConnected)) }
        }
        send(message, generation: generation)
    }

    private func send(_ message: LinkMessage, generation: Int) {
        guard let data = try? message.encoded() else { return }
        let task: URLSessionWebSocketTask? = sync {
            guard generation == self.generation else { return nil }
            return self.task
        }
        guard let task = task else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if error != nil { self?.socketFailed(generation: generation, error: error) }
        }
    }

    private func timeOutRequest(id: Int, generation: Int) {
        let pending: PendingJSON? = sync {
            guard generation == self.generation else { return nil }
            return pendingJSON.removeValue(forKey: id)
        }
        guard let pending = pending else { return }
        main { pending.completion(.failure(.timeout)) }
    }

    private func timeOutCommand(tag: UInt16, generation: Int) {
        let pending: PendingCommand? = sync {
            guard generation == self.generation else { return nil }
            return pendingCommands.removeValue(forKey: tag)
        }
        guard let pending = pending else { return }
        main { pending.completion(LinkCmdResponse(tag: tag, status: .timeout)) }
    }

    // MARK: - Receive loop

    private func receiveNext(task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            guard self.sync({ generation == self.generation }) else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleText(Data(text.utf8))
                case .data(let data):   self.handleBinary(data)
                @unknown default:       break
                }
                self.receiveNext(task: task, generation: generation)
            case .failure(let error):
                self.socketFailed(generation: generation, error: error)
            }
        }
    }

    private func handleText(_ data: Data) {
        guard let message = try? LinkMessage.decode(data) else { return }
        switch message {
        case .helloHub(let hello):
            handleHubHello(hello)

        case .ok(let ok):
            guard let id = ok.id, let pending = takePendingJSON(id) else { return }
            main { pending.completion(.success(ok)) }

        case .err(let err):
            guard let id = err.id, let pending = takePendingJSON(id) else { return }
            main { pending.completion(.failure(.rejected(code: err.code, message: err.msg))) }

        case .deviceAdded(let event), .deviceChanged(let event):
            upsertDevice(event.device)

        case .deviceRemoved(let event):
            removeDevice(handle: event.handle)

        default:
            break   // events this build does not act on; spec 7.1 says ignore
        }
    }

    private func takePendingJSON(_ id: Int) -> PendingJSON? {
        sync {
            guard let pending = pendingJSON.removeValue(forKey: id) else { return nil }
            pending.timeout.cancel()
            return pending
        }
    }

    private func handleBinary(_ data: Data) {
        guard let frame = try? LinkFrame.decode(data) else { return }
        switch frame {
        case .cmdResponse(let response):
            let pending: PendingCommand? = sync {
                guard let p = pendingCommands.removeValue(forKey: response.tag) else { return nil }
                p.timeout.cancel()
                return p
            }
            guard let pending = pending else { return }
            main { pending.completion(response) }

        case .notify(let frame):
            let handler = sync { _onNotify }
            if let handler = handler { main { handler(frame) } }

        case .poll(let frame):
            let handler = sync { _onPoll }
            if let handler = handler { main { handler(frame) } }

        case .resync(let frame):
            let handler = sync { _onResync }
            if let handler = handler { main { handler(frame) } }

        default:
            break   // frames only a hub receives, or ones this build ignores
        }
    }

    // MARK: - Session lifecycle

    private func handleHubHello(_ hello: LinkHelloHub) {
        sync {
            _hubInfo = hello.hub
            _capabilities = hello.caps
            _limits = hello.limits
        }

        switch hello.auth {
        case .none:
            // Open access: the hub opened the session the moment it answered
            // hello and expects no auth message.  Ask anyway with any PIN,
            // which is how spec 6.1 says a client learns its session id - it
            // needs that id to recognise its own writes in NOTIFY origins.
            let name = sync { clientName }
            sendRequest({ id in
                .authPair(LinkAuthPair(id: id, pin: Self.openAccessPIN, name: name, role: nil))
            }, requiresReady: false) { [weak self] result in
                guard let self = self else { return }
                if case .success(let ok) = result, let body = try? ok.decodeBody(LinkAuthOkBody.self) {
                    self.becameReady(session: body.session, role: body.role)
                } else {
                    // The session exists regardless; only the id is unknown, so
                    // go ready with 0 rather than stalling a usable connection.
                    self.becameReady(session: 0, role: .admin)
                }
            }

        case .pin:
            let token: String? = sync {
                let t = pendingToken
                pendingToken = nil
                phase = .awaitingAuth
                return t
            }
            guard let token = token else {
                return publishState(.awaitingAuth(needsPairing: true))
            }
            sendRequest({ id in .authToken(LinkAuthToken(id: id, token: token)) },
                        requiresReady: false) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let ok):
                    guard let body = try? ok.decodeBody(LinkAuthOkBody.self) else {
                        return self.publishState(.awaitingAuth(needsPairing: true))
                    }
                    self.becameReady(session: body.session, role: body.role)
                case .failure:
                    // A refused or expired token is indistinguishable from
                    // having none: the user pairs again.
                    self.publishState(.awaitingAuth(needsPairing: true))
                }
            }
        }
    }

    private func becameReady(session: Int, role: LinkRole) {
        let changed: Bool = sync {
            guard phase == .connecting || phase == .awaitingAuth else { return false }
            _sessionID = LinkSessionID(truncatingIfNeeded: session)
            _role = role
            phase = .ready
            return true
        }
        guard changed else { return }
        publishState(.ready)
        requestDeviceList()
    }

    private func requestDeviceList() {
        sendRequest({ id in .deviceList(LinkDeviceListRequest(id: id)) }) { [weak self] result in
            guard let self = self,
                  case .success(let ok) = result,
                  let body = try? ok.decodeBody(LinkDeviceListBody.self) else { return }
            self.publishDevices(body.devices)
        }
    }

    // MARK: - Device inventory

    private func upsertDevice(_ device: LinkDeviceInfo) {
        var list = devicesSubject.value
        if let index = list.firstIndex(where: { $0.handle == device.handle }) {
            list[index] = device
        } else {
            list.append(device)
        }
        publishDevices(list)
    }

    private func removeDevice(handle: Int) {
        publishDevices(devicesSubject.value.filter { $0.handle != handle })
    }

    // MARK: - Keepalive

    private func startPing(task: URLSessionWebSocketTask, generation: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self, weak task] in
            guard let self = self, let task = task else { return }
            // A ping that cannot be written is the earliest evidence the socket
            // is gone; URLSession answers the hub's own pings by itself.
            task.sendPing { error in
                if let error = error { self.socketFailed(generation: generation, error: error) }
            }
        }
        sync {
            pingTimer?.cancel()
            pingTimer = timer
        }
        timer.resume()
    }

    // MARK: - Failure and teardown

    /// The socket failed or the hub closed it.  The close code, when the hub
    /// sent one, names the reason; it arrives on the task rather than in the
    /// error, and may land a moment after the failed receive.
    private func socketFailed(generation: Int, error: Error?) {
        let task: URLSessionWebSocketTask? = sync {
            guard generation == self.generation, phase != .closed else { return nil }
            return self.task
        }
        guard let task = task else { return }

        if let code = closeCode(of: task), code != 0 {
            return shutdown(generation: generation, newState: .failed(Self.reason(forCloseCode: code)),
                            closeNormally: false)
        }
        queue.asyncAfter(deadline: .now() + Self.closeCodeGrace) { [weak self] in
            guard let self = self else { return }
            let late = self.closeCode(of: task) ?? 0
            let reason = late != 0 ? Self.reason(forCloseCode: late)
                                   : (error?.localizedDescription ?? "connection lost")
            self.shutdown(generation: generation, newState: .failed(reason), closeNormally: false)
        }
    }

    /// URLSessionWebSocketTask.CloseCode has no cases for the protocol's
    /// 4001-4003, so the raw NSInteger is read through KVC rather than
    /// converted into the enum.
    private func closeCode(of task: URLSessionWebSocketTask) -> Int? {
        let object = task as NSObject
        guard object.responds(to: Selector(("closeCode"))) else { return nil }
        return object.value(forKey: "closeCode") as? Int
    }

    private static func reason(forCloseCode code: Int) -> String {
        switch code {
        case 1000: return "hub closed the connection"
        case 4000: return "protocol error"
        case 4001: return "authentication timed out"
        case 4002: return "access revoked"
        case 4003: return "hub shutting down"
        default:   return "connection closed (\(code))"
        }
    }

    private func shutdown(generation: Int, newState: LinkClientState, closeNormally: Bool) {
        var jsonPending: [PendingJSON] = []
        var cmdPending: [PendingCommand] = []

        let proceed: Bool = sync {
            guard generation == self.generation, phase != .closed else { return false }
            phase = .closed
            pingTimer?.cancel()
            pingTimer = nil
            if closeNormally {
                task?.cancel(with: .normalClosure, reason: nil)
            } else {
                task?.cancel()
            }
            task = nil
            jsonPending = Array(pendingJSON.values)
            cmdPending = Array(pendingCommands.values)
            pendingJSON.removeAll()
            pendingCommands.removeAll()
            _sessionID = 0
            _role = nil
            pendingToken = nil
            return true
        }
        guard proceed else { return }

        for pending in jsonPending { pending.timeout.cancel() }
        for pending in cmdPending { pending.timeout.cancel() }
        main {
            for pending in jsonPending { pending.completion(.failure(.notConnected)) }
            // The data plane has no "not connected"; NO_DEVICE is the status
            // for a command the hub could not put on a device (spec 8.1).
            for pending in cmdPending {
                pending.completion(LinkCmdResponse(tag: pending.tag, status: .noDevice))
            }
        }
        publishState(newState)
    }

    /// Drop everything a previous connection left, without publishing a state:
    /// the caller is about to publish its own.  Lock held.
    private func resetLocked() {
        let jsonPending = Array(pendingJSON.values)
        let cmdPending = Array(pendingCommands.values)
        pendingJSON.removeAll()
        pendingCommands.removeAll()
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel()
        task = nil
        _hubInfo = nil
        _capabilities = []
        _limits = nil
        _sessionID = 0
        _role = nil
        pendingToken = nil
        phase = .idle

        for pending in jsonPending { pending.timeout.cancel() }
        for pending in cmdPending { pending.timeout.cancel() }
        main {
            for pending in jsonPending { pending.completion(.failure(.notConnected)) }
            for pending in cmdPending {
                pending.completion(LinkCmdResponse(tag: pending.tag, status: .noDevice))
            }
        }
    }

    deinit {
        task?.cancel()
        pingTimer?.cancel()
    }

    // MARK: - Helpers

    @discardableResult
    private func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func main(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    private func publishState(_ newState: LinkClientState) {
        main { [weak self] in
            guard let self = self, self.stateSubject.value != newState else { return }
            self.stateSubject.send(newState)
        }
    }

    private func publishDevices(_ list: [LinkDeviceInfo]) {
        main { [weak self] in self?.devicesSubject.send(list) }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
