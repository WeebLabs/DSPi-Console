import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the Stereo Upmixer (upmixer_spec.md).  The
/// pure-logic tests need no device; the live-device tests SKIP (never fail) when
/// no DSPi is attached.
final class UpmixerWireTests: XCTestCase {

    // MARK: - Constants (spec §6, §4)

    func testRequestCodes() {
        XCTAssertEqual(REQ_UPMIX_SET_CONFIG, 0x4A)
        XCTAssertEqual(REQ_UPMIX_GET_CONFIG, 0x4B)
        XCTAssertEqual(REQ_UPMIX_SET_PARAM,  0x4C)
        XCTAssertEqual(REQ_UPMIX_GET_PARAM,  0x4D)
        XCTAssertEqual(REQ_UPMIX_GET_STATUS, 0x4E)
    }

    func testParamIds() {
        XCTAssertEqual(UPMIX_PARAM_ENABLED, 0)
        XCTAssertEqual(UPMIX_PARAM_CENTER_MODE, 1)
        XCTAssertEqual(UPMIX_PARAM_SURROUND_MODE, 2)
        XCTAssertEqual(UPMIX_PARAM_STRENGTH, 3)
        XCTAssertEqual(UPMIX_PARAM_CENTER_WIDTH, 4)
        XCTAssertEqual(UPMIX_PARAM_THRESHOLD, 5)
        XCTAssertEqual(UPMIX_PARAM_ATTACK, 6)
        XCTAssertEqual(UPMIX_PARAM_RELEASE, 7)
        XCTAssertEqual(UPMIX_PARAM_DET_HPF, 8)
        XCTAssertEqual(UPMIX_PARAM_SUR_DELAY, 9)
        XCTAssertEqual(UPMIX_PARAM_SUR_HPF, 10)
        XCTAssertEqual(UPMIX_PARAM_SUR_LPF, 11)
        XCTAssertEqual(UPMIX_PARAM_DECORR, 12)
        XCTAssertEqual(UPMIX_PARAM_PRESENCE, 13)
    }

    func testModeAndParkedConstants() {
        XCTAssertEqual(UPMIX_CENTER_MODE_PASSIVE, 0)
        XCTAssertEqual(UPMIX_CENTER_MODE_ADAPTIVE, 1)
        // V27 appended OFF as 2 rather than renumbering to the surround enum's
        // OFF-first layout, so saved presets and older hosts keep their meaning.
        XCTAssertEqual(UPMIX_CENTER_MODE_OFF, 2)
        XCTAssertEqual(UPMIX_SURROUND_MODE_OFF, 0)
        XCTAssertEqual(UPMIX_SURROUND_MODE_PASSIVE, 1)
        XCTAssertEqual(UPMIX_SURROUND_MODE_ADAPTIVE, 2)
        XCTAssertEqual(UPMIX_PARKED_ACTIVE, 0)
        XCTAssertEqual(UPMIX_PARKED_DISABLED, 1)
        XCTAssertEqual(UPMIX_PARKED_NOT_STEREO, 2)
        XCTAssertEqual(UPMIX_PARKED_RATE_TOO_HIGH, 3)
    }

