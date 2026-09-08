//
//  LinkServiceTests.swift
//  DSPi ConsoleTests
//
//  The network-sharing coordinator driving the real NIO server end to end:
//  turning sharing on starts the server and reports a bound port; turning it
//  off stops it.  Pairing state flows through the auth store.
//

import XCTest
@testable import DSPi_Console

@MainActor
final class LinkServiceTests: XCTestCase {

    private func makeService(port: Int) -> (LinkService, LinkAuthStore) {
        let usb = USBDevice()
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lsvc-\(UUID().uuidString).json"))
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        let defaults = UserDefaults(suiteName: "lsvc-\(UUID().uuidString)")!
        let service = LinkService(hub: hub, auth: auth, server: server, defaults: defaults)
        service.port = port
        return (service, auth)
    }

    func testStartAndStopDrivesTheServer() throws {
        let (service, _) = makeService(port: 0)   // ephemeral
        XCTAssertFalse(service.isRunning)
        service.start()
        XCTAssertTrue(service.isRunning, service.lastError ?? "no error")
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    func testSetSharingPersistsPreference() throws {
        let defaults = UserDefaults(suiteName: "lsvc-pref-\(UUID().uuidString)")!
        let usb = USBDevice()
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lsvc-\(UUID().uuidString).json"))
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        let service = LinkService(hub: hub, auth: auth, server: server, defaults: defaults)
        service.port = 0
        service.setSharing(true)
        XCTAssertTrue(defaults.bool(forKey: "LinkSharingEnabled"))
        service.setSharing(false)
        XCTAssertFalse(defaults.bool(forKey: "LinkSharingEnabled"))
    }

    func testAllowNewClientProducesAPINAndPairs() throws {
        let (service, auth) = makeService(port: 0)
        service.authMode = .pin
        service.allowNewClient()
        let pin = try XCTUnwrap(service.activePIN)
        XCTAssertEqual(pin.count, 6)
        // A client pairs with that PIN through the auth store.
        guard case .success = auth.pair(pin: pin, clientName: "Phone",
                                        requestedRole: .control, from: "10.0.0.9") else {
            return XCTFail("pairing with the shown PIN should succeed")
        }
        service.refreshClients()
        XCTAssertEqual(service.clients.count, 1)
        XCTAssertEqual(service.clients.first?.name, "Phone")
    }

    func testRevokeRemovesClient() throws {
        let (service, auth) = makeService(port: 0)
        let pin = auth.beginPairing()
        _ = auth.pair(pin: pin, clientName: "Laptop", requestedRole: .admin, from: "10.0.0.5")
        service.refreshClients()
        let client = try XCTUnwrap(service.clients.first)
        service.revoke(client)
        XCTAssertTrue(service.clients.isEmpty)
    }
}
