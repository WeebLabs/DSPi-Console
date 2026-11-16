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

    /// With no local board, a device on an open hub is picked and connected
    /// on its own, as USBDevice does for a local one.  The picker used to show
    /// it while nothing ever selected it, so the link never opened.
    func testLoneRemoteDeviceOnOpenHubIsSelectedAutomatically() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        var open = hub("bridge-1", serials: ["REMOTE0000REMOTE"])
        open.authMode = "none"
        composite.updateHubs([open])
        XCTAssertTrue(composite.isRemoteActive)
        XCTAssertEqual(fake.connectCalls.count, 1, "connects once, not again on the re-entrant recompute")

        composite.updateHubs([open])
        XCTAssertEqual(fake.connectCalls.count, 1, "a later browse update does not reconnect")
    }

    /// A PIN hub is left for the user to choose: selecting it would raise a
    /// pairing prompt nobody asked for.  A stored token means no prompt.
    func testPinHubIsAutoSelectedOnlyWithAStoredToken() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let tokens = LinkTokenStore(service: "t-\(UUID())")
        let composite = CompositeTransport(local: local, tokens: tokens, clientName: "T") { fake }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertTrue(fake.connectCalls.isEmpty)

        tokens.setToken("tok", forHub: "hub-2")
        composite.updateHubs([hub("hub-2", serials: ["REMOTE0000REMOTE"])])
        XCTAssertTrue(composite.isRemoteActive)
        XCTAssertEqual(fake.connectCalls.count, 1)
        tokens.removeToken(forHub: "hub-2")
    }

    /// A local board with nothing attached to the hub: only USBDevice's
    /// published list and selection, which is all the composite watches.
    private func makeBareLocal() -> (HubTransport, USBDevice) {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? .empty, auth: auth)
        return (HubTransport(hub: hub, usb: usb), usb)
    }

    private func openBridge() -> DiscoveredHub {
        var bridge = hub("bridge-1", serials: ["REMOTE0000REMOTE"])
        bridge.authMode = "none"
        return bridge
    }

    /// USBDevice.onTerminated empties its list before it clears the
    /// selection.  The auto-select used to look only at the list change, find
    /// the board still selected, and never run again, leaving the bridge's
    /// device in the picker with a red dot until something republished hubs.
    func testUnpluggingTheLocalBoardSelectsAnOpenRemote() {
        let (local, usb) = makeBareLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        let board = DSPiDevice(serial: "LOCAL0000LOCAL00", locationID: 1)
        usb.availableDevices = [board]
        usb.selectedDevice = board
        composite.updateHubs([openBridge()])
        XCTAssertFalse(composite.isRemoteActive, "the local board is in use")

        // onTerminated's order.
        usb.availableDevices.removeAll()
        usb.isConnected = false
        usb.selectedDevice = nil

        XCTAssertTrue(composite.isRemoteActive)
        XCTAssertEqual(fake.connectCalls.count, 1)
    }

    /// A remote the composite picked on its own gives way to a board USBDevice
    /// opens, as after a USB firmware flash: the installer verifies whichever
    /// device the view model is on.
    func testAutoSelectedRemoteHandsBackToALocalBoard() {
        let (local, usb) = makeBareLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([openBridge()])
        XCTAssertTrue(composite.isRemoteActive)

        // Listed but not yet opened: stay on the remote.
        let board = DSPiDevice(serial: "LOCAL0000LOCAL00", locationID: 1)
        usb.availableDevices = [board]
        XCTAssertTrue(composite.isRemoteActive)

        usb.selectedDevice = board
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertEqual(composite.session, LinkHub.localSessionID)
        XCTAssertEqual(composite.selectedDevice, board)
    }

    /// A remote the user chose stays chosen when a local board turns up.
    func testUserChosenRemoteIsKeptWhenALocalBoardAppears() {
        let (local, usb) = makeBareLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([openBridge()])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertTrue(composite.isRemoteActive)

        let board = DSPiDevice(serial: "LOCAL0000LOCAL00", locationID: 1)
        usb.availableDevices = [board]
        usb.selectedDevice = board
        XCTAssertTrue(composite.isRemoteActive)
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

    /// A hub that comes back on a new DHCP lease re-announces the same id.
    /// The transport made for it used to keep dialling the old address until
    /// the app was relaunched.
    func testHubBackAtANewAddressIsDialledThere() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertEqual(fake.connectCalls.last?.0.host, "10.0.0.2")

        var moved = hub("hub-1", serials: ["REMOTE0000REMOTE"])
        moved.host = "10.0.0.7"
        composite.updateHubs([moved])
        XCTAssertEqual(fake.connectCalls.count, 2)
        XCTAssertEqual(fake.connectCalls.last?.0.host, "10.0.0.7")
    }

    /// A failed connection asks the browser to look the hub up again.  A hub
    /// that then drops off the browse list and comes back within the grace
    /// period keeps its transport and is dialled without waiting out the
    /// backoff; a hub merely re-listed is not.
    func testFailureAsksForAFreshAddressAndAReappearingHubReconnectsAtOnce() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        var asked: [String] = []
        composite.hubUnreachable = { asked.append($0) }
        let studio = hub("hub-1", serials: ["REMOTE0000REMOTE"])
        composite.updateHubs([studio])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)

        fake.setState(.failed("connection lost"))
        XCTAssertEqual(asked, ["hub-1"])
        XCTAssertTrue(composite.isRemoteActive, "the hub is still advertised: keep trying")

        composite.updateHubs([studio])
        XCTAssertEqual(fake.connectCalls.count, 1, "re-listed with no news: the backoff stands")

        composite.updateHubs([])
        XCTAssertTrue(composite.isRemoteActive, "a short absence is within the grace period")
        composite.updateHubs([studio])
        XCTAssertEqual(fake.connectCalls.count, 2, "back: dial now")
        XCTAssertEqual(fake.disconnectCalls, 0)
    }

    /// The hub the view model is on leaves the network (its Console quit, its
    /// bridge was unplugged) and its socket is down: the view model goes back
    /// to the local transport instead of sitting on a dead remote with a red
    /// dot, and the dead transport stops retrying.
    func testActiveHubLeavingTheNetworkFallsBackToLocal() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.pruneGrace = 0
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertTrue(composite.isRemoteActive)

        fake.setState(.failed("connection lost"))
        composite.updateHubs([])
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertEqual(composite.session, LinkHub.localSessionID)
        XCTAssertTrue(composite.isConnected, "the local hub has its device")
        XCTAssertEqual(fake.disconnectCalls, 1, "the dead transport is given up")
        XCTAssertFalse(composite.availableDevices.contains { $0.isRemote })

        // Back later: listed again, but a PIN hub is not re-selected unasked.
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        XCTAssertTrue(composite.availableDevices.contains { $0.isRemote })
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertEqual(fake.connectCalls.count, 1)
    }

    /// The goodbye and the socket failure race: when Bonjour drops the hub
    /// first, the still-open session keeps the transport; the failure that
    /// follows completes the hand-back.
    func testActiveHubFailingAfterItsGoodbyeFallsBackToLocal() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.pruneGrace = 0
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setDevices([LinkDeviceInfo(handle: 4, serial: "REMOTE0000REMOTE", name: "Kitchen", state: .online)])
        fake.setState(.ready)

        composite.updateHubs([])
        XCTAssertTrue(composite.isRemoteActive, "the session is up; Bonjour is not believed over it")
        fake.setState(.failed("connection lost"))
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertEqual(fake.disconnectCalls, 1)
    }

    /// A transport that is connecting or waiting for a PIN is not a dead one:
    /// a browse update that momentarily omits its hub leaves it alone however
    /// long the grace period, and once the hub has been gone for the grace
    /// period a session that is down is dropped by the booked check even if
    /// nothing else happens.
    func testPruneSparesSessionsThatAreUpAndDropsDeadOnesAfterTheGrace() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.pruneGrace = 0.1
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setState(.awaitingAuth(needsPairing: true))

        composite.updateHubs([])
        let later = expectation(description: "past the grace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { later.fulfill() }
        wait(for: [later], timeout: 1)
        composite.updateHubs([])
        XCTAssertTrue(composite.isRemoteActive, "waiting for a PIN is a session in progress")
        XCTAssertEqual(fake.disconnectCalls, 0)

        fake.setState(.failed("authentication timed out"))
        XCTAssertTrue(composite.isRemoteActive, "the grace period starts now")
        let dropped = expectation(for: NSPredicate { _, _ in !composite.isRemoteActive }, evaluatedWith: nil)
        wait(for: [dropped], timeout: 2)
        XCTAssertEqual(fake.disconnectCalls, 1)
    }

    /// A missed Bonjour announcement must not empty the picker of the device
    /// being driven over a healthy session.
    func testConnectedRemoteStaysListedThroughABonjourFlap() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        let studio = hub("hub-1", serials: ["REMOTE0000REMOTE"])
        composite.updateHubs([studio])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setDevices([LinkDeviceInfo(handle: 4, serial: "REMOTE0000REMOTE", name: "Kitchen", state: .online)])
        fake.setState(.ready)
        XCTAssertTrue(composite.isConnected)

        composite.updateHubs([])
        XCTAssertEqual(composite.availableDevices.filter { $0.isRemote }.map { $0.displayName },
                       ["Kitchen via Studio"])
        XCTAssertTrue(composite.isConnected)
        XCTAssertEqual(composite.selectedDevice?.hub?.handle, 4)

        // Re-selecting it while the hub is unlisted uses the live transport.
        composite.selectDevice(DSPiDevice(serial: "LOCAL0000LOCAL00", locationID: 0))
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertTrue(composite.isRemoteActive)
        XCTAssertEqual(fake.connectCalls.count, 1, "no second connection")

        composite.updateHubs([studio])
        XCTAssertEqual(composite.availableDevices.filter { $0.isRemote }.count, 1, "listed once, not twice")
    }

    /// While the hub is unreachable but still advertised, the device stays
    /// selected under its last name and stays in the list.
    func testBoundDeviceStaysSelectedAndListedWhileTheHubIsUnreachable() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setDevices([LinkDeviceInfo(handle: 4, serial: "REMOTE0000REMOTE", name: "Kitchen", state: .online)])
        fake.setState(.ready)

        // What LinkClient does on every reconnect attempt.
        fake.setState(.failed("connection lost"))
        fake.setDevices([])
        XCTAssertFalse(composite.isConnected)
        XCTAssertEqual(composite.selectedDevice?.displayName, "Kitchen via Studio")
        XCTAssertEqual(composite.selectedDevice?.hub?.handle, 255)
        XCTAssertTrue(composite.availableDevices.contains(composite.selectedDevice!))
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

    // MARK: - Cancelled pairing

    private func pinHub(_ id: String, name: String, serials: [String]) -> DiscoveredHub {
        DiscoveredHub(id: id, name: name, kind: "console", authMode: "pin",
                      deviceCount: serials.count, serials: serials, path: "/dspi/v1",
                      tls: false, host: "10.0.0.2", port: 11915, isManual: false)
    }

    /// Picking a private device and cancelling its PIN used to leave the
    /// window on a device nothing could reach.  It goes back to local.
    func testCancellingPairingReturnsToTheLocalDevice() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        composite.pairingPrompt = { _, reply in reply(nil) }
        composite.updateHubs([pinHub("p", name: "Private", serials: ["REMOTE0000REMOTE"])])
        XCTAssertTrue(composite.isConnected, "on the local board")

        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        XCTAssertTrue(composite.isRemoteActive)
        XCTAssertFalse(composite.isConnected)

        fake.setState(.awaitingAuth(needsPairing: true))     // prompts; the user cancels
        XCTAssertFalse(composite.isRemoteActive, "back on the local transport")
        XCTAssertTrue(composite.isConnected, "and its board is live again")
    }

    /// Coming from a device on another hub, a cancel goes back to that one.
    func testCancellingPairingReturnsToThePreviousRemoteDevice() {
        let (local, _, _) = makeLocal()
        let open = LinkClientFake(), locked = LinkClientFake()
        var clients = [open, locked]
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { clients.removeFirst() }
        composite.pairingPrompt = { _, reply in reply(nil) }
        composite.updateHubs([pinHub("a", name: "Kitchen", serials: ["AAAA0000AAAA0000"]),
                              pinHub("b", name: "Private", serials: ["BBBB0000BBBB0000"])])

        composite.selectDevice(composite.availableDevices.first { $0.serial == "AAAA0000AAAA0000" }!)
        open.setDevices([LinkDeviceInfo(handle: 1, serial: "AAAA0000AAAA0000", name: "Kitchen DSPi", state: .online)])
        open.setState(.ready)
        XCTAssertTrue(composite.isConnected)

        composite.selectDevice(composite.availableDevices.first { $0.serial == "BBBB0000BBBB0000" }!)
        locked.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(composite.selectedDevice?.serial, "AAAA0000AAAA0000")
        XCTAssertEqual(composite.selectedDevice?.hub?.hubID, "a")
        XCTAssertTrue(composite.isConnected)
    }

    /// A hub that asks again long after it connected (its token revoked) has
    /// no earlier device to return to; a cancel then drops to local.
    func testCancellingARepairOfAConnectedHubDropsToLocal() {
        let (local, _, _) = makeLocal()
        let fake = LinkClientFake()
        let tokens = LinkTokenStore(service: "t-\(UUID())")
        let composite = CompositeTransport(local: local, tokens: tokens, clientName: "T") { fake }
        var answers: [String?] = ["123456", nil]
        var prompts = 0
        composite.pairingPrompt = { _, reply in prompts += 1; reply(answers.removeFirst()) }
        composite.updateHubs([pinHub("p", name: "Private", serials: ["REMOTE0000REMOTE"])])

        composite.selectDevice(composite.availableDevices.first { $0.isRemote }!)
        fake.setDevices([LinkDeviceInfo(handle: 2, serial: "REMOTE0000REMOTE", name: nil, state: .online)])
        fake.setState(.awaitingAuth(needsPairing: true))     // pairs; the fake goes ready
        XCTAssertTrue(composite.isConnected)
        XCTAssertTrue(composite.isRemoteActive)

        fake.setState(.awaitingAuth(needsPairing: true))     // asks again later; cancelled
        XCTAssertEqual(prompts, 2)
        XCTAssertFalse(composite.isRemoteActive)
        XCTAssertNil(tokens.token(forHub: "p"), "the refused token is dropped")
        composite.updateHubs([pinHub("p", name: "Private", serials: ["REMOTE0000REMOTE"])])
        XCTAssertEqual(prompts, 2, "not auto-selected and asked again")
        XCTAssertFalse(composite.isRemoteActive)
    }

    // MARK: - Routes

    private func routeHub(_ id: String, name: String, kind: String, serials: [String]) -> DiscoveredHub {
        DiscoveredHub(id: id, name: name, kind: kind, authMode: "pin",
                      deviceCount: serials.count, serials: serials, path: "/dspi/v1",
                      tls: false, host: "10.0.0.2", port: 11915, isManual: false)
    }

    private func routeRemote(_ serial: String, hubID: String, hubName: String, handle: UInt8) -> DSPiDevice {
        DSPiDevice(serial: serial, locationID: 0,
                   hub: RemoteHubRef(hubID: hubID, hubName: hubName, handle: handle), remoteName: nil)
    }

    func testBoardPluggedInHereAndBehindABridgeListsBothRoutes() {
        let serial = "LOCAL0000LOCAL00"
        let merged = CompositeTransport.mergeRoutes(
            local: [DSPiDevice(serial: serial, locationID: 1)],
            hubs: [routeHub("esp", name: "MyESP32", kind: "bridge", serials: [serial])],
            connected: [:], pinned: nil)
        XCTAssertEqual(merged.count, 1, "still one board")
        XCTAssertNil(merged[0].hub, "local USB is the default route")
        XCTAssertEqual(merged[0].routes.map(\.routeLabel), ["via USB (Direct)", "via MyESP32 (Bridge)"])
    }

    func testCompositePublishesRoutesFromItsHubs() {
        // The test USBDevice does not monitor, so the routes here are two hubs.
        let (local, _, _) = makeLocal()
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { LinkClientFake() }
        let serial = "REMOTE0000REMOTE"
        composite.updateHubs([routeHub("k", name: "Kitchen", kind: "console", serials: [serial]),
                              routeHub("esp", name: "MyESP32", kind: "bridge", serials: [serial])])
        XCTAssertEqual(composite.availableDevices.count, 1)
        XCTAssertEqual(composite.availableDevices[0].routes.map(\.routeLabel),
                       ["via Kitchen (Hub)", "via MyESP32 (Bridge)"])
    }

    func testSingleRouteDevicesCarryNoRoutes() {
        let merged = CompositeTransport.mergeRoutes(
            local: [DSPiDevice(serial: "LOCAL0000LOCAL00", locationID: 1)],
            hubs: [routeHub("h1", name: "Kitchen", kind: "console", serials: ["REMOTE0000REMOTE"])],
            connected: [:], pinned: nil)
        XCTAssertEqual(merged.map(\.serial), ["LOCAL0000LOCAL00", "REMOTE0000REMOTE"])
        XCTAssertTrue(merged.allSatisfy { $0.routes.isEmpty })
        XCTAssertEqual(merged[1].displayName, "DSPi (00REMOTE) via Kitchen", "single-route label unchanged")
    }

    func testConnectedHubIsPreferredOverAnAdvertisedOne() {
        // "Attic" sorts first but is only known from TXT; "Kitchen" is connected.
        let serial = "REMOTE0000REMOTE"
        let merged = CompositeTransport.mergeRoutes(
            local: [],
            hubs: [routeHub("a", name: "Attic", kind: "console", serials: [serial]),
                   routeHub("k", name: "Kitchen", kind: "console", serials: [serial])],
            connected: ["k": [routeRemote(serial, hubID: "k", hubName: "Kitchen", handle: 3)]],
            pinned: nil)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].hub?.hubID, "k")
        XCTAssertEqual(merged[0].hub?.handle, 3)
        XCTAssertEqual(merged[0].routes.map(\.routeLabel), ["via Kitchen (Hub)", "via Attic (Hub)"])
    }

    func testConnectedRouteTakesItsKindFromTheHub() {
        let serial = "REMOTE0000REMOTE"
        let merged = CompositeTransport.mergeRoutes(
            local: [DSPiDevice(serial: serial, locationID: 1)],
            hubs: [routeHub("esp", name: "MyESP32", kind: "bridge", serials: [serial]),
                   routeHub("odd", name: "Typed", kind: "unknown", serials: [serial])],
            connected: ["esp": [routeRemote(serial, hubID: "esp", hubName: "MyESP32", handle: 0)]],
            pinned: nil)
        XCTAssertEqual(merged[0].routes.map(\.routeLabel),
                       ["via USB (Direct)", "via MyESP32 (Bridge)", "via Typed (Hub)"])
    }

    func testSessionOffTheBrowseListAndPinnedRouteStayListed() {
        // "gone" has a session up but Bonjour lost it; "lost" is the route in
        // use with no session at all.  Both stay as routes, after the board's
        // local USB route.
        let serial = "LOCAL0000LOCAL00"
        let merged = CompositeTransport.mergeRoutes(
            local: [DSPiDevice(serial: serial, locationID: 1)],
            hubs: [],
            connected: ["gone": [routeRemote(serial, hubID: "gone", hubName: "Gone", handle: 1)]],
            pinned: routeRemote(serial, hubID: "lost", hubName: "Lost", handle: 2))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].routes.map(\.routeID), ["local", "gone", "lost"])
    }
}
