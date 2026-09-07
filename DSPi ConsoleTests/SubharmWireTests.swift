import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the Subharmonic Synthesizer
/// (subharmonic_synth_spec.md).  The pure-logic tests need no device; the
/// live-device tests SKIP (never fail) when no DSPi is attached.
final class SubharmWireTests: XCTestCase {

    // MARK: - Constants (spec §3 command summary)

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_SUBHARM, 0x10)
        XCTAssertEqual(REQ_GET_SUBHARM, 0x11)
        XCTAssertEqual(REQ_SET_SUBHARM_LOW, 0x12)
        XCTAssertEqual(REQ_GET_SUBHARM_LOW, 0x13)
        XCTAssertEqual(REQ_SET_SUBHARM_HIGH, 0x14)
        XCTAssertEqual(REQ_GET_SUBHARM_HIGH, 0x15)
        XCTAssertEqual(REQ_SET_SUBHARM_BOOST, 0x16)
        XCTAssertEqual(REQ_GET_SUBHARM_BOOST, 0x17)
        XCTAssertEqual(REQ_SET_SUBHARM_MASK, 0x18)
        XCTAssertEqual(REQ_GET_SUBHARM_MASK, 0x19)
        XCTAssertEqual(REQ_GET_SUBHARM_HEADROOM, 0x1A)
        XCTAssertEqual(SUBHARM_DEFAULT_OUTPUT_MASK, 0xFFFF)
    }

    /// V30 spread the block over three ranges (spec §3): the rest of 0x10-0x1F,
    /// then 0x2C-0x2F and 0xA9-0xAE.
    func testExtendedRequestCodes() {
        XCTAssertEqual(REQ_SET_SUBHARM_TOP, 0x1B)
        XCTAssertEqual(REQ_GET_SUBHARM_TOP, 0x1C)
        XCTAssertEqual(REQ_SET_SUBHARM_SELECT, 0x1D)
        XCTAssertEqual(REQ_GET_SUBHARM_SELECT, 0x1E)
        XCTAssertEqual(REQ_GET_SUBHARM_METER, 0x1F)
        XCTAssertEqual(REQ_SET_SUBHARM_SOLO, 0x2C)
        XCTAssertEqual(REQ_GET_SUBHARM_SOLO, 0x2D)
        XCTAssertEqual(REQ_SET_SUBHARM_LINK, 0x2E)
        XCTAssertEqual(REQ_GET_SUBHARM_LINK, 0x2F)
        XCTAssertEqual(REQ_SET_SUBHARM_DEPTH, 0xA9)
        XCTAssertEqual(REQ_GET_SUBHARM_DEPTH, 0xAA)
        XCTAssertEqual(REQ_SET_SUBHARM_HOLD, 0xAB)
        XCTAssertEqual(REQ_GET_SUBHARM_HOLD, 0xAC)
        XCTAssertEqual(REQ_SET_SUBHARM_CEILING, 0xAD)
        XCTAssertEqual(REQ_GET_SUBHARM_CEILING, 0xAE)
    }

    /// The block must not collide with the siggen codes it sits next to: siggen
    /// keeps 0xA4-0xA8 and subharm took the reserved range above it at V30.
    func testExtendedCodesDoNotCollideWithSiggen() {
        let siggen: Set<UInt8> = [REQ_SIGGEN_SET_CONFIG, REQ_SIGGEN_GET_CONFIG,
                                  REQ_SIGGEN_CONTROL, REQ_SIGGEN_GET_STATUS,
                                  REQ_SIGGEN_GET_CAPS]
        let subharm: Set<UInt8> = [REQ_SET_SUBHARM_DEPTH, REQ_GET_SUBHARM_DEPTH,
                                   REQ_SET_SUBHARM_HOLD, REQ_GET_SUBHARM_HOLD,
                                   REQ_SET_SUBHARM_CEILING, REQ_GET_SUBHARM_CEILING]
        XCTAssertTrue(siggen.isDisjoint(with: subharm))
    }

    /// Parameter ranges the app enforces on commit so its state matches the
    /// firmware's silent clamping without a read-back (spec §2).
    func testParameterRanges() {
        XCTAssertEqual(SUBHARM_LEVEL_MIN, -30.0)
        XCTAssertEqual(SUBHARM_LEVEL_MAX, 12.0)
        XCTAssertEqual(SUBHARM_BOOST_MIN, 0.0)
        XCTAssertEqual(SUBHARM_BOOST_MAX, 6.0)
        XCTAssertEqual(SUBHARM_DEPTH_MIN, 0.0)
        XCTAssertEqual(SUBHARM_DEPTH_MAX, 100.0)
        XCTAssertEqual(SUBHARM_HOLD_MIN_MS, 50.0)
        XCTAssertEqual(SUBHARM_HOLD_MAX_MS, 400.0)
        XCTAssertEqual(SUBHARM_CEILING_MIN, -40.0)
        XCTAssertEqual(SUBHARM_CEILING_MAX, 0.0)
        XCTAssertEqual(SUBHARM_SELECT_ALL, 0)
        XCTAssertEqual(SUBHARM_SELECT_PERCUSSIVE, 1)
        XCTAssertEqual(SUBHARM_SELECT_SUSTAINED, 2)
        XCTAssertEqual(SUBHARM_METER_FULL_SCALE, 32767.0)
    }

    /// V29 appended WireSubharmParams (16 bytes) as the final section at offset
    /// 5944; V30 grew it to 36 by tail-appending, taking the flat layout from
    /// 5960 to 5980 bytes (spec §4).
    func testWireFormatSizing() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 30)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5980)
        XCTAssertEqual(BULK_SUBHARM_OFFSET, 5944)
        XCTAssertEqual(WIRE_SUBHARM_PARAMS_SIZE, 36)
        // It sits immediately after the 44-byte upmixer section (V25).
        XCTAssertEqual(BULK_UPMIX_OFFSET + 44, BULK_SUBHARM_OFFSET)
        // And it is still the last section: 36 bytes take the image to full size.
        XCTAssertEqual(BULK_SUBHARM_OFFSET + WIRE_SUBHARM_PARAMS_SIZE, Int(BULK_PARAMS_SIZE))
    }

    // MARK: - WireSubharmParams field decode (spec §4 table)

    /// Encodes a 36-byte section and decodes it exactly as `fetchAllParams`
    /// does, confirming every field lands at the documented offset.
    func testBulkSectionRoundTrip() {
        var section = Data(count: WIRE_SUBHARM_PARAMS_SIZE)
        section[0] = 0x01                                  // enabled
        section[1] = 0x00                                  // reserved
        section[2] = 0x11; section[3] = 0x01               // output_mask = 0x0111 LE
        func putFloat(_ v: Float, at off: Int) {
            var f = v
            withUnsafeBytes(of: &f) { section.replaceSubrange(off..<off+4, with: $0) }
        }
        putFloat(-6.0,  at: 4)    // low_db
        putFloat(3.5,   at: 8)    // high_db
        putFloat(2.0,   at: 12)   // boost_db
        putFloat(-1.5,  at: 16)   // top_db (V30)
        putFloat(75.0,  at: 20)   // select_depth (V30)
        putFloat(220.0, at: 24)   // select_hold_ms (V30)
        putFloat(-12.0, at: 28)   // ceiling_db (V30)
        section[32] = 0x02                                 // select_mode = sustained
        section[33] = 0x01                                 // link_pairs

        let enabled = section[0] != 0
        let mask = UInt16(section[2]) | (UInt16(section[3]) << 8)
        func f(_ off: Int) -> Float { section.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float.self) } }

        XCTAssertTrue(enabled)
        XCTAssertEqual(mask, 0x0111)
        XCTAssertEqual(f(4), -6.0)
        XCTAssertEqual(f(8), 3.5)
        XCTAssertEqual(f(12), 2.0)
        XCTAssertEqual(f(16), -1.5)
        XCTAssertEqual(f(20), 75.0)
        XCTAssertEqual(f(24), 220.0)
        XCTAssertEqual(f(28), -12.0)
        XCTAssertEqual(Int(section[32]), SUBHARM_SELECT_SUSTAINED)
        XCTAssertTrue(section[33] != 0)
    }

    // MARK: - Feature detection gate (spec §6)

    func testFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 28
        XCTAssertFalse(vm.firmwareSupportsSubharm)
        vm.firmwareWireFormatVersion = 29
        XCTAssertTrue(vm.firmwareSupportsSubharm)
    }

    /// The V30 additions have their own gate: on V29 firmware the third band,
    /// selectivity, ceiling, link and solo commands STALL, so the UI hides them.
    func testExtendedFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 29
        XCTAssertTrue(vm.firmwareSupportsSubharm)
        XCTAssertFalse(vm.firmwareSupportsSubharmExtended)
        vm.firmwareWireFormatVersion = 30
        XCTAssertTrue(vm.firmwareSupportsSubharmExtended)
    }

    /// The mode is a clamp, not a drop: the firmware reads a byte of 7 back as 2,
    /// and the app clamps the same way so its state matches without a read-back.
    func testSelectModeClamps() {
        let vm = DSPViewModel()
        vm.setSubharmSelectMode(7)
        XCTAssertEqual(vm.subharmSelectMode, SUBHARM_SELECT_SUSTAINED)
        vm.setSubharmSelectMode(-3)
        XCTAssertEqual(vm.subharmSelectMode, SUBHARM_SELECT_ALL)
        vm.setSubharmSelectMode(SUBHARM_SELECT_PERCUSSIVE)
        XCTAssertEqual(vm.subharmSelectMode, SUBHARM_SELECT_PERCUSSIVE)
    }

    /// Factory defaults the app starts from, so a fresh device and an
    /// unconnected app agree before the first bulk read (spec §2, §5).
    func testDefaultsMatchTheFirmware() {
        let vm = DSPViewModel()
        XCTAssertFalse(vm.subharmEnabled)
        XCTAssertEqual(vm.subharmLowDB, 0.0)
        XCTAssertEqual(vm.subharmHighDB, 0.0)
        XCTAssertEqual(vm.subharmTopDB, SUBHARM_LEVEL_MIN)   // third band ships off
        XCTAssertEqual(vm.subharmBoostDB, 0.0)
        XCTAssertEqual(vm.subharmSelectMode, SUBHARM_SELECT_ALL)
        XCTAssertEqual(vm.subharmSelectDepthPct, 100.0)
        XCTAssertEqual(vm.subharmSelectHoldMs, 150.0)
        XCTAssertEqual(vm.subharmCeilingDB, 0.0)             // 0 dBFS = ceiling off
        XCTAssertTrue(vm.subharmLinkPairs)
        XCTAssertFalse(vm.subharmSolo)
    }

    /// Both platforms run subharm, unlike the upmixer: the gate must not depend
    /// on the platform name.
    func testSupportedOnBothPlatforms() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 29
        vm.platformName = "RP2040"
        XCTAssertTrue(vm.firmwareSupportsSubharm)
        vm.platformName = "RP2350"
        XCTAssertTrue(vm.firmwareSupportsSubharm)
    }

    // MARK: - Mask bit toggle helper

    func testOutputChannelMaskToggle() {
        let vm = DSPViewModel()
        vm.subharmOutputMask = 0x0000
        vm.setSubharmOutputChannel(0, enabled: true)
        XCTAssertEqual(vm.subharmOutputMask & 0x0001, 0x0001)
        vm.setSubharmOutputChannel(8, enabled: true)   // PDM sub bit on RP2350
        XCTAssertEqual(vm.subharmOutputMask & 0x0100, 0x0100)
        vm.setSubharmOutputChannel(0, enabled: false)
        XCTAssertEqual(vm.subharmOutputMask & 0x0001, 0x0000)
        // Bits outside the 16-bit mask are rejected rather than wrapping.
        let before = vm.subharmOutputMask
        vm.setSubharmOutputChannel(16, enabled: true)
        XCTAssertEqual(vm.subharmOutputMask, before)
    }

    // MARK: - Preset document round-trip

    /// The subharm block survives an encode/decode, and a document written
    /// before V29 (no block) decodes as absent rather than as defaults applied.
    func testPresetDocumentBlockRoundTrip() throws {
        var doc = PresetDocument()
        var block = PresetDocument.SubharmBlock()
        block.enabled = true
        block.lowDb = -6
        block.highDb = 3
        block.topDb = -1.5
        block.boostDb = 4.5
        block.outputMask = 0x0100
        block.selectMode = SUBHARM_SELECT_PERCUSSIVE
        block.selectDepthPct = 60
        block.selectHoldMs = 250
        block.ceilingDb = -9
        block.linkPairs = false
        doc.subharm = block

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(PresetDocument.self, from: data)
        XCTAssertEqual(decoded.subharm?.enabled, true)
        XCTAssertEqual(decoded.subharm?.lowDb, -6)
        XCTAssertEqual(decoded.subharm?.highDb, 3)
        XCTAssertEqual(decoded.subharm?.topDb, -1.5)
        XCTAssertEqual(decoded.subharm?.boostDb, 4.5)
        XCTAssertEqual(decoded.subharm?.outputMask, 0x0100)
        XCTAssertEqual(decoded.subharm?.selectMode, SUBHARM_SELECT_PERCUSSIVE)
        XCTAssertEqual(decoded.subharm?.selectDepthPct, 60)
        XCTAssertEqual(decoded.subharm?.selectHoldMs, 250)
        XCTAssertEqual(decoded.subharm?.ceilingDb, -9)
        XCTAssertEqual(decoded.subharm?.linkPairs, false)

        let bare = try JSONDecoder().decode(PresetDocument.self,
                                            from: try JSONEncoder().encode(PresetDocument()))
        XCTAssertNil(bare.subharm)
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// The bulk subharm section agrees with the five individual GETs, and every
    /// value sits inside its documented range.
    func testSubharmReadbackConsistency() throws {
        let usb = try HardwareTest.requireDevice()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Firmware predates the Subharmonic Synthesizer (wire format < V29).")
        }

        let o = BULK_SUBHARM_OFFSET
        let bulkEnabled = all[o] != 0
        let bulkMask = UInt16(all[o + 2]) | (UInt16(all[o + 3]) << 8)
        let bulkLow: Float = all.withUnsafeBytes { $0.load(fromByteOffset: o + 4, as: Float.self) }
        let bulkHigh: Float = all.withUnsafeBytes { $0.load(fromByteOffset: o + 8, as: Float.self) }
        let bulkBoost: Float = all.withUnsafeBytes { $0.load(fromByteOffset: o + 12, as: Float.self) }

        guard let en = usb.getControlRequest(request: REQ_GET_SUBHARM, value: 0, index: 0, length: 1),
              let mk = usb.getControlRequest(request: REQ_GET_SUBHARM_MASK, value: 0, index: 0, length: 2),
              let lo = usb.getControlRequest(request: REQ_GET_SUBHARM_LOW, value: 0, index: 0, length: 4),
              let hi = usb.getControlRequest(request: REQ_GET_SUBHARM_HIGH, value: 0, index: 0, length: 4),
              let bo = usb.getControlRequest(request: REQ_GET_SUBHARM_BOOST, value: 0, index: 0, length: 4),
              mk.count >= 2, lo.count >= 4, hi.count >= 4, bo.count >= 4 else {
            throw XCTSkip("Subharm individual GETs STALLed.")
        }
        XCTAssertEqual((en.first ?? 0) != 0, bulkEnabled)
        XCTAssertEqual(UInt16(mk[0]) | (UInt16(mk[1]) << 8), bulkMask)
        XCTAssertEqual(lo.withUnsafeBytes { $0.load(as: Float.self) }, bulkLow, accuracy: 0.01)
        XCTAssertEqual(hi.withUnsafeBytes { $0.load(as: Float.self) }, bulkHigh, accuracy: 0.01)
        XCTAssertEqual(bo.withUnsafeBytes { $0.load(as: Float.self) }, bulkBoost, accuracy: 0.01)

        XCTAssertGreaterThanOrEqual(bulkLow, SUBHARM_LEVEL_MIN)
        XCTAssertLessThanOrEqual(bulkLow, SUBHARM_LEVEL_MAX)
        XCTAssertGreaterThanOrEqual(bulkHigh, SUBHARM_LEVEL_MIN)
        XCTAssertLessThanOrEqual(bulkHigh, SUBHARM_LEVEL_MAX)
        XCTAssertGreaterThanOrEqual(bulkBoost, SUBHARM_BOOST_MIN)
        XCTAssertLessThanOrEqual(bulkBoost, SUBHARM_BOOST_MAX)
    }

    /// The V30 tail of the section agrees with its individual GETs and sits
    /// inside the documented ranges (spec §2.7 to §2.12).
    func testExtendedReadbackConsistency() throws {
        let usb = try HardwareTest.requireDevice()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Firmware predates the extended Subharmonic Synthesizer (wire format < V30).")
        }

        let o = BULK_SUBHARM_OFFSET
        func bulkF(_ off: Int) -> Float { all.withUnsafeBytes { $0.load(fromByteOffset: o + off, as: Float.self) } }
        let bulkTop = bulkF(16), bulkDepth = bulkF(20), bulkHold = bulkF(24), bulkCeiling = bulkF(28)
        let bulkMode = Int(all[o + 32])
        let bulkLink = all[o + 33] != 0

        guard let tp = usb.getControlRequest(request: REQ_GET_SUBHARM_TOP, value: 0, index: 0, length: 4),
              let sm = usb.getControlRequest(request: REQ_GET_SUBHARM_SELECT, value: 0, index: 0, length: 1),
              let dp = usb.getControlRequest(request: REQ_GET_SUBHARM_DEPTH, value: 0, index: 0, length: 4),
              let hd = usb.getControlRequest(request: REQ_GET_SUBHARM_HOLD, value: 0, index: 0, length: 4),
              let cl = usb.getControlRequest(request: REQ_GET_SUBHARM_CEILING, value: 0, index: 0, length: 4),
              let lk = usb.getControlRequest(request: REQ_GET_SUBHARM_LINK, value: 0, index: 0, length: 1),
              tp.count >= 4, !sm.isEmpty, dp.count >= 4, hd.count >= 4, cl.count >= 4, !lk.isEmpty else {
            throw XCTSkip("Extended subharm GETs STALLed.")
        }
        XCTAssertEqual(tp.withUnsafeBytes { $0.load(as: Float.self) }, bulkTop, accuracy: 0.01)
        XCTAssertEqual(Int(sm[0]), bulkMode)
        XCTAssertEqual(dp.withUnsafeBytes { $0.load(as: Float.self) }, bulkDepth, accuracy: 0.01)
        XCTAssertEqual(hd.withUnsafeBytes { $0.load(as: Float.self) }, bulkHold, accuracy: 0.01)
        XCTAssertEqual(cl.withUnsafeBytes { $0.load(as: Float.self) }, bulkCeiling, accuracy: 0.01)
        XCTAssertEqual((lk.first ?? 0) != 0, bulkLink)

        XCTAssertGreaterThanOrEqual(bulkTop, SUBHARM_LEVEL_MIN)
        XCTAssertLessThanOrEqual(bulkTop, SUBHARM_LEVEL_MAX)
        XCTAssertGreaterThanOrEqual(bulkDepth, SUBHARM_DEPTH_MIN)
        XCTAssertLessThanOrEqual(bulkDepth, SUBHARM_DEPTH_MAX)
        XCTAssertGreaterThanOrEqual(bulkHold, SUBHARM_HOLD_MIN_MS)
        XCTAssertLessThanOrEqual(bulkHold, SUBHARM_HOLD_MAX_MS)
        XCTAssertGreaterThanOrEqual(bulkCeiling, SUBHARM_CEILING_MIN)
        XCTAssertLessThanOrEqual(bulkCeiling, SUBHARM_CEILING_MAX)
        XCTAssertLessThanOrEqual(bulkMode, SUBHARM_SELECT_SUSTAINED)
    }

    /// The selectivity mode clamps rather than being rejected: a byte of 7 comes
    /// back as 2 (spec §2.8).  Non-destructive - the original is restored.
    func testSelectModeClampsOnDevice() throws {
        let usb = try HardwareTest.requireDevice()
        guard let orig = usb.getControlRequest(request: REQ_GET_SUBHARM_SELECT, value: 0, index: 0, length: 1),
              !orig.isEmpty else {
            throw XCTSkip("Firmware predates the extended Subharmonic Synthesizer.")
        }
        defer {
            var restore = orig[0]
            usb.sendControlRequest(request: REQ_SET_SUBHARM_SELECT, value: 0, index: 0, data: Data(bytes: &restore, count: 1))
        }

        var over: UInt8 = 7
        usb.sendControlRequest(request: REQ_SET_SUBHARM_SELECT, value: 0, index: 0, data: Data(bytes: &over, count: 1))
        guard let back = usb.getControlRequest(request: REQ_GET_SUBHARM_SELECT, value: 0, index: 0, length: 1),
              !back.isEmpty else {
            throw XCTSkip("Subharm select GET STALLed.")
        }
        XCTAssertEqual(Int(back[0]), SUBHARM_SELECT_SUSTAINED,
                       "a mode byte above 2 must clamp to 2, not be dropped")
    }

    /// The sub meter is one uint16 per output channel, all inside 0..32767.
    func testSubMeterShape() throws {
        let usb = try HardwareTest.requireDevice()
        // 9 outputs on RP2350, 5 on RP2040; ask for the larger and accept either.
        guard let d = usb.getControlRequest(request: REQ_GET_SUBHARM_METER, value: 0, index: 0, length: 18),
              d.count >= 10 else {
            throw XCTSkip("Firmware has no subharm sub meter (wire format < V30).")
        }
        XCTAssertEqual(d.count % 2, 0, "the meter is an array of uint16, so its length must be even")
        XCTAssertTrue(d.count == 10 || d.count == 18,
                      "expected 5 or 9 entries, got \(d.count / 2)")
        for i in stride(from: 0, to: d.count, by: 2) {
            let raw = UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
            XCTAssertLessThanOrEqual(raw, 32767, "meter entries share the peaks scale")
        }
    }

    /// The ceiling bounds the synthesized sub, so switching it on can only lower
    /// the reported headroom - never raise it (spec §2.6).
    func testCeilingLowersTheHeadroom() throws {
        let usb = try HardwareTest.requireDevice()

        func headroom() -> Float? {
            guard let d = usb.getControlRequest(request: REQ_GET_SUBHARM_HEADROOM, value: 0, index: 0, length: 4),
                  d.count >= 4 else { return nil }
            return d.withUnsafeBytes { $0.load(as: Float.self) }
        }
        guard let origCeilingData = usb.getControlRequest(request: REQ_GET_SUBHARM_CEILING, value: 0, index: 0, length: 4),
              origCeilingData.count >= 4,
              let origEnabled = usb.getControlRequest(request: REQ_GET_SUBHARM, value: 0, index: 0, length: 1),
              headroom() != nil else {
            throw XCTSkip("Firmware predates the extended Subharmonic Synthesizer.")
        }
        let origCeiling: Float = origCeilingData.withUnsafeBytes { $0.load(as: Float.self) }
        let wasEnabled = (origEnabled.first ?? 0) != 0
        defer {
            var c = origCeiling
            usb.sendControlRequest(request: REQ_SET_SUBHARM_CEILING, value: 0, index: 0, data: Data(bytes: &c, count: 4))
            var en: UInt8 = wasEnabled ? 1 : 0
            usb.sendControlRequest(request: REQ_SET_SUBHARM, value: 0, index: 0, data: Data(bytes: &en, count: 1))
        }

        var on: UInt8 = 1
        usb.sendControlRequest(request: REQ_SET_SUBHARM, value: 0, index: 0, data: Data(bytes: &on, count: 1))
        var noCeiling = SUBHARM_CEILING_MAX
        usb.sendControlRequest(request: REQ_SET_SUBHARM_CEILING, value: 0, index: 0, data: Data(bytes: &noCeiling, count: 4))
        let unlimited = try XCTUnwrap(headroom())

        var tight = SUBHARM_CEILING_MIN
        usb.sendControlRequest(request: REQ_SET_SUBHARM_CEILING, value: 0, index: 0, data: Data(bytes: &tight, count: 4))
        let limited = try XCTUnwrap(headroom())

        XCTAssertLessThanOrEqual(limited, unlimited + 0.001,
                                 "a ceiling caps the sub, so it cannot raise the headroom requirement")
    }

    /// Writing an out-of-range band level and reading it back returns the
    /// clamped value; the original is restored so the test is non-destructive.
    func testLowBandClampsAndRestores() throws {
        let usb = try HardwareTest.requireDevice()
        guard let orig = usb.getControlRequest(request: REQ_GET_SUBHARM_LOW, value: 0, index: 0, length: 4),
              orig.count >= 4 else {
            throw XCTSkip("Firmware predates the Subharmonic Synthesizer.")
        }
        let original: Float = orig.withUnsafeBytes { $0.load(as: Float.self) }
        defer {
            var restore = original
            usb.sendControlRequest(request: REQ_SET_SUBHARM_LOW, value: 0, index: 0, data: Data(bytes: &restore, count: 4))
        }

        var over: Float = 40.0   // well above the +12 dB ceiling
        usb.sendControlRequest(request: REQ_SET_SUBHARM_LOW, value: 0, index: 0, data: Data(bytes: &over, count: 4))
        guard let back = usb.getControlRequest(request: REQ_GET_SUBHARM_LOW, value: 0, index: 0, length: 4),
              back.count >= 4 else {
            throw XCTSkip("Subharm low GET STALLed.")
        }
        let clamped: Float = back.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertLessThanOrEqual(clamped, SUBHARM_LEVEL_MAX,
                                 "firmware must clamp the band level to its -30..+12 dB range")
    }

    /// The headroom reading is derived from live state on every GET, so a SET
    /// followed immediately by a GET must already reflect the new value.  It
    /// reads 0 while the effect is disabled and rises with the boost.
    func testHeadroomTracksConfiguration() throws {
        let usb = try HardwareTest.requireDevice()

        func headroom() -> Float? {
            guard let d = usb.getControlRequest(request: REQ_GET_SUBHARM_HEADROOM, value: 0, index: 0, length: 4),
                  d.count >= 4 else { return nil }
            return d.withUnsafeBytes { $0.load(as: Float.self) }
        }
        guard headroom() != nil,
              let origEnabled = usb.getControlRequest(request: REQ_GET_SUBHARM, value: 0, index: 0, length: 1),
              let origBoostData = usb.getControlRequest(request: REQ_GET_SUBHARM_BOOST, value: 0, index: 0, length: 4),
              origBoostData.count >= 4 else {
            throw XCTSkip("Firmware predates the Subharmonic Synthesizer.")
        }
        let wasEnabled = (origEnabled.first ?? 0) != 0
        let origBoost: Float = origBoostData.withUnsafeBytes { $0.load(as: Float.self) }
        defer {
            var boost = origBoost
            usb.sendControlRequest(request: REQ_SET_SUBHARM_BOOST, value: 0, index: 0, data: Data(bytes: &boost, count: 4))
            var en: UInt8 = wasEnabled ? 1 : 0
            usb.sendControlRequest(request: REQ_SET_SUBHARM, value: 0, index: 0, data: Data(bytes: &en, count: 1))
        }

        var off: UInt8 = 0
        usb.sendControlRequest(request: REQ_SET_SUBHARM, value: 0, index: 0, data: Data(bytes: &off, count: 1))
        XCTAssertEqual(try XCTUnwrap(headroom()), 0.0, accuracy: 0.001,
                       "headroom must read 0 while the effect is disabled")

        var on: UInt8 = 1
        usb.sendControlRequest(request: REQ_SET_SUBHARM, value: 0, index: 0, data: Data(bytes: &on, count: 1))
        // Start from a known boost so the comparison below is against a floor,
        // not against whatever the device happened to be set to.
        var noBoost = SUBHARM_BOOST_MIN
        usb.sendControlRequest(request: REQ_SET_SUBHARM_BOOST, value: 0, index: 0, data: Data(bytes: &noBoost, count: 4))
        let enabledHeadroom = try XCTUnwrap(headroom())
        XCTAssertGreaterThan(enabledHeadroom, 0.0,
                             "an enabled effect always has some worst-case gain")

        var maxBoost = SUBHARM_BOOST_MAX
        usb.sendControlRequest(request: REQ_SET_SUBHARM_BOOST, value: 0, index: 0, data: Data(bytes: &maxBoost, count: 4))
        let boostedHeadroom = try XCTUnwrap(headroom())
        XCTAssertGreaterThan(boostedHeadroom, enabledHeadroom,
                             "the LF boost adds gain, so it must raise the reported headroom")
    }
}
