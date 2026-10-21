//
//  HubBrowserResolveTests.swift
//  DSPi ConsoleTests
//
//  A browsed service carries no address; the browser resolves one and must
//  keep it current without the user restarting the search.
//

import XCTest
import Network
import Combine
@testable import DSPi_Console

@MainActor
final class HubBrowserResolveTests: XCTestCase {

    /// A scripted resolver: answers each attempt from `answers` in order, and
    /// records how many attempts were made.
    private final class FakeResolver {
        var answers: [(host: String, port: Int)?] = []
        var attempts = 0
        var pending: [((host: String, port: Int)?) -> Void] = []
        /// True holds every attempt open until `settle` is called.
        var holds = false

        func resolve(_ endpoint: NWEndpoint,
                     _ completion: @escaping ((host: String, port: Int)?) -> Void) -> AnyCancellable {
            attempts += 1
            if holds {
                pending.append(completion)
            } else {
                let answer = answers.isEmpty ? nil : answers.removeFirst()
                completion(answer)
            }
            return AnyCancellable {}
        }

        func settle(_ answer: (host: String, port: Int)?) {
            let done = pending; pending.removeAll()
            done.forEach { $0(answer) }
        }
    }

    private func txt(_ hid: String) -> NWTXTRecord {
        NWTXTRecord(["hid": hid, "kind": "console", "auth": "none", "n": "1", "d": "REMOTE0000REMOTE"])
    }

    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_dspi._tcp", domain: "local.", interface: nil)
    }

    private func make(_ resolver: FakeResolver) -> HubBrowser {
        let browser = HubBrowser(ownHubID: nil, fetchInfo: { _, done in done(nil) },
                                 resolver: resolver.resolve)
        browser.resolveRetryBase = 0.05
        return browser
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) {
        let e = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        wait(for: [e], timeout: timeout)
    }

    /// Resolve results hop to the main actor; let that hop land (and give a
    /// result that should not arrive a moment to not arrive).
    private func settle() {
        let e = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { e.fulfill() }
        wait(for: [e], timeout: 1)
    }

    /// A resolve that fails (the hub's port refusing while it starts, no route
    /// yet after a wake) used to leave the hub unlisted until the search was
    /// turned off and on.
    func testFailedResolveIsRetriedUntilTheHubAppears() {
        let resolver = FakeResolver()
        resolver.answers = [nil, nil, ("10.0.0.5", 11915)]
        let browser = make(resolver)
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        XCTAssertTrue(browser.hubs.isEmpty, "nothing to dial yet")

        waitUntil { browser.hubs.first?.host == "10.0.0.5" }
        XCTAssertEqual(resolver.attempts, 3)
        XCTAssertEqual(browser.hubs.first?.port, 11915)
    }

    /// A hub that re-announces the same name from a new lease is resolved
    /// again; the old address stays listed until the new one lands.
    func testChangedServiceIsResolvedAgainAndTheNewAddressReplacesTheOld() {
        let resolver = FakeResolver()
        resolver.answers = [("10.0.0.5", 11915), ("10.0.0.9", 11915)]
        let browser = make(resolver)
        let entry = (name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))
        browser.ingest([entry])
        waitUntil { browser.hubs.first?.host == "10.0.0.5" }

        // An unrelated browse update does not dial the hub again.
        browser.ingest([entry], changed: [])
        settle()
        XCTAssertEqual(resolver.attempts, 1)
        XCTAssertEqual(browser.hubs.first?.host, "10.0.0.5")

        browser.ingest([entry], changed: ["Studio"])
        XCTAssertEqual(resolver.attempts, 2)
        XCTAssertEqual(browser.hubs.first?.host, "10.0.0.5", "the old address serves until the new one lands")
        waitUntil { browser.hubs.first?.host == "10.0.0.9" }
        XCTAssertEqual(browser.hubs.first?.id, "hub-1", "same hub, new address")
    }

    /// The composite asks for a fresh address when its connection to the hub
    /// fails; the answer is published when it differs.
    func testRefreshAddressResolvesAgainOnRequest() {
        let resolver = FakeResolver()
        resolver.answers = [("10.0.0.5", 11915), ("10.0.0.5", 11915), ("10.0.0.7", 11915)]
        let browser = make(resolver)
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        waitUntil { browser.hubs.first?.host == "10.0.0.5" }

        var published = 0
        let sub = browser.$hubs.dropFirst().sink { _ in published += 1 }
        defer { sub.cancel() }

        browser.refreshAddress(ofHub: "hub-1")
        XCTAssertEqual(resolver.attempts, 2)
        settle()
        XCTAssertEqual(published, 0, "an unchanged address is not republished")

        browser.refreshAddress(ofHub: "hub-1")
        waitUntil { browser.hubs.first?.host == "10.0.0.7" }
        XCTAssertEqual(published, 1)

        browser.refreshAddress(ofHub: "not-a-hub")
        XCTAssertEqual(resolver.attempts, 3, "an unknown hub is ignored")
    }

    /// One attempt per service at a time: a refresh during an attempt waits
    /// for it rather than starting another.
    func testOnlyOneResolveRunsPerService() {
        let resolver = FakeResolver()
        resolver.holds = true
        let browser = make(resolver)
        let entry = (name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))
        browser.ingest([entry])
        browser.refreshAddress(ofHub: "hub-1")
        browser.ingest([entry], changed: ["Studio"])
        XCTAssertEqual(resolver.attempts, 1)
        resolver.settle(("10.0.0.5", 11915))
        waitUntil { browser.hubs.first?.host == "10.0.0.5" }
    }

    /// A service that leaves the browse results takes its pending retry with
    /// it, and stopping the browser forgets every browsed hub so the next
    /// start resolves afresh.
    func testRemovedServiceStopsRetryingAndStopForgetsBrowsedHubs() {
        let resolver = FakeResolver()
        resolver.answers = [nil]
        let browser = make(resolver)
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        browser.ingest([])
        settle(); settle()
        XCTAssertEqual(resolver.attempts, 1, "no retry for a service that is gone")

        resolver.answers = [("10.0.0.5", 11915)]
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        browser.addManual("10.0.0.9")
        waitUntil { browser.hubs.map { $0.host } == ["10.0.0.5", "10.0.0.9"] }
        browser.stop()
        XCTAssertEqual(browser.hubs.map { $0.host }, ["10.0.0.9"], "manual entries survive a stop")
    }
}
