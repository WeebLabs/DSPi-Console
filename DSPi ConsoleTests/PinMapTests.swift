import XCTest
import Combine
@testable import DSPi_Console

/// A device that answers the pin map commands from a scripted state.
private final class PinFakeTransport: DeviceTransport {
    var session: LinkSessionID = 1
    var generation: UInt64 = 1
    var isConnected: Bool = true
    var isConnectedPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] = []
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { Just([]).eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? = nil
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { Just(nil).eraseToAnyPublisher() }
    var errorMessage: String? = nil
    var errorMessagePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var deviceProtocol: DeviceProtocolState { .unknown }
    var deviceProtocolPublisher: AnyPublisher<DeviceProtocolState, Never> { Just(.unknown).eraseToAnyPublisher() }
    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {}
    func sendControlResult(request: UInt8, value: UInt16, index: UInt16, data: Data,
                           completion: @escaping (LinkStatus) -> Void) { completion(.ok) }
    func selectDevice(_ device: DSPiDevice) {}
    func reconnect() {}
    func disconnect() {}
    func markDisconnected() {}
    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable { AnyCancellable {} }

    private let lock = NSLock()
    private var _pinGen: UInt32 = 5
    var pinGen: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return _pinGen }
        set { lock.lock(); _pinGen = newValue; lock.unlock() }
    }
    /// Answer every pin command with this status instead.
    var refuseAll: LinkStatus?
    var claimsBusy = false
    /// Bump the generation after this many availability reads (once).
    var bumpAfterAvailReads: Int?
    private(set) var reads: [VendorCommand] = []

    private func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        let cmd = VendorCommand((index & 0xFF00) | UInt16(request))
        lock.lock(); reads.append(cmd); lock.unlock()
        if let r = refuseAll { return .failure(r) }
        let g = pinGen
        switch cmd {
        case VC.SYS.PIN_STATE:
            return .success(Data(le(UInt64(g), 4) + [30, 1, 0, 0] + le(0x3C7F_FFFF, 8) + le(0, 8)))
        case VC.SYS.PIN_CLAIMS:
            if claimsBusy { return .failure(.vcBusy) }
            return .success(Data(le(UInt64(g), 4) + [1, 0, 0, 0] + [6, 1, 0, 0]))
        case VC.CS.BINDING_PIN_AVAIL:
            return .success(Data([0, 0, 1, 1] + le(UInt64(g), 4) + le(0xFF, 8) + le(0x0F, 8)
                                 + [UInt8](repeating: 0, count: 56)))
        default:
            guard VendorCommandRegistry.info(for: cmd)?.name.hasSuffix("PIN_AVAIL") == true else { return .failure(.vcUnknown) }
            let availReads = reads.filter { VendorCommandRegistry.info(for: $0)?.name.hasSuffix("PIN_AVAIL") == true }.count
            if let n = bumpAfterAvailReads, availReads == n { bumpAfterAvailReads = nil; pinGen = g + 1 }
            let roles: UInt8 = (cmd == VC.XPORT.UART_PIN_AVAIL || cmd == VC.XPORT.I2C_PIN_AVAIL) ? 2 : 1
            let groups = roles
            var bytes: [UInt8] = [0, 0, groups, roles] + le(UInt64(g), 4)
            for _ in 0..<(Int(groups) * Int(roles)) { bytes += le(0xFF, 8) + le(0xF0, 8) }
            return .success(Data(bytes))
        }
    }

    func availReadCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return reads.filter { VendorCommandRegistry.info(for: $0)?.name.hasSuffix("PIN_AVAIL") == true }.count
    }
}

final class PinMapTests: XCTestCase {
    private let shape = PinMapShape(pinOutputs: 5, spdifInputs: 4, i2sPairs: 4, csTypes: [1, 3])

