//
//  HubBrowserReconfirmTests.swift
//  DSPi ConsoleTests
//
//  A hub that loses power sends no Bonjour goodbye.  The browser asks
//  mDNSResponder to reconfirm the PTR record when a resolve fails, and the
//  record data it hands over must be the instance's full name in wire form.
//

import XCTest
@testable import DSPi_Console

final class HubBrowserReconfirmTests: XCTestCase {

    func testPTRDataEncodesEachLabelWithALengthPrefix() {
        let data = HubBrowser.ptrRecordData(name: "Studio", type: "_dspi._tcp", domain: "local.")
        var expected = Data()
        for label in ["Studio", "_dspi", "_tcp", "local"] {
            expected.append(UInt8(label.utf8.count))
            expected.append(contentsOf: Array(label.utf8))
        }
        expected.append(0)
        XCTAssertEqual(data, expected)
    }

    func testInstanceNameIsOneLabelEvenWithDots() {
        let data = HubBrowser.ptrRecordData(name: "Troy's Mac 2.0", type: "_dspi._tcp", domain: "")
        XCTAssertEqual(data?.first, UInt8("Troy's Mac 2.0".utf8.count))
        // Empty domain defaults to .local.
        var tail = Data([5])
        tail.append(contentsOf: Array("local".utf8))
        tail.append(0)
        XCTAssertEqual(data.map { Data($0.suffix(7)) }, tail)
    }

    func testOverlongLabelIsRefused() {
        let name = String(repeating: "x", count: 64)
        XCTAssertNil(HubBrowser.ptrRecordData(name: name, type: "_dspi._tcp", domain: "local."))
    }
}
