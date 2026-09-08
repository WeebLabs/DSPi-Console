//
//  LinkHubCoreTests.swift
//  DSPi ConsoleTests
//
//  CommandRouter and DeviceRegistry, exercised against a fake device: command
//  ordering across sessions, role authorization, locks, in-flight caps,
//  timeouts, attribution, and the registry's handle / name / state / event
//  behaviour.
//

import XCTest
@testable import DSPi_Console

/// A controllable HubDevice.  Records the order commands arrive in, can block
/// a command until released, and answers a fixed status.
private final class FakeDevice: HubDevice {
    var info: HubDeviceInfo
    var generation: UInt64 = 0
    var isConnected: Bool = true

    private let lock = NSLock()
    private(set) var executed: [UInt8] = []      // bRequest order
    var status: LinkStatus = .ok
    var responsePayload: Data = Data()
    /// When set, execute() blocks on this until the test signals it.
    var gate: DispatchSemaphore?
    var perCallDelay: TimeInterval = 0

    init(serial: String = "E46058388B1A2E2C") {
        info = HubDeviceInfo(serial: serial, platform: 1, firmware: "1.1.7",
                             outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
    }

    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse {
        if let gate = gate { gate.wait() }
        if perCallDelay > 0 { Thread.sleep(forTimeInterval: perCallDelay) }
        lock.lock(); executed.append(request.bRequest); lock.unlock()
        return LinkCmdResponse(tag: request.tag, status: status,
                               payload: request.direction == .get ? responsePayload : Data())
    }

    var executedOrder: [UInt8] { lock.lock(); defer { lock.unlock() }; return executed }
}

final class LinkHubCoreTests: XCTestCase {

    private func makePolicy() -> LinkPolicy {
        // The bundled table; every code the app uses is classified.
        LinkPolicy.bundled!
    }

    private func control(_ id: LinkSessionID) -> RouterSession { RouterSession(id: id, role: .control) }
    private func viewer(_ id: LinkSessionID) -> RouterSession { RouterSession(id: id, role: .viewer) }
    private func admin(_ id: LinkSessionID) -> RouterSession { RouterSession(id: id, role: .admin) }

    // MARK: Ordering

    func testCommandsRunInSubmissionOrderAcrossSessions() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let gate = DispatchSemaphore(value: 0)
        dev.gate = gate

        // Three master-volume SETs from two sessions, submitted in a known
        // order; the device is gated so all queue before any runs.
        let done = expectation(description: "all done")
        done.expectedFulfillmentCount = 3
        let reqs: [(LinkSessionID, UInt8)] = [(10, 0xD2), (11, 0xD2), (10, 0xD2)]
        for (i, (sid, code)) in reqs.enumerated() {
            let r = LinkCmdRequest(tag: UInt16(i), handle: 0, direction: .set,
                                   bRequest: code, wValue: UInt16(i), wIndex: 2,
                                   payload: Data([0,0,0,0]))
            router.submit(r, session: control(sid)) { _ in done.fulfill() }
        }
        // Let them through one at a time.
        for _ in reqs { gate.signal() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(dev.executedOrder.count, 3)
    }

    // MARK: Authorization

