//
//  LinkSessionHandler.swift
//  DSPi Console
//
//  The server-side protocol brain for one connection.  It takes the frames a
//  transport hands it (a WebSocket text frame carrying JSON, or a binary frame
//  carrying a data-plane frame), authenticates, then drives the LinkHub as one
//  session and turns hub events back into outbound frames.  It has no socket
//  and no NIO in it, so it is fully unit-testable: feed it decoded input and
//  assert the bytes it emits.  The NIO server (LinkServer) is a thin adapter
//  that moves bytes in and out of one of these.  See spec sections 5-8.
//

import Foundation

/// One outbound message the handler wants sent on the wire.
enum LinkOutbound: Equatable {
    case text(Data)      // a JSON control-plane message
    case binary(Data)    // a data-plane frame
    case close(UInt16)   // close the connection with this code
}

final class LinkSessionHandler {
    private let hub: LinkHub
    private let auth: LinkAuthStore
    private let policy: LinkPolicy
    /// The peer address, for auth rate-limiting.
    private let peer: String
    /// Every outbound message goes here; the adapter writes it to the socket.
    private let emit: (LinkOutbound) -> Void

    private var helloReceived = false
    private var session: LinkHubSession?
    /// The live role, read from the hub session so a re-role takes effect at
    /// once.  Viewer until a session exists.
    private var role: LinkRole { session?.role ?? .viewer }

    /// The largest command payload the hub accepts, and the largest WebSocket
    /// message (after reassembly) the server will buffer; both are advertised
    /// in hello and enforced.
    static let maxPayload = 8192
    static let maxFrame = 65536

    init(hub: LinkHub, auth: LinkAuthStore, policy: LinkPolicy,
         peer: String, emit: @escaping (LinkOutbound) -> Void) {
        self.hub = hub
        self.auth = auth
        self.policy = policy
        self.peer = peer
        self.emit = emit
    }

    var isAuthenticated: Bool { session != nil }

    // MARK: - Inbound

    /// A text (JSON) frame arrived.  Malformed JSON closes the connection with
    /// a protocol-error code.
    func receiveText(_ data: Data) {
        guard let message = try? LinkMessage.decode(data) else {
            return emit(.close(4000))
        }
        dispatch(message)
    }

    /// A binary (data-plane) frame arrived.  Only CMD requests are handled in
    /// this phase; unknown or unsupported frames answer where they can.
    func receiveBinary(_ data: Data) {
        guard isAuthenticated, let session = session else {
            return   // no data-plane traffic before auth; drop silently
        }
        guard let frame = try? LinkFrame.decode(data) else { return }
        switch frame {
        case .cmdRequest(let req):
            handleCommand(req, session: session)
        case .fwData:
            // Firmware install streaming lands in Phase 5.
            break
        default:
            break
        }
    }

    /// The connection closed.  Release the hub session and its resources.
    func connectionClosed() {
        if let s = session { hub.closeSession(s.id) }
        session = nil
    }

    // MARK: - Dispatch

    private func dispatch(_ message: LinkMessage) {
        // hello must come first, and nothing but hello/auth runs before auth.
        switch message {
        case .helloClient(let hello):
            handleHello(hello)
        case .authToken(let m):
            handleAuthToken(m)
        case .authPair(let m):
            handleAuthPair(m)
        default:
            guard isAuthenticated else {
                return emit(err(idOf(message), LinkErrorCode.unauthenticated))
            }
            dispatchAuthenticated(message)
        }
    }

    private func handleHello(_ hello: LinkHelloClient) {
        helloReceived = true
        let info = LinkHubInfo(id: auth.hubID.uuidString.lowercased(),
                               name: auth.hubName, kind: .console,
                               version: Self.appVersion)
        let limits = LinkLimits(maxFrame: Self.maxFrame, maxPayload: Self.maxPayload,
                                maxInflight: 8, pollMaxHz: 20, pollBudgetBps: 200000)
        let reply = LinkHelloHub(hub: info, auth: auth.authMode,
                                 caps: Self.capabilities, limits: limits)
        send(.helloHub(reply))
        // Open access: every connection is an admin session and the auth step
        // is skipped (spec 5, 6.1).  A client that wants its session id may
        // still send auth.pair and gets the usual ok.
        if auth.authMode == .none, session == nil {
            openSession(cid: nil, role: .admin, reply: nil, token: nil)
        }
    }

