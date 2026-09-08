//
//  AuthStore.swift
//  DSPi Console
//
//  The DSPi Link hub's authentication state: who this hub is, whether it
//  demands a PIN, which clients have paired with it, and the short-lived
//  pairing window.  See Documentation/dspi_link_protocol_spec.md sections 6
//  (authentication and authorization) and 7.3 (auth messages).
//
//  Everything here is synchronous and guarded by one lock, because the hub's
//  connection handlers call in from whatever queue a WebSocket frame arrived
//  on and the settings UI calls in from the main thread.
//

import Foundation
import CryptoKit
import Security

/// How the hub authenticates a new connection (spec 6.1).  Hubs must default
/// to `.pin`; `.none` makes every session an admin and is bench-only.
enum LinkAuthMode: String, Codable {
    case none
    case pin
}

/// Why an authentication or pairing attempt was refused.
enum LinkAuthError: Error, Equatable {
    /// No pairing window is open (never opened, cancelled, consumed by five
    /// failures, or already expired and cleared).
    case noPairingActive
    case wrongPIN
    /// The pairing window was open but its TTL had passed.
    case expired
    /// Too many recent failures from this address (spec 6.2).
    case rateLimited
    /// The token does not match any paired client.
    case unknownToken
    /// Reserved for a token whose client is known to have been revoked.
    case revoked
}

/// One client that has paired with this hub.  The raw token is never stored;
/// only the hex SHA-256 of its 32 random bytes.
struct PairedClient: Codable, Identifiable, Equatable {
    /// `cid` in the protocol: monotonically assigned, never reused.
    let id: Int
    var name: String
    var role: LinkRole
    let created: Date
    var lastSeen: Date?
    /// Lowercase hex SHA-256 of the raw token bytes.
    let tokenHash: String
}

/// Owns the hub identity, the auth mode, the paired-client list and the
/// pairing window, and persists all but the transient parts to a JSON file.
final class LinkAuthStore {

    // MARK: - Tunables (spec 6.2)

    /// Failures from one address inside `rateWindow` before that address is
    /// blocked, and failed PIN attempts before the PIN is discarded.
    static let failureLimit = 5
    /// Sliding window the failures are counted over, and the length of the
    /// block that follows.
    static let rateWindow: TimeInterval = 60

    // MARK: - Persisted shape

    /// Exactly what lands in the JSON file.  The active PIN and the
    /// rate-limit ledger are deliberately absent: a restart should not carry
    /// a pairing window or a block across it.
    private struct PersistedState: Codable {
        var hubID: UUID
        var hubName: String
        var authMode: LinkAuthMode
        var clients: [PairedClient]
        var nextCID: Int
    }

    // MARK: - State

    private let storeURL: URL
    private let lock = NSLock()

    private var state: PersistedState

    // Transient, in-memory only.
    private var pin: String?
    private var pinExpiry: Date?
    private var pinFailures = 0
    /// address -> recent failure timestamps and, once tripped, the instant the
    /// block lifts.
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    // MARK: - Init

    init(storeURL: URL) {
        self.storeURL = storeURL
        if let loaded = Self.load(from: storeURL) {
            state = loaded
        } else {
            // No file, unreadable, or corrupt JSON: start fresh rather than
            // refusing to run.  The first mutation overwrites the bad file.
            state = PersistedState(hubID: UUID(),
                                   hubName: Self.defaultHubName(),
                                   authMode: .pin,
                                   clients: [],
                                   nextCID: 1)
            save()
        }
    }