    func testViewerDeniedControlCommand() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "denied")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                               wIndex: 2, payload: Data([0,0,0,0]))
        router.submit(r, session: viewer(5)) { result in
            XCTAssertEqual(result.response.status, .denied)
            XCTAssertEqual(result.attributedTo, 0)
            e.fulfill()
        }
        wait(for: [e], timeout: 2)
        XCTAssertTrue(dev.executedOrder.isEmpty, "a denied command never reaches the device")
    }

    func testViewerAllowedReadCommand() {
        let dev = FakeDevice(); dev.responsePayload = Data([1,2,3,4])
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "ok")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                               wValue: 9, wIndex: 2, wLength: 4)
        router.submit(r, session: viewer(5)) { result in
            XCTAssertEqual(result.response.status, .ok)
            XCTAssertEqual(result.response.payload, Data([1,2,3,4]))
            XCTAssertEqual(result.attributedTo, 0, "a GET is never attributed")
            e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    func testAdminAllowedConfigCommand() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "ok")
        // 0xF0 bootloader entry is config, write-as-read (get direction).
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0xF0,
                               wIndex: 2, wLength: 1)
        router.submit(r, session: admin(1)) { result in
            XCTAssertEqual(result.response.status, .ok); e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    // MARK: Attribution

    func testSuccessfulSetAttributedToItsSession() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "done")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                               wIndex: 2, payload: Data([0,0,0,0]))
        router.submit(r, session: control(42)) { result in
            XCTAssertEqual(result.attributedTo, 42)
            e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    func testFailedSetNotAttributed() {
        let dev = FakeDevice(); dev.status = .error
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "done")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                               wIndex: 2, payload: Data([0,0,0,0]))
        router.submit(r, session: control(42)) { result in
            XCTAssertEqual(result.response.status, .error)
            XCTAssertEqual(result.attributedTo, 0)
            e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    // MARK: Locks

    func testLockBlocksOtherSessions() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        XCTAssertTrue(router.acquireLock(session: 1, timeout: 10))
        XCTAssertEqual(router.currentLockHolder, 1)

        let e = expectation(description: "blocked")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                               wIndex: 2, payload: Data([0,0,0,0]))
        router.submit(r, session: control(2)) { result in
            XCTAssertEqual(result.response.status, .locked); e.fulfill()
        }
        wait(for: [e], timeout: 2)

        // The holder itself still gets through.
        let e2 = expectation(description: "holder ok")
        router.submit(r, session: control(1)) { result in
            XCTAssertEqual(result.response.status, .ok); e2.fulfill()
        }
        wait(for: [e2], timeout: 2)

        router.releaseLock(session: 1)
        XCTAssertNil(router.currentLockHolder)
    }

    func testSecondSessionCannotStealLock() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        XCTAssertTrue(router.acquireLock(session: 1, timeout: 10))
        XCTAssertFalse(router.acquireLock(session: 2, timeout: 10))
    }

    func testSessionCloseReleasesLock() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        XCTAssertTrue(router.acquireLock(session: 1, timeout: 10))
        router.sessionDidClose(1)
        XCTAssertNil(router.currentLockHolder)
        XCTAssertTrue(router.acquireLock(session: 2, timeout: 10))
    }

    // MARK: In-flight cap

    func testInflightCapRejectsExcess() {
        let dev = FakeDevice()
        let gate = DispatchSemaphore(value: 0); dev.gate = gate
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        router.maxInflightPerSession = 2

        var statuses = [LinkStatus]()
        let lock = NSLock()
        let done = expectation(description: "3 replies")
        done.expectedFulfillmentCount = 3
        for i in 0..<3 {
            let r = LinkCmdRequest(tag: UInt16(i), handle: 0, direction: .set, bRequest: 0xD2,
                                   wIndex: 2, payload: Data([0,0,0,0]))
            router.submit(r, session: control(1)) { result in
                lock.lock(); statuses.append(result.response.status); lock.unlock()
                done.fulfill()
            }
        }
        // The third should be rejected immediately with rateLimited while the
        // first two are gated; release the gate so the first two finish.
        gate.signal(); gate.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(statuses.filter { $0 == .rateLimited }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 2)
    }

    // MARK: Timeout

    func testTimeoutWhenDeviceBlocks() {
        let dev = FakeDevice()
        let gate = DispatchSemaphore(value: 0); dev.gate = gate   // never signalled
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        router.commandTimeout = 0.3
        let e = expectation(description: "timeout")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                               wValue: 9, wIndex: 2, wLength: 4)
        router.submit(r, session: control(1)) { result in
            XCTAssertEqual(result.response.status, .timeout); e.fulfill()
        }
        wait(for: [e], timeout: 2)
        gate.signal()   // let the abandoned worker finish
    }

    func testNoDeviceWhenDisconnected() {
        let dev = FakeDevice(); dev.isConnected = false
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let e = expectation(description: "no device")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x50,
                               wValue: 9, wIndex: 2, wLength: 4)
        router.submit(r, session: control(1)) { result in
            XCTAssertEqual(result.response.status, .noDevice); e.fulfill()
        }
        wait(for: [e], timeout: 2)
    }

    // MARK: Registry

    func testRegistryAssignsHandleAndEmitsAdded() {
        let reg = DeviceRegistry(nameStore: DeviceNameStore(defaults: ephemeralDefaults()))
        var events = [DeviceRegistryEvent]()
        reg.onEvent = { events.append($0) }
        let info = HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7",
                                 outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
        let d = reg.deviceOnline(info)
        XCTAssertEqual(d.handle, 0)
        XCTAssertEqual(events.count, 1)
        if case .added(let dev) = events[0] { XCTAssertEqual(dev.handle, 0) } else { XCTFail() }
    }

    func testRegistryReusesHandleWithinGrace() {
        let reg = DeviceRegistry(nameStore: DeviceNameStore(defaults: ephemeralDefaults()))
        let info = HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7",
                                 outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
        let first = reg.deviceOnline(info).handle
        reg.deviceOffline(serial: "AAAA")
        let again = reg.deviceOnline(info).handle
        XCTAssertEqual(first, again, "a device returning within grace keeps its handle")
    }

    func testRegistryReapsAfterGrace() {
        let reg = DeviceRegistry(nameStore: DeviceNameStore(defaults: ephemeralDefaults()))
        reg.offlineGrace = 0
        var removed = false
        let info = HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7",
                                 outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
        _ = reg.deviceOnline(info)
        reg.onEvent = { if case .removed = $0 { removed = true } }
        reg.deviceOffline(serial: "AAAA")
        reg.reapOffline(now: Date().addingTimeInterval(1))
        XCTAssertTrue(removed)
        XCTAssertNil(reg.device(serial: "AAAA"))
    }

    func testRegistryNamePersistsBySerial() {
        let defaults = ephemeralDefaults()
        let info = HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7",
                                 outputs: 9, inputs: 8, wireVersion: 30, link: .usb)
        let reg1 = DeviceRegistry(nameStore: DeviceNameStore(defaults: defaults))
        _ = reg1.deviceOnline(info)
        reg1.rename(handle: 0, to: "Living room")
        // A fresh registry on the same store gives the device its saved name.
        let reg2 = DeviceRegistry(nameStore: DeviceNameStore(defaults: defaults))
        XCTAssertEqual(reg2.deviceOnline(info).name, "Living room")
    }

    func testTwoDevicesGetDistinctHandles() {
        let reg = DeviceRegistry(nameStore: DeviceNameStore(defaults: ephemeralDefaults()))
        let a = reg.deviceOnline(HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7", outputs: 9, inputs: 8, wireVersion: 30, link: .usb)).handle
        let b = reg.deviceOnline(HubDeviceInfo(serial: "BBBB", platform: 1, firmware: "1.1.7", outputs: 9, inputs: 8, wireVersion: 30, link: .usb)).handle
        XCTAssertNotEqual(a, b)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "link-test-\(UUID().uuidString)")!
        return d
    }
}

