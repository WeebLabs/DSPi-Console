import XCTest
@testable import DSPi_Console

/// Wire-format and mapping tests for the S/PDIF input block (firmware
/// input_enable_plan.md): a switch plus a count of 1..4 inputs, with the I2S and
/// ADAT switches alongside in one wire mask (V34).  The pure-logic tests need no
/// device; the live-device tests SKIP (never fail) when no DSPi is attached.
final class SpdifInputWireTests: XCTestCase {

    /// One view model for the whole class.  Constructing a DSPViewModel starts a
    /// 60 ms status poller against the shared USB transport that lives for the
    /// rest of the process, so a per-test instance would pile up pollers and
    /// starve the live control transfers below.
    private static let sharedVM = DSPViewModel()
    private var vm: DSPViewModel { Self.sharedVM }

    /// Sharing one instance means each test must start from a known S/PDIF state
    /// rather than inherit the previous test's (or a live device's) enable mask.
    override func setUp() {
        super.setUp()
        vm.multiSpdifSupported = false
        vm.spdifInputCount = 1
        vm.spdifRxPinsExt = Array(SPDIF_RX_PIN_DEFAULTS.dropFirst())
        vm.spdifRxEnabled = true
        vm.spdifRxCount = 1
        vm.i2sInputSupported = false
        vm.i2sInputEnabled = false
        vm.adatInputSupported = false
        vm.adatInputEnabled = false
        vm.inputSource = INPUT_SOURCE_USB
    }

    // MARK: - Constants (paged INPUT commands, firmware 1.1.7)

    func testRequestCodes() {
        XCTAssertEqual(VC.INPUT.SPDIF_RX_PIN.id, 0x0322)
        XCTAssertEqual(VC.INPUT.SPDIF_RX_CONFIG.id, 0x0324)
        XCTAssertEqual(VC.INPUT.SPDIF_RX_COUNT.id, 0x0326)
        XCTAssertEqual(VC.INPUT.SPDIF_RX_ENABLE.id, 0x0327)
        XCTAssertEqual(VC.INPUT.I2S_RX_ENABLE.id, 0x0334)
        // The block switches and count take no address; the old per-input
        // enable at 0x0323 is retired.
        for cmd in [VC.INPUT.SPDIF_RX_ENABLE, VC.INPUT.SPDIF_RX_COUNT, VC.INPUT.I2S_RX_ENABLE] {
            XCTAssertEqual(VendorCommandRegistry.info(for: cmd)?.address, VendorAddressKind.none)
        }
        XCTAssertNil(VendorCommandRegistry.info(for: VendorCommand(0x0323)))
        XCTAssertEqual(VendorCommandRegistry.info(for: VC.INPUT.SPDIF_RX_CONFIG)?.getLength, .fixed(7))
    }

    /// The optional sources are contiguous from INPUT_SOURCE_SPDIF2, which is
    /// what lets the index<->source mapping be arithmetic (the firmware holds
    /// the same layout with a _Static_assert in audio_input.h).
    func testInputSourceEnum() {
        XCTAssertEqual(INPUT_SOURCE_USB, 0)
        XCTAssertEqual(INPUT_SOURCE_SPDIF, 1)
        XCTAssertEqual(INPUT_SOURCE_I2S, 2)
        XCTAssertEqual(INPUT_SOURCE_ADAT, 3)
        XCTAssertEqual(INPUT_SOURCE_SPDIF2, 4)
        XCTAssertEqual(INPUT_SOURCE_SPDIF3, 5)
        XCTAssertEqual(INPUT_SOURCE_SPDIF4, 6)
        XCTAssertEqual(INPUT_SOURCE_SPDIF4 - INPUT_SOURCE_SPDIF2, SPDIF_RX_NUM_INPUTS - 2)
    }

    func testInventoryDefaults() {
        XCTAssertEqual(SPDIF_RX_NUM_INPUTS, 4)
        XCTAssertEqual(SPDIF_RX_PIN_DEFAULTS, [5, 20, 21, 22])
    }

