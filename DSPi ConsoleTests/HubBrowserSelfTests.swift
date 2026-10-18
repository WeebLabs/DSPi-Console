//
//  HubBrowserSelfTests.swift
//  DSPi ConsoleTests
//
//  This Console's own hub is not an "other" hub: Bonjour returns our own
//  advertisement, and a typed address can point back at this Mac.
//

import XCTest
import Network
@testable import DSPi_Console

@MainActor
final class HubBrowserSelfTests: XCTestCase {

    private let ownID = "94146af2-2bc6-4bca-bb14-6bd911812737"

    private func txt(_ hid: String) -> NWTXTRecord {
        NWTXTRecord(["hid": hid, "kind": "console", "auth": "none", "n": "0"])
    }

    private func endpoint(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: NWEndpoint.Port(rawValue: port)!)
    }

    func testOwnAdvertisementIsNotListed() {
        let browser = HubBrowser(ownHubID: ownID.uppercased())
        browser.ingest([(name: "This Mac", txt: txt(ownID), endpoint: endpoint(11915)),
                        (name: "Studio", txt: txt("other-hub"), endpoint: endpoint(11916))])
        XCTAssertEqual(browser.hubs.map { $0.name }, ["Studio"])
    }

    func testOwnHubLaterRecognisedIsDropped() {
        let browser = HubBrowser(ownHubID: nil)
        browser.ingest([(name: "This Mac", txt: txt(ownID), endpoint: endpoint(11915))])
        XCTAssertEqual(browser.hubs.count, 1, "without an own id every hub is someone else's")

        let filtering = HubBrowser(ownHubID: ownID)
        filtering.ingest([(name: "This Mac", txt: txt("not-yet"), endpoint: endpoint(11915))])
        XCTAssertEqual(filtering.hubs.count, 1)
        filtering.ingest([(name: "This Mac", txt: txt(ownID), endpoint: endpoint(11915))])
        XCTAssertTrue(filtering.hubs.isEmpty, "a listed hub that turns out to be ours goes")
    }

    func testManualAddressOfThisMacIsMarkedSelf() {
        var asked: [URL] = []
        let own = ownID
        let browser = HubBrowser(ownHubID: ownID) { url, done in
            asked.append(url)
            done(url.host == "127.0.0.1" ? Data(#"{"hub":{"id":"\#(own)","name":"Me"}}"#.utf8) : nil)
        }
        browser.addManual("127.0.0.1")
        browser.addManual("10.0.0.9:12000")
        XCTAssertEqual(asked.map { $0.absoluteString },
                       ["http://127.0.0.1:11915/dspi/v1/info", "http://10.0.0.9:12000/dspi/v1/info"])
        let marked = expectation(for: NSPredicate { _, _ in
            browser.hubs.first { $0.host == "127.0.0.1" }?.isSelf == true
        }, evaluatedWith: nil)
        wait(for: [marked], timeout: 2)
        XCTAssertEqual(browser.hubs.first { $0.host == "10.0.0.9" }?.isSelf, false)
    }
}