    /// `~/Library/Application Support/DSPi Console/link-auth.json`, creating
    /// the directory if needed.
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DSPi Console", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("link-auth.json")
    }

    static func defaultHubName() -> String {
        let machine = Host.current().localizedName ?? "Mac"
        return "\(machine) DSPi Console"
    }

    // MARK: - Identity and mode

    var hubID: UUID {
        lock.lock(); defer { lock.unlock() }
        return state.hubID
    }

    var hubName: String {
        get {
            lock.lock(); defer { lock.unlock() }
            return state.hubName
        }
        set {
            lock.lock()
            state.hubName = newValue
            saveLocked()
            lock.unlock()
        }
    }

    var authMode: LinkAuthMode {
        get {
            lock.lock(); defer { lock.unlock() }
            return state.authMode
        }
        set {
            lock.lock()
            state.authMode = newValue
            saveLocked()
            lock.unlock()
        }
    }

    // MARK: - Pairing window

    /// The PIN currently displayed by the hub, or nil.  Reading it does not
    /// clear an expired one; `pair` does that.
    var activePIN: String? {
        lock.lock(); defer { lock.unlock() }
        return pin
    }

    var pairingExpires: Date? {
        lock.lock(); defer { lock.unlock() }
        return pinExpiry
    }

    /// Open a pairing window, replacing any PIN already on show, and return
    /// the 6-digit PIN for the UI to display.
    @discardableResult
    func beginPairing(ttl: TimeInterval = 120) -> String {
        let generated = Self.makePIN()
        lock.lock()
        pin = generated
        pinExpiry = Date().addingTimeInterval(ttl)
        pinFailures = 0
        lock.unlock()
        return generated
    }

    func cancelPairing() {
        lock.lock()
        pin = nil
        pinExpiry = nil
        pinFailures = 0
        lock.unlock()
    }

    // MARK: - Pairing and authentication

    /// Exchange a PIN for a long-lived token (spec 6.2 step 2).  The returned
    /// token is the only time the raw bytes exist here; the store keeps its
    /// hash.
    func pair(pin candidate: String,
              clientName: String,
              requestedRole: LinkRole,
              from address: String,
              now: Date = Date()) -> Result<(token: String, client: PairedClient), LinkAuthError> {
        lock.lock(); defer { lock.unlock() }

        if isBlockedLocked(address, now: now) { return .failure(.rateLimited) }

        guard let active = pin else {
            noteFailureLocked(address, now: now)
            return .failure(.noPairingActive)
        }
        if let expiry = pinExpiry, now >= expiry {
            // A window that has run out is gone for good, not merely refused.
            clearPINLocked()
            noteFailureLocked(address, now: now)
            return .failure(.expired)
        }
        guard candidate == active else {
            noteFailureLocked(address, now: now)
            pinFailures += 1
            // Spec 6.2: the PIN itself dies after five failures, independent
            // of which addresses they came from.
            if pinFailures >= Self.failureLimit { clearPINLocked() }
            return .failure(.wrongPIN)
        }

        // Success consumes the window: one PIN pairs one client.
        clearPINLocked()
        clearFailuresLocked(address)

        let raw = Self.makeTokenBytes()
        let client = PairedClient(id: state.nextCID,
                                  name: clientName,
                                  role: requestedRole,
                                  created: now,
                                  lastSeen: nil,
                                  tokenHash: Self.hashHex(raw))
        state.nextCID += 1
        state.clients.append(client)
        saveLocked()
        return .success((token: Self.base64URL(raw), client: client))
    }

    /// Look a returning client up by its token (spec 7.3 `auth.token`) and
    /// stamp `lastSeen`.
    func authenticate(token: String,
                      from address: String,
                      now: Date = Date()) -> Result<PairedClient, LinkAuthError> {
        lock.lock(); defer { lock.unlock() }

        if isBlockedLocked(address, now: now) { return .failure(.rateLimited) }

        // Only hashes are compared, so no constant-time work is needed; the
        // hex strings are fixed length, which keeps the comparison total.
        guard let raw = Self.decodeBase64URL(token) else {
            noteFailureLocked(address, now: now)
            return .failure(.unknownToken)
        }
        let hash = Self.hashHex(raw)
        guard let index = state.clients.firstIndex(where: { $0.tokenHash.count == hash.count && $0.tokenHash == hash }) else {
            noteFailureLocked(address, now: now)
            return .failure(.unknownToken)
        }

        clearFailuresLocked(address)
        state.clients[index].lastSeen = now
        saveLocked()
        return .success(state.clients[index])
    }

    // MARK: - Client management (spec 7.3, admin)

    var clients: [PairedClient] {
        lock.lock(); defer { lock.unlock() }
        return state.clients
    }

    /// Forget a client entirely.  Its token then reads as unknown, since no
    /// tombstone of the hash is kept.
    func revoke(cid: Int) {
        lock.lock()
        state.clients.removeAll { $0.id == cid }
        saveLocked()
        lock.unlock()
    }

    func setRole(cid: Int, role: LinkRole) {
        lock.lock()
        if let index = state.clients.firstIndex(where: { $0.id == cid }) {
            state.clients[index].role = role
            saveLocked()
        }
        lock.unlock()
    }

    func rename(cid: Int, name: String) {
        lock.lock()
        if let index = state.clients.firstIndex(where: { $0.id == cid }) {
            state.clients[index].name = name
            saveLocked()
        }
        lock.unlock()
    }

    // MARK: - Rate limiting (lock held)

    private func isBlockedLocked(_ address: String, now: Date) -> Bool {
        guard let until = blockedUntil[address] else { return false }
        if now < until { return true }
        // The block has lapsed: forget it and the failures that caused it, so
        // the address starts from a clean slate.
        blockedUntil[address] = nil
        failures[address] = nil
        return false
    }

    private func noteFailureLocked(_ address: String, now: Date) {
        var recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < Self.rateWindow }
        recent.append(now)
        failures[address] = recent
        // The block runs 60 s from the fifth failure; that fifth attempt still
        // gets its own error, the sixth is refused outright.
        if recent.count >= Self.failureLimit {
            blockedUntil[address] = now.addingTimeInterval(Self.rateWindow)
        }
    }

    private func clearFailuresLocked(_ address: String) {
        failures[address] = nil
        blockedUntil[address] = nil
    }

    private func clearPINLocked() {
        pin = nil
        pinExpiry = nil
        pinFailures = 0
    }

    // MARK: - Persistence (lock held for saveLocked)

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func save() {
        lock.lock(); saveLocked(); lock.unlock()
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedState.self, from: data)
    }

    // MARK: - Crypto helpers

    /// Lowercase hex SHA-256, the only form of a token this hub ever keeps.
    static func hashHex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// base64url without padding (RFC 4648 section 5), the encoding the spec
    /// gives for tokens.
    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Inverse of `base64URL`, tolerating the padding a client might add.
    static func decodeBase64URL(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 1 { return nil }        // never a valid base64 length
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    private static func makeTokenBytes() -> Data {
        randomBytes(32)
    }

    /// Six digits, zero padded.  Rejection sampling keeps every PIN equally
    /// likely rather than favouring the low end as a plain modulo would.
    private static func makePIN() -> String {
        let limit: UInt32 = 4_294_967_295 - (4_294_967_295 % 1_000_000)
        var value: UInt32 = 0
        repeat {
            let bytes = randomBytes(4)
            value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        } while value >= limit
        return String(format: "%06u", value % 1_000_000)
    }

    /// SecRandomCopyBytes, falling back to the system RNG if it ever fails.
    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return Data(bytes)
    }
}
