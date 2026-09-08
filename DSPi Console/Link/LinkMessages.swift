//
//  LinkMessages.swift
//  DSPi Console
//
//  JSON control plane of the DSPi Link protocol, section 7 of
//  Documentation/dspi_link_protocol_spec.md.  One text frame is one
//  LinkMessage.  Unknown message types decode to `.unknown` and unknown
//  fields are ignored, which is what makes minor versions additive.
//
//  Key spelling: every model spells its wire keys out in an explicit
//  CodingKeys enum and LinkJSON uses `.useDefaultKeys`.  JSONDecoder's
//  `.convertFromSnakeCase` rewrites incoming keys to camelCase *before*
//  matching CodingKeys, so explicit snake_case keys and that strategy cannot
//  both be used; and the strategy would also rewrite the dynamic keys of the
//  `ok` body bag, losing the exact spec spellings a caller needs to read.
//  Explicit keys are therefore the whole story, and LinkMessageTests pins
//  every spelling that carries a digit or an acronym.
//

import Foundation

/// Shared JSON configuration.  Both sides are ISO-8601 for timestamps (spec
/// 7.1) and neither sorts keys, since implementations must not depend on key
/// order.
enum LinkJSON {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .useDefaultKeys
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = []         // sorted keys off
        return e
    }
}

// MARK: - JSONValue

/// A whole JSON value, for the parts of the protocol whose shape depends on
/// the request that is being answered.
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        // Integral values go out as integers so a session id reads back as
        // "12" rather than "12.0" for anything re-parsing the text.
        case .number(let v): if v == v.rounded(), abs(v) < 9.007199254740992e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    var intValue: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var isNull: Bool { self == .null }
}

// MARK: - Small vocabularies

// LinkRole is defined in LinkRole.swift; LinkAuthMode in AuthStore.swift.
// Both are used here for the auth and hello messages.

enum LinkHubKind: String, Codable {
    case console, bridge
}

enum LinkDeviceState: String, Codable {
    case online, offline, updating
}

/// How the hub reaches the device.  Tells a client what to expect for
/// latency and bulk timing.
enum LinkDeviceLinkKind: String, Codable {
    case usb, uart
}

enum LinkFwPhase: String, Codable {
    case uploading, rebooting, copying, verifying
}

/// Optional hub capabilities from `hello.caps`.  The wire field stays a
/// `[String]` so a hub may advertise capabilities this build never heard of.
enum LinkCapability: String {
    case cmd, notify, poll, snapshot, lock
    case fwInstall = "fw_install"
    case web, rename
}

/// Error codes from spec 7.1.  Kept as strings on the wire so a new code
/// does not become a decode failure.
enum LinkErrorCode {
    static let unauthenticated = "unauthenticated"
    static let denied          = "denied"
    static let badRequest      = "bad_request"
    static let unknownType     = "unknown_type"
    static let noDevice        = "no_device"
    static let locked          = "locked"
    static let busy            = "busy"
    static let rateLimited     = "rate_limited"
    static let unsupported     = "unsupported"
    static let internalError   = "internal"
}

// MARK: - Shared objects

struct LinkProtoVersion: Codable, Equatable {
    var major: Int
    var minor: Int

    init(major: Int = 1, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    enum CodingKeys: String, CodingKey {
        case major, minor
    }
}

struct LinkClientInfo: Codable, Equatable {
    var name: String
    var app: String?
    var version: String?

    init(name: String, app: String? = nil, version: String? = nil) {
        self.name = name
        self.app = app
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case name, app, version
    }
}

struct LinkHubInfo: Codable, Equatable {
    var id: String
    var name: String
    var kind: LinkHubKind
    var version: String?

    init(id: String, name: String, kind: LinkHubKind, version: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, version
    }
}

struct LinkLimits: Codable, Equatable {
    var maxFrame: Int?
    var maxPayload: Int?
    var maxInflight: Int?
    var pollMaxHz: Int?
    var pollBudgetBps: Int?

