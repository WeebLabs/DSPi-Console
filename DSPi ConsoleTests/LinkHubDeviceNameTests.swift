//
//  LinkHubDeviceNameTests.swift
//  DSPi ConsoleTests
//
//  The hub's board-name paths with a fake device attached: adoption at
//  attach, device.rename routing, and the 0x10 notify updating the registry.
//  Rules: Documentation/Features/device_name_spec.md section 5 (firmware repo).
//

import XCTest
@testable import DSPi_Console

final class LinkHubDeviceNameTests: XCTestCase {

    private let serial = "NAMEDEV000000001"

    private func makeHub(stored: String? = nil) -> (LinkHub, DeviceNameStore) {
        let defaults = UserDefaults(suiteName: "link-name-\(UUID().uuidString)")!
        let store = DeviceNameStore(defaults: defaults)
        if let stored { store.setName(stored, forSerial: serial) }
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("link-name-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? .empty, auth: auth,
                          registry: DeviceRegistry(nameStore: store))
        return (hub, store)
    }

    private func makeDevice(boardName: String?) -> LinkFakeDevice {
        let device = LinkFakeDevice(serial: serial)
        device.info.boardName = boardName
        return device
    }

    private func nameSets(_ device: LinkFakeDevice) -> [LinkCmdRequest] {
        device.executed.filter { $0.bRequest == REQ_SET_DEVICE_NAME }
    }

    /// Wait until the router has run at least `count` board-name writes.
    private func waitForNameSets(_ device: LinkFakeDevice, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while nameSets(device).count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func nameNotify(_ name: String) -> LinkNotification {
        var p = Data(count: NOTIFY_INPUT_SOURCE_NAME_SIZE)
        p[0] = 0x02; p[1] = NOTIFY_EVT_DEVICE_NAME; p[3] = 1; p[5] = 6
        p.replaceSubrange(8..<(8 + name.utf8.count), with: Data(name.utf8))
        return LinkNotification(packet: p, origin: 0, receivedAt: Date())
    }

    func testUnnamedCapableBoardAdoptsStoredNameOnce() {
        let (hub, store) = makeHub(stored: "Living room")
        let device = makeDevice(boardName: "")
        hub.attachDevice(device)
        waitForNameSets(device, count: 1)
        let sets = nameSets(device)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.payload.prefix(11), Data("Living room".utf8))
        XCTAssertEqual(sets.first?.payload.count, DEVICE_NAME_LEN)
        // The accepted write retires the entry, so a later attach never re-adopts.
        let deadline = Date().addingTimeInterval(2)
        while store.name(forSerial: serial) != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(store.name(forSerial: serial))
    }

    func testNamedBoardIsNotOverwritten() {
        let (hub, store) = makeHub(stored: "Old hub name")
        let device = makeDevice(boardName: "Rack left")
        hub.attachDevice(device)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(nameSets(device).isEmpty)
        XCTAssertEqual(hub.registry.device(serial: serial)?.name, "Rack left")
        XCTAssertNil(store.name(forSerial: serial))
    }

    func testRenameWritesCapableBoardAndNotifyUpdatesRegistry() {
        let (hub, _) = makeHub()
        let device = makeDevice(boardName: "")
        hub.attachDevice(device)
        let session = hub.openSession(role: .control)
        let done = expectation(description: "renamed")
        hub.renameDevice(handle: hub.currentHandle, to: "Studio", from: session.id) { status in
            XCTAssertEqual(status, .ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(nameSets(device).count, 1)
        XCTAssertNotEqual(hub.registry.device(serial: serial)?.name, "Studio",
                          "the registry waits for the board's notify")
        hub.ingest(nameNotify("Studio"))
        XCTAssertEqual(hub.registry.device(serial: serial)?.name, "Studio")
    }

    func testRenameOnOldFirmwareKeepsHubStoredName() {
        let (hub, store) = makeHub()
        let device = makeDevice(boardName: nil)
        hub.attachDevice(device)
        let session = hub.openSession(role: .control)
        let done = expectation(description: "renamed")
        hub.renameDevice(handle: hub.currentHandle, to: "Kitchen", from: session.id) { status in
            XCTAssertEqual(status, .ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(nameSets(device).isEmpty)
        XCTAssertEqual(store.name(forSerial: serial), "Kitchen")
        XCTAssertEqual(hub.registry.device(serial: serial)?.name, "Kitchen")
    }

    func testRenameOfDetachedCapableBoardAnswersNoDevice() {
        let (hub, store) = makeHub()
        hub.attachDevice(makeDevice(boardName: "Rack left"))
        let handle = hub.currentHandle
        hub.detachDevice()
        let session = hub.openSession(role: .control)
        let done = expectation(description: "refused")
        hub.renameDevice(handle: handle, to: "Elsewhere", from: session.id) { status in
            XCTAssertEqual(status, .noDevice)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertNil(store.name(forSerial: serial))
    }

    func testRenameOfUnknownHandleAnswersNoDevice() {
        let (hub, store) = makeHub()
        let session = hub.openSession(role: .control)
        let done = expectation(description: "refused")
        hub.renameDevice(handle: 5, to: "Nobody", from: session.id) { status in
            XCTAssertEqual(status, .noDevice)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertNil(store.name(forSerial: serial))
    }

    func testRenameDropsUnsupportedCharactersAndClosesTheGaps() {
        let (hub, _) = makeHub()
        let device = makeDevice(boardName: "")
        hub.attachDevice(device)
        let session = hub.openSession(role: .control)
        let done = expectation(description: "renamed")
        hub.renameDevice(handle: hub.currentHandle, to: "Caf\u{e9} \u{2013} Rack \u{1F50A}",
                         from: session.id) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        let payload = nameSets(device).first?.payload ?? Data()
        XCTAssertEqual(payload.prefix(while: { $0 != 0 }), Data("Caf Rack".utf8))
    }

    func testBoardNameCleanup() {
        XCTAssertEqual(DeviceRegistry.boardName(from: "  Living   Room  "), "Living Room")
        XCTAssertEqual(DeviceRegistry.boardName(from: "\u{1F50A}\u{1F50A}"), "")
        XCTAssertEqual(DeviceRegistry.boardName(from: String(repeating: "A", count: 40)).count, 31)
        XCTAssertEqual(DeviceRegistry.boardName(from: String(repeating: "A", count: 30) + " B"),
                       String(repeating: "A", count: 30), "a cut that ends on a space is trimmed")
    }
}
