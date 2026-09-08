import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the DSPi Link hub authentication store
/// (dspi_link_protocol_spec.md sections 6 and 7.3).  Every test gets its own
/// temporary directory, so no test sees another's store file and none touch
/// the real one under Application Support.
final class LinkAuthStoreTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkAuthStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("link-auth.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        storeURL = nil
    }

    // MARK: - Helpers

    private func makeStore() -> LinkAuthStore { LinkAuthStore(storeURL: storeURL) }

    /// Pair a fresh client and return its token, failing the test if the
    /// pairing did not succeed.
    @discardableResult
    private func pairSucceeding(_ store: LinkAuthStore,
                                name: String = "Troy's iPhone",
                                role: LinkRole = .control,
                                address: String = "192.168.1.10",
                                now: Date = Date(),
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> (token: String, client: PairedClient) {
        let pin = store.beginPairing()
        let result = store.pair(pin: pin, clientName: name, requestedRole: role, from: address, now: now)
        switch result {
        case .success(let pairing):
            return pairing
        case .failure(let error):
            XCTFail("expected pairing to succeed, got \(error)", file: file, line: line)
            throw error
        }
    }

    private func error<T>(_ result: Result<T, LinkAuthError>,
                          file: StaticString = #filePath,
                          line: UInt = #line) -> LinkAuthError? {
        switch result {
        case .success: XCTFail("expected a failure", file: file, line: line); return nil
        case .failure(let error): return error
        }
    }

    // MARK: - Identity and persistence

    /// The hub id is generated once and survives a restart, because clients
    /// key their stored token on `hid` (spec 6.2 step 3).
    func testHubIdentityPersistsAcrossInstances() {
        let first = makeStore()
        let id = first.hubID
        let name = first.hubName

        let second = makeStore()
        XCTAssertEqual(second.hubID, id)
        XCTAssertEqual(second.hubName, name)
    }

    func testDefaultsAreSpecCompliant() {
        let store = makeStore()
        // Spec 6.1: hubs must default to `pin`.
        XCTAssertEqual(store.authMode, .pin)
        XCTAssertTrue(store.hubName.hasSuffix("DSPi Console"))
        XCTAssertNil(store.activePIN)
        XCTAssertTrue(store.clients.isEmpty)
    }

    func testHubNameAndModePersist() {
        let first = makeStore()
        first.hubName = "Studio Mac"
        first.authMode = .none

        let second = makeStore()
        XCTAssertEqual(second.hubName, "Studio Mac")
        XCTAssertEqual(second.authMode, .none)
    }

    /// A store file that is not valid JSON must not take the hub down; it is
    /// replaced by a fresh, working store.
    func testCorruptStoreFileYieldsFreshStore() throws {
        try Data("{ this is not json".utf8).write(to: storeURL)

        let store = makeStore()
        XCTAssertTrue(store.clients.isEmpty)
        XCTAssertEqual(store.authMode, .pin)
        // And it is usable, not merely non-crashing.
        let pairing = try pairSucceeding(store)
        XCTAssertEqual(store.clients.count, 1)
        XCTAssertFalse(pairing.token.isEmpty)
    }

    // MARK: - Pairing

    func testPairingSucceedsAndTokenAuthenticates() throws {
        let store = makeStore()
        let pin = store.beginPairing()
        XCTAssertEqual(pin.count, 6)
        XCTAssertTrue(pin.allSatisfy { $0.isNumber })
        XCTAssertEqual(store.activePIN, pin)

        let pairing = try pairSucceeding(store)
        XCTAssertEqual(pairing.client.name, "Troy's iPhone")
        XCTAssertEqual(pairing.client.role, .control)
        XCTAssertEqual(store.clients.count, 1)
        // A successful pairing consumes the window: one PIN, one client.
        XCTAssertNil(store.activePIN)

        switch store.authenticate(token: pairing.token, from: "192.168.1.10") {
        case .success(let client):
            XCTAssertEqual(client.id, pairing.client.id)
            XCTAssertEqual(client.role, .control)
        case .failure(let error):
            XCTFail("expected the freshly issued token to authenticate, got \(error)")
        }
    }

    func testWrongPINFails() {
        let store = makeStore()
        let pin = store.beginPairing()
        let wrong = pin == "000000" ? "111111" : "000000"

        let result = store.pair(pin: wrong, clientName: "Imposter", requestedRole: .admin, from: "10.0.0.9")
        XCTAssertEqual(error(result), .wrongPIN)
        XCTAssertTrue(store.clients.isEmpty)
        // The window stays open until the fifth failure.
        XCTAssertEqual(store.activePIN, pin)
    }

    func testNoPairingWindowFails() {
        let store = makeStore()
        let result = store.pair(pin: "123456", clientName: "Nobody", requestedRole: .viewer, from: "10.0.0.9")
        XCTAssertEqual(error(result), .noPairingActive)
    }

    func testCancelPairingClosesTheWindow() {
        let store = makeStore()
        let pin = store.beginPairing()
        store.cancelPairing()
        XCTAssertNil(store.activePIN)
        XCTAssertNil(store.pairingExpires)
        let result = store.pair(pin: pin, clientName: "Late", requestedRole: .viewer, from: "10.0.0.9")
        XCTAssertEqual(error(result), .noPairingActive)
    }

    /// Spec 6.2: "The PIN is invalidated after any 5 failures."  The failures
    /// come from five distinct addresses so the per-address rate limit does
    /// not fire first and mask the effect; the sixth attempt presents the
    /// correct PIN and is refused with `noPairingActive`, because the window
    /// is gone rather than mismatched.
    func testFiveWrongPINsInvalidateTheWindow() {
        let store = makeStore()
        let pin = store.beginPairing()
        let wrong = pin == "000000" ? "111111" : "000000"

        for i in 1...5 {
            let result = store.pair(pin: wrong, clientName: "Imposter", requestedRole: .viewer, from: "10.0.0.\(i)")
            XCTAssertEqual(error(result), .wrongPIN, "failure \(i)")
        }
        XCTAssertNil(store.activePIN)

        let sixth = store.pair(pin: pin, clientName: "Troy", requestedRole: .control, from: "10.0.0.6")
        XCTAssertEqual(error(sixth), .noPairingActive)
        XCTAssertTrue(store.clients.isEmpty)
    }

    func testExpiredPINFails() {
        let store = makeStore()
        let pin = store.beginPairing(ttl: 120)
        let late = Date().addingTimeInterval(200)

        let result = store.pair(pin: pin, clientName: "Troy", requestedRole: .control, from: "10.0.0.9", now: late)
        XCTAssertEqual(error(result), .expired)
        // An expired window is cleared, not merely refused.
        XCTAssertNil(store.activePIN)
        XCTAssertTrue(store.clients.isEmpty)
    }

    // MARK: - Token shape and storage

    func testTokenIsBase64URLWithoutPadding() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store)

        XCTAssertFalse(pairing.token.contains("+"))
        XCTAssertFalse(pairing.token.contains("/"))
        XCTAssertFalse(pairing.token.contains("="))
        // 32 raw bytes encode to 43 unpadded base64 characters.
        XCTAssertEqual(pairing.token.count, 43)

        // The encoder itself must substitute both characters, checked on bytes
        // that are guaranteed to produce them under standard base64.
        let awkward = Data([0xFB, 0xFF, 0xBF])
        XCTAssertEqual(awkward.base64EncodedString(), "+/+/")
        XCTAssertEqual(LinkAuthStore.base64URL(awkward), "-_-_")
        XCTAssertEqual(LinkAuthStore.decodeBase64URL("-_-_"), awkward)
        // Round trip of a real token.
        XCTAssertEqual(LinkAuthStore.decodeBase64URL(pairing.token)?.count, 32)
    }

    /// Spec 6.2: "A hub stores only a SHA-256 of the token."
    func testStoreFileHoldsTheHashAndNotTheToken() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store)

        let contents = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(pairing.token), "the raw token must never reach the file")
        XCTAssertTrue(contents.contains(pairing.client.tokenHash))
        XCTAssertEqual(pairing.client.tokenHash.count, 64)
        XCTAssertTrue(pairing.client.tokenHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // The hash on file really is the hash of the issued token.
        let raw = try XCTUnwrap(LinkAuthStore.decodeBase64URL(pairing.token))
        XCTAssertEqual(LinkAuthStore.hashHex(raw), pairing.client.tokenHash)
    }

    func testTokenSurvivesARestart() throws {
        let first = makeStore()
        let pairing = try pairSucceeding(first)

        let second = makeStore()
        switch second.authenticate(token: pairing.token, from: "192.168.1.10") {
        case .success(let client): XCTAssertEqual(client.id, pairing.client.id)
        case .failure(let error): XCTFail("token should survive a restart, got \(error)")
        }
    }

    // MARK: - Authentication

    func testAuthenticateUpdatesLastSeen() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store)
        // lastSeen starts nil: pairing records `created`, a session records
        // `last_seen` (spec 7.3 auth.list).
        XCTAssertNil(pairing.client.lastSeen)

        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        _ = store.authenticate(token: pairing.token, from: "192.168.1.10", now: seen)
        XCTAssertEqual(store.clients.first?.lastSeen, seen)

        let later = seen.addingTimeInterval(3600)
        _ = store.authenticate(token: pairing.token, from: "192.168.1.10", now: later)
        XCTAssertEqual(store.clients.first?.lastSeen, later)

        // And it is persisted, not merely in memory.
        XCTAssertEqual(makeStore().clients.first?.lastSeen, later)
    }

    func testUnknownAndMalformedTokensFail() {
        let store = makeStore()
        XCTAssertEqual(error(store.authenticate(token: "not-a-real-token", from: "10.0.0.9")), .unknownToken)
        XCTAssertEqual(error(store.authenticate(token: "!!!!", from: "10.0.0.8")), .unknownToken)
    }

    /// Revoking forgets the client outright, so its token reads as unknown.
    /// No tombstone of the hash is kept, which is why `.unknownToken` and not
    /// `.revoked` is the answer.
    func testRevokeInvalidatesTheToken() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store)

        store.revoke(cid: pairing.client.id)
        XCTAssertTrue(store.clients.isEmpty)
        XCTAssertEqual(error(store.authenticate(token: pairing.token, from: "192.168.1.10")), .unknownToken)
        // The revocation is on disk too.
        XCTAssertTrue(makeStore().clients.isEmpty)
    }

    // MARK: - Client management

    func testSetRoleAndRenamePersist() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store, name: "iPhone", role: .viewer)
        let cid = pairing.client.id

        store.setRole(cid: cid, role: .admin)
        store.rename(cid: cid, name: "Troy's iPhone")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.clients.first?.role, .admin)
        XCTAssertEqual(reloaded.clients.first?.name, "Troy's iPhone")
        // A later authentication reports the changed role.
        switch reloaded.authenticate(token: pairing.token, from: "192.168.1.10") {
        case .success(let client): XCTAssertEqual(client.role, .admin)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    /// cids are monotonic and never reused, so a revoked client's id cannot
    /// come back attached to someone else.
    func testClientIDsAreMonotonic() throws {
        let store = makeStore()
        let first = try pairSucceeding(store, name: "A")
        store.revoke(cid: first.client.id)
        let second = try pairSucceeding(store, name: "B")
        XCTAssertGreaterThan(second.client.id, first.client.id)
    }

    // MARK: - Rate limiting (spec 6.2)

    /// Five failures from one address inside a minute block that address for
    /// 60 s from the fifth.  Driven with explicit `now` values, and through
    /// `authenticate` so the PIN-invalidation rule does not interfere.
    func testRateLimitTripsOnFifthFailureAndClearsAfterAMinute() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let bogus = LinkAuthStore.base64URL(Data(repeating: 0xAB, count: 32))

        for i in 0..<5 {
            let result = store.authenticate(token: bogus, from: "10.1.1.1", now: t0.addingTimeInterval(Double(i)))
            XCTAssertEqual(error(result), .unknownToken, "failure \(i + 1) reports its own error")
        }

        // The sixth attempt, and anything else inside the block, is refused.
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.1.1.1", now: t0.addingTimeInterval(5))),
                       .rateLimited)
        let pin = store.beginPairing()
        XCTAssertEqual(error(store.pair(pin: pin, clientName: "Troy", requestedRole: .control,
                                        from: "10.1.1.1", now: t0.addingTimeInterval(10))),
                       .rateLimited, "the block covers pair as well as authenticate")

        // The block runs 60 s from the fifth failure, which was at t0 + 4.
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.1.1.1", now: t0.addingTimeInterval(63))),
                       .rateLimited)
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.1.1.1", now: t0.addingTimeInterval(65))),
                       .unknownToken, "the block lifts 60 s after the fifth failure")
    }

    func testRateLimitIsPerAddress() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let bogus = LinkAuthStore.base64URL(Data(repeating: 0xCD, count: 32))

        for _ in 0..<5 {
            _ = store.authenticate(token: bogus, from: "10.1.1.1", now: t0)
        }
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.1.1.1", now: t0)), .rateLimited)
        // A different address is untouched.
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.1.1.2", now: t0)), .unknownToken)
    }

    /// Failures older than the window fall out of the count, so slow guessing
    /// does not accumulate forever.
    func testFailuresOutsideTheWindowDoNotAccumulate() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let bogus = LinkAuthStore.base64URL(Data(repeating: 0xEF, count: 32))

        for i in 0..<4 {
            _ = store.authenticate(token: bogus, from: "10.2.2.2", now: t0.addingTimeInterval(Double(i)))
        }
        // Two minutes later the earlier four have aged out, so this fifth
        // attempt overall is only the first inside the window.
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.2.2.2", now: t0.addingTimeInterval(120))),
                       .unknownToken)
        XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.2.2.2", now: t0.addingTimeInterval(121))),
                       .unknownToken)
    }

    /// A successful authentication clears the address's failure ledger.
    func testSuccessResetsTheFailureCount() throws {
        let store = makeStore()
        let pairing = try pairSucceeding(store, address: "10.3.3.3")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let bogus = LinkAuthStore.base64URL(Data(repeating: 0x11, count: 32))

        for _ in 0..<4 {
            _ = store.authenticate(token: bogus, from: "10.3.3.3", now: t0)
        }
        _ = store.authenticate(token: pairing.token, from: "10.3.3.3", now: t0)
        // Four more failures would trip the limit had the count not reset.
        for _ in 0..<4 {
            XCTAssertEqual(error(store.authenticate(token: bogus, from: "10.3.3.3", now: t0)), .unknownToken)
        }
    }
}
