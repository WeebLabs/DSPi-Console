//
//  StatsViewModelThreadingTests.swift
//  DSPi ConsoleTests
//
//  The Stats window polls a device on main-thread timers; through a DSPi Link
//  hub each GET blocks on the network, so the reads must leave the main thread.
//

import XCTest
import Combine
@testable import DSPi_Console

final class StatsViewModelThreadingTests: XCTestCase {

    func testStatsReadsNeverBlockTheMainThread() {
        let client = LinkClientFake()
        let tokens = LinkTokenStore(service: "test-\(UUID().uuidString)")
        let transport = NetworkTransport(client: client, hubID: "hub-1", hubName: "Studio",
                                         tokens: tokens, clientName: "Tester")
        let lock = NSLock()
        var onMain: [UInt8] = []
        var count = 0
        client.responder = { req in
            lock.lock()
            count += 1
            if Thread.isMainThread { onMain.append(req.bRequest) }
            lock.unlock()
            return LinkCmdResponse(tag: req.tag, status: .ok, payload: Data(count: Int(req.wLength)))
        }
        transport.bind(serial: "AAAA")
        client.setDevices([LinkDeviceInfo(handle: 1, serial: "AAAA", name: nil, state: .online)])

        let stats = StatsViewModel(transport: transport)
        client.setState(.ready)

        // Let the connect fetch, the initial stats fetch and a few buffer polls run.
        let settled = expectation(description: "polls")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        lock.lock(); let seen = count; let main = onMain; lock.unlock()
        XCTAssertGreaterThan(seen, 0, "the Stats model polled the device")
        XCTAssertEqual(main, [], "every GET was issued off the main thread")
        _ = stats
    }
}
