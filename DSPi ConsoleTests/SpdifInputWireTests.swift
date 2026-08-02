import XCTest
@testable import DSPi_Console

/// Wire-format and mapping tests for the multiple selectable S/PDIF inputs
/// (SPDIF_input_spec.md §2 "Multiple SPDIF Inputs").  Firmware v1.1.5 shipped
/// three inputs; wire V28 raised the maximum to four.  The pure-logic tests need
/// no device; the live-device tests SKIP (never fail) when no DSPi is attached.
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
        vm.spdifExtEnabled = Array(repeating: false, count: SPDIF_RX_NUM_INPUTS - 1)
        vm.inputSource = INPUT_SOURCE_USB
    }

    // MARK: - Constants (spec §1 / §4)

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_SPDIF_RX_PIN, 0xE4)
        XCTAssertEqual(REQ_GET_SPDIF_RX_PIN, 0xE5)
        XCTAssertEqual(REQ_SET_SPDIF_INPUT_ENABLE, 0xE9)
        XCTAssertEqual(REQ_GET_SPDIF_INPUT_CONFIG, 0xEF)
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

    /// V28 grew WireInputConfig.spdif_rx_pin_ext from 2 to 3 entries, consuming
    /// the section's last reserved byte and pushing the fields below it down one.
    /// The section stays 16 bytes, so no later section moved.
    func testWireInputConfigLayout() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 28)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5944)
        // +8/+9/+10 optional pins, +11 enable mask, +12 I2S clock mode,
        // +13/+14/+15 the ADAT input trio - exactly filling the 16-byte section.
        XCTAssertEqual(BULK_INPUT_I2S_CLOCK_MODE_OFFSET, BULK_INPUT_CONFIG_OFFSET + 12)
        XCTAssertEqual(BULK_INPUT_ADAT_PIN_OFFSET, BULK_INPUT_CONFIG_OFFSET + 13)
        XCTAssertEqual(BULK_INPUT_ADAT_ENABLED_P1_OFFSET, BULK_INPUT_CONFIG_OFFSET + 14)
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
        XCTAssertEqual(vm.inputSourceTitle(INPUT_SOURCE_SPDIF4), "S/PDIF 4")
        // Input 1 drops its number until an optional input is on.
        XCTAssertEqual(vm.inputSourceTitle(INPUT_SOURCE_SPDIF), "S/PDIF")
        vm.spdifExtEnabled = [false, false, true]
        XCTAssertEqual(vm.inputSourceTitle(INPUT_SOURCE_SPDIF), "S/PDIF 1")
        // Every S/PDIF input is stereo regardless of which one is selected.
        vm.inputSource = INPUT_SOURCE_SPDIF4
        XCTAssertEqual(vm.effectiveInputChannels, BASE_MATRIX_INPUTS)
    }

    /// The count selector shows every row up to the highest enabled input, so a
    /// non-consecutive enable state (only input 4 on) still reports 4.
    func testEnabledCountTracksHighestEnabled() {
        vm.spdifInputCount = SPDIF_RX_NUM_INPUTS
        vm.spdifExtEnabled = [false, false, false]
        XCTAssertEqual(vm.spdifEnabledCount, 1)
        vm.spdifExtEnabled = [true, false, false]
        XCTAssertEqual(vm.spdifEnabledCount, 2)
        vm.spdifExtEnabled = [false, false, true]
        XCTAssertEqual(vm.spdifEnabledCount, 4)
        // A three-input device never reports 4 even if the stale fourth bit is set.
        vm.spdifInputCount = 3
        XCTAssertEqual(vm.spdifEnabledCount, 1)
    }

    /// Only enabled optional inputs are offered as sources - a disabled one is
    /// rejected by the firmware's input_source_selectable().
    func testSourceOptionsFollowEnableState() {
        vm.multiSpdifSupported = true
        vm.spdifInputCount = SPDIF_RX_NUM_INPUTS
        vm.spdifExtEnabled = [true, false, true]
        let opts = vm.inputSourceOptions
        XCTAssertEqual(opts.prefix(4).map { $0 },
                       [INPUT_SOURCE_USB, INPUT_SOURCE_SPDIF, INPUT_SOURCE_SPDIF2, INPUT_SOURCE_SPDIF4])
        XCTAssertFalse(opts.contains(INPUT_SOURCE_SPDIF3))
    }

    // MARK: - Live device (spec §4.8)

    /// REQ_GET_SPDIF_INPUT_CONFIG returns 2 + count bytes: count, an enable mask
    /// whose bit 0 is hard-set (input 1 is never disableable), then one GPIO per
    /// input.  Cross-checked against per-index REQ_GET_SPDIF_RX_PIN reads, which
    /// is an independent path - a shared decode bug can't make this pass.
    func testLiveInventoryMatchesPerIndexPins() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_SPDIF_INPUT_CONFIG, value: 0,
                                            index: 2, length: UInt16(2 + SPDIF_RX_NUM_INPUTS)),
              d.count >= 3 else {
            throw XCTSkip("Firmware predates the multiple-S/PDIF feature (0xEF STALLs).")
        }
        let count = Int(d[0])
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, SPDIF_RX_NUM_INPUTS)
        XCTAssertEqual(d.count, 2 + count, "response is 2 + count bytes")
        XCTAssertEqual(d[1] & 0x01, 0x01, "input 1 is always enabled")

        for idx in 0..<count {
            guard let p = usb.getControlRequest(request: REQ_GET_SPDIF_RX_PIN,
                                                value: UInt16(idx), index: 2, length: 1),
                  p.count >= 1 else {
                XCTFail("0xE5 index \(idx) returned nothing")
                continue
            }
            XCTAssertEqual(p[0], d[2 + idx], "0xEF pin \(idx) disagrees with 0xE5")
        }
        // Out-of-range indices report 0 rather than stalling or aliasing.
        if let p = usb.getControlRequest(request: REQ_GET_SPDIF_RX_PIN,
                                         value: UInt16(SPDIF_RX_NUM_INPUTS), index: 2, length: 1),
           p.count >= 1 {
            XCTAssertEqual(p[0], 0, "index past the inventory should read back 0")
        }
    }

    /// The app's own parse of 0xEF must agree with the raw bytes, and must keep
    /// the ext arrays full-length even when the device reports only three inputs.
    func testLiveFetchPopulatesViewModel() throws {
        let usb = try HardwareTest.requireDevice()
        vm.fetchSpdifInputConfig()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        try XCTSkipUnless(vm.multiSpdifSupported,
                          "Firmware predates the multiple-S/PDIF feature (0xEF STALLs).")

        guard let d = usb.getControlRequest(request: REQ_GET_SPDIF_INPUT_CONFIG, value: 0,
                                            index: 2, length: UInt16(2 + SPDIF_RX_NUM_INPUTS)),
              d.count >= 3 else {
            return XCTFail("0xEF returned nothing on the confirmation read")
        }
        XCTAssertEqual(vm.spdifInputCount, Int(d[0]))
        XCTAssertEqual(vm.spdifRxPinsExt.count, SPDIF_RX_NUM_INPUTS - 1)
        XCTAssertEqual(vm.spdifExtEnabled.count, SPDIF_RX_NUM_INPUTS - 1)
        for idx in 0..<Int(d[0]) {
            XCTAssertEqual(vm.spdifPin(index: idx), d[2 + idx])
            XCTAssertEqual(vm.spdifInputEnabled(index: idx), (d[1] & (1 << UInt8(idx))) != 0)
        }
    }
}