    /// Wait on the main run loop until `cond` holds.
    private func settle(_ cond: () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testUnwatchedRefreshReadsStateAndClaimsOnly() {
        let t = PinFakeTransport()
        let map = PinMap(transport: t)
        map.updateShape(shape)
        map.requestRefresh(force: true)
        settle { map.snapshot.state != nil }
        XCTAssertEqual(map.snapshot.support, .supported)
        XCTAssertEqual(map.snapshot.pinGeneration, 5)
        XCTAssertEqual(map.snapshot.claims.count, 1)
        XCTAssertEqual(t.availReadCount(), 0, "no sweep while nothing watches")
        XCTAssertTrue(map.snapshot.avail.isEmpty)
    }

    func testWatchSweepsEveryKey() {
        let t = PinFakeTransport()
        let map = PinMap(transport: t)
        map.watch(shape: shape)
        settle { map.snapshot.sweptGeneration != nil }
        XCTAssertEqual(map.snapshot.avail.count, shape.keys.count)
        XCTAssertEqual(map.snapshot.avail[.output(4)]?.freePins(), [4, 5, 6, 7])
        XCTAssertEqual(map.snapshot.avail[.uart]?.groupCount, 2)

        // Same generation, not forced: nothing is read again.
        let before = t.availReadCount()
        map.requestRefresh()
        settle { false }
        XCTAssertEqual(t.availReadCount(), before)
    }

    func testGenerationMovingMidSweepRereads() {
        let t = PinFakeTransport()
        t.bumpAfterAvailReads = 3
        let map = PinMap(transport: t)
        map.watch(shape: shape)
        settle { map.snapshot.sweptGeneration == 6 }
        XCTAssertEqual(map.snapshot.pinGeneration, 6)
        XCTAssertTrue(map.snapshot.avail.values.allSatisfy { $0.generation == 6 },
                      "one snapshot never mixes two generations")
    }

    func testAbsentAndDenied() {
        let t = PinFakeTransport()
        t.refuseAll = .vcUnknown
        let map = PinMap(transport: t)
        map.requestRefresh(force: true)
        settle { map.snapshot.support != .unknown }
        XCTAssertEqual(map.snapshot.support, .absent)

        let d = PinFakeTransport()
        d.refuseAll = .denied
        let dm = PinMap(transport: d)
        dm.requestRefresh(force: true)
        settle { dm.snapshot.support != .unknown }
        XCTAssertEqual(dm.snapshot.support, .denied)
    }

    /// A lock held by another session keeps the old data and reads once, not
    /// once per command.
    func testLockedKeepsOldDataAndStopsEarly() {
        let t = PinFakeTransport()
        let map = PinMap(transport: t)
        map.watch(shape: shape)
        settle { map.snapshot.sweptGeneration != nil }
        let old = map.snapshot
        t.refuseAll = .locked
        let readsBefore = t.availReadCount()
        map.requestRefresh(force: true)
        settle { false }
        XCTAssertEqual(map.snapshot, old)
        XCTAssertEqual(t.availReadCount(), readsBefore, "aborted at PIN_STATE")
    }

    func testClaimsBusyDoesNotFailTheSnapshot() {
        let t = PinFakeTransport()
        t.claimsBusy = true
        let map = PinMap(transport: t)
        map.watch(shape: shape)
        settle { map.snapshot.sweptGeneration != nil }
        XCTAssertEqual(map.snapshot.avail.count, shape.keys.count)
        t.claimsBusy = false
        settle { !map.snapshot.claims.isEmpty }
        XCTAssertEqual(map.snapshot.claims.count, 1, "retried after BUSY")
    }

    func testCSSlotFetchesEveryType() {
        let t = PinFakeTransport()
        let map = PinMap(transport: t)
        map.watchCS(slot: 2, shape: shape)
        settle { map.snapshot.cs.count == 2 }
        XCTAssertEqual(map.snapshot.cs[CsAvailKey(slot: 2, type: 3)]?.freePins(), [0, 1, 2, 3])
        XCTAssertTrue(map.snapshot.avail.isEmpty, "a CS editor alone does not sweep the other functions")
    }

    func testConnectionChangeDropsTheResult() {
        let t = PinFakeTransport()
        let map = PinMap(transport: t)
        t.generation = 1
        map.requestRefresh(force: true)
        t.generation = 2
        settle { false }
        XCTAssertNil(map.snapshot.state)
    }
}
