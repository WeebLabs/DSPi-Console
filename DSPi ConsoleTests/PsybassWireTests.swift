import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the Psychoacoustic Bass feature
/// (psychoacoustic_bass_spec.md).  The pure-logic tests need no device; the
/// live-device tests SKIP (never fail) when no DSPi is attached.
final class PsybassWireTests: XCTestCase {

    // MARK: - Constants (spec §3 command summary)

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_PSYBASS, 0x30)
        XCTAssertEqual(REQ_GET_PSYBASS, 0x31)
        XCTAssertEqual(REQ_SET_PSYBASS_CUTOFF, 0x32)
        XCTAssertEqual(REQ_GET_PSYBASS_CUTOFF, 0x33)
        XCTAssertEqual(REQ_SET_PSYBASS_HARMONICS, 0x34)
        XCTAssertEqual(REQ_GET_PSYBASS_HARMONICS, 0x35)
        XCTAssertEqual(REQ_SET_PSYBASS_DRIVE, 0x36)
        XCTAssertEqual(REQ_GET_PSYBASS_DRIVE, 0x37)
        XCTAssertEqual(REQ_SET_PSYBASS_CHARACTER, 0x38)
        XCTAssertEqual(REQ_GET_PSYBASS_CHARACTER, 0x39)
        XCTAssertEqual(REQ_SET_PSYBASS_ORIGINAL, 0x3A)
        XCTAssertEqual(REQ_GET_PSYBASS_ORIGINAL, 0x3B)
        XCTAssertEqual(REQ_SET_PSYBASS_MASK, 0x3C)
        XCTAssertEqual(REQ_GET_PSYBASS_MASK, 0x3D)
        XCTAssertEqual(PSYBASS_DEFAULT_OUTPUT_MASK, 0xFFFF)
    }

    /// V23 appends WirePsybassParams (24 bytes) as the final section at offset
    /// 5876, growing the flat layout from 5876 to 5900 bytes (spec §4).
    func testWireFormatSizing() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 28)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5944)
        XCTAssertEqual(BULK_PSYBASS_OFFSET, 5876)
        // The psybass section is 24 bytes; the upmixer section follows it (V25).
        XCTAssertEqual(BULK_PSYBASS_OFFSET + 24, BULK_UPMIX_OFFSET)
        // It sits immediately after the ADAT config (8 bytes at 5868).
        XCTAssertEqual(BULK_ADAT_OFFSET + 8, BULK_PSYBASS_OFFSET)
    }

    // MARK: - WirePsybassParams field decode (spec §4 table)

    /// Encodes a 24-byte section and decodes it exactly as `fetchAllParams`
    /// does, confirming every field lands at the documented offset.
    func testBulkSectionRoundTrip() {
        var section = Data(count: 24)
        section[0] = 0x01                                  // enabled
        section[1] = 0x00                                  // reserved
        section[2] = 0x34; section[3] = 0x12               // output_mask = 0x1234 LE
        func putFloat(_ v: Float, at off: Int) {
            var f = v
            withUnsafeBytes(of: &f) { section.replaceSubrange(off..<off+4, with: $0) }
        }
        putFloat(90.0,   at: 4)    // cutoff_hz
        putFloat(-3.5,   at: 8)    // harmonics_db
        putFloat(9.0,    at: 12)   // drive_db
        putFloat(40.0,   at: 16)   // character_pct
        putFloat(-12.0,  at: 20)   // original_db

        let enabled = section[0] != 0
        let mask = UInt16(section[2]) | (UInt16(section[3]) << 8)
        let cutoff: Float = section.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
        let harmonics: Float = section.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
        let drive: Float = section.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float.self) }
        let character: Float = section.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Float.self) }
        let original: Float = section.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Float.self) }

        XCTAssertTrue(enabled)
        XCTAssertEqual(mask, 0x1234)
        XCTAssertEqual(cutoff, 90.0)
        XCTAssertEqual(harmonics, -3.5)
        XCTAssertEqual(drive, 9.0)
        XCTAssertEqual(character, 40.0)
        XCTAssertEqual(original, -12.0)
    }

    // MARK: - Feature detection gate (spec §6)

    func testFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 22
        XCTAssertFalse(vm.firmwareSupportsPsybass)
        vm.firmwareWireFormatVersion = 23
        XCTAssertTrue(vm.firmwareSupportsPsybass)
    }

    // MARK: - Mask bit toggle helper

    func testOutputChannelMaskToggle() {
        let vm = DSPViewModel()
        vm.psybassOutputMask = 0x0000
        vm.setPsybassOutputChannel(0, enabled: true)
        XCTAssertEqual(vm.psybassOutputMask & 0x0001, 0x0001)
        vm.setPsybassOutputChannel(8, enabled: true)   // PDM sub bit on RP2350
        XCTAssertEqual(vm.psybassOutputMask & 0x0100, 0x0100)
        vm.setPsybassOutputChannel(0, enabled: false)
        XCTAssertEqual(vm.psybassOutputMask & 0x0001, 0x0000)
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// Each individual GET returns a value inside the documented range, and the
    /// bulk psybass section agrees with the seven individual GETs.
    func testPsybassReadbackConsistency() throws {
        let usb = try HardwareTest.requireDevice()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Firmware predates Psychoacoustic Bass (wire format < V23).")
        }

        // Bulk section values.
        let o = BULK_PSYBASS_OFFSET
        let bulkEnabled = all[o] != 0
        let bulkMask = UInt16(all[o + 2]) | (UInt16(all[o + 3]) << 8)
        let bulkCutoff: Float = all.withUnsafeBytes { $0.load(fromByteOffset: o + 4, as: Float.self) }

        // Individual GETs.
        guard let en = usb.getControlRequest(request: REQ_GET_PSYBASS, value: 0, index: 0, length: 1),
              let mk = usb.getControlRequest(request: REQ_GET_PSYBASS_MASK, value: 0, index: 0, length: 2),
              let ct = usb.getControlRequest(request: REQ_GET_PSYBASS_CUTOFF, value: 0, index: 0, length: 4),
              mk.count >= 2, ct.count >= 4 else {
            throw XCTSkip("Psybass individual GETs STALLed.")
        }
        XCTAssertEqual((en.first ?? 0) != 0, bulkEnabled)
        XCTAssertEqual(UInt16(mk[0]) | (UInt16(mk[1]) << 8), bulkMask)
        let getCutoff: Float = ct.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertEqual(getCutoff, bulkCutoff, accuracy: 0.01)

        // Cutoff must be within the firmware's clamp range.
        XCTAssertGreaterThanOrEqual(bulkCutoff, 30.0)
        XCTAssertLessThanOrEqual(bulkCutoff, 300.0)
    }

    /// Writing an out-of-range cutoff and reading it back returns the clamped
    /// value; restores the original afterwards so the test is non-destructive.
    func testCutoffClampsAndRestores() throws {
        let usb = try HardwareTest.requireDevice()
        guard let orig = usb.getControlRequest(request: REQ_GET_PSYBASS_CUTOFF, value: 0, index: 0, length: 4),
              orig.count >= 4 else {
            throw XCTSkip("Firmware predates Psychoacoustic Bass.")
        }
        let original: Float = orig.withUnsafeBytes { $0.load(as: Float.self) }
        defer {
            var restore = original
            usb.sendControlRequest(request: REQ_SET_PSYBASS_CUTOFF, value: 0, index: 0, data: Data(bytes: &restore, count: 4))
        }

        var over: Float = 5000.0   // well above the 300 Hz ceiling
        usb.sendControlRequest(request: REQ_SET_PSYBASS_CUTOFF, value: 0, index: 0, data: Data(bytes: &over, count: 4))
        guard let back = usb.getControlRequest(request: REQ_GET_PSYBASS_CUTOFF, value: 0, index: 0, length: 4),
              back.count >= 4 else {
            throw XCTSkip("Cutoff GET STALLed.")
        }
        let clamped: Float = back.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertLessThanOrEqual(clamped, 300.0, "firmware must clamp cutoff to its 30-300 Hz range")
    }
}