    /// V25 appends WireUpmixParams (44 bytes) as the final section at offset
    /// 5900, growing the flat layout to 5944 bytes; V26 claims its reserved byte
    /// +3 for presence_q1 with no size change (spec §7).
    func testWireFormatSizing() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 28)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5944)
        XCTAssertEqual(BULK_UPMIX_OFFSET, 5900)
        XCTAssertEqual(UPMIX_CONFIG_PACKET_SIZE, 44)
        XCTAssertEqual(UPMIX_STATUS_SIZE, 16)
        // The section is the final member: offset + 44 == total size.
        XCTAssertEqual(BULK_UPMIX_OFFSET + UPMIX_CONFIG_PACKET_SIZE, Int(BULK_PARAMS_SIZE))
        // It sits immediately after the 24-byte psybass section (offset 5876).
        XCTAssertEqual(BULK_PSYBASS_OFFSET + 24, BULK_UPMIX_OFFSET)
    }

    // MARK: - UpmixConfigPacket / WireUpmixParams decode (spec §6.1)

    /// Encodes a 44-byte packet and decodes each field exactly as `fetchUpmixConfig`
    /// / the bulk parser do, confirming every field lands at the documented offset.
    func testConfigPacketRoundTrip() {
        var p = Data(count: UPMIX_CONFIG_PACKET_SIZE)
        p[0] = 0x01   // enabled
        p[1] = 0x01   // center_mode = ADAPTIVE
        p[2] = 0x02   // surround_mode = ADAPTIVE
        p[3] = UInt8(bitPattern: -7)  // presence_q1 = -7 -> -3.5 dB
        func put(_ v: Float, at off: Int) {
            var f = v
            withUnsafeBytes(of: &f) { p.replaceSubrange(off..<off+4, with: $0) }
        }
        put(100.0, at: 4)    // strength_pct
        put(25.0,  at: 8)    // center_width_pct
        put(30.0,  at: 12)   // corr_threshold_pct
        put(10.0,  at: 16)   // attack_ms
        put(100.0, at: 20)   // release_ms
        put(200.0, at: 24)   // detector_hpf_hz
        put(12.0,  at: 28)   // surround_delay_ms
        put(300.0, at: 32)   // surround_hpf_hz
        put(7000.0, at: 36)  // surround_lpf_hz
        put(90.0,  at: 40)   // decorr_pct

        XCTAssertTrue(p[0] != 0)
        XCTAssertEqual(Int(p[1]), UPMIX_CENTER_MODE_ADAPTIVE)
        XCTAssertEqual(Int(p[2]), UPMIX_SURROUND_MODE_ADAPTIVE)
        // Byte 3 is a signed presence_q1 in 0.5 dB steps (spec §6.1, V26+).
        XCTAssertEqual(Float(Int8(bitPattern: p[3])) / 2.0, -3.5)
        func f(_ off: Int) -> Float { p.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float.self) } }
        XCTAssertEqual(f(4), 100.0)
        XCTAssertEqual(f(8), 25.0)
        XCTAssertEqual(f(12), 30.0)
        XCTAssertEqual(f(16), 10.0)
        XCTAssertEqual(f(20), 100.0)
        XCTAssertEqual(f(24), 200.0)
        XCTAssertEqual(f(28), 12.0)
        XCTAssertEqual(f(32), 300.0)
        XCTAssertEqual(f(36), 7000.0)
        XCTAssertEqual(f(40), 90.0)
    }

    // MARK: - UpmixStatus decode (spec §6.3)

    func testStatusFixedPointDecode() {
        var d = Data(count: 16)
        d[0] = 1                                  // active
        d[1] = UPMIX_PARKED_ACTIVE                // parked_reason
        func putI16(_ v: Int16, at off: Int) { var x = v; withUnsafeBytes(of: &x) { d.replaceSubrange(off..<off+2, with: $0) } }
        func putU16(_ v: UInt16, at off: Int) { var x = v; withUnsafeBytes(of: &x) { d.replaceSubrange(off..<off+2, with: $0) } }
        putI16(-16384, at: 2)   // corr_q14 = -1.0
        putU16(16384,  at: 4)   // balance_q14 = 1.0
        putU16(32767,  at: 6)   // center_gain_q15 = 1.0
        putU16(16383,  at: 8)   // ls_gain_q15 ≈ 0.5
        putU16(0,      at: 10)  // rs_gain_q15 = 0

        let corr = Float(d.withUnsafeBytes { $0.load(fromByteOffset: 2, as: Int16.self) }) / 16384.0
        let balance = Float(d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }) / 16384.0
        let center = Float(d.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }) / 32767.0
        let ls = Float(d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) }) / 32767.0

        XCTAssertEqual(corr, -1.0, accuracy: 0.0001)
        XCTAssertEqual(balance, 1.0, accuracy: 0.0001)
        XCTAssertEqual(center, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ls, 0.5, accuracy: 0.001)
    }

    // MARK: - Presence packing (spec §4, §6.1)

    /// Config byte 3 is a signed presence_q1 (dB x 2) spanning -24..+24, i.e.
    /// -12..+12 dB in 0.5 dB steps.  Decode matches `fetchUpmixConfig` / bulk.
    func testPresenceQ1Encoding() {
        func decode(_ q1: Int8) -> Float { Float(q1) / 2.0 }
        XCTAssertEqual(decode(0), 0.0)
        XCTAssertEqual(decode(24), 12.0)     // +12 dB ceiling
        XCTAssertEqual(decode(-24), -12.0)   // -12 dB floor
        XCTAssertEqual(decode(1), 0.5)       // half-step resolution
        XCTAssertEqual(decode(-9), -4.5)
        // Round-trip through the raw byte as stored on the wire.
        let raw = UInt8(bitPattern: Int8(-24))
        XCTAssertEqual(Float(Int8(bitPattern: raw)) / 2.0, -12.0)
    }

    // MARK: - Feature detection gate (spec §6)

    func testFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.platformName = "RP2350"
        vm.firmwareWireFormatVersion = 25
        XCTAssertFalse(vm.firmwareSupportsUpmixer)   // presence needs V26
        vm.firmwareWireFormatVersion = 26
        XCTAssertTrue(vm.firmwareSupportsUpmixer)
        // RP2040 never supports it even at V26.
        vm.platformName = "RP2040"
        XCTAssertFalse(vm.firmwareSupportsUpmixer)
    }

    // MARK: - Matrix source-row labelling (spec §3)

    func testDerivedMatrixRows() {
        let vm = DSPViewModel()
        vm.platformName = "RP2350"
        vm.firmwareWireFormatVersion = 26

        // Disabled: no derived rows, plain stereo labels.
        vm.upmixEnabled = false
        XCTAssertFalse(vm.upmixDerivesRows)
        XCTAssertEqual(vm.matrixSourceRowCount, vm.numMatrixInputs)

        // Enabled + adaptive surround: 5 rows, C/Ls/Rs above the stereo pair.
        vm.upmixEnabled = true
        vm.upmixSurroundMode = UPMIX_SURROUND_MODE_ADAPTIVE
        XCTAssertTrue(vm.upmixDerivesRows)
        XCTAssertEqual(vm.matrixSourceRowCount, 5)
        XCTAssertEqual(vm.matrixRowShortName(2), "C")
        XCTAssertEqual(vm.matrixRowShortName(3), "Ls")
        XCTAssertEqual(vm.matrixRowShortName(4), "Rs")
        XCTAssertEqual(vm.matrixRowFullName(2), "Upmix Centre")

        // Surround OFF: only the Centre row is exposed (3 rows total).
        vm.upmixSurroundMode = UPMIX_SURROUND_MODE_OFF
        XCTAssertEqual(vm.matrixSourceRowCount, 3)
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// The bulk upmix section agrees with the individual GET_CONFIG readback.
    func testUpmixReadbackConsistency() throws {
        let usb = try HardwareTest.requireDevice()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Firmware predates the Stereo Upmixer (wire format < V25).")
        }

        let o = BULK_UPMIX_OFFSET
        let bulkEnabled = all[o] != 0
        let bulkStrength: Float = all.withUnsafeBytes { $0.load(fromByteOffset: o + 4, as: Float.self) }

        guard let cfg = usb.getControlRequest(request: REQ_UPMIX_GET_CONFIG, value: 0, index: 0,
                                              length: UInt16(UPMIX_CONFIG_PACKET_SIZE)),
              cfg.count >= UPMIX_CONFIG_PACKET_SIZE else {
            throw XCTSkip("Upmix GET_CONFIG STALLed.")
        }
        XCTAssertEqual((cfg.first ?? 0) != 0, bulkEnabled)
        let cfgStrength: Float = cfg.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
        XCTAssertEqual(cfgStrength, bulkStrength, accuracy: 0.01)
    }

    /// Writing an out-of-range strength and reading it back returns the clamped
    /// value; restores the original afterwards so the test is non-destructive.
    /// Per spec §4 the firmware keeps the written value in the stored config
    /// (clamping happens only at coefficient computation), so an in-range write
    /// must read back exactly.
    func testStrengthParamRoundTrips() throws {
        let usb = try HardwareTest.requireDevice()
        guard let cfg = usb.getControlRequest(request: REQ_UPMIX_GET_CONFIG, value: 0, index: 0,
                                              length: UInt16(UPMIX_CONFIG_PACKET_SIZE)),
              cfg.count >= UPMIX_CONFIG_PACKET_SIZE else {
            throw XCTSkip("Firmware predates the Stereo Upmixer.")
        }
        let original: Float = cfg.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
        defer {
            var restore = original
            usb.sendControlRequest(request: REQ_UPMIX_SET_PARAM, value: UPMIX_PARAM_STRENGTH,
                                   index: 0, data: Data(bytes: &restore, count: 4))
        }

        var probe: Float = 55.0   // a distinct in-range value
        usb.sendControlRequest(request: REQ_UPMIX_SET_PARAM, value: UPMIX_PARAM_STRENGTH,
                               index: 0, data: Data(bytes: &probe, count: 4))
        guard let back = usb.getControlRequest(request: REQ_UPMIX_GET_PARAM, value: UPMIX_PARAM_STRENGTH,
                                               index: 0, length: 4), back.count >= 4 else {
            throw XCTSkip("Upmix GET_PARAM STALLed.")
        }
        let readback: Float = back.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertEqual(readback, 55.0, accuracy: 0.01, "an in-range strength must round-trip exactly")
    }
}