    init(maxFrame: Int? = nil, maxPayload: Int? = nil, maxInflight: Int? = nil,
         pollMaxHz: Int? = nil, pollBudgetBps: Int? = nil) {
        self.maxFrame = maxFrame
        self.maxPayload = maxPayload
        self.maxInflight = maxInflight
        self.pollMaxHz = pollMaxHz
        self.pollBudgetBps = pollBudgetBps
    }

    enum CodingKeys: String, CodingKey {
        case maxFrame = "max_frame"
        case maxPayload = "max_payload"
        case maxInflight = "max_inflight"
        case pollMaxHz = "poll_max_hz"
        case pollBudgetBps = "poll_budget_bps"
    }
}

/// The session's effective denial list: `[bRequest, dir]` pairs, so a client
/// can grey out controls instead of guessing the hub's policy table.
struct LinkPolicyDescriptor: Codable, Equatable {
    var denied: [[Int]]?

    init(denied: [[Int]]? = nil) { self.denied = denied }

    enum CodingKeys: String, CodingKey {
        case denied
    }

    var deniedCommands: [(bRequest: UInt8, direction: LinkDirection)] {
        (denied ?? []).compactMap { pair in
            guard pair.count >= 2,
                  let req = UInt8(exactly: pair[0]),
                  let dir = LinkDirection(rawValue: UInt8(truncatingIfNeeded: pair[1]))
            else { return nil }
            return (req, dir)
        }
    }
}

struct LinkDeviceInfo: Codable, Equatable {
    var handle: Int
    var serial: String
    var name: String?
    var platform: Int?
    var fw: String?
    var outputs: Int?
    var inputs: Int?
    var wireVersion: Int?
    var state: LinkDeviceState?
    var link: LinkDeviceLinkKind?
    /// Session id holding the exclusive lock, absent or null when free.
    var lockedBy: Int?

    init(handle: Int, serial: String, name: String? = nil, platform: Int? = nil,
         fw: String? = nil, outputs: Int? = nil, inputs: Int? = nil,
         wireVersion: Int? = nil, state: LinkDeviceState? = nil,
         link: LinkDeviceLinkKind? = nil, lockedBy: Int? = nil) {
        self.handle = handle
        self.serial = serial
        self.name = name
        self.platform = platform
        self.fw = fw
        self.outputs = outputs
        self.inputs = inputs
        self.wireVersion = wireVersion
        self.state = state
        self.link = link
        self.lockedBy = lockedBy
    }

    enum CodingKeys: String, CodingKey {
        case handle, serial, name, platform, fw, outputs, inputs
        case wireVersion = "wire_version"
        case state, link
        case lockedBy = "locked_by"
    }
}

/// One entry of a `poll.subscribe` request: the GET to run and how often.
struct LinkPollSpec: Codable, Equatable {
    var slot: Int
    var req: Int
    var val: Int
    var idx: Int
    var len: Int
    var hz: Int

    init(slot: Int, req: Int, val: Int, idx: Int, len: Int, hz: Int) {
        self.slot = slot
        self.req = req
        self.val = val
        self.idx = idx
        self.len = len
        self.hz = hz
    }

    enum CodingKeys: String, CodingKey {
        case slot, req, val, idx, len, hz
    }
}

struct LinkPollGrant: Codable, Equatable {
    var slot: Int
    var hz: Int

    init(slot: Int, hz: Int) {
        self.slot = slot
        self.hz = hz
    }

    enum CodingKeys: String, CodingKey {
        case slot, hz
    }
}

struct LinkAuthClient: Codable, Equatable {
    var cid: Int
    var name: String
    var role: LinkRole
    var created: Date?
    var lastSeen: Date?
    var online: Bool?

    init(cid: Int, name: String, role: LinkRole, created: Date? = nil,
         lastSeen: Date? = nil, online: Bool? = nil) {
        self.cid = cid
        self.name = name
        self.role = role
        self.created = created
        self.lastSeen = lastSeen
        self.online = online
    }

    enum CodingKeys: String, CodingKey {
        case cid, name, role, created
        case lastSeen = "last_seen"
        case online
    }
}

struct LinkHubDeviceStats: Codable, Equatable {
    var handle: Int
    var cmds: Int?
    var errors: Int?
    var avgRttMs: Double?
    var notifyDropped: Int?

