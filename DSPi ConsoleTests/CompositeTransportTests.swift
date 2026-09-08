//
//  CompositeTransportTests.swift
//  DSPi ConsoleTests
//

import XCTest
@testable import DSPi_Console

final class CompositeTransportTests: XCTestCase {

    private func makeLocal() -> (HubTransport, LinkHub, LinkFakeDevice) {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? .empty, auth: auth)
        let device = LinkFakeDevice(serial: "LOCAL0000LOCAL00")
        hub.attachDevice(device)
        return (HubTransport(hub: hub, usb: usb), hub, device)
    }

    private func hub(_ id: String, serials: [String]) -> DiscoveredHub {
        DiscoveredHub(id: id, name: "Studio", kind: "console", authMode: "pin",
                      deviceCount: serials.count, serials: serials, path: "/dspi/v1",
                      tls: false, host: "10.0.0.2", port: 11915, isManual: false)
    }

    func testAdvertisedRemoteDevicesAppearBeforeConnecting() {
        let (local, _, _) = makeLocal()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { LinkClientFake() }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        let remote = composite.availableDevices.filter { $0.isRemote }
        XCTAssertEqual(remote.map { $0.serial }, ["REMOTE0000REMOTE"])
        XCTAssertEqual(remote.first?.hub?.handle, 255, "handle unknown until connected")
        XCTAssertEqual(remote.first?.displayName, "DSPi (00REMOTE) via Studio")
    }

    func testSelectingRemoteConnectsBindsAndSwitches() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        let device = composite.availableDevices.first { $0.isRemote }!

        composite.selectDevice(device)
        XCTAssertEqual(fake.connectCalls.count, 1, "first selection connects to the hub")
        XCTAssertEqual(fake.connectCalls.first?.0.absoluteString, "ws://10.0.0.2:11915/dspi/v1")
        XCTAssertTrue(composite.isRemoteActive)

        fake.setDevices([LinkDeviceInfo(handle: 4, serial: "REMOTE0000REMOTE", name: "Kitchen", state: .online)])
        fake.sessionID = 9
        fake.setState(.ready)
        XCTAssertTrue(composite.isConnected)
        XCTAssertEqual(composite.session, 9)
        XCTAssertEqual(composite.selectedDevice?.hub?.handle, 4)
        XCTAssertEqual(composite.selectedDevice?.displayName, "Kitchen via Studio")

        // Commands go to the remote hub with the resolved handle.
        composite.sendControlRequest(request: 0xD2, value: 0, index: 2, data: Data([0,0,0,0]))
        XCTAssertEqual(fake.commands.last?.handle, 4)
    }

    func testSwitchingBackToLocalRestoresTheLocalSession() {
        let (local, _, device) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertTrue(composite.isRemoteActive)

        let localDevice = DSPiDevice(serial: device.info.serial, locationID: 0)
        composite.selectDevice(localDevice)
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertEqual(composite.session, LinkHub.localSessionID)
        XCTAssertTrue(composite.isConnected, "the local hub still has its device")
    }

    func testNotificationsFollowTheActiveTransport() {
        let (local, hub, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        var seen = [LinkSessionID]()
        let token = composite.addNotificationObserver { seen.append($0.origin) }

        // Local: a knob turn on the local hub reaches the view model.
        let got = expectation(description: "local")
        let t2 = composite.addNotificationObserver { _ in got.fulfill() }
        hub.ingest(LinkNotification(packet: makeParamChangedPacket(source: 5), origin: 0, receivedAt: Date()))
        wait(for: [got], timeout: 3)
        t2.cancel()

        // Remote: after switching, only the remote hub's frames arrive.
        composite.updateHubs([self.hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setDevices([LinkDeviceInfo(handle: 1, serial: "REMOTE0000REMOTE", name: nil, state: .online)])
        fake.onNotify?(LinkNotifyFrame(tag: 1, handle: 1, origin: 42, packet: makeParamChangedPacket(source: 1)))
        XCTAssertEqual(seen.last, 42)
        token.cancel()
    }
}
