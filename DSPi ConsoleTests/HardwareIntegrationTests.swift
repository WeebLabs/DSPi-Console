import XCTest
@testable import DSPi_Console

/// Live-device integration tests. Each drives the REAL app command layer (the
/// same `DSPViewModel` methods the UI buttons call) to WRITE, then reads the
/// value back over USB with an INDEPENDENT raw control transfer to VERIFY -
/// catching bugs a self-consistent set/get pair would hide. Every test snapshots
/// the original value and restores it on exit.
///
/// All tests SKIP cleanly when no DSPi is attached (`requireDevice`). Reads use
/// the synchronous `getData`, which serializes behind the preceding
/// async `set*` through the DSPi Link hub, whose router runs the local
/// session's commands in order; `HardwareTest.readFloat` settles behind them
/// first, so a read right after a write observes the new value deterministically.
final class HardwareIntegrationTests: XCTestCase {

    func testMasterVolumeRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        let original = HardwareTest.readFloat(usb, VC.ROUTE.MASTER_VOLUME)
        try XCTSkipIf(original == nil, "device did not report master volume")
        defer { if let o = original { vm.setMasterVolume(o) } }

        let target: Float = -12.0
        vm.setMasterVolume(target)
        let readBack = HardwareTest.readFloat(usb, VC.ROUTE.MASTER_VOLUME)
        XCTAssertEqual(readBack ?? .nan, target, accuracy: 0.05,
                       "master volume set via ViewModel should land on the device")
    }

    func testOutputGainRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        let output = 0

        let original = HardwareTest.readFloat(usb, VC.ROUTE.OUTPUT_GAIN, value: UInt16(output))
        try XCTSkipIf(original == nil, "device did not report output gain")
        defer { if let o = original { vm.setOutputGain(output: output, db: o) } }

        let target: Float = -6.0
        vm.setOutputGain(output: output, db: target)
        let readBack = HardwareTest.readFloat(usb, VC.ROUTE.OUTPUT_GAIN, value: UInt16(output))
        XCTAssertEqual(readBack ?? .nan, target, accuracy: 0.05,
                       "output \(output) gain set via ViewModel should land on the device")
    }

    func testEQBandRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        let ch = 0, band = 0

        let orig = HardwareTest.readBand(usb, ch: ch, band: band)
        try XCTSkipIf(orig == nil, "device did not return EQ band 0")
        defer {
            if let o = orig, let ft = FilterType(rawValue: Int(o.type)) {
                vm.setFilter(ch: ch, band: band, p: FilterParams(type: ft, freq: o.freq, q: o.q, gain: o.gain))
            }
        }

        vm.setFilter(ch: ch, band: band,
                     p: FilterParams(type: .peaking, freq: 1234.5, q: 1.5, gain: 3.0))

        let back = HardwareTest.readBand(usb, ch: ch, band: band)
        XCTAssertEqual(back.map { Int($0.type) }, FilterType.peaking.rawValue, "type round-trip")
        XCTAssertEqual(back?.freq ?? .nan, 1234.5, accuracy: 0.5, "freq round-trip")
        XCTAssertEqual(back?.q ?? .nan, 1.5, accuracy: 0.01, "Q round-trip")
        XCTAssertEqual(back?.gain ?? .nan, 3.0, accuracy: 0.05, "gain round-trip")
    }

    func testInputSourceReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getData(VC.INPUT.SOURCE, length: 1) else {
            throw XCTSkip("Firmware does not support input-source switching (INPUT.SOURCE refused).")
        }
        let src = d.first ?? 255
        XCTAssertTrue((0...2).contains(src),
                      "input source should be USB(0) / SPDIF(1) / I2S(2), got \(src)")
    }
}
