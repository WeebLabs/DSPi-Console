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
        let usb = USBDevice(startMonitoring: false)
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
        let usb = USBDevice(startMonitoring: false)
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

    // MARK: - Re-advertisement

    private final class FakeAdvertiser: LinkAdvertising {
        var registeredNames: [String] = []
        var txtAuth: [String] = []
        func start(name: String, port: Int, ad: LinkAdvertisement) { registeredNames.append(name) }
        func updateTXT(_ ad: LinkAdvertisement) { txtAuth.append(ad.auth) }
        func stop() {}
    }

    private func makeAdvertisedService() -> (LinkService, LinkAuthStore, FakeAdvertiser) {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lsvc-\(UUID().uuidString).json"))
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        let advertiser = FakeAdvertiser()
        let service = LinkService(hub: hub, auth: auth, server: server,
                                  defaults: UserDefaults(suiteName: "lsvc-\(UUID().uuidString)")!,
                                  discovery: advertiser)
        service.port = 0
        service.start()
        return (service, auth, advertiser)
    }

    /// hub.rename over Link sets the store from the event loop; the service
    /// must follow it and register under the new instance name.
    func testRemoteHubRenameUpdatesNameAndReadvertises() {
        let (service, auth, advertiser) = makeAdvertisedService()
        defer { service.stop() }
        XCTAssertEqual(advertiser.registeredNames.count, 1)
        DispatchQueue.global().async { auth.hubName = "Studio Mac" }
        let followed = expectation(for: NSPredicate { _, _ in service.hubName == "Studio Mac" },
                                   evaluatedWith: nil)
        wait(for: [followed], timeout: 3)
        XCTAssertEqual(advertiser.registeredNames.last, "Studio Mac")
    }

    func testSettingsRenameReadvertises() {
        let (service, auth, advertiser) = makeAdvertisedService()
        defer { service.stop() }
        service.hubName = "Desk"
        XCTAssertEqual(auth.hubName, "Desk")
        XCTAssertEqual(advertiser.registeredNames.last, "Desk")
    }

    func testAuthModeChangeRefreshesTheTXTRecord() {
        let (service, _, advertiser) = makeAdvertisedService()
        defer { service.stop() }
        service.authMode = .none
        XCTAssertEqual(advertiser.txtAuth.last, "none")
        service.authMode = .pin
        XCTAssertEqual(advertiser.txtAuth.last, "pin")
    }
}
