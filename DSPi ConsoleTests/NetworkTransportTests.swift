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
        XCTAssertNil(t.selectedDevice)
        client.setDevices([info("AAAA", handle: 3)])
        XCTAssertEqual(t.selectedDevice?.hub?.handle, 3)
        XCTAssertEqual(t.selectedDevice?.displayName, "Living room via Studio")
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
}
