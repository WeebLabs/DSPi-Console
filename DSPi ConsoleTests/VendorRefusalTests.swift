import XCTest
import Combine
@testable import DSPi_Console

/// 1.1.6 accepted most bad writes silently; 1.1.7 refuses them.  A refused
/// fire-and-forget write must reach the user and correct the UI, and the
/// former write-as-reads must still show the messages they showed in 1.1.6.
final class VendorRefusalTests: XCTestCase {

    /// Answers every SET with a fixed status and counts what reached it.
    private final class FakeTransport: DeviceTransport {
        var answer: LinkStatus = .ok
        private(set) var sets = 0
        var session: LinkSessionID = 1
        var generation: UInt64 = 1
        var isConnected: Bool { false }
        var isConnectedPublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        var availableDevices: [DSPiDevice] = []
        var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { Just([]).eraseToAnyPublisher() }
        var selectedDevice: DSPiDevice? = nil
        var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { Just(nil).eraseToAnyPublisher() }
        var errorMessage: String? = nil
        var errorMessagePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        var deviceProtocol: DeviceProtocolState { .paged(major: 1, minor: 0) }
        var deviceProtocolPublisher: AnyPublisher<DeviceProtocolState, Never> { Just(deviceProtocol).eraseToAnyPublisher() }
        func selectDevice(_ device: DSPiDevice) {}
        func reconnect() {}
        func disconnect() {}
        func markDisconnected() {}
        func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) { sets += 1 }
        func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
            .failure(.noDevice)
        }
        func sendControlResult(request: UInt8, value: UInt16, index: UInt16, data: Data,
                               completion: @escaping (LinkStatus) -> Void) {
            sets += 1
            completion(answer)
        }
        func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
            AnyCancellable {}
        }
    }

    private var seen: [VendorRefusal] = []
    private var token: AnyCancellable?

    override func setUp() {
        super.setUp()
        seen = []
        token = DeviceRefusal.notice.refusals.sink { [weak self] in self?.seen.append($0) }
    }

    override func tearDown() {
        token = nil
        super.tearDown()
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testOnlyTheDevicesOwnRefusalsAreReported() {
        func r(_ s: LinkStatus) -> VendorRefusal { VendorRefusal(command: VC.ROUTE.OUTPUT_ENABLE, value: 0, status: s) }
        XCTAssertTrue(r(.vcState).isReportable)
        XCTAssertTrue(r(.vcValue).isReportable)
        XCTAssertTrue(r(.error).isReportable, "a STALL whose reason is unknown")
        for s in [LinkStatus.ok, .vcBusy, .noDevice, .timeout, .locked, .unsupported, .denied] {
            XCTAssertFalse(r(s).isReportable, "\(s)")
        }
    }

    func testSendReportsARefusedWrite() {
        let fake = FakeTransport()
        fake.answer = .vcState
        fake.send(VC.ROUTE.OUTPUT_ENABLE, value: 3, data: Data([1]))
        pump()
        XCTAssertEqual(seen, [VendorRefusal(command: VC.ROUTE.OUTPUT_ENABLE, value: 3, status: .vcState)])
        XCTAssertEqual(DeviceRefusal.notice.message, "Device refused a change: not allowed in the current state")
    }

    func testSendStaysQuietWhenNothingWasRefused() {
        let fake = FakeTransport()
        for s in [LinkStatus.ok, .vcBusy, .noDevice, .unsupported] {
            fake.answer = s
            fake.send(VC.ROUTE.MASTER_VOLUME, data: Data(count: 4))
        }
        pump()
        XCTAssertEqual(seen, [])
    }

    func testALocalRefusalIsReportedAndNeverSent() {
        let fake = FakeTransport()
        fake.send(VC.FILTER.BAND, value: 0x0203, data: Data(count: 18))   // the old LT packet length
        pump()
        XCTAssertEqual(fake.sets, 0)
        XCTAssertEqual(seen.map(\.status), [.vcLength])
    }

    func testControlInterfaceRefusalsMapToTheSettingsMessages() {
        XCTAssertNil(DSPViewModel.ctrlIfaceRefusal(.ok))
        XCTAssertEqual(DSPViewModel.ctrlIfaceRefusal(.vcValue), PIN_CONFIG_INVALID_PARAM, "baud or address out of range")
        XCTAssertEqual(DSPViewModel.ctrlIfaceRefusal(.vcPinInvalid), PIN_CONFIG_INVALID_PIN)
        XCTAssertEqual(DSPViewModel.ctrlIfaceRefusal(.vcPinInUse), PIN_CONFIG_PIN_IN_USE)
        XCTAssertEqual(DSPViewModel.ctrlIfaceRefusal(.timeout), 0xFF, "no verdict")
    }

    // MARK: Live device

    /// Phase 5's hardware check: a rejected pin assignment answers the 1.1.6
    /// status byte, so Settings shows the same message, and nothing changes.
    func testPinAlreadyInUseIsRefusedWithTheOldStatus() throws {
        let usb = try HardwareTest.requireDevice()
        guard let pin0 = usb.getData(VC.OUTPUT.PIN, value: 0, length: 1)?.first,
              let pin1 = usb.getData(VC.OUTPUT.PIN, value: 1, length: 1)?.first, pin0 != pin1 else {
            throw XCTSkip("Could not read two distinct output pins.")
        }
        let vm = DSPViewModel(transport: usb)
        _ = try HardwareTest.requireDevice()
        let status = vm.setOutputPin(output: 0, pin: pin1)
        defer { if status == PIN_CONFIG_SUCCESS { _ = vm.setOutputPin(output: 0, pin: pin0) } }
        XCTAssertEqual(status, PIN_CONFIG_PIN_IN_USE)
        XCTAssertEqual(usb.getData(VC.OUTPUT.PIN, value: 0, length: 1)?.first, pin0, "the refused SET changed nothing")
    }

    /// A refused control-interface config reports its own reason at once,
    /// not the status left over from the previous apply.
    func testOutOfRangeBaudIsRefusedWithItsOwnStatus() throws {
        let usb = try HardwareTest.requireDevice()
        guard let before = usb.getData(VC.XPORT.UART_CONFIG, length: 8) else {
            throw XCTSkip("XPORT.UART_CONFIG could not be read.")
        }
        let vm = DSPViewModel(transport: usb)
        _ = try HardwareTest.requireDevice()
        var bad = UartCtrlConfig()
        bad.baud = 1
        let status = vm.setUartCtrlConfig(bad)
        if status == PIN_CONFIG_SUCCESS {
            // Should never happen; put the original back (this persists).
            usb.send(VC.XPORT.UART_CONFIG, data: before)
        }
        XCTAssertEqual(status, PIN_CONFIG_INVALID_PARAM)
        XCTAssertEqual(usb.getData(VC.XPORT.UART_CONFIG, length: 8), before, "the refused config was not applied")
    }
}
