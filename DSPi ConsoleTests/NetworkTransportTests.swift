//
//  NetworkTransportTests.swift
//  DSPi ConsoleTests
//

import XCTest
import Combine
@testable import DSPi_Console

final class NetworkTransportTests: XCTestCase {

    private func make() -> (NetworkTransport, LinkClientFake, LinkTokenStore) {
        let client = LinkClientFake()
        let tokens = LinkTokenStore(service: "test-\(UUID().uuidString)")
        let t = NetworkTransport(client: client, hubID: "hub-1", hubName: "Studio",
                                 tokens: tokens, clientName: "Tester")
        return (t, client, tokens)
    }

    private func info(_ serial: String, handle: Int, state: LinkDeviceState = .online) -> LinkDeviceInfo {
        LinkDeviceInfo(handle: handle, serial: serial, name: "Living room", state: state)
    }

    func testBindResolvesHandleWhenDevicesArrive() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        XCTAssertEqual(t.selectedDevice?.serial, "AAAA", "selected from the moment it is chosen")
        XCTAssertEqual(t.selectedDevice?.hub?.handle, 255, "handle unknown until the list arrives")
        client.setDevices([info("AAAA", handle: 3)])
        XCTAssertEqual(t.selectedDevice?.hub?.handle, 3)
        XCTAssertEqual(t.selectedDevice?.displayName, "Living room via Studio")
    }

    /// While the hub is unreachable the client's inventory is empty (every
    /// connect attempt clears it).  The bound device stays selected, under
    /// the name the hub last gave it, so the picker does not jump to whatever
    /// device happens to be listed first.
    func testBoundDeviceStaysSelectedWhileTheInventoryIsEmpty() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 3)])
        client.setState(.ready)
        XCTAssertTrue(t.isConnected)

        client.setState(.failed("connection lost"))
        client.setDevices([])
        XCTAssertFalse(t.isConnected)
        XCTAssertEqual(t.selectedDevice?.serial, "AAAA")
        XCTAssertEqual(t.selectedDevice?.hub?.handle, 255)
        XCTAssertEqual(t.selectedDevice?.displayName, "Living room via Studio")

        t.bind(serial: "BBBB")
        XCTAssertEqual(t.selectedDevice?.displayName, "DSPi (BBBB) via Studio", "no name borrowed from the last device")
    }

    /// A session that is up is never dropped for an address change: a
    /// dual-stack hub resolves to a different family from one probe to the
    /// next.  The new address is kept and used once the session fails.
    func testHubSeenKeepsAReadySessionAndRemembersTheNewAddress() {
        let (t, client, _) = make()
        let a = URL(string: "ws://10.0.0.2:11915/dspi/v1")!
        let b = URL(string: "ws://[fe80::1%25en0]:11915/dspi/v1")!
        t.connect(to: a)
        client.setState(.ready)
        t.hubSeen(at: b, reappeared: false)
        XCTAssertEqual(client.connectCalls.count, 1, "a healthy socket is left alone")
        XCTAssertEqual(t.url, b)

        client.setState(.failed("connection lost"))
        let redialled = expectation(description: "reconnect")
        redialled.assertForOverFulfill = false
        let probe = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if client.connectCalls.count >= 2 { redialled.fulfill() }
        }
        wait(for: [redialled], timeout: 3)
        probe.invalidate()
        XCTAssertEqual(client.connectCalls.last?.0, b, "the reconnect goes to the address last seen")
    }

    /// With the session down, a new address is dialled at once, and the hub
    /// coming back during a backoff wait is dialled at once; the same address
    /// re-listed with no news is not, so browse traffic cannot collapse the
    /// backoff ladder for a hub that keeps refusing.
    func testHubSeenDialsADownSessionOnNewsOnly() {
        let (t, client, _) = make()
        let a = URL(string: "ws://10.0.0.2:11915/dspi/v1")!
        let b = URL(string: "ws://10.0.0.7:11915/dspi/v1")!
        t.connect(to: a)
        var failed = 0
        t.onConnectionFailed = { failed += 1 }
        client.setState(.failed("connection lost"))
        XCTAssertEqual(failed, 1)
        XCTAssertTrue(t.isSessionDown)

        t.hubSeen(at: a, reappeared: false)
        XCTAssertEqual(client.connectCalls.count, 1, "same hub, same address, still listed: wait out the backoff")

        t.hubSeen(at: a, reappeared: true)
        XCTAssertEqual(client.connectCalls.count, 2, "back after an absence: dial now")

        client.setState(.failed("connection lost"))
        t.hubSeen(at: b, reappeared: false)
        XCTAssertEqual(client.connectCalls.count, 3, "a new address: dial now")
        XCTAssertEqual(client.connectCalls.last?.0, b)

        client.setState(.connecting)
        XCTAssertFalse(t.isSessionDown, "connecting counts as up")
    }

    func testConnectedRequiresReadyAndOnlineDevice() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        XCTAssertFalse(t.isConnected, "not ready yet")
        client.setState(.ready)
        XCTAssertTrue(t.isConnected)
        client.setDevices([info("AAAA", handle: 0, state: .offline)])
        XCTAssertFalse(t.isConnected, "an offline device is not connected")
    }

    func testCommandsCarryTheBoundHandle() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 5)])
        client.setState(.ready)
        let e = expectation(description: "get")
        DispatchQueue.global().async {
            let r = t.getControlRequest(request: 0x50, value: 9, index: 2, length: 4)
            XCTAssertEqual(r, Data([1, 2, 3, 4]))
            e.fulfill()
        }
        wait(for: [e], timeout: 3)
        t.sendControlRequest(request: 0xD2, value: 0, index: 2, data: Data([0, 0, 0, 0]))
        XCTAssertEqual(client.commands.map { $0.handle }, [5, 5])
        XCTAssertEqual(client.commands.last?.direction, .set)
    }

    func testNotificationsFilteredByHandleAndCarryOrigin() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 2)])
        var seen: [LinkNotification] = []
        let token = t.addNotificationObserver { seen.append($0) }
        client.onNotify?(LinkNotifyFrame(tag: 1, handle: 9, origin: 4, packet: makeParamChangedPacket(source: 1)))
        client.onNotify?(LinkNotifyFrame(tag: 2, handle: 2, origin: 4, packet: makeParamChangedPacket(source: 1)))
        XCTAssertEqual(seen.count, 1, "another handle's traffic is ignored")
        XCTAssertEqual(seen.first?.origin, 4)
        token.cancel()
    }

    func testResyncBecomesBulkInvalidated() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        var seen: LinkNotification?
        let token = t.addNotificationObserver { seen = $0 }
        client.onResync?(LinkResyncFrame(handle: 0, reason: 0))
        XCTAssertEqual(seen?.eventID, 0x03)
        token.cancel()
    }

    func testBulkReadUsesSnapshotWhenOffered() {
        let (t, client, _) = make()
        client.capabilities.append("snapshot")
        var blob = Data(count: Int(BULK_PARAMS_SIZE)); blob[0] = UInt8(WIRE_FORMAT_VERSION)
        client.snapshotBody = LinkSnapshotBody(handle: 0, wireVersion: WIRE_FORMAT_VERSION, ageMs: 5,
                                               bulkB64: blob.base64EncodedString(), statusB64: nil)
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        client.setState(.ready)
        let e = expectation(description: "bulk")
        DispatchQueue.global().async {
            let r = t.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE)
            XCTAssertEqual(r?.count, Int(BULK_PARAMS_SIZE))
            e.fulfill()
        }
        wait(for: [e], timeout: 3)
        XCTAssertTrue(client.commands.isEmpty, "the snapshot answered; no tunnelled 0xA0")
    }

    func testPairingPromptRunsAndStoresToken() {
        let (t, client, tokens) = make()
        var prompted: String?
        t.pairingPrompt = { name in prompted = name; return "123456" }
        t.connect(to: URL(string: "ws://10.0.0.2:11915/dspi/v1")!)
        XCTAssertNil(client.connectCalls.first?.1, "no token yet")
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(prompted, "Studio")
        XCTAssertEqual(client.pairCalls, ["123456"])
        XCTAssertEqual(tokens.token(forHub: "hub-1"), "tok-abc")
        XCTAssertEqual(t.session, 7)
        tokens.removeToken(forHub: "hub-1")
    }

    func testGenerationBumpsPerReadyConnection() {
        let (t, client, _) = make()
        let g0 = t.generation
        client.setState(.ready)
        XCTAssertEqual(t.generation, g0 + 1)
        client.setState(.failed("x")); client.setState(.ready)
        XCTAssertEqual(t.generation, g0 + 2)
    }
    func testMarkDisconnectedFromAWorkerPublishesOfflineAndReconnects() {
        let (t, client, _) = make()
        t.connect(to: URL(string: "ws://10.0.0.2:11915/dspi/v1")!)
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        client.setState(.ready)
        XCTAssertTrue(t.isConnected)

        var seen: [Bool] = []
        let sub = t.isConnectedPublisher.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }

        // The command layer declares the link dead from its poll queue, where
        // a Timer would never fire.
        let offline = expectation(description: "offline")
        DispatchQueue.global().async {
            t.markDisconnected()
            DispatchQueue.main.async { offline.fulfill() }
        }
        wait(for: [offline], timeout: 3)
        XCTAssertEqual(seen.first, false, "the view model needs a false before the next true")
        XCTAssertFalse(t.isConnected)
        XCTAssertEqual(client.disconnectCalls, 1)

        // First backoff step is 1 s; the reconnect must land on this run loop.
        let reconnected = expectation(description: "reconnect")
        reconnected.assertForOverFulfill = false
        let probe = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if client.connectCalls.count >= 2 { reconnected.fulfill() }
        }
        wait(for: [reconnected], timeout: 3)
        probe.invalidate()
        XCTAssertEqual(client.connectCalls.count, 2)
    }
    func testMainThreadGetFailsAtOnceWithoutAReadySession() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        client.setState(.connecting)
        let started = Date()
        let r = t.getControlResult(request: 0x50, value: 0, index: 0, length: 4)
        XCTAssertEqual(r, .failure(.noDevice))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertTrue(client.commands.isEmpty, "nothing was sent to a hub we are not ready on")
    }

    func testMainThreadGetIsBoundedWhenTheHubStopsAnswering() {
        let (t, client, _) = make()
        t.bind(serial: "AAAA")
        client.setDevices([info("AAAA", handle: 0)])
        client.setState(.ready)
        client.answersCommands = false

        // A poll timer firing during the wait asks again, as the Stats window's
        // 60 ms timer did; that request must return at once, not nest a wait.
        var nestedElapsed: TimeInterval?
        var nestedResult: Result<Data, LinkStatus>?
        let probe = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            let s = Date()
            nestedResult = t.getControlResult(request: 0x51, value: 0, index: 0, length: 4)
            nestedElapsed = Date().timeIntervalSince(s)
        }

        let started = Date()
        let r = t.getControlResult(request: 0x50, value: 0, index: 0, length: 4)
        let elapsed = Date().timeIntervalSince(started)
        probe.invalidate()

        XCTAssertEqual(r, .failure(.timeout))
        XCTAssertLessThan(elapsed, 1.5, "NetworkTransport.mainThreadWait plus slack")
        XCTAssertEqual(nestedResult, .failure(.timeout))
        XCTAssertLessThan(nestedElapsed ?? 99, 0.1, "a nested main-thread GET does not wait")
        XCTAssertEqual(client.commands.map { $0.bRequest }, [0x50], "the nested GET was not sent")
    }
    func testUnattributedChangesAreNeverTakenForOurOwnEcho() {
        let (t, client, _) = make()
        // A hub that did not tell us our id leaves the session at 0; knob
        // turns and the OS volume slider arrive with origin 0 too.
        client.sessionID = 0
        XCTAssertFalse(t.isOwnWrite(origin: 0))
        XCTAssertFalse(t.isOwnWrite(origin: 4))

        client.sessionID = 7
        XCTAssertTrue(t.isOwnWrite(origin: 7))
        XCTAssertFalse(t.isOwnWrite(origin: 0), "origin 0 is unattributed, not ours")
        XCTAssertFalse(t.isOwnWrite(origin: 4), "another client's write")
    }
    func testAuthDeadlineDuringThePromptDoesNotOpenASecondPrompt() {
        let (t, client, _) = make()
        var prompts = 0
        t.pairingPrompt = { _ in
            prompts += 1
            // While the user reads the alert the hub's 30 s auth deadline
            // closes the socket (4001) and the reconnect asks for a PIN again.
            if prompts == 1 {
                client.setState(.failed("authentication timed out"))
                client.setState(.awaitingAuth(needsPairing: true))
            }
            return "123456"
        }
        t.connect(to: URL(string: "ws://10.0.0.2:11915/dspi/v1")!)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(prompts, 1, "one alert, not one per reconnect")
        XCTAssertEqual(client.pairCalls, ["123456"])
    }

    func testPINTypedAfterTheSocketClosedIsSentOnTheNextConnection() {
        let (t, client, _) = make()
        var prompts = 0
        t.pairingPrompt = { _ in
            prompts += 1
            client.setState(.failed("authentication timed out"))
            return "123456"
        }
        t.connect(to: URL(string: "ws://10.0.0.2:11915/dspi/v1")!)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(client.pairCalls, [], "nothing to pair with yet")

        // The reconnect reaches the hub and asks again: the held PIN answers.
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(client.pairCalls, ["123456"])
    }

    func testCancellingPairingThenSelectingTheDeviceAgainReconnects() {
        let (t, client, _) = make()
        t.pairingPrompt = { _ in nil }
        t.connect(to: URL(string: "ws://10.0.0.2:11915/dspi/v1")!)
        t.bind(serial: "AAAA")
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(client.disconnectCalls, 1)
        XCTAssertEqual(client.connectCalls.count, 1)

        t.selectDevice(DSPiDevice(serial: "AAAA", locationID: 0,
                                  hub: RemoteHubRef(hubID: "hub-1", hubName: "Studio", handle: 255),
                                  remoteName: nil))
        XCTAssertEqual(client.connectCalls.count, 2, "selecting again asks for a new connection")
    }
}