    init(handle: Int, cmds: Int? = nil, errors: Int? = nil,
         avgRttMs: Double? = nil, notifyDropped: Int? = nil) {
        self.handle = handle
        self.cmds = cmds
        self.errors = errors
        self.avgRttMs = avgRttMs
        self.notifyDropped = notifyDropped
    }

    enum CodingKeys: String, CodingKey {
        case handle, cmds, errors
        case avgRttMs = "avg_rtt_ms"
        case notifyDropped = "notify_dropped"
    }
}

// MARK: - Message bodies

struct LinkHelloClient: Codable, Equatable {
    var proto: LinkProtoVersion
    var client: LinkClientInfo

    init(proto: LinkProtoVersion = LinkProtoVersion(), client: LinkClientInfo) {
        self.proto = proto
        self.client = client
    }

    enum CodingKeys: String, CodingKey {
        case proto, client
    }
}

struct LinkHelloHub: Codable, Equatable {
    var proto: LinkProtoVersion
    var hub: LinkHubInfo
    var auth: LinkAuthMode
    var caps: [String]
    var limits: LinkLimits?

    init(proto: LinkProtoVersion = LinkProtoVersion(), hub: LinkHubInfo,
         auth: LinkAuthMode, caps: [String] = [], limits: LinkLimits? = nil) {
        self.proto = proto
        self.hub = hub
        self.auth = auth
        self.caps = caps
        self.limits = limits
    }

    enum CodingKeys: String, CodingKey {
        case proto, hub, auth, caps, limits
    }

    func supports(_ capability: LinkCapability) -> Bool {
        caps.contains(capability.rawValue)
    }
}

struct LinkAuthToken: Codable, Equatable {
    var id: Int
    var token: String

    init(id: Int, token: String) {
        self.id = id
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case id, token
    }
}

struct LinkAuthPair: Codable, Equatable {
    var id: Int
    var pin: String
    var name: String
    var role: LinkRole?

    init(id: Int, pin: String, name: String, role: LinkRole? = nil) {
        self.id = id
        self.pin = pin
        self.name = name
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case id, pin, name, role
    }
}

struct LinkAuthList: Codable, Equatable {
    var id: Int

    init(id: Int) { self.id = id }

    enum CodingKeys: String, CodingKey {
        case id
    }
}

struct LinkAuthRevoke: Codable, Equatable {
    var id: Int
    var cid: Int

    init(id: Int, cid: Int) {
        self.id = id
        self.cid = cid
    }

    enum CodingKeys: String, CodingKey {
        case id, cid
    }
}

struct LinkAuthSetRole: Codable, Equatable {
    var id: Int
    var cid: Int
    var role: LinkRole

    init(id: Int, cid: Int, role: LinkRole) {
        self.id = id
        self.cid = cid
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case id, cid, role
    }
}

struct LinkDeviceListRequest: Codable, Equatable {
    var id: Int

    init(id: Int) { self.id = id }

    enum CodingKeys: String, CodingKey {
        case id
    }
}

/// `device.added` and `device.changed` carry the same device object.
struct LinkDeviceEvent: Codable, Equatable {
    var device: LinkDeviceInfo

    init(device: LinkDeviceInfo) { self.device = device }

    enum CodingKeys: String, CodingKey {
        case device
    }
}

struct LinkDeviceRemoved: Codable, Equatable {
    var handle: Int
    var serial: String?

    init(handle: Int, serial: String? = nil) {
        self.handle = handle
        self.serial = serial
    }

    enum CodingKeys: String, CodingKey {
        case handle, serial
    }
}

struct LinkDeviceRename: Codable, Equatable {
    var id: Int
    var handle: Int
    var name: String

    init(id: Int, handle: Int, name: String) {
        self.id = id
        self.handle = handle
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, name
    }
}

struct LinkDeviceSnapshotRequest: Codable, Equatable {
    var id: Int
    var handle: Int

    init(id: Int, handle: Int) {
        self.id = id
        self.handle = handle
    }

    enum CodingKeys: String, CodingKey {
        case id, handle
    }
}

struct LinkPollSubscribe: Codable, Equatable {
    var id: Int
    var handle: Int
    var polls: [LinkPollSpec]