    /// V34 reuses two WireInputConfig bytes: +11 becomes the S/PDIF block count
    /// and +14 the input block switch mask plus one.  The section stays 16 bytes.
    func testWireInputConfigLayout() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 34)
        XCTAssertEqual(BULK_PARAMS_SIZE, 6136)
        // +8/+9/+10 optional pins, +11 S/PDIF count, +12 I2S clock mode, +13 ADAT
        // pin, +14 block switches, +15 ADAT clock mode - filling the section.
        XCTAssertEqual(BULK_INPUT_SPDIF_RX_COUNT_OFFSET, BULK_INPUT_CONFIG_OFFSET + 11)
        XCTAssertEqual(BULK_INPUT_I2S_CLOCK_MODE_OFFSET, BULK_INPUT_CONFIG_OFFSET + 12)
        XCTAssertEqual(BULK_INPUT_ADAT_PIN_OFFSET, BULK_INPUT_CONFIG_OFFSET + 13)
        XCTAssertEqual(BULK_INPUT_ENABLE_P1_OFFSET, BULK_INPUT_CONFIG_OFFSET + 14)
        XCTAssertEqual([INPUT_ENABLE_SPDIF, INPUT_ENABLE_I2S, INPUT_ENABLE_ADAT], [0x01, 0x02, 0x04])
        XCTAssertEqual(BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET, BULK_INPUT_CONFIG_OFFSET + 15)
        // The section is full: the next section starts right after byte +15.
        XCTAssertEqual(BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET + 1, BULK_LG_OFFSET)
    }

    // MARK: - Index <-> source mapping

    func testIndexSourceRoundTrip() {
        for idx in 0..<SPDIF_RX_NUM_INPUTS {
            XCTAssertEqual(vm.spdifIndex(forSource: vm.spdifSource(forIndex: idx)), idx)
        }
        XCTAssertEqual(vm.spdifSource(forIndex: 0), INPUT_SOURCE_SPDIF)
        XCTAssertEqual(vm.spdifSource(forIndex: 3), INPUT_SOURCE_SPDIF4)
        // Non-S/PDIF sources map to nil, including the ADAT value wedged into
        // the middle of the enum.
        XCTAssertNil(vm.spdifIndex(forSource: INPUT_SOURCE_USB))
        XCTAssertNil(vm.spdifIndex(forSource: INPUT_SOURCE_I2S))
        XCTAssertNil(vm.spdifIndex(forSource: INPUT_SOURCE_ADAT))
        XCTAssertNil(vm.spdifIndex(forSource: INPUT_SOURCE_SPDIF4 + 1))
    }

    func testTitlesAndStereoLayout() {
        // The built-in titles: a connected board's own source names (which
        // inputSourceTitle prefers) must not decide this test.
        XCTAssertEqual(vm.builtInInputSourceTitle(INPUT_SOURCE_SPDIF4), "S/PDIF 4")
        // Input 1 drops its number while the block holds only one input.
        XCTAssertEqual(vm.builtInInputSourceTitle(INPUT_SOURCE_SPDIF), "S/PDIF")
        vm.spdifRxCount = 4
        XCTAssertEqual(vm.builtInInputSourceTitle(INPUT_SOURCE_SPDIF), "S/PDIF 1")
        // Every S/PDIF input is stereo regardless of which one is selected.
        vm.inputSource = INPUT_SOURCE_SPDIF4
        XCTAssertEqual(vm.effectiveInputChannels, BASE_MATRIX_INPUTS)
    }

    /// An input is in the block when the block is on and its index is within
    /// the count; the count is remembered while the block is off.
    func testInputInBlockFollowsSwitchAndCount() {
        vm.spdifRxCount = 3
        XCTAssertTrue(vm.spdifInputEnabled(index: 0))
        XCTAssertTrue(vm.spdifInputEnabled(index: 2))
        XCTAssertFalse(vm.spdifInputEnabled(index: 3))
        vm.spdifRxEnabled = false
        XCTAssertFalse(vm.spdifInputEnabled(index: 0), "a block that is off holds no input, input 1 included")
        XCTAssertEqual(vm.spdifRxCount, 3)
    }

    /// Only sources whose block is on (and, for S/PDIF, within the count) are
    /// offered - the firmware refuses the rest with VC_ERR_STATE.  The live
    /// source stays listed so the picker always shows what is playing.
    func testSourceOptionsFollowBlocks() {
        vm.multiSpdifSupported = true
        vm.spdifInputCount = SPDIF_RX_NUM_INPUTS
        vm.spdifRxCount = 2
        vm.i2sInputSupported = true
        XCTAssertEqual(vm.inputSourceOptions, [INPUT_SOURCE_USB, INPUT_SOURCE_SPDIF, INPUT_SOURCE_SPDIF2])
        vm.i2sInputEnabled = true
        XCTAssertEqual(vm.inputSourceOptions.last, INPUT_SOURCE_I2S)
        vm.spdifRxEnabled = false
        XCTAssertEqual(vm.inputSourceOptions, [INPUT_SOURCE_USB, INPUT_SOURCE_I2S])
        vm.inputSource = INPUT_SOURCE_SPDIF2
        XCTAssertEqual(vm.inputSourceOptions, [INPUT_SOURCE_USB, INPUT_SOURCE_SPDIF2, INPUT_SOURCE_I2S])
        // A count past the device's own limit never offers inputs it lacks.
        vm.inputSource = INPUT_SOURCE_USB
        vm.spdifRxEnabled = true
        vm.spdifInputCount = 3
        vm.spdifRxCount = 4
        XCTAssertFalse(vm.inputSourceOptions.contains(INPUT_SOURCE_SPDIF4))
    }

    /// Source names cover every source the board has, whatever its block says.
    func testAllSourcesIgnoreBlocks() {
        vm.multiSpdifSupported = true
        vm.spdifInputCount = 3
        vm.spdifRxEnabled = false
        vm.i2sInputSupported = true
        XCTAssertEqual(vm.allInputSources,
                       [INPUT_SOURCE_USB, INPUT_SOURCE_SPDIF, INPUT_SOURCE_SPDIF2, INPUT_SOURCE_SPDIF3, INPUT_SOURCE_I2S])
        XCTAssertFalse(vm.inputSourceSelectable(INPUT_SOURCE_I2S))
        XCTAssertFalse(vm.inputSourceSelectable(INPUT_SOURCE_SPDIF))
        XCTAssertTrue(vm.inputSourceSelectable(INPUT_SOURCE_USB))
    }

    /// PARAM_CHANGED on the switch mask updates all three blocks; on the count
    /// byte, the S/PDIF count.  Zero is "absent" on both and changes nothing.
    func testNotifiedBlockChanges() {
        vm.adatInputSupported = true
        let maskOff = UInt16(BULK_INPUT_ENABLE_P1_OFFSET)
        vm.applyNotifiedParamChange(offset: maskOff, size: 1,
                                    payload: Data([(INPUT_ENABLE_I2S | INPUT_ENABLE_ADAT) + 1]))
        XCTAssertFalse(vm.spdifRxEnabled)
        XCTAssertTrue(vm.i2sInputEnabled)
        XCTAssertTrue(vm.adatInputEnabled)
        vm.applyNotifiedParamChange(offset: maskOff, size: 1, payload: Data([0]))
        XCTAssertTrue(vm.i2sInputEnabled, "0 is absent, not all off")
        vm.applyNotifiedParamChange(offset: maskOff, size: 1, payload: Data([INPUT_ENABLE_SPDIF + 1]))
        XCTAssertTrue(vm.spdifRxEnabled)
        XCTAssertFalse(vm.i2sInputEnabled)
        XCTAssertFalse(vm.adatInputEnabled)

        let countOff = UInt16(BULK_INPUT_SPDIF_RX_COUNT_OFFSET)
        vm.applyNotifiedParamChange(offset: countOff, size: 1, payload: Data([3]))
        XCTAssertEqual(vm.spdifRxCount, 3)
        vm.applyNotifiedParamChange(offset: countOff, size: 1, payload: Data([0]))
        XCTAssertEqual(vm.spdifRxCount, 3)
    }

    // MARK: - Live device (spec §4.8)

    /// INPUT.SPDIF_RX_CONFIG returns 3 + limit bytes: the build's input limit,
    /// the block switch, the block count, then one GPIO per input.  Cross-checked
    /// against the per-command GETs, an independent path, so a shared decode bug
    /// can't make this pass.
    func testLiveInventoryMatchesPerIndexPins() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getData(VC.INPUT.SPDIF_RX_CONFIG, length: UInt16(3 + SPDIF_RX_NUM_INPUTS)),
              d.count >= 4, d.count == 3 + Int(d[0]) else {
            throw XCTSkip("INPUT.SPDIF_RX_CONFIG refused or not the 1.1.7 input-block layout (firmware older than the input blocks).")
        }
        let limit = Int(d[0])
        XCTAssertGreaterThanOrEqual(limit, 1)
        XCTAssertLessThanOrEqual(limit, SPDIF_RX_NUM_INPUTS)
        XCTAssertEqual(usb.getData(VC.INPUT.SPDIF_RX_ENABLE, length: 1)?.first, d[1])
        XCTAssertEqual(usb.getData(VC.INPUT.SPDIF_RX_COUNT, length: 1)?.first, d[2])
        XCTAssertTrue((1...limit).contains(Int(d[2])), "count within 1..limit")

        for idx in 0..<limit {
            guard let p = usb.getData(VC.INPUT.SPDIF_RX_PIN, value: UInt16(idx), length: 1),
                  p.count >= 1 else {
                XCTFail("SPDIF_RX_PIN index \(idx) returned nothing")
                continue
            }
            XCTAssertEqual(p[0], d[3 + idx], "SPDIF_RX_CONFIG pin \(idx) disagrees with SPDIF_RX_PIN")
        }
    }

    /// The app's own parse of SPDIF_RX_CONFIG must agree with the raw bytes.
    func testLiveFetchPopulatesViewModel() throws {
        let usb = try HardwareTest.requireDevice()
        vm.fetchSpdifInputConfig()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        try XCTSkipUnless(vm.multiSpdifSupported, "INPUT.SPDIF_RX_CONFIG refused or short.")

        guard let d = usb.getData(VC.INPUT.SPDIF_RX_CONFIG, length: UInt16(3 + SPDIF_RX_NUM_INPUTS)),
              d.count >= 4 else {
            return XCTFail("SPDIF_RX_CONFIG returned nothing on the confirmation read")
        }
        try XCTSkipUnless(d.count == 3 + Int(d[0]), "Firmware older than the input blocks.")
        XCTAssertEqual(vm.spdifInputCount, Int(d[0]))
        XCTAssertEqual(vm.spdifRxEnabled, d[1] != 0)
        XCTAssertEqual(vm.spdifRxCount, Int(d[2]))
        XCTAssertEqual(vm.spdifRxPinsExt.count, SPDIF_RX_NUM_INPUTS - 1)
        for idx in 0..<Int(d[0]) {
            XCTAssertEqual(vm.spdifPin(index: idx), d[3 + idx])
            XCTAssertEqual(vm.spdifInputEnabled(index: idx), d[1] != 0 && idx < Int(d[2]))
        }
    }
}