    private func dispatchAuthenticated(_ message: LinkMessage) {
        switch message {
        case .deviceList(let m):        handleDeviceList(m)
        case .deviceSnapshot(let m):    handleSnapshot(m)
        case .deviceRename(let m):      handleRename(m)
        case .pollSubscribe(let m):     handlePollSubscribe(m)
        case .pollUnsubscribe(let m):   handlePollUnsubscribe(m)
        case .lockAcquire(let m):       handleLockAcquire(m)
        case .lockRelease(let m):       handleLockRelease(m)
        case .authList(let m):          handleAuthList(m)
        case .authRevoke(let m):        handleAuthRevoke(m)
        case .authSetRole(let m):       handleAuthSetRole(m)
        case .hubStats(let m):          handleHubStats(m)
        case .hubRename(let m):         handleHubRename(m)
        case .unknown(_, let id):       emit(err(id, LinkErrorCode.unknownType))
        default:                        emit(err(idOf(message), LinkErrorCode.unknownType))
        }
    }

    // MARK: - Auth

    private func handleAuthToken(_ m: LinkAuthToken) {
        switch auth.authenticate(token: m.token, from: peer) {
        case .success(let client):
            openSession(cid: client.id, role: client.role, reply: m.id, token: nil)
        case .failure(let e):
            emit(err(m.id, authErrorCode(e)))
        }
    }

    private func handleAuthPair(_ m: LinkAuthPair) {
        // `none` mode: no PIN, every connection is admin (spec 6.1).
        if auth.authMode == .none {
            return openSession(cid: nil, role: .admin, reply: m.id, token: nil)
        }
        switch auth.pair(pin: m.pin, clientName: m.name,
                         requestedRole: m.role ?? .control, from: peer) {
        case .success(let result):
            openSession(cid: result.client.id, role: result.client.role, reply: m.id, token: result.token)
        case .failure(let e):
            emit(err(m.id, authErrorCode(e)))
        }
    }

    /// Open the hub session this connection will drive.  A second successful
    /// authentication on the same connection closes the first session, so its
    /// subscriptions, locks and callbacks do not outlive it.  `reply` is the
    /// request id to answer with an ok, or nil when the session opens silently
    /// (open access on hello).
    private func openSession(cid: Int?, role: LinkRole, reply: Int?, token: String?) {
        if let old = session { hub.closeSession(old.id) }
        let s = hub.openSession(role: role)
        s.clientID = cid
        self.session = s
        wireSessionCallbacks(s)
        if let id = reply {
            let descriptor = LinkPolicyDescriptor(
                denied: policy.denied(for: role).map { [Int($0.code), Int($0.direction == .set ? 0 : 1)] })
            let body = LinkAuthOkBody(session: Int(s.id), role: role, token: token, policy: descriptor)
            sendOk(id: id, body: body)
        }
    }

    private func wireSessionCallbacks(_ s: LinkHubSession) {
        // Revoked while connected: the hub has already closed the session;
        // drop our reference so nothing routes, and close with code 4002.
        s.onClosedByHub = { [weak self, weak s] in
            guard let self = self, let s = s, self.session === s else { return }
            self.session = nil
            self.emit(.close(4002))
        }
        s.onNotify = { [weak self] frame in self?.emit(.binary(LinkFrame.notify(frame).encode())) }
        s.onResync = { [weak self] frame in self?.emit(.binary(LinkFrame.resync(frame).encode())) }
        s.onPoll = { [weak self] frame in self?.emit(.binary(LinkFrame.poll(frame).encode())) }
        s.onDeviceEvent = { [weak self] event in self?.handleDeviceEvent(event) }
    }

    // MARK: - Commands

