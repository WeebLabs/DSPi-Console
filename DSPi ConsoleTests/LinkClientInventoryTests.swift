//
//  LinkClientInventoryTests.swift
//  DSPi ConsoleTests
//
//  The client's device inventory is fed from the socket's callback thread
//  and mirrored to the main thread for its publisher.  These feed the
//  control-plane handler directly, so the race between the two is
//  deterministic rather than a matter of socket timing.
//

import XCTest
import Combine
@testable import DSPi_Console

final class LinkClientInventoryTests: XCTestCase {

    private func added(_ handle: Int, serial: String) throws -> Data {
        try LinkMessage.deviceAdded(LinkDeviceEvent(device:
            LinkDeviceInfo(handle: handle, serial: serial, name: nil, state: .online))).encoded()
    }

    private func removed(_ handle: Int) throws -> Data {
        try LinkMessage.deviceRemoved(LinkDeviceRemoved(handle: handle)).encoded()
    }

    /// Run the main queue so the publisher mirror catches up.
    private func drainMain() {
        let e = expectation(description: "main")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    func testABurstOfDeviceAddedEventsKeepsEveryDevice() throws {
        let client = LinkClient()
        var published: [[LinkDeviceInfo]] = []
        let sub = client.devicesPublisher.dropFirst().sink { published.append($0) }
        defer { sub.cancel() }

        // Two events back to back, before the main thread can run between them.
        client.handleText(try added(1, serial: "AAAA"))
        client.handleText(try added(2, serial: "BBBB"))
        XCTAssertEqual(client.devices.map { $0.handle }, [1, 2], "the inventory is current at once")

        drainMain()
        XCTAssertEqual(published.last?.map { $0.handle }, [1, 2], "the publisher ends on the full list")
    }

    func testChangedAndRemovedApplyToTheCurrentInventory() throws {
        let client = LinkClient()
        client.handleText(try added(1, serial: "AAAA"))
        client.handleText(try added(2, serial: "BBBB"))
        client.handleText(try removed(1))
        client.handleText(try LinkMessage.deviceChanged(LinkDeviceEvent(device:
            LinkDeviceInfo(handle: 2, serial: "BBBB", name: "Kitchen", state: .online))).encoded())
        XCTAssertEqual(client.devices.count, 1)
        XCTAssertEqual(client.devices.first?.name, "Kitchen")

        drainMain()
        var seen: [LinkDeviceInfo] = []
        let sub = client.devicesPublisher.sink { seen = $0 }
        defer { sub.cancel() }
        XCTAssertEqual(seen.map { $0.handle }, [2])
    }
}
