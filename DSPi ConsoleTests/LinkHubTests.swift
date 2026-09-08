//
//  LinkHubTests.swift
//  DSPi ConsoleTests
//
//  The hub glue with no device attached: session identity, the safe answers
//  the hub gives before a device connects, and lock arbitration across two
//  sessions.  The full command/notification round trip needs hardware and is
//  covered by LinkHubHardwareTests.
//

import XCTest
@testable import DSPi_Console

final class LinkHubTests: XCTestCase {

    private func makeHub() -> LinkHub {
        let usb = USBDevice()
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("link-hub-test-\(UUID().uuidString).json"))
        return LinkHub(usb: usb, policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
    }

    func testLocalSessionIsSessionOne() {
        let hub = makeHub()
        let local = hub.openSession(role: .admin, id: 1)
        XCTAssertEqual(local.id, 1)
    }

    func testRemoteSessionsGetDistinctIDs() {
        let hub = makeHub()
        let a = hub.openSession(role: .control)
        let b = hub.openSession(role: .control)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertGreaterThanOrEqual(a.id, 2, "remote ids start above the local session")
    }

    func testSubmitBeforeConnectIsNoDevice() {
        let hub = makeHub()
        let s = hub.openSession(role: .admin)
        let e = expectation(description: "noDevice")
        let req = LinkCmdRequest(tag: 1, handle: LinkHub.localHandle, direction: .get,
                                 bRequest: 0x50, wValue: 9, wIndex: 2, wLength: 4)
        hub.submit(req, from: s.id) { response in
            XCTAssertEqual(response.status, .noDevice)
            e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    func testSubmitFromUnknownSessionIsNoDevice() {
        let hub = makeHub()
        let e = expectation(description: "noDevice")
        let req = LinkCmdRequest(tag: 1, handle: LinkHub.localHandle, direction: .get,
                                 bRequest: 0x50, wValue: 9, wIndex: 2, wLength: 4)
        hub.submit(req, from: 999) { response in
            XCTAssertEqual(response.status, .noDevice); e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    func testSnapshotAbsentBeforeConnect() {
        let hub = makeHub()
        XCTAssertNil(hub.currentSnapshot())
    }

    func testLockFailsWithNoDevice() {
        let hub = makeHub()
        let s = hub.openSession(role: .admin)
        XCTAssertFalse(hub.acquireLock(session: s.id, timeout: 5),
                       "there is no router to lock until a device attaches")
    }

    func testPollSubscribeGrantsZeroWithNoDevice() {
        let hub = makeHub()
        let s = hub.openSession(role: .control)
        let spec = PollScheduler.PollSpec(handle: 0, req: 0x50, wValue: 9, wIndex: 2, len: 27)
        let granted = hub.subscribePolls(session: s.id, requests: [(slot: 0, spec: spec, hz: 10)])
        XCTAssertEqual(granted.first?.grantedHz, 0)
    }

    func testCloseSessionIsSafe() {
        let hub = makeHub()
        let s = hub.openSession(role: .control)
        hub.closeSession(s.id)
        // A second close and a submit afterwards must not crash.
        hub.closeSession(s.id)
        let e = expectation(description: "noDevice")
        let req = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                                 wValue: 9, wIndex: 2, wLength: 4)
        hub.submit(req, from: s.id) { r in XCTAssertEqual(r.status, .noDevice); e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    func testDeviceEventReachesSession() {
        let hub = makeHub()
        let s = hub.openSession(role: .control)
        var events = [DeviceRegistryEvent]()
        s.onDeviceEvent = { events.append($0) }
        // Drive the registry directly; the hub relays its events to sessions.
        let info = HubDeviceInfo(serial: "TESTSERIAL01", platform: 1, firmware: "1.1.7",
                                 outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
        hub.registry.deviceOnline(info)
        XCTAssertTrue(events.contains { if case .added = $0 { return true }; return false })
    }
}