    init(id: Int, handle: Int, polls: [LinkPollSpec]) {
        self.id = id
        self.handle = handle
        self.polls = polls
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, polls
    }
}

struct LinkPollUnsubscribe: Codable, Equatable {
    var id: Int
    var handle: Int
    var slots: [Int]

    init(id: Int, handle: Int, slots: [Int]) {
        self.id = id
        self.handle = handle
        self.slots = slots
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, slots
    }
}

/// Event after three consecutive failures of one subscribed poll.  The spec
/// names the event but not its fields; `handle` and `slot` identify the
/// subscription and the error vocabulary is shared with `err`.
struct LinkPollError: Codable, Equatable {
    var handle: Int
    var slot: Int?
    var code: String?
    var msg: String?

    init(handle: Int, slot: Int? = nil, code: String? = nil, msg: String? = nil) {
        self.handle = handle
        self.slot = slot
        self.code = code
        self.msg = msg
    }

    enum CodingKeys: String, CodingKey {
        case handle, slot, code, msg
    }
}

struct LinkLockAcquire: Codable, Equatable {
    var id: Int
    var handle: Int
    var reason: String?
    var timeoutMs: Int?

    init(id: Int, handle: Int, reason: String? = nil, timeoutMs: Int? = nil) {
        self.id = id
        self.handle = handle
        self.reason = reason
        self.timeoutMs = timeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, reason
        case timeoutMs = "timeout_ms"
    }
}

struct LinkLockRelease: Codable, Equatable {
    var id: Int
    var handle: Int

    init(id: Int, handle: Int) {
        self.id = id
        self.handle = handle
    }

    enum CodingKeys: String, CodingKey {
        case id, handle
    }
}

struct LinkFwInstall: Codable, Equatable {
    var id: Int
    var handle: Int
    var size: Int
    var sha256: String
    var version: String?

    init(id: Int, handle: Int, size: Int, sha256: String, version: String? = nil) {
        self.id = id
        self.handle = handle
        self.size = size
        self.sha256 = sha256
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, size
        case sha256
        case version
    }
}

struct LinkFwProgress: Codable, Equatable {
    var handle: Int
    var phase: LinkFwPhase
    var pct: Int?

    init(handle: Int, phase: LinkFwPhase, pct: Int? = nil) {
        self.handle = handle
        self.phase = phase
        self.pct = pct
    }

    enum CodingKeys: String, CodingKey {
        case handle, phase, pct
    }
}

struct LinkFwDone: Codable, Equatable {
    var handle: Int
    var ok: Bool
    var fw: String?

    init(handle: Int, ok: Bool, fw: String? = nil) {
        self.handle = handle
        self.ok = ok
        self.fw = fw
    }

    enum CodingKeys: String, CodingKey {
        case handle, ok, fw
    }
}

struct LinkHubStatsRequest: Codable, Equatable {
    var id: Int

    init(id: Int) { self.id = id }

    enum CodingKeys: String, CodingKey {
        case id
    }
}

struct LinkHubRename: Codable, Equatable {
    var id: Int
    var name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, name
    }
}

// MARK: - Replies

/// An `ok` reply.  Its fields depend on the request, and a client that lost
/// track of which request an id belonged to must still be able to decode the
/// frame, so the body is kept as a bag and typed views are decoded from it
/// on demand with `decodeBody`.
struct LinkOk: Equatable {
    var id: Int?
    var body: [String: JSONValue]

    init(id: Int?, body: [String: JSONValue] = [:]) {
        self.id = id
        self.body = body
    }

    init<Body: Encodable>(id: Int?, body: Body) throws {
        let data = try LinkJSON.encoder().encode(body)
        self.init(id: id, body: try LinkJSON.decoder().decode([String: JSONValue].self, from: data))
    }

    func decodeBody<Body: Decodable>(_ type: Body.Type) throws -> Body {
        let data = try LinkJSON.encoder().encode(body)
        return try LinkJSON.decoder().decode(Body.self, from: data)
    }
}

