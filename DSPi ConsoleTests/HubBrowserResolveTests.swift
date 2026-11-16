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
        resolver.holds = true
        let browser = make(resolver)
        browser.resolveRetryBase = 0.3     // longer than a settle, shorter than the wait below
        let entry = (name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))
        browser.ingest([entry])
        resolver.settle(nil)
        settle()                       // the failure lands and books a retry
        browser.ingest([])             // the service is gone before it fires
        let past = expectation(description: "past the retry delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { past.fulfill() }
        wait(for: [past], timeout: 1)
        XCTAssertEqual(resolver.attempts, 1, "no retry for a service that is gone")

        resolver.holds = false
        resolver.answers = [("10.0.0.5", 11915)]
        browser.ingest([entry])
        browser.addManual("10.0.0.9")
        waitUntil { browser.hubs.map { $0.host } == ["10.0.0.5", "10.0.0.9"] }
        browser.stop()
        XCTAssertEqual(browser.hubs.map { $0.host }, ["10.0.0.9"], "manual entries survive a stop")
    }

    /// An attempt's result can reach the main actor after the service left
    /// and came back with a new attempt under way.  The late result must not
    /// cancel that attempt or be taken for its answer.
    func testALateResultFromAnAbandonedAttemptIsIgnored() {
        let resolver = FakeResolver()
        resolver.holds = true
        let browser = make(resolver)
        let entry = (name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))
        browser.ingest([entry])
        let first = resolver.pending.removeFirst()
        browser.ingest([])                  // abandons the first attempt
        browser.ingest([entry])             // starts a second
        XCTAssertEqual(resolver.attempts, 2)
        first(("10.0.0.1", 11915))          // the first answers anyway
        settle()
        XCTAssertTrue(browser.hubs.isEmpty, "the stale answer is not used")
        resolver.settle(("10.0.0.5", 11915))
        waitUntil { browser.hubs.first?.host == "10.0.0.5" }
    }

    // MARK: - Restarting a running search

    /// A searching browser with no system browse behind it: restarts are
    /// counted and results are fed by hand.
    private func makeSearching(_ resolver: FakeResolver) -> HubBrowser {
        let browser = make(resolver)
        browser.usesSystemBrowser = false
        browser.refreshInterval = 1000      // tests restart on demand
        browser.earlyRefreshDelays = []
        browser.refreshGap = 0.02
        browser.refreshSettle = 0.3
        return browser
    }

    /// A long-running search left a hub unlisted for hours until the user
    /// turned it off and on.  It now restarts itself, and stops when told to.
    func testRunningSearchRestartsItselfUntilStopped() {
        let browser = makeSearching(FakeResolver())
        browser.refreshInterval = 0.1
        browser.start()
        waitUntil { browser.browserStarts >= 3 }
        browser.stop()
        let starts = browser.browserStarts
        settle(); settle(); settle()
        XCTAssertEqual(browser.browserStarts, starts, "no restarts after stop")
    }

    /// Soon after starting, the search restarts on the early schedule, then
    /// settles to the steady interval.  A later start runs the early ones again.
    func testEarlyRestartsRunOnceThenTheSteadyIntervalTakesOver() {
        let browser = makeSearching(FakeResolver())
        browser.earlyRefreshDelays = [0.05, 0.05]
        browser.start()
        waitUntil { browser.browserStarts == 3 }     // the start plus two early restarts
        settle(); settle(); settle()
        XCTAssertEqual(browser.browserStarts, 3, "the steady interval (1000 s) is next")

        browser.stop()
        browser.start()
        waitUntil { browser.browserStarts == 6 }
        browser.stop()
    }

    /// A hub the old browser never reported is listed as soon as the restarted
    /// one sees it, while a listed hub missing from the restarted browser's
    /// first (possibly partial) snapshot stays until the window settles.
    func testRestartListsNewHubsAndDropsMissingOnesOnlyOnceSettled() {
        let resolver = FakeResolver()
        resolver.answers = [("10.0.0.5", 11915), ("10.0.0.6", 11915)]
        let browser = makeSearching(resolver)
        browser.start()
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        waitUntil { browser.hubs.count == 1 }

        // The window opens with refresh() itself.  waitUntil polls about once
        // a second, longer than the window, so only fixed short waits here.
        browser.refresh()
        browser.ingest([(name: "Bridge", txt: txt("hub-2"), endpoint: service("Bridge"))])
        settle()
        XCTAssertEqual(browser.hubs.map(\.name), ["Bridge", "Studio"], "Studio kept while the window is open")

        waitUntil { browser.hubs.map(\.name) == ["Bridge"] }
        XCTAssertEqual(browser.browserStarts, 2)
        browser.stop()
    }

    /// The restarted browser reports every cached service as new.  That is no
    /// reason to dial hubs whose address is known, nor to drop any of them.
    func testRestartDoesNotResolveKnownHubsAgain() {
        let resolver = FakeResolver()
        resolver.answers = [("10.0.0.5", 11915)]
        let browser = makeSearching(resolver)
        browser.start()
        let entry = (name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))
        browser.ingest([entry])
        waitUntil { browser.hubs.first?.host == "10.0.0.5" }

        browser.refresh()
        browser.ingest([entry])                     // changed: nil means "all new"
        settle(); settle(); settle(); settle()      // past the settle window
        XCTAssertEqual(resolver.attempts, 1)
        XCTAssertEqual(browser.hubs.first?.host, "10.0.0.5")
        browser.stop()
    }

    /// A restarted browser that reports nothing and never becomes ready (still
    /// waiting, say) is no evidence that the listed hubs left.
    func testSilentRestartedBrowserDropsNothing() {
        let resolver = FakeResolver()
        resolver.answers = [("10.0.0.5", 11915)]
        let browser = makeSearching(resolver)
        browser.start()
        browser.ingest([(name: "Studio", txt: txt("hub-1"), endpoint: service("Studio"))])
        waitUntil { browser.hubs.count == 1 }

        browser.refresh()
        settle(); settle(); settle(); settle()
        XCTAssertEqual(browser.hubs.map(\.name), ["Studio"])
        browser.stop()
    }
}
