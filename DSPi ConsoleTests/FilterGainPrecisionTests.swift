import XCTest
@testable import DSPi_Console

/// Pins the gain-precision contract for PEQ band writes
/// (automated_room_correction_spec.md §7.4).
///
/// `EqParamPacket` carries frequency, Q and gain as IEEE-754 float32, so the
/// old 0.1 dB grid in `setFilter` was a host convention rather than a wire
/// limit.  Room correction generates gains off that grid, and the Milestone 0
/// corpus measured up to 0.363 dB of avoidable response error from rounding
/// them (worst on shelf-bearing targets, where the whole plateau shifts).
/// These tests exist so the grid is not quietly reintroduced.
final class FilterGainPrecisionTests: XCTestCase {

    /// A view model on an inert USB device.
    ///
    /// `DSPViewModel()` defaults to `AppState.shared.usb`, which auto-connects
    /// to real hardware, so `setFilter` below wrote actual PEQ bands to the
    /// attached DSPi - corrupting its EQ and flooding the shared serial queue
    /// that the live-device tests depend on.
    private func makeViewModel() -> DSPViewModel {
        DSPViewModel(usb: USBDevice(autoConnect: false, monitor: false))
    }

    /// A gain that is not on the 0.1 dB grid must survive `setFilter` exactly.
    func testSetFilterPreservesOffGridGain() {
        let vm = makeViewModel()
        let offGrid: Float = -3.14159
        var p = FilterParams()
        p.type = .peaking
        p.freq = 63.0
        p.q = 4.2
        p.gain = offGrid

        vm.setFilter(ch: 0, band: 0, p: p)

        let stored = vm.channelData[0]?[0]
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.gain, offGrid,
                       "setFilter must not quantize gain; the wire carries float32")
    }

    /// The specific failure the old grid caused: a shelf gain landing mid-step
    /// was pulled a full half-step away.  0.05 dB is the worst-case error of a
    /// 0.1 dB grid, and it must now be zero.
    func testShelfGainIsNotPulledToGrid() {
        let vm = makeViewModel()
        let midStep: Float = 2.05
        var p = FilterParams()
        p.type = .lowShelf
        p.freq = 120.0
        p.q = 0.707
        p.gain = midStep

        vm.setFilter(ch: 0, band: 1, p: p)

        let stored = vm.channelData[0]?[1]
        XCTAssertEqual(stored?.gain, midStep)
        // Guard against a reintroduced grid snapping either direction.
        XCTAssertNotEqual(stored?.gain, 2.0)
        XCTAssertNotEqual(stored?.gain, 2.1)
    }

    /// Full float32 precision must round-trip, including values that a Double
    /// intermediate would perturb.  This is what lets `PresetSnapshot` keep
    /// using exact Float equality.
    func testFloat32RoundTripIsExact() {
        let vm = makeViewModel()
        // Deliberately not representable on any decimal grid.
        let values: [Float] = [0.0333333, -11.987654, 5.0000005, -0.0001]
        for (index, value) in values.enumerated() {
            var p = FilterParams()
            p.type = .peaking
            p.freq = 1000.0
            p.gain = value
            vm.setFilter(ch: 0, band: index, p: p)
            XCTAssertEqual(vm.channelData[0]?[index].gain, value,
                           "band \(index) gain \(value) was altered in transit")
        }
    }

    /// The compensation room correction writes is a level, and it went through
    /// the same 0.1 dB grid the filter gains used to.
    ///
    /// This is what made Apply impossible: the plan held an ungridded
    /// compensation, the setter quantized it on the way out, and the read-back
    /// verification then found the two disagreeing in the second decimal place
    /// and rolled the whole thing back every time.
    func testOutputGainKeepsItsSecondDecimalPlace() {
        let vm = makeViewModel()
        vm.setOutputGain(output: 0, db: 4.93)
        XCTAssertEqual(vm.outputGainDB[0], 4.93,
                       "the wire carries float32; the grid was a host convention")

        vm.setOutputGain(output: 1, db: -2.07)
        XCTAssertEqual(vm.outputGainDB[1], -2.07)
    }

    func testInputPreampKeepsItsSecondDecimalPlace() {
        let vm = makeViewModel()
        vm.setPreampChannel(channel: 0, db: -3.46)
        XCTAssertEqual(vm.preampDB[0], -3.46)
    }

    func testGainsThatWereAlreadyOnTheGridAreUnchanged() {
        // Removing the rounding must not perturb the values it used to produce.
        let vm = makeViewModel()
        for db in [Float(0), -6, 3.5, -12.1] {
            vm.setOutputGain(output: 2, db: db)
            XCTAssertEqual(vm.outputGainDB[2], db, "\(db) should survive untouched")
        }
    }

    /// Negative zero is still normalized, because it is a display artifact
    /// rather than a precision question, and `-0.0 == 0.0` would otherwise
    /// hide a real diff behind an inconsistent textual rendering.
    func testNegativeZeroIsNormalized() {
        let vm = makeViewModel()
        var p = FilterParams()
        p.type = .peaking
        p.gain = -0.0
        vm.setFilter(ch: 0, band: 2, p: p)
        XCTAssertEqual(vm.channelData[0]?[2].gain.sign, .plus)
    }

    /// The same normalization survives on the level path, where it is also a
    /// display concern rather than a precision one.
    func testNegativeZeroIsNormalizedOnGainsToo() {
        let vm = makeViewModel()
        vm.setOutputGain(output: 3, db: -0.0)
        XCTAssertEqual(vm.outputGainDB[3].sign, .plus)
        vm.setPreampChannel(channel: 1, db: -0.0)
        XCTAssertEqual(vm.preampDB[1].sign, .plus)
    }

    /// Apply verifies against the device, not against its own cache.
    ///
    /// The cache-populating fetches publish from a main-queue hop, so a caller
    /// on the main actor that read the cache straight afterwards would get the
    /// value from before the fetch - which is whatever this app had just
    /// written into it. That verifies nothing.
    @MainActor
    func testApplyReadBackDoesNotConsultTheCache() {
        let vm = makeViewModel()
        var peak = FilterParams()
        peak.type = .peaking
        peak.freq = 63
        peak.gain = -6
        vm.setFilter(ch: 0, band: 0, p: peak)
        vm.setOutputGain(output: 0, db: -4.25)

        // With no device attached the transfers fail, so an honest device read
        // returns nil. A cache read would cheerfully return the values above.
        XCTAssertNil(vm.readBand(channel: 0, band: 0),
                     "a read-back with no device must not fall back on the cache")
        XCTAssertNil(vm.readOutputGain(output: 0))
        XCTAssertNil(vm.readInputPreamp(channel: 0))
    }
}
