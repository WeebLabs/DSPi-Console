//
//  LinkDiscoveryTests.swift
//  DSPi ConsoleTests
//
//  The TXT-record encoding.  DNSServiceRegister itself is a system call and is
//  exercised by hand, not in CI, so these tests pin the wire form of the record.
//

import XCTest
@testable import DSPi_Console

final class LinkDiscoveryTests: XCTestCase {

    /// Parse a DNS-SD TXT blob back into key=value strings.
    private func parseTXT(_ data: Data) -> [String] {
        var out = [String]()
        var i = data.startIndex
        while i < data.endIndex {
            let len = Int(data[i]); i = data.index(after: i)
            guard len > 0, data.index(i, offsetBy: len, limitedBy: data.endIndex) != nil else { break }
            let end = data.index(i, offsetBy: len)
            out.append(String(decoding: data[i..<end], as: UTF8.self))
            i = end
        }
        return out
    }

    func testRequiredKeysPresent() {
        let ad = LinkAdvertisement(hubID: "abc-123", auth: "pin", deviceCount: 2,
                                   serials: ["AAAA", "BBBB"])
        let entries = parseTXT(ad.txtData())
        XCTAssertTrue(entries.contains("v=1"))
        XCTAssertTrue(entries.contains("hid=abc-123"))
        XCTAssertTrue(entries.contains("kind=console"))
        XCTAssertTrue(entries.contains("auth=pin"))
        XCTAssertTrue(entries.contains("n=2"))
        XCTAssertTrue(entries.contains("d=AAAA,BBBB"))
    }

    func testSerialsDroppedWhenTooLong() {
        let many = (0..<40).map { String(format: "SERIAL%010d", $0) }
        let ad = LinkAdvertisement(hubID: "abc", auth: "pin", deviceCount: many.count, serials: many)
        let entries = parseTXT(ad.txtData())
        XCTAssertFalse(entries.contains { $0.hasPrefix("d=") },
                       "an oversize serial list is omitted, not truncated mid-value")
        XCTAssertTrue(entries.contains("n=40"), "the count is still advertised")
    }

    func testOptionalFlags() {
        var ad = LinkAdvertisement(hubID: "x", auth: "none", deviceCount: 0, serials: [])
        ad.tls = true; ad.web = true
        let entries = parseTXT(ad.txtData())
        XCTAssertTrue(entries.contains("tls=1"))
        XCTAssertTrue(entries.contains("web=1"))
        XCTAssertTrue(entries.contains("auth=none"))
        XCTAssertFalse(entries.contains { $0.hasPrefix("d=") }, "no serials, no d key")
    }

    func testDefaultPortIsVIDDecimal() {
        XCTAssertEqual(LinkDiscovery.defaultPort, 11915)   // 0x2E8B
        XCTAssertEqual(LinkDiscovery.serviceType, "_dspi._tcp")
    }
}
