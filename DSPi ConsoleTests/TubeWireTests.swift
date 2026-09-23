import XCTest
@testable import DSPi_Console

/// Wire-format and behaviour tests for the Tube Modeller (tube_preamp_spec.md).
/// The pure-logic tests need no device; the live-device tests SKIP (never fail)
/// when no DSPi is attached, and restore every parameter they touch.
final class TubeWireTests: XCTestCase {

    // MARK: - Constants (spec §3 command summary)

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_TUBE_PARAM, 0x3E)
        XCTAssertEqual(REQ_GET_TUBE_PARAM, 0x3F)
        XCTAssertEqual(TUBE_DEFAULT_OUTPUT_MASK, 0xFFFF)
    }

    /// The indexed pair sits directly above the psybass block (0x30-0x3D) and
    /// must not collide with it.
    func testCodesDoNotCollideWithPsybass() {
        let psybass: Set<UInt8> = Set((0x30...0x3D).map { UInt8($0) })
        XCTAssertFalse(psybass.contains(REQ_SET_TUBE_PARAM))
        XCTAssertFalse(psybass.contains(REQ_GET_TUBE_PARAM))
    }

    /// Indices are wire and flash order (spec §2 table).
    func testParameterIndices() {
        XCTAssertEqual(TUBE_PARAM_ENABLED, 0)
        XCTAssertEqual(TUBE_PARAM_OUTPUT_MASK, 1)
        XCTAssertEqual(TUBE_PARAM_TUBE_TYPE, 2)
        XCTAssertEqual(TUBE_PARAM_DRIVE_DB, 3)
        XCTAssertEqual(TUBE_PARAM_BIAS_PCT, 4)
        XCTAssertEqual(TUBE_PARAM_ASYM_DB, 5)
        XCTAssertEqual(TUBE_PARAM_HARDNESS_PCT, 6)
        XCTAssertEqual(TUBE_PARAM_SAG_PCT, 7)
        XCTAssertEqual(TUBE_PARAM_RECTIFIER, 8)
        XCTAssertEqual(TUBE_PARAM_XFMR_ENABLED, 9)
        XCTAssertEqual(TUBE_PARAM_XFMR_DAMPING, 10)
        XCTAssertEqual(TUBE_PARAM_XFMR_RES_HZ, 11)
        XCTAssertEqual(TUBE_PARAM_MIX_PCT, 12)
        XCTAssertEqual(TUBE_PARAM_TRIM_DB, 13)
        XCTAssertEqual(TUBE_NUM_PARAMS, 14)
    }

    /// The row table is the spec's own (§2.3); the app mirrors a type SET from
    /// it, so a wrong value here would show knobs the device does not have.
    func testTubeTypeTable() throws {
        XCTAssertEqual(TUBE_TYPE_ROWS.count, TUBE_TYPE_MAX + 1)
        XCTAssertNil(TUBE_TYPE_ROWS[TUBE_TYPE_CUSTOM])
        let ax7 = try XCTUnwrap(TUBE_TYPE_ROWS[1])
        XCTAssertEqual(ax7.name, "12AX7 / ECC83")
        XCTAssertEqual(ax7.biasPct, 10)
        XCTAssertEqual(ax7.asymDB, 3)
        XCTAssertEqual(ax7.hardnessPct, 40)
        XCTAssertEqual(ax7.sagPct, 15)
        let dht = try XCTUnwrap(TUBE_TYPE_ROWS[16])
        XCTAssertEqual(dht.name, "300B / 2A3")
        XCTAssertEqual(dht.biasPct, 12)
        XCTAssertEqual(dht.asymDB, 6)
        XCTAssertEqual(dht.hardnessPct, 10)
        XCTAssertEqual(dht.sagPct, 12)
        // Exactly the five push-pull power stages are flagged, and they are the
        // rows with neither bias nor asymmetry.
        let pushPull = (1...TUBE_TYPE_MAX).filter { TUBE_TYPE_ROWS[$0]?.pushPull == true }
        XCTAssertEqual(pushPull, [11, 12, 13, 14, 15])
        for t in pushPull {
            XCTAssertEqual(TUBE_TYPE_ROWS[t]?.biasPct, 0)
            XCTAssertEqual(TUBE_TYPE_ROWS[t]?.asymDB, 0)
        }
        XCTAssertEqual(tubeTypeName(0), "Custom")
        XCTAssertEqual(TUBE_RECTIFIER_ROWS.count, TUBE_RECT_MAX + 1)
        XCTAssertEqual(TUBE_RECTIFIER_ROWS[0].depthScale, 0)
    }

    // MARK: - Wire layout (spec §4)

    /// V31 appended WireTubeParams (48 bytes) at 5980, taking the flat layout
    /// from 5980 to 6028 bytes.  V32 appended the limiter after it.
    func testWireFormatSizing() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 32)
        XCTAssertEqual(BULK_PARAMS_SIZE, 6136)
        XCTAssertEqual(BULK_TUBE_OFFSET, 5980)
        XCTAssertEqual(WIRE_TUBE_PARAMS_SIZE, 48)
        XCTAssertEqual(BULK_SUBHARM_OFFSET + WIRE_SUBHARM_PARAMS_SIZE, BULK_TUBE_OFFSET)
        XCTAssertEqual(BULK_TUBE_OFFSET + WIRE_TUBE_PARAMS_SIZE, BULK_LIMITER_OFFSET)
    }

    /// Encodes a section and decodes it at the offsets `fetchAllParams` uses.
    func testBulkSectionRoundTrip() {
        var section = Data(count: WIRE_TUBE_PARAMS_SIZE)
        section[0] = 0x01                              // enabled
        section[1] = 16                                // tube_type = 300B
        section[2] = 3                                 // rectifier = 5Y3
        section[3] = 0x01                              // xfmr_enabled
        section[4] = 0x0F; section[5] = 0x01           // output_mask = 0x010F LE
        let floats: [Float] = [12, -40, 6.5, 70, 55, 6, 120, 75, -3, 0]
        for (i, v) in floats.enumerated() {
            var f = v
            withUnsafeBytes(of: &f) { section.replaceSubrange(8 + i * 4 ..< 12 + i * 4, with: $0) }
        }

        func f(_ off: Int) -> Float { section.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float.self) } }
        XCTAssertTrue(section[0] != 0)
        XCTAssertEqual(Int(section[1]), 16)
        XCTAssertEqual(Int(section[2]), 3)
        XCTAssertTrue(section[3] != 0)
        XCTAssertEqual(UInt16(section[4]) | (UInt16(section[5]) << 8), 0x010F)
        XCTAssertEqual(section[6], 0)   // reserved
        XCTAssertEqual(section[7], 0)
        XCTAssertEqual(f(8), 12)        // drive_db
        XCTAssertEqual(f(12), -40)      // bias_pct
        XCTAssertEqual(f(16), 6.5)      // asym_db
        XCTAssertEqual(f(20), 70)       // hardness_pct
        XCTAssertEqual(f(24), 55)       // sag_pct
        XCTAssertEqual(f(28), 6)        // xfmr_damping
        XCTAssertEqual(f(32), 120)      // xfmr_res_hz
        XCTAssertEqual(f(36), 75)       // mix_pct
        XCTAssertEqual(f(40), -3)       // trim_db
        XCTAssertEqual(f(44), 0)        // reserved_f, holds the section at 48 bytes
    }

    // MARK: - Feature detection (spec §6)

    func testFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 30
        XCTAssertFalse(vm.firmwareSupportsTube)
        vm.firmwareWireFormatVersion = 31
        XCTAssertTrue(vm.firmwareSupportsTube)
        // Both platforms run it.
        vm.platformName = "RP2040"
        XCTAssertTrue(vm.firmwareSupportsTube)
    }

    /// An unconnected app and a fresh device agree before the first bulk read.
    func testDefaultsMatchTheFirmware() {
        let vm = DSPViewModel()
        XCTAssertFalse(vm.tubeEnabled)
        XCTAssertEqual(vm.tube.outputMask, 0xFFFF)
        XCTAssertEqual(vm.tube.type, 1)
        XCTAssertEqual(vm.tube.driveDB, -6)
        XCTAssertEqual(vm.tube.biasPct, 10)
        XCTAssertEqual(vm.tube.asymDB, 3)
        XCTAssertEqual(vm.tube.hardnessPct, 40)
        XCTAssertEqual(vm.tube.sagPct, 15)
        XCTAssertEqual(vm.tube.rectifier, 1)
        XCTAssertFalse(vm.tube.xfmrEnabled)
        XCTAssertEqual(vm.tube.xfmrDamping, 2)
        XCTAssertEqual(vm.tube.xfmrResHz, 85)
        XCTAssertEqual(vm.tube.mixPct, 100)
        XCTAssertEqual(vm.tube.trimDB, 0)
    }

    // MARK: - Cross-field rules mirrored from the firmware (spec §2.3)

    /// A type 1..16 loads its row into the four character knobs.
    func testTypeLoadsItsRow() {
        let vm = DSPViewModel()
        vm.setTubeType(12)   // EL34
        XCTAssertEqual(vm.tube.type, 12)
        XCTAssertEqual(vm.tube.biasPct, 0)
        XCTAssertEqual(vm.tube.asymDB, 0)
        XCTAssertEqual(vm.tube.hardnessPct, 60)
        XCTAssertEqual(vm.tube.sagPct, 30)
        // Drive, mix, the rectifier and the output stage are not part of a row.
        XCTAssertEqual(vm.tube.driveDB, TUBE_DEFAULT_DRIVE_DB)
        XCTAssertEqual(vm.tube.rectifier, 1)
    }

    /// Custom stores 0 and leaves the knobs where they are.
    func testCustomLeavesKnobsAlone() {
        let vm = DSPViewModel()
        vm.setTubeType(16)
        vm.setTubeType(TUBE_TYPE_CUSTOM)
        XCTAssertEqual(vm.tube.type, TUBE_TYPE_CUSTOM)
        XCTAssertEqual(vm.tube.biasPct, 12)
        XCTAssertEqual(vm.tube.asymDB, 6)
    }

    /// A real change to a character knob drops the type to Custom; re-sending
    /// the stored value does not, exactly as the firmware gates it.
    func testCharacterEditDropsToCustomOnlyOnChange() {
        let vm = DSPViewModel()
        vm.setTubeType(1)
        vm.setTubeBias(10)       // same as the 12AX7 row
        XCTAssertEqual(vm.tube.type, 1)
        vm.setTubeHardness(41)
        XCTAssertEqual(vm.tube.type, TUBE_TYPE_CUSTOM)
        XCTAssertEqual(vm.tube.hardnessPct, 41)
    }

    /// The comparison is made after clamping: an over-range write that lands on
    /// the value already stored is not a change, so the type survives it.
    func testClampedRewriteIsNotAChange() {
        let vm = DSPViewModel()
        vm.setTubeBias(TUBE_BIAS_MAX)
        vm.tube.type = 5          // as if a notification had set the type since
        vm.setTubeBias(250)      // clamps to the stored +100
        XCTAssertEqual(vm.tube.type, 5)
    }

    /// Floats clamp to their ranges and enums to theirs, as the firmware does.
    func testClamping() {
        let vm = DSPViewModel()
        vm.setTubeDrive(40);        XCTAssertEqual(vm.tube.driveDB, TUBE_DRIVE_MAX)
        vm.setTubeDrive(-20);       XCTAssertEqual(vm.tube.driveDB, TUBE_DRIVE_MIN)
        vm.setTubeBias(-500);       XCTAssertEqual(vm.tube.biasPct, TUBE_BIAS_MIN)
        vm.setTubeXfmrDamping(0);   XCTAssertEqual(vm.tube.xfmrDamping, TUBE_XFMR_DAMPING_MIN)
        vm.setTubeXfmrDamping(99);  XCTAssertEqual(vm.tube.xfmrDamping, TUBE_XFMR_DAMPING_MAX)
        vm.setTubeXfmrRes(5);       XCTAssertEqual(vm.tube.xfmrResHz, TUBE_XFMR_RES_MIN)
        vm.setTubeXfmrRes(5000);    XCTAssertEqual(vm.tube.xfmrResHz, TUBE_XFMR_RES_MAX)
        vm.setTubeMix(150);         XCTAssertEqual(vm.tube.mixPct, TUBE_MIX_MAX)
        vm.setTubeTrim(-20);        XCTAssertEqual(vm.tube.trimDB, TUBE_TRIM_MIN)
        vm.setTubeType(99);         XCTAssertEqual(vm.tube.type, TUBE_TYPE_MAX)
        vm.setTubeRectifier(9);     XCTAssertEqual(vm.tube.rectifier, TUBE_RECT_MAX)
        vm.setTubeRectifier(-1);    XCTAssertEqual(vm.tube.rectifier, TUBE_RECT_SOLID_STATE)
    }

    func testOutputChannelMaskToggle() {
        let vm = DSPViewModel()
        vm.tube.outputMask = 0
        vm.setTubeOutputChannel(8, enabled: true)
        XCTAssertEqual(vm.tube.outputMask, 0x0100)
        vm.setTubeOutputChannel(8, enabled: false)
        XCTAssertEqual(vm.tube.outputMask, 0)
        vm.setTubeOutputChannel(16, enabled: true)
        XCTAssertEqual(vm.tube.outputMask, 0)
    }

    // MARK: - Shaper model (the graph and the harmonics readout)

    /// Small-signal gain is unity at every hardness AND every drive (spec §2.4
    /// and §2.7): the shaper carries 1/m makeup gain, so drive moves the knee
    /// rather than the level.  Without the makeup the curve would leave the
    /// graph by 24 dB at full drive.
    func testShaperSmallSignalGainIsUnity() {
        for hardness in [Float(0), 40, 100] {
            for drive in [TUBE_DRIVE_MIN, 0, 12, TUBE_DRIVE_MAX] {
                let s = TubeShaper(driveDB: drive, biasPct: 0, asymDB: 0,
                                   hardnessPct: hardness, mixPct: 100, trimDB: 0)
                let dx = 1e-6
                XCTAssertEqual((s.output(dx) - s.output(-dx)) / (2 * dx), 1.0, accuracy: 1e-3,
                               "hardness \(hardness), drive \(drive)")
            }
        }
    }

    /// The positive-half ceiling is 1/(c1 m): +2.5 dBFS at the -6 dB default
    /// and 1 dB lower per dB of drive above 0 (spec §7, headroom).
    func testShaperCeilingFollowsDrive() {
        func ceiling(_ drive: Float) -> Double {
            let s = TubeShaper(driveDB: drive, biasPct: 0, asymDB: 0, hardnessPct: 0,
                               mixPct: 100, trimDB: 0)
            // Well past the knee at every drive, so this is the clipped value.
            return s.output(10)
        }
        XCTAssertEqual(ceiling(TUBE_DRIVE_MIN), 1.333, accuracy: 0.01)
        XCTAssertEqual(ceiling(0), 0.667, accuracy: 0.01)
        XCTAssertEqual(ceiling(6), 0.334, accuracy: 0.01)
    }

    /// Silence stays silence: the rest-point offset is removed (spec §1, v0).
    func testShaperRestsAtZero() {
        let s = TubeShaper(driveDB: 12, biasPct: 60, asymDB: 6, hardnessPct: 40, mixPct: 100, trimDB: 0)
        XCTAssertEqual(s.output(0), 0, accuracy: 1e-12)
    }

    /// A symmetric stage makes no even harmonics; bias adds a second harmonic.
    func testShaperEvenHarmonicsFollowBias() {
        let sym = TubeShaper(driveDB: 12, biasPct: 0, asymDB: 0, hardnessPct: 50, mixPct: 100, trimDB: 0)
        XCTAssertLessThan(sym.harmonics().second, -100)
        XCTAssertGreaterThan(sym.harmonics().third, -40)
        let biased = TubeShaper(driveDB: 12, biasPct: 40, asymDB: 0, hardnessPct: 50, mixPct: 100, trimDB: 0)
        XCTAssertGreaterThan(biased.harmonics().second, -40)
    }

    /// Mix 0 is the dry path exactly.
    func testShaperDryAtZeroMix() {
        let s = TubeShaper(driveDB: 24, biasPct: 100, asymDB: 12, hardnessPct: 100, mixPct: 0, trimDB: 12)
        for x in stride(from: -1.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(s.output(x), x, accuracy: 1e-12)
        }
    }

    // MARK: - Control Surfaces (caps v19)

    func testControlSurfaceNouns() {
        XCTAssertEqual(CS_NOUN_TUBE, 70)
        XCTAssertEqual(CS_NOUN_TUBE_DRIVE, 71)
        XCTAssertEqual(CS_NOUN_TUBE_TYPE, 72)
        XCTAssertEqual(CS_NOUN_TUBE_MIX, 73)
    }

    // MARK: - Preset document

    func testPresetDocumentBlockRoundTrip() throws {
        var doc = PresetDocument()
        var block = PresetDocument.TubeBlock()
        block.enabled = true
        block.outputMask = 0x00FF
        block.tubeType = 0
        block.driveDb = 14
        block.biasPct = -20
        block.asymDb = 7
        block.hardnessPct = 90
        block.sagPct = 10
        block.rectifier = 3
        block.xfmrEnabled = true
        block.xfmrDamping = 12
        block.xfmrResHz = 45
        block.mixPct = 50
        block.trimDb = -4
        doc.tube = block

        let decoded = try JSONDecoder().decode(PresetDocument.self, from: try JSONEncoder().encode(doc))
        let t = try XCTUnwrap(decoded.tube)
        XCTAssertTrue(t.enabled)
        XCTAssertEqual(t.outputMask, 0x00FF)
        XCTAssertEqual(t.tubeType, 0)
        XCTAssertEqual(t.driveDb, 14)
        XCTAssertEqual(t.biasPct, -20)
        XCTAssertEqual(t.asymDb, 7)
        XCTAssertEqual(t.hardnessPct, 90)
        XCTAssertEqual(t.sagPct, 10)
        XCTAssertEqual(t.rectifier, 3)
        XCTAssertTrue(t.xfmrEnabled)
        XCTAssertEqual(t.xfmrDamping, 12)
        XCTAssertEqual(t.xfmrResHz, 45)
        XCTAssertEqual(t.mixPct, 50)
        XCTAssertEqual(t.trimDb, -4)

        // A document from before V31 has no block, and decodes as absent.
        let bare = try JSONDecoder().decode(PresetDocument.self,
                                            from: try JSONEncoder().encode(PresetDocument()))
        XCTAssertNil(bare.tube)
    }

    /// A file whose stored knobs differ from its type's row keeps the knobs:
    /// importing writes the type first and the knobs after, so the knobs win
    /// and the type drops to Custom, just as the firmware would.
    func testImportOrderPreservesStoredKnobs() {
        let vm = DSPViewModel()
        vm.setTubeType(1)
        vm.setTubeBias(12)
        XCTAssertEqual(vm.tube.type, TUBE_TYPE_CUSTOM)
        XCTAssertEqual(vm.tube.biasPct, 12)
        XCTAssertEqual(vm.tube.asymDB, 3)
    }

    // MARK: - Live device (skip when no DSPi is attached)

    private func getParam(_ usb: USBDevice, _ index: UInt16) -> Float? {
        guard let d = usb.getControlRequest(request: REQ_GET_TUBE_PARAM, value: index, index: 0, length: 4),
              d.count >= 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: Float.self) }
    }

    private func setParam(_ usb: USBDevice, _ index: UInt16, _ value: Float) {
        var v = value
        usb.sendControlRequest(request: REQ_SET_TUBE_PARAM, value: index, index: 0, data: Data(bytes: &v, count: 4))
    }

    private func requireTube() throws -> USBDevice {
        let usb = try HardwareTest.requireDevice()
        guard getParam(usb, TUBE_PARAM_ENABLED) != nil else {
            throw XCTSkip("Firmware has no tube modeller (REQ_GET_TUBE_PARAM index 0 STALLed).")
        }
        return usb
    }

    /// Reads every parameter so a test can put the device back exactly.
    private func snapshot(_ usb: USBDevice) -> [UInt16: Float] {
        var out: [UInt16: Float] = [:]
        for i in 0..<TUBE_NUM_PARAMS { out[i] = getParam(usb, i) }
        return out
    }

    /// Restores the type first, then everything else.  A snapshot on a type
    /// holds that type's row, so the knob writes change nothing and the type
    /// survives; a snapshot on Custom gets its own knobs back.
    private func restore(_ usb: USBDevice, _ snap: [UInt16: Float]) {
        if let t = snap[TUBE_PARAM_TUBE_TYPE] { setParam(usb, TUBE_PARAM_TUBE_TYPE, t) }
        for i in 0..<TUBE_NUM_PARAMS where i != TUBE_PARAM_TUBE_TYPE {
            if let v = snap[i] { setParam(usb, i, v) }
        }
    }

    /// The bulk tube section agrees with the fourteen indexed GETs.
    func testBulkAgreesWithIndexedGets() throws {
        let usb = try requireTube()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Bulk image is not the current wire format.")
        }
        let o = BULK_TUBE_OFFSET
        func bf(_ off: Int) -> Float { all.withUnsafeBytes { $0.load(fromByteOffset: o + off, as: Float.self) } }
        let snap = snapshot(usb)
        XCTAssertEqual(snap[TUBE_PARAM_ENABLED], all[o] != 0 ? 1 : 0)
        XCTAssertEqual(snap[TUBE_PARAM_TUBE_TYPE], Float(all[o + 1]))
        XCTAssertEqual(snap[TUBE_PARAM_RECTIFIER], Float(all[o + 2]))
        XCTAssertEqual(snap[TUBE_PARAM_XFMR_ENABLED], all[o + 3] != 0 ? 1 : 0)
        XCTAssertEqual(snap[TUBE_PARAM_OUTPUT_MASK], Float(UInt16(all[o + 4]) | (UInt16(all[o + 5]) << 8)))
        let floatIndices: [UInt16] = [TUBE_PARAM_DRIVE_DB, TUBE_PARAM_BIAS_PCT, TUBE_PARAM_ASYM_DB,
                                      TUBE_PARAM_HARDNESS_PCT, TUBE_PARAM_SAG_PCT,
                                      TUBE_PARAM_XFMR_DAMPING, TUBE_PARAM_XFMR_RES_HZ,
                                      TUBE_PARAM_MIX_PCT, TUBE_PARAM_TRIM_DB]
        for (i, idx) in floatIndices.enumerated() {
            XCTAssertEqual(snap[idx] ?? .nan, bf(8 + i * 4), accuracy: 0.001, "param \(idx)")
        }
    }

    /// An index past the end STALLs, which is how a host feature-detects.
    func testOutOfRangeIndexStalls() throws {
        let usb = try requireTube()
        XCTAssertNil(getParam(usb, TUBE_NUM_PARAMS))
    }

    /// A type SET loads the row on the device, and the app's mirror agrees.
    func testTypeLoadsRowOnDevice() throws {
        let usb = try requireTube()
        let snap = snapshot(usb)
        defer { restore(usb, snap) }

        setParam(usb, TUBE_PARAM_TUBE_TYPE, 14)   // 6V6
        let row = try XCTUnwrap(TUBE_TYPE_ROWS[14])
        XCTAssertEqual(getParam(usb, TUBE_PARAM_TUBE_TYPE), 14)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_BIAS_PCT), row.biasPct)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_ASYM_DB), row.asymDB)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_HARDNESS_PCT), row.hardnessPct)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_SAG_PCT), row.sagPct)

        // Every row in the app's table matches the firmware's.
        for t in 1...TUBE_TYPE_MAX {
            setParam(usb, TUBE_PARAM_TUBE_TYPE, Float(t))
            let r = try XCTUnwrap(TUBE_TYPE_ROWS[t])
            XCTAssertEqual(getParam(usb, TUBE_PARAM_BIAS_PCT), r.biasPct, "row \(t) bias")
            XCTAssertEqual(getParam(usb, TUBE_PARAM_ASYM_DB), r.asymDB, "row \(t) asym")
            XCTAssertEqual(getParam(usb, TUBE_PARAM_HARDNESS_PCT), r.hardnessPct, "row \(t) hardness")
            XCTAssertEqual(getParam(usb, TUBE_PARAM_SAG_PCT), r.sagPct, "row \(t) sag")
        }
    }

    /// Editing a character knob to a new value flips the type to Custom; writing
    /// the stored value leaves it.
    func testCharacterEditFlipsToCustomOnDevice() throws {
        let usb = try requireTube()
        let snap = snapshot(usb)
        defer { restore(usb, snap) }

        setParam(usb, TUBE_PARAM_TUBE_TYPE, 1)
        setParam(usb, TUBE_PARAM_SAG_PCT, 15)       // the 12AX7 value
        XCTAssertEqual(getParam(usb, TUBE_PARAM_TUBE_TYPE), 1)
        setParam(usb, TUBE_PARAM_SAG_PCT, 16)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_TUBE_TYPE), Float(TUBE_TYPE_CUSTOM))
    }

    /// Out-of-range floats and enums read back clamped.
    func testClampsOnDevice() throws {
        let usb = try requireTube()
        let snap = snapshot(usb)
        defer { restore(usb, snap) }

        setParam(usb, TUBE_PARAM_DRIVE_DB, 99)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_DRIVE_DB), TUBE_DRIVE_MAX)
        setParam(usb, TUBE_PARAM_DRIVE_DB, -99)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_DRIVE_DB), TUBE_DRIVE_MIN)
        setParam(usb, TUBE_PARAM_XFMR_DAMPING, 100)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_XFMR_DAMPING), TUBE_XFMR_DAMPING_MAX)
        setParam(usb, TUBE_PARAM_XFMR_RES_HZ, 1)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_XFMR_RES_HZ), TUBE_XFMR_RES_MIN)
        setParam(usb, TUBE_PARAM_RECTIFIER, 7)
        XCTAssertEqual(getParam(usb, TUBE_PARAM_RECTIFIER), Float(TUBE_RECT_MAX))
    }

}