extension LinkOk: Codable {
    init(from decoder: Decoder) throws {
        var all = try [String: JSONValue](from: decoder)
        all.removeValue(forKey: "t")
        id = all.removeValue(forKey: "id")?.intValue
        body = all
    }

    func encode(to encoder: Encoder) throws {
        var out = body
        if let id { out["id"] = .number(Double(id)) }
        try out.encode(to: encoder)
    }
}

struct LinkErr: Codable, Equatable {
    var id: Int?
    var code: String
    var msg: String?

    init(id: Int?, code: String, msg: String? = nil) {
        self.id = id
        self.code = code
        self.msg = msg
    }

    enum CodingKeys: String, CodingKey {
        case id, code, msg
    }
}

// MARK: - Typed ok bodies

/// Reply to `auth.token` and `auth.pair`; `token` is present only for pair.
struct LinkAuthOkBody: Codable, Equatable {
    var session: Int
    var role: LinkRole
    var token: String?
    var policy: LinkPolicyDescriptor?

    init(session: Int, role: LinkRole, token: String? = nil, policy: LinkPolicyDescriptor? = nil) {
        self.session = session
        self.role = role
        self.token = token
        self.policy = policy
    }

    enum CodingKeys: String, CodingKey {
        case session, role, token, policy
    }
}

struct LinkDeviceListBody: Codable, Equatable {
    var devices: [LinkDeviceInfo]

    init(devices: [LinkDeviceInfo]) { self.devices = devices }

    enum CodingKeys: String, CodingKey {
        case devices
    }
}

struct LinkAuthListBody: Codable, Equatable {
    var clients: [LinkAuthClient]

    init(clients: [LinkAuthClient]) { self.clients = clients }

    enum CodingKeys: String, CodingKey {
        case clients
    }
}

struct LinkSnapshotBody: Codable, Equatable {
    var handle: Int
    var wireVersion: Int?
    var ageMs: Int?
    var bulkB64: String?
    var statusB64: String?

    init(handle: Int, wireVersion: Int? = nil, ageMs: Int? = nil,
         bulkB64: String? = nil, statusB64: String? = nil) {
        self.handle = handle
        self.wireVersion = wireVersion
        self.ageMs = ageMs
        self.bulkB64 = bulkB64
        self.statusB64 = statusB64
    }

    enum CodingKeys: String, CodingKey {
        case handle
        case wireVersion = "wire_version"
        case ageMs = "age_ms"
        case bulkB64 = "bulk_b64"
        case statusB64 = "status_b64"
    }

    var bulk: Data? { bulkB64.flatMap { Data(base64Encoded: $0) } }
    var status: Data? { statusB64.flatMap { Data(base64Encoded: $0) } }
}

struct LinkPollSubscribeBody: Codable, Equatable {
    var granted: [LinkPollGrant]

    init(granted: [LinkPollGrant]) { self.granted = granted }

    enum CodingKeys: String, CodingKey {
        case granted
    }
}

struct LinkFwInstallBody: Codable, Equatable {
    /// Transfer id to put in the tag of every FWDATA frame.
    var xfer: Int

    init(xfer: Int) { self.xfer = xfer }

    enum CodingKeys: String, CodingKey {
        case xfer
    }
}

struct LinkHubStatsBody: Codable, Equatable {
    var sessions: Int?
    var uptimeS: Int?
    var devices: [LinkHubDeviceStats]?

    init(sessions: Int? = nil, uptimeS: Int? = nil, devices: [LinkHubDeviceStats]? = nil) {
        self.sessions = sessions
        self.uptimeS = uptimeS
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case sessions
        case uptimeS = "uptime_s"
        case devices
    }
}

// MARK: - Envelope