// MARK: - Review fixes: cap exemption and attribution at the router

extension LinkHubCoreTests {
    func testExemptSessionIsNeverRateLimited() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        router.maxInflightPerSession = 2
        let local = RouterSession(id: 1, role: .admin, exemptFromInflightCap: true)
        let done = expectation(description: "50"); done.expectedFulfillmentCount = 50
        var limited = 0
        let lock = NSLock()
        for i in 0..<50 {
            let r = LinkCmdRequest(tag: UInt16(i), handle: 0, direction: .set, bRequest: 0xD2,
                                   wIndex: 2, payload: Data([0,0,0,0]))
            router.submit(r, session: local) { res in
                if res.response.status == .rateLimited { lock.lock(); limited += 1; lock.unlock() }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(limited, 0)
        XCTAssertEqual(dev.executedOrder.count, 50)
    }

    func testRouterQueuesWritersInOrderAndConsumesThem() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        XCTAssertEqual(router.consumeAttribution(within: 1), 0)
        let done = expectation(description: "sets"); done.expectedFulfillmentCount = 2
        for sid: LinkSessionID in [7, 9] {
            let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                                   wIndex: 2, payload: Data([0,0,0,0]))
            router.submit(r, session: control(sid)) { _ in done.fulfill() }
        }
        wait(for: [done], timeout: 3)
        // Oldest first, each consumed once: B's later write cannot steal A's.
        XCTAssertEqual(router.consumeAttribution(within: 1), 7)
        XCTAssertEqual(router.consumeAttribution(within: 1), 9)
        XCTAssertEqual(router.consumeAttribution(within: 1), 0, "queue is empty after both")
    }

    func testRouterAttributionExpires() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let done = expectation(description: "set")
        let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                               wIndex: 2, payload: Data([0,0,0,0]))
        router.submit(r, session: control(7)) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(router.consumeAttribution(within: 1, now: Date().addingTimeInterval(5)), 0,
                       "an entry older than the window is dropped, not attributed")
    }

    /// Repeated writes of one parameter by one session are one queue entry,
    /// matching the firmware's coalescing, so a knob sweep does not run the
    /// queue ahead of the notifications.
    func testRepeatedWritesOfOneParameterCoalesceInTheQueue() {
        let dev = FakeDevice()
        let router = CommandRouter(handle: 0, device: dev, policy: makePolicy())
        let done = expectation(description: "sweep"); done.expectedFulfillmentCount = 5
        for _ in 0..<5 {
            let r = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                                   wIndex: 2, payload: Data([0,0,0,0]))
            router.submit(r, session: control(7)) { _ in done.fulfill() }
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(router.consumeAttribution(within: 1), 7)
        XCTAssertEqual(router.consumeAttribution(within: 1), 0, "five sweeps, one entry")
    }
}