    private func handleCommand(_ req: LinkCmdRequest, session: LinkHubSession) {
        guard req.payload.count <= Self.maxPayload, req.wLength <= UInt16(Self.maxPayload) else {
            return emit(.binary(LinkFrame.cmdResponse(LinkCmdResponse(tag: req.tag, status: .tooLarge)).encode()))
        }
        hub.submit(req, from: session.id) { [weak self] response in
            self?.emit(.binary(LinkFrame.cmdResponse(response).encode()))
        }
    }

    // MARK: - Device inventory

    private func handleDeviceList(_ m: LinkDeviceListRequest) {
        let devices = hub.registry.devices.map { linkDeviceInfo($0) }
        sendOk(id: m.id, body: LinkDeviceListBody(devices: devices))
    }

    private func handleSnapshot(_ m: LinkDeviceSnapshotRequest) {
        guard let snap = hub.currentSnapshot() else {
            return emit(err(m.id, LinkErrorCode.noDevice))
        }
        let ageMs = Int(Date().timeIntervalSince(snap.updatedAt) * 1000)
        let body = LinkSnapshotBody(handle: m.handle, wireVersion: snap.wireVersion, ageMs: ageMs,
                                    bulkB64: snap.bulk.base64EncodedString(),
                                    statusB64: snap.status?.base64EncodedString())
        sendOk(id: m.id, body: body)
    }

