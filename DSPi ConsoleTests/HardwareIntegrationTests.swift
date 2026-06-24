import XCTest
@testable import DSPi_Console

/// Live-device integration tests. Each drives the REAL app command layer (the
/// same `DSPViewModel` methods the UI buttons call) to WRITE, then reads the
/// value back over USB with an INDEPENDENT raw control transfer to VERIFY -
/// catching bugs a self-consistent set/get pair would hide. Every test snapshots
/// the original value and restores it on exit.
///
/// All tests SKIP cleanly when no DSPi is attached (`requireDevice`). Reads use
/// the synchronous `getControlRequest`, which serializes behind the preceding
/// async `set*` on the device's serial queue, so a read right after a write
/// observes the new value deterministically.
final class HardwareIntegrationTests: XCTestCase {

    func testMasterVolumeRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        let original = HardwareTest.readFloat(usb, REQ_GET_MASTER_VOLUME, value: 0)
        try XCTSkipIf(original == nil, "device did not report master volume")
        defer { if let o = original { vm.setMasterVolume(o) } }

        let target: Float = -12.0
        vm.setMasterVolume(target)
        let readBack = HardwareTest.readFloat(usb, REQ_GET_MASTER_VOLUME, value: 0)
        XCTAssertEqual(readBack ?? .nan, target, accuracy: 0.05,
                       "master volume set via ViewModel should land on the device")
    }

    func testOutputGainRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        let output = 0

        let original = HardwareTest.readFloat(usb, REQ_GET_OUTPUT_GAIN, value: UInt16(output), index: 2)
        try XCTSkipIf(original == nil, "device did not report output gain")
        defer { if let o = original { vm.setOutputGain(output: output, db: o) } }

        let target: Float = -6.0
        vm.setOutputGain(output: output, db: target)
        let readBack = HardwareTest.readFloat(usb, REQ_GET_OUTPUT_GAIN, value: UInt16(output), index: 2)
        XCTAssertEqual(readBack ?? .nan, target, accuracy: 0.05,
                       "output \(output) gain set via ViewModel should land on the device")
    }

    func testEQBandRoundTrip() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        let ch = 0, band = 0

        func get(_ param: Int) -> UInt32? {
            HardwareTest.readU32(usb, REQ_GET_EQ_PARAM, value: HardwareTest.eqWValue(ch: ch, band: band, param: param))
        }
        func getF(_ param: Int) -> Float? {
            HardwareTest.readFloat(usb, REQ_GET_EQ_PARAM, value: HardwareTest.eqWValue(ch: ch, band: band, param: param))
        }

        let origType = get(0), origFreq = getF(1), origQ = getF(2), origGain = getF(3)
        try XCTSkipIf(origType == nil || origFreq == nil, "device did not return EQ band 0")
        defer {
            if let t = origType, let f = origFreq, let q = origQ, let g = origGain,
               let ft = FilterType(rawValue: Int(t)) {
                vm.setFilter(ch: ch, band: band, p: FilterParams(type: ft, freq: f, q: q, gain: g))
            }
        }

        vm.setFilter(ch: ch, band: band,
                     p: FilterParams(type: .peaking, freq: 1234.5, q: 1.5, gain: 3.0))

        XCTAssertEqual(get(0).map { Int($0) }, FilterType.peaking.rawValue, "type round-trip")
        XCTAssertEqual(getF(1) ?? .nan, 1234.5, accuracy: 0.5, "freq round-trip")
        XCTAssertEqual(getF(2) ?? .nan, 1.5, accuracy: 0.01, "Q round-trip")
        XCTAssertEqual(getF(3) ?? .nan, 3.0, accuracy: 0.05, "gain round-trip")
    }

    func testInputSourceReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_INPUT_SOURCE, value: 0, index: 0, length: 1) else {
            throw XCTSkip("Firmware does not support input-source switching (0xE1 STALLed).")
        }
        let src = d.first ?? 255
        XCTAssertTrue((0...2).contains(src),
                      "input source should be USB(0) / SPDIF(1) / I2S(2), got \(src)")
    }
}
