import XCTest
import Combine
@testable import DSPi_Console

/// Updating a board that still runs 1.1.6 or older: it is never attached, so
/// the update flow works from its probed version alone, and only the old
/// ENTER_BOOTLOADER may reach it.
final class LegacyFirmwareUpdateTests: XCTestCase {

    /// A transport whose board has a fixed protocol state; records how it was
    /// asked to enter the bootloader.
    private final class FakeTransport: DeviceTransport {
        let protocolState: DeviceProtocolState
        let connected: Bool
        private(set) var legacyBootloaderCalls = 0
        private(set) var pagedSets: [VendorCommand] = []
        private let lock = NSLock()

        init(protocolState: DeviceProtocolState, connected: Bool) {
            self.protocolState = protocolState
            self.connected = connected
        }

        var session: LinkSessionID = 1
        var generation: UInt64 = 1
        var isConnected: Bool { connected }
        var isConnectedPublisher: AnyPublisher<Bool, Never> { Just(connected).eraseToAnyPublisher() }
        var availableDevices: [DSPiDevice] = []
        var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { Just([]).eraseToAnyPublisher() }
        var selectedDevice: DSPiDevice? = nil
        var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { Just(nil).eraseToAnyPublisher() }
        var errorMessage: String? = nil
        var errorMessagePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        var deviceProtocol: DeviceProtocolState { protocolState }
        var deviceProtocolPublisher: AnyPublisher<DeviceProtocolState, Never> {
            Just(protocolState).eraseToAnyPublisher()
        }
        func selectDevice(_ device: DSPiDevice) {}
        func reconnect() {}
        func disconnect() {}
        func markDisconnected() {}
        func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {}
        func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
            .failure(.noDevice)
        }
        func sendControlResult(request: UInt8, value: UInt16, index: UInt16, data: Data,
                               completion: @escaping (LinkStatus) -> Void) {
            lock.lock(); pagedSets.append(VendorCommand((index & 0xFF00) | UInt16(request))); lock.unlock()
            completion(.ok)
        }
        func enterLegacyBootloader() -> LinkStatus {
            lock.lock(); legacyBootloaderCalls += 1; lock.unlock()
            return .ok
        }
        func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
            AnyCancellable {}
        }
        var calls: (legacy: Int, paged: [VendorCommand]) {
            lock.lock(); defer { lock.unlock() }
            return (legacyBootloaderCalls, pagedSets)
        }
    }

    private let old = FirmwareVersion(1, 1, 5, 0)

    private func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testLegacyVersionDrivesTheMatchWithoutAConnection() throws {
        let fake = FakeTransport(protocolState: .legacy(old), connected: false)
        let vm = DSPViewModel(transport: fake)
        pump { vm.legacyFirmwareVersion != nil }
        XCTAssertEqual(vm.legacyFirmwareVersion, old)
        XCTAssertFalse(vm.isDeviceConnected, "a legacy board is never attached")
        XCTAssertEqual(vm.deviceFirmwareVersion, old)
        XCTAssertTrue(vm.canEnterBootloader)
        let expected = try XCTUnwrap(FirmwareVersion.expected)
        XCTAssertEqual(vm.firmwareMatch, old < expected ? .deviceOlder : (old == expected ? .match : .deviceNewer))
    }

    func testNoBoardMeansNoMatchAndNoBootloader() {
        let vm = DSPViewModel(transport: FakeTransport(protocolState: .unknown, connected: false))
        pump { false }
        XCTAssertNil(vm.firmwareMatch)
        XCTAssertFalse(vm.canEnterBootloader)
    }

    func testLegacyBoardGetsOnlyTheOldBootloaderRequest() {
        let fake = FakeTransport(protocolState: .legacy(old), connected: false)
        let vm = DSPViewModel(transport: fake)
        pump { vm.legacyFirmwareVersion != nil }
        let done = expectation(description: "sent")
        vm.enterBootloaderForInstall { sent in XCTAssertTrue(sent); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fake.calls.legacy, 1)
        XCTAssertEqual(fake.calls.paged, [], "no paged request reaches a legacy board")
    }

    func testPagedBoardGetsTheNewBootloaderCommand() {
        let fake = FakeTransport(protocolState: .paged(major: 1, minor: 0), connected: true)
        let vm = DSPViewModel(transport: fake)
        pump { vm.isDeviceConnected }
        let done = expectation(description: "sent")
        vm.enterBootloaderForInstall { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        vm.releaseFirmwareInstallLock()
        XCTAssertEqual(fake.calls.legacy, 0)
        XCTAssertTrue(fake.calls.paged.contains(VC.SYS.ENTER_BOOTLOADER))
    }

    func testUSBRefusesTheOldRequestUnlessTheBoardIsLegacy() {
        // An inert USBDevice has no board, so its state is unknown.
        XCTAssertEqual(USBDevice(startMonitoring: false).enterLegacyBootloader(), .unsupported)
    }

    func testRemoteTransportsNeverSendTheOldRequest() {
        let transport = NetworkTransport(client: LinkClientFake(), hubID: "hub-1", hubName: "Studio",
                                         tokens: LinkTokenStore(service: "test-\(UUID().uuidString)"),
                                         clientName: "Tester")
        XCTAssertEqual(transport.enterLegacyBootloader(), .unsupported)
    }
}
