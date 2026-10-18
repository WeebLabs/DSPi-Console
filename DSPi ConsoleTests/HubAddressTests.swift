//
//  HubAddressTests.swift
//  DSPi ConsoleTests
//
//  Hub addresses as the browser resolves them and the user types them.  A
//  link-local IPv6 hub used to lose its closing bracket, leaving a nil URL so
//  the client never connected.
//

import XCTest
import Network
@testable import DSPi_Console

final class HubAddressTests: XCTestCase {

    private func hub(host: String, port: Int = 11915) -> DiscoveredHub {
        DiscoveredHub(id: "h", name: "Studio", kind: "console", authMode: "pin",
                      deviceCount: 1, serials: [], path: "/dspi/v1",
                      tls: false, host: host, port: port, isManual: false)
    }

    func testLinkLocalIPv6KeepsZoneInURL() {
        let h = hub(host: "fe80::1c2b:3d4e:5f60:7182%en0")
        XCTAssertEqual(h.webSocketURL?.absoluteString, "ws://[fe80::1c2b:3d4e:5f60:7182%25en0]:11915/dspi/v1")
        XCTAssertEqual(h.displayAddress, "[fe80::1c2b:3d4e:5f60:7182%en0]:11915")
    }

    func testIPv4AndNameURLs() {
        XCTAssertEqual(hub(host: "192.168.1.20").webSocketURL?.absoluteString, "ws://192.168.1.20:11915/dspi/v1")
        XCTAssertEqual(hub(host: "studio.local", port: 12000).displayAddress, "studio.local:12000")
        XCTAssertEqual(hub(host: "2001:db8::5").webSocketURL?.absoluteString, "ws://[2001:db8::5]:11915/dspi/v1")
    }

    func testResolvedHostTextKeepsZone() {
        let v6 = NWEndpoint.Host.ipv6(IPv6Address("fe80::1%lo0")!)
        XCTAssertEqual(HubBrowser.hostText(v6), "fe80::1%lo0")
        let v4 = NWEndpoint.Host.ipv4(IPv4Address("192.168.1.20")!)
        XCTAssertEqual(HubBrowser.hostText(v4), "192.168.1.20")
    }

    func testParseAddress() {
        let cases: [(String, String, Int)] = [
            ("192.168.1.20", "192.168.1.20", 11915),
            ("192.168.1.20:12000", "192.168.1.20", 12000),
            ("studio.local", "studio.local", 11915),
            ("[fe80::1%en0]:12000", "fe80::1%en0", 12000),
            ("[fe80::1%en0]", "fe80::1%en0", 11915),
            // A bare literal's last group is not a port.
            ("fe80::1", "fe80::1", 11915),
            ("  10.0.0.2 ", "10.0.0.2", 11915),
        ]
        for (text, host, port) in cases {
            let parsed = HubBrowser.parseAddress(text)
            XCTAssertEqual(parsed?.host, host, text)
            XCTAssertEqual(parsed?.port, port, text)
        }
        for bad in ["", "host:abc", "[fe80::1", "[fe80::1]x", ":12000"] {
            XCTAssertNil(HubBrowser.parseAddress(bad), bad)
        }
    }
}