enum LinkMessage: Equatable {
    case helloClient(LinkHelloClient)
    case helloHub(LinkHelloHub)
    case authToken(LinkAuthToken)
    case authPair(LinkAuthPair)
    case authList(LinkAuthList)
    case authRevoke(LinkAuthRevoke)
    case authSetRole(LinkAuthSetRole)
    case deviceList(LinkDeviceListRequest)
    case deviceAdded(LinkDeviceEvent)
    case deviceRemoved(LinkDeviceRemoved)
    case deviceChanged(LinkDeviceEvent)
    case deviceRename(LinkDeviceRename)
    case deviceSnapshot(LinkDeviceSnapshotRequest)
    case pollSubscribe(LinkPollSubscribe)
    case pollUnsubscribe(LinkPollUnsubscribe)
    case pollError(LinkPollError)
    case lockAcquire(LinkLockAcquire)
    case lockRelease(LinkLockRelease)
    case fwInstall(LinkFwInstall)
    case fwProgress(LinkFwProgress)
    case fwDone(LinkFwDone)
    case hubStats(LinkHubStatsRequest)
    case hubRename(LinkHubRename)
    case ok(LinkOk)
    case err(LinkErr)
    /// A type this build does not know.  Clients drop unknown events; hubs
    /// answer unknown requests with `err` `unknown_type`.
    case unknown(type: String, id: Int?)

    var typeName: String {
        switch self {
        case .helloClient, .helloHub: return "hello"
        case .authToken:      return "auth.token"
        case .authPair:       return "auth.pair"
        case .authList:       return "auth.list"
        case .authRevoke:     return "auth.revoke"
        case .authSetRole:    return "auth.set_role"
        case .deviceList:     return "device.list"
        case .deviceAdded:    return "device.added"
        case .deviceRemoved:  return "device.removed"
        case .deviceChanged:  return "device.changed"
        case .deviceRename:   return "device.rename"
        case .deviceSnapshot: return "device.snapshot"
        case .pollSubscribe:  return "poll.subscribe"
        case .pollUnsubscribe: return "poll.unsubscribe"
        case .pollError:      return "poll.error"
        case .lockAcquire:    return "lock.acquire"
        case .lockRelease:    return "lock.release"
        case .fwInstall:      return "fw.install"
        case .fwProgress:     return "fw.progress"
        case .fwDone:         return "fw.done"
        case .hubStats:       return "hub.stats"
        case .hubRename:      return "hub.rename"
        case .ok:             return "ok"
        case .err:            return "err"
        case .unknown(let t, _): return t
        }
    }

    /// The request id, for matching a reply to what was sent.  Events have none.
    var requestID: Int? {
        switch self {
        case .authToken(let m):      return m.id
        case .authPair(let m):       return m.id
        case .authList(let m):       return m.id
        case .authRevoke(let m):     return m.id
        case .authSetRole(let m):    return m.id
        case .deviceList(let m):     return m.id
        case .deviceRename(let m):   return m.id
        case .deviceSnapshot(let m): return m.id
        case .pollSubscribe(let m):  return m.id
        case .pollUnsubscribe(let m): return m.id
        case .lockAcquire(let m):    return m.id
        case .lockRelease(let m):    return m.id
        case .fwInstall(let m):      return m.id
        case .hubStats(let m):       return m.id
        case .hubRename(let m):      return m.id
        case .ok(let m):             return m.id
        case .err(let m):            return m.id
        case .unknown(_, let id):    return id
        default: return nil
        }
    }
}

extension LinkMessage: Codable {
    private enum EnvelopeKeys: String, CodingKey {
        case t, id
    }

    /// Just enough of the object to route it.  `hub` and `auth` appear only
    /// in the hub's half of the `hello` exchange, which is how the two
    /// directions of one type name are told apart.
    private struct Peek: Decodable {
        let t: String
        let id: Int?
        let hub: JSONValue?
        let auth: JSONValue?

        enum CodingKeys: String, CodingKey {
            case t, id, hub, auth
        }
    }

