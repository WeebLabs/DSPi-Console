import XCTest
import Combine
@testable import DSPi_Console

/// Firmware 1.1.7 has one pending band slot and refuses a band write with
/// VC_ERR_BUSY while it is full.  The BandWriter must still leave the device
/// holding the newest value of every band.
final class BandWriterTests: XCTestCase {

    /// Records every SET and answers from a script; can hold the first SET so
    /// writes pile up behind it.
    private final class FakeTransport: DeviceTransport {
        struct Sent: Equatable { let command: VendorCommand; let value: UInt16; let data: Data }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var answers: [LinkStatus] = []           // consumed in order, then .ok
        var commandSet: DeviceCommandSet?
        let gate = DispatchSemaphore(value: 0)
        var holdFirst = false
        private var held = false
        var generation: UInt64 = 1

        var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }

        var session: LinkSessionID = 1
        var isConnected: Bool { true }
        var isConnectedPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
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
        func implements(_ command: VendorCommand, set: Bool) -> Bool? { commandSet?.implements(command, set: set) }
        func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {}
        func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
            lock.lock(); _sent.append(Sent(command: VendorCommand((index & 0xFF00) | UInt16(request)), value: value, data: Data())); lock.unlock()
            return .failure(.error)
        }
        func sendControlResult(request: UInt8, value: UInt16, index: UInt16, data: Data,
                               completion: @escaping (LinkStatus) -> Void) {
            lock.lock()
            _sent.append(Sent(command: VendorCommand((index & 0xFF00) | UInt16(request)), value: value, data: data))
            let wait = holdFirst && !held
            held = true
            let answer = answers.isEmpty ? LinkStatus.ok : answers.removeFirst()
            lock.unlock()
            if wait { gate.wait() }
            completion(answer)
        }
        func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable { AnyCancellable {} }
    }

    private func record(_ gain: Float) -> Data {
        var p = FilterParams(); p.gain = gain
        return DSPViewModel.filterBandRecord(p)
    }

    private func waitIdle(_ writer: BandWriter, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !writer.isIdle, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    func testABurstOnOneBandSendsTheNewestValue() {
        let fake = FakeTransport(); fake.holdFirst = true
        let writer = BandWriter(transport: fake)
        writer.write(address: 0x0001, record: record(1))
        Thread.sleep(forTimeInterval: 0.02)            // the first write is now in flight, held
        for g in 2...10 { writer.write(address: 0x0001, record: record(Float(g))) }
        fake.gate.signal()
        waitIdle(writer)
        XCTAssertEqual(fake.sent.map(\.data), [record(1), record(10)], "intermediate values coalesce away")
    }

    func testBusyIsRetriedWithTheNewestValue() {
        let fake = FakeTransport(); fake.answers = [.vcBusy, .vcBusy]
        let writer = BandWriter(transport: fake)
        writer.write(address: 0x0203, record: record(-3))
        waitIdle(writer)
        XCTAssertEqual(fake.sent.count, 3)
        XCTAssertEqual(fake.sent.last, .init(command: VC.FILTER.BAND, value: 0x0203, data: record(-3)))
    }

    func testEveryBandOfABurstArrives() {
        let fake = FakeTransport()
        // Busy on every other write, as when the main loop is a beat behind.
        fake.answers = (0..<20).map { $0 % 2 == 0 ? .ok : .vcBusy }
        let writer = BandWriter(transport: fake)
        for band in 0..<10 { writer.write(address: UInt16(band), record: record(Float(band))) }
        waitIdle(writer)
        for band in 0..<10 {
            XCTAssertEqual(fake.sent.last { $0.value == UInt16(band) }?.data, record(Float(band)), "band \(band)")
        }
    }

    func testABypassFoldsIntoAPendingRecord() {
        let fake = FakeTransport(); fake.holdFirst = true
        let writer = BandWriter(transport: fake)
        writer.write(address: 0x0100, record: record(0))     // in flight, held
        Thread.sleep(forTimeInterval: 0.02)
        writer.write(address: 0x0101, record: record(5))
        writer.writeBypass(address: 0x0101, bypass: true)
        fake.gate.signal()
        waitIdle(writer)
        let last = fake.sent.last
        XCTAssertEqual(last?.command, VC.FILTER.BAND, "one record, not a record then a bypass")
        XCTAssertEqual(last?.data[1], 1)
        XCTAssertEqual(fake.sent.filter { $0.command == VC.FILTER.BAND_BYPASS }, [])
    }

    func testABandStillBusyAfterTheBudgetIsTriedAgainLater() {
        let fake = FakeTransport()
        fake.answers = Array(repeating: .vcBusy, count: 200)  // well past the 5 ms budget below
        let writer = BandWriter(transport: fake)
        writer.busyBudget = 0.005
        writer.busyBackoff = 0.05
        writer.write(address: 0x0007, record: record(7))
        Thread.sleep(forTimeInterval: 0.02)
        fake.answers = []                                       // the slot frees
        waitIdle(writer)
        XCTAssertEqual(fake.sent.last?.data, record(7))
        XCTAssertTrue(writer.isIdle)
    }

    func testANewDeviceDropsThePendingBands() {
        let fake = FakeTransport(); fake.holdFirst = true
        let writer = BandWriter(transport: fake)
        writer.write(address: 0x0001, record: record(1))
        Thread.sleep(forTimeInterval: 0.02)
        writer.write(address: 0x0002, record: record(2))
        fake.generation = 2                                    // switched boards
        fake.gate.signal()
        waitIdle(writer)
        XCTAssertFalse(fake.sent.contains { $0.value == 0x0002 }, "the old board's band never reaches the new one")
    }

    // MARK: Live device

    /// A burst of band edits, as Clear All or a preset document makes, all
    /// reach the bench board: every band reads back what was written last.
    func testABurstOfBandWritesAllLandOnTheDevice() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = DSPViewModel(transport: usb)
        _ = try HardwareTest.requireDevice()
        let ch = 0
        let originals: [Data] = try (0..<10).map { band in
            try XCTUnwrap(usb.getData(VC.FILTER.BAND, value: DSPViewModel.filterBandAddress(ch: ch, band: band), length: 16))
        }
        defer {
            for (band, rec) in originals.enumerated() {
                vm.bandWriter.write(address: DSPViewModel.filterBandAddress(ch: ch, band: band), record: rec)
            }
            waitIdle(vm.bandWriter, timeout: 5)
        }
        for round in 0..<3 {
            for band in 0..<10 {
                var p = FilterParams()
                p.type = .peaking
                p.freq = Float(100 * (band + 1))
                p.q = 1
                p.gain = Float(round * 10 + band) / 10
                vm.setFilter(ch: ch, band: band, p: p)
            }
        }
        waitIdle(vm.bandWriter, timeout: 5)
        Thread.sleep(forTimeInterval: 0.05)     // the device applies the last write a beat later
        for band in 0..<10 {
            let d = try XCTUnwrap(usb.getData(VC.FILTER.BAND, value: DSPViewModel.filterBandAddress(ch: ch, band: band), length: 16))
            let gain = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Float.self) }
            XCTAssertEqual(gain, Float(20 + band) / 10, accuracy: 0.001, "band \(band)")
        }
    }

    func testTheBenchBoardReportsItsCommands() throws {
        let usb = try HardwareTest.requireDevice()
        XCTAssertEqual(usb.implements(VC.SYS.PROTOCOL_INFO, set: false), true)
        XCTAssertEqual(usb.implements(VC.FILTER.BAND, set: true), true)
        XCTAssertEqual(usb.implements(VC.SYS.PROTOCOL_INFO, set: true), false, "a GET-only command has no SET bit")
    }

    // MARK: Implemented commands

    func testCommandSetBitmaps() {
        var set = DeviceCommandSet()
        var map = Data(count: 64)
        map[0x10 >> 3] |= 1 << (0x10 & 7)            // FILTER.BAND GET (0x10)
        map[32 + (0x10 >> 3)] |= 1 << (0x10 & 7)     // and SET
        set.record(page: VC.FILTER.page, bitmap: map)
        set.recordAbsent(page: VC.DIAG.page)
        XCTAssertEqual(set.implements(VC.FILTER.BAND), true)
        XCTAssertEqual(set.implements(VC.FILTER.BAND, set: true), true)
        XCTAssertEqual(set.implements(VC.FILTER.BAND_BYPASS), false)
        XCTAssertEqual(set.implements(VC.DIAG.CLOCK_DIAG), false, "a page the build lacks")
        XCTAssertNil(set.implements(VC.FX.UPMIX_CONFIG), "a page that could not be read")
    }

    func testAnAbsentCommandIsAnsweredWithoutATransfer() {
        let fake = FakeTransport()
        var set = DeviceCommandSet(); set.recordAbsent(page: VC.FX.page)
        fake.commandSet = set
        XCTAssertEqual(fake.get(VC.FX.UPMIX_CONFIG, length: 44), .failure(.vcUnknown))
        XCTAssertEqual(fake.sent, [])
    }
}