    private func handleRename(_ m: LinkDeviceRename) {
        guard role != .viewer else { return emit(err(m.id, LinkErrorCode.denied)) }
        hub.registry.rename(handle: UInt8(truncatingIfNeeded: m.handle), to: m.name)
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    private func handleDeviceEvent(_ event: DeviceRegistryEvent) {
        switch event {
        case .added(let d):   send(.deviceAdded(LinkDeviceEvent(device: linkDeviceInfo(d))))
        case .changed(let d): send(.deviceChanged(LinkDeviceEvent(device: linkDeviceInfo(d))))
        case .removed(let h, let s):
            send(.deviceRemoved(LinkDeviceRemoved(handle: Int(h), serial: s)))
        }
    }

    // MARK: - Polls

    private func handlePollSubscribe(_ m: LinkPollSubscribe) {
        guard let session = session else { return }
        let requests = m.polls.map { p in
            (slot: p.slot,
             spec: PollScheduler.PollSpec(handle: UInt8(truncatingIfNeeded: m.handle),
                                          req: UInt8(truncatingIfNeeded: p.req),
                                          wValue: UInt16(truncatingIfNeeded: p.val),
                                          wIndex: UInt16(truncatingIfNeeded: p.idx),
                                          len: UInt16(truncatingIfNeeded: p.len)),
             hz: Double(p.hz))
        }
        let granted = hub.subscribePolls(session: session.id, requests: requests)
        sendOk(id: m.id, body: LinkPollSubscribeBody(
            granted: granted.map { LinkPollGrant(slot: $0.slot, hz: Int($0.grantedHz.rounded())) }))
    }

    private func handlePollUnsubscribe(_ m: LinkPollUnsubscribe) {
        guard let session = session else { return }
        hub.unsubscribePolls(session: session.id, slots: m.slots)
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    // MARK: - Locks

    private func handleLockAcquire(_ m: LinkLockAcquire) {
        guard let session = session else { return }
        let timeout = Double(m.timeoutMs ?? 10000) / 1000.0
        if hub.acquireLock(session: session.id, timeout: timeout) {
            sendOk(id: m.id, body: [String: JSONValue]())
        } else {
            emit(err(m.id, LinkErrorCode.locked))
        }
    }

    private func handleLockRelease(_ m: LinkLockRelease) {
        guard let session = session else { return }
        hub.releaseLock(session: session.id)
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    // MARK: - Admin: client and hub management

    private func handleAuthList(_ m: LinkAuthList) {
        guard role == .admin else { return emit(err(m.id, LinkErrorCode.denied)) }
        let clients = auth.clients.map {
            LinkAuthClient(cid: $0.id, name: $0.name, role: $0.role,
                           created: $0.created, lastSeen: $0.lastSeen, online: nil)
        }
        sendOk(id: m.id, body: LinkAuthListBody(clients: clients))
    }

    private func handleAuthRevoke(_ m: LinkAuthRevoke) {
        guard role == .admin else { return emit(err(m.id, LinkErrorCode.denied)) }
        auth.revoke(cid: m.cid)
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    private func handleAuthSetRole(_ m: LinkAuthSetRole) {
        guard role == .admin else { return emit(err(m.id, LinkErrorCode.denied)) }
        auth.setRole(cid: m.cid, role: m.role)
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    private func handleHubStats(_ m: LinkHubStatsRequest) {
        guard role == .admin else { return emit(err(m.id, LinkErrorCode.denied)) }
        sendOk(id: m.id, body: LinkHubStatsBody(sessions: nil, uptimeS: nil, devices: nil))
    }

    private func handleHubRename(_ m: LinkHubRename) {
        guard role == .admin else { return emit(err(m.id, LinkErrorCode.denied)) }
        auth.hubName = m.name
        sendOk(id: m.id, body: [String: JSONValue]())
    }

    // MARK: - Helpers

    private func linkDeviceInfo(_ d: RegisteredDevice) -> LinkDeviceInfo {
        LinkDeviceInfo(handle: Int(d.handle), serial: d.info.serial, name: d.name,
                       platform: Int(d.info.platform), fw: d.info.firmware,
                       outputs: d.info.outputs, inputs: d.info.inputs,
                       wireVersion: d.info.wireVersion,
                       state: d.state, link: d.info.link == .usb ? .usb : .uart,
                       lockedBy: d.lockedBy.map { Int($0) })
    }

    private func send(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        emit(.text(data))
    }

    private func sendOk<Body: Encodable>(id: Int?, body: Body) {
        guard let ok = try? LinkOk(id: id, body: body) else {
            return emit(err(id, LinkErrorCode.internalError))
        }
        send(.ok(ok))
    }

    private func sendOk(id: Int?, body: [String: JSONValue]) {
        send(.ok(LinkOk(id: id, body: body)))
    }

    private func err(_ id: Int?, _ code: String, _ msg: String? = nil) -> LinkOutbound {
        guard let data = try? LinkMessage.err(LinkErr(id: id, code: code, msg: msg)).encoded() else {
            return .close(4000)
        }
        return .text(data)
    }

    private func authErrorCode(_ e: LinkAuthError) -> String {
        switch e {
        case .rateLimited: return LinkErrorCode.rateLimited
        default:           return LinkErrorCode.unauthenticated
        }
    }

    private func idOf(_ message: LinkMessage) -> Int? { message.id }

    private static let capabilities: [String] = [
        LinkCapability.cmd.rawValue, LinkCapability.notify.rawValue,
        LinkCapability.poll.rawValue, LinkCapability.snapshot.rawValue,
        LinkCapability.lock.rawValue, LinkCapability.rename.rawValue
    ]

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}


// MARK: - Message id accessor

extension LinkMessage {
    /// The request `id` a reply must echo, when the message carries one.
    /// Events and hellos have none.
    var id: Int? {
        switch self {
        case .authToken(let m): return m.id
        case .authPair(let m): return m.id
        case .authList(let m): return m.id
        case .authRevoke(let m): return m.id
        case .authSetRole(let m): return m.id
        case .deviceList(let m): return m.id
        case .deviceRename(let m): return m.id
        case .deviceSnapshot(let m): return m.id
        case .pollSubscribe(let m): return m.id
        case .pollUnsubscribe(let m): return m.id
        case .lockAcquire(let m): return m.id
        case .lockRelease(let m): return m.id
        case .fwInstall(let m): return m.id
        case .hubStats(let m): return m.id
        case .hubRename(let m): return m.id
        case .ok(let m): return m.id
        case .err(let m): return m.id
        case .unknown(_, let id): return id
        default: return nil
        }
    }
}