    init(from decoder: Decoder) throws {
        let peek = try Peek(from: decoder)
        switch peek.t {
        case "hello":
            if peek.hub != nil || peek.auth != nil {
                self = .helloHub(try LinkHelloHub(from: decoder))
            } else {
                self = .helloClient(try LinkHelloClient(from: decoder))
            }
        case "auth.token":       self = .authToken(try LinkAuthToken(from: decoder))
        case "auth.pair":        self = .authPair(try LinkAuthPair(from: decoder))
        case "auth.list":        self = .authList(try LinkAuthList(from: decoder))
        case "auth.revoke":      self = .authRevoke(try LinkAuthRevoke(from: decoder))
        case "auth.set_role":    self = .authSetRole(try LinkAuthSetRole(from: decoder))
        case "device.list":      self = .deviceList(try LinkDeviceListRequest(from: decoder))
        case "device.added":     self = .deviceAdded(try LinkDeviceEvent(from: decoder))
        case "device.removed":   self = .deviceRemoved(try LinkDeviceRemoved(from: decoder))
        case "device.changed":   self = .deviceChanged(try LinkDeviceEvent(from: decoder))
        case "device.rename":    self = .deviceRename(try LinkDeviceRename(from: decoder))
        case "device.snapshot":  self = .deviceSnapshot(try LinkDeviceSnapshotRequest(from: decoder))
        case "poll.subscribe":   self = .pollSubscribe(try LinkPollSubscribe(from: decoder))
        case "poll.unsubscribe": self = .pollUnsubscribe(try LinkPollUnsubscribe(from: decoder))
        case "poll.error":       self = .pollError(try LinkPollError(from: decoder))
        case "lock.acquire":     self = .lockAcquire(try LinkLockAcquire(from: decoder))
        case "lock.release":     self = .lockRelease(try LinkLockRelease(from: decoder))
        case "fw.install":       self = .fwInstall(try LinkFwInstall(from: decoder))
        case "fw.progress":      self = .fwProgress(try LinkFwProgress(from: decoder))
        case "fw.done":          self = .fwDone(try LinkFwDone(from: decoder))
        case "hub.stats":        self = .hubStats(try LinkHubStatsRequest(from: decoder))
        case "hub.rename":       self = .hubRename(try LinkHubRename(from: decoder))
        case "ok":               self = .ok(try LinkOk(from: decoder))
        case "err":              self = .err(try LinkErr(from: decoder))
        default:                 self = .unknown(type: peek.t, id: peek.id)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .helloClient(let m):    try m.encode(to: encoder)
        case .helloHub(let m):       try m.encode(to: encoder)
        case .authToken(let m):      try m.encode(to: encoder)
        case .authPair(let m):       try m.encode(to: encoder)
        case .authList(let m):       try m.encode(to: encoder)
        case .authRevoke(let m):     try m.encode(to: encoder)
        case .authSetRole(let m):    try m.encode(to: encoder)
        case .deviceList(let m):     try m.encode(to: encoder)
        case .deviceAdded(let m):    try m.encode(to: encoder)
        case .deviceRemoved(let m):  try m.encode(to: encoder)
        case .deviceChanged(let m):  try m.encode(to: encoder)
        case .deviceRename(let m):   try m.encode(to: encoder)
        case .deviceSnapshot(let m): try m.encode(to: encoder)
        case .pollSubscribe(let m):  try m.encode(to: encoder)
        case .pollUnsubscribe(let m): try m.encode(to: encoder)
        case .pollError(let m):      try m.encode(to: encoder)
        case .lockAcquire(let m):    try m.encode(to: encoder)
        case .lockRelease(let m):    try m.encode(to: encoder)
        case .fwInstall(let m):      try m.encode(to: encoder)
        case .fwProgress(let m):     try m.encode(to: encoder)
        case .fwDone(let m):         try m.encode(to: encoder)
        case .hubStats(let m):       try m.encode(to: encoder)
        case .hubRename(let m):      try m.encode(to: encoder)
        case .ok(let m):             try m.encode(to: encoder)
        case .err(let m):            try m.encode(to: encoder)
        case .unknown(_, let id):
            var c = encoder.container(keyedBy: EnvelopeKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
        }
        // The bodies do not carry `t`; the envelope stamps it into the same
        // object afterwards.
        var c = encoder.container(keyedBy: EnvelopeKeys.self)
        try c.encode(typeName, forKey: .t)
    }
}

extension LinkMessage {
    static func decode(_ data: Data) throws -> LinkMessage {
        try LinkJSON.decoder().decode(LinkMessage.self, from: data)
    }

    func encoded() throws -> Data {
        try LinkJSON.encoder().encode(self)
    }
}
