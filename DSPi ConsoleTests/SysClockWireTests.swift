import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the selectable system clock / core voltage
/// (Documentation/Features/selectable_sys_clock.md).  The pure-logic tests need
/// no device; the live-device tests SKIP (never fail) when no DSPi is attached
/// and are strictly read-only - nothing here persists a clock change, because a
/// mis-set clock can leave a chip unable to enumerate.
final class SysClockWireTests: XCTestCase {

    // MARK: - Constants (spec §"Vendor interface")

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_SYS_CLOCK, 0x40)
        XCTAssertEqual(REQ_GET_SYS_CLOCK, 0x41)
        // The pair sits directly below the EQ opcodes; an overlap would
        // silently retarget filter writes.
        XCTAssertLessThan(REQ_GET_SYS_CLOCK, REQ_SET_EQ_PARAM)
    }

    func testModeConstants() {
        XCTAssertEqual(SYS_CLOCK_MODE_307P2, 0)
        XCTAssertEqual(SYS_CLOCK_MODE_384, 1)
        XCTAssertEqual(SYS_CLOCK_MODE_480, 2)
        XCTAssertEqual(SYS_CLOCK_MODE_COUNT, 3)
        XCTAssertEqual(SysClockModeInfo.all.count, SYS_CLOCK_MODE_COUNT)
    }

    /// The mode table mirrors firmware `sys_clock_table` in sys_clock.c.  A
    /// drift here would offer the user a mode the firmware doesn't have, or
    /// mislabel the voltage floor and get the SET STALLed.
    func testModeTableMatchesFirmware() {
        let expected: [(mode: UInt8, hz: UInt32, vreg: UInt8)] = [
            (SYS_CLOCK_MODE_307P2, 307_200_000, 12),  // VREG_VOLTAGE_1_15
            (SYS_CLOCK_MODE_384,   384_000_000, 13),  // VREG_VOLTAGE_1_20
            (SYS_CLOCK_MODE_480,   480_000_000, 15),  // VREG_VOLTAGE_1_30
        ]
        for e in expected {
            let info = SysClockModeInfo.info(for: e.mode)
            XCTAssertEqual(info.hz, e.hz)
            XCTAssertEqual(info.defaultVreg, e.vreg)
        }
    }

    func testModeLabels() {
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_307P2).label, "307.2 MHz")
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_384).label, "384 MHz")
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_480).label, "480 MHz")
    }

    /// An out-of-range mode resolves to the stock entry rather than trapping,
    /// so a garbled reply can't crash the settings page.
    func testUnknownModeResolvesToStock() {
        XCTAssertEqual(SysClockModeInfo.info(for: 200).mode, SYS_CLOCK_MODE_307P2)
    }

    // MARK: - Core voltage ladder

    /// Millivolts mirror firmware `vreg_voltage_to_mv`.  The ladder steps
    /// 0.05 V up to 1.40 V and then jumps to 1.50 V - a linear formula would
    /// mislabel the top step as 1.45 V.
    func testVregLadder() {
        XCTAssertEqual(SYS_CLOCK_VREG_MIN, 6)
        XCTAssertEqual(SYS_CLOCK_VREG_MAX, 18)
        XCTAssertEqual(sysClockVregMillivolts(6), 850)
        XCTAssertEqual(sysClockVregMillivolts(12), 1150)   // VREG_VOLTAGE_1_15
        XCTAssertEqual(sysClockVregMillivolts(13), 1200)   // VREG_VOLTAGE_1_20
        XCTAssertEqual(sysClockVregMillivolts(15), 1300)   // VREG_VOLTAGE_1_30
        XCTAssertEqual(sysClockVregMillivolts(16), 1350)   // VREG_VOLTAGE_1_35
        XCTAssertEqual(sysClockVregMillivolts(17), 1400)   // VREG_VOLTAGE_1_40
        XCTAssertEqual(sysClockVregMillivolts(18), 1500)   // VREG_VOLTAGE_1_50, not 1450
        // Off the ladder in both directions, including the 0xFF sentinel.
        XCTAssertNil(sysClockVregMillivolts(5))
        XCTAssertNil(sysClockVregMillivolts(19))
        XCTAssertNil(sysClockVregMillivolts(SYS_CLOCK_VREG_DEFAULT))
    }

    func testVregLabels() {
        XCTAssertEqual(sysClockVregLabel(12), "1.15 V")
        XCTAssertEqual(sysClockVregLabel(15), "1.30 V")
        XCTAssertEqual(sysClockVregLabel(17), "1.40 V")
        XCTAssertEqual(sysClockVregLabel(18), "1.50 V")
        XCTAssertEqual(sysClockVregLabel(SYS_CLOCK_VREG_DEFAULT), "-")
    }

    func testVregDefaultSentinel() {
        XCTAssertEqual(SYS_CLOCK_VREG_DEFAULT, 0xFF)
    }

    /// The ceiling is platform-dependent (firmware `SYS_CLOCK_VREG_CEIL`):
    /// RP2350 unlocks the POWMAN voltage limit to reach 1.50 V, the RP2040
    /// regulator field stops at 1.30 V.  Unknown platforms get the safe one.
    func testVregCeilingPerPlatform() {
        XCTAssertEqual(SYS_CLOCK_VREG_1_30, 15)
        XCTAssertEqual(SYS_CLOCK_VREG_1_50, 18)
        XCTAssertEqual(SysClockModeInfo.vregCeiling(platform: "RP2350"), SYS_CLOCK_VREG_1_50)
        XCTAssertEqual(SysClockModeInfo.vregCeiling(platform: "RP2040"), SYS_CLOCK_VREG_1_30)
        XCTAssertEqual(SysClockModeInfo.vregCeiling(platform: "STM32H723"), SYS_CLOCK_VREG_1_30)
        XCTAssertEqual(SysClockModeInfo.vregCeiling(platform: ""), SYS_CLOCK_VREG_1_30)
    }

    // MARK: - Voltage validation (mirrors firmware sys_clock_vreg_valid)

    /// The knob only trades voltage UP: at or above the mode's default and at
    /// most the platform ceiling.  The firmware STALLs anything else rather
    /// than clamping, so the app must never offer or send it.
    func testAllowedVregsPerMode() {
        let rp2350 = SYS_CLOCK_VREG_1_50
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_307P2).allowedVregs(ceiling: rp2350),
                       [12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_384).allowedVregs(ceiling: rp2350),
                       [13, 14, 15, 16, 17, 18])
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_480).allowedVregs(ceiling: rp2350),
                       [15, 16, 17, 18])

        // RP2040 tops out at 1.30 V, which is already the 480 MHz default -
        // there is nothing above it left to offer.
        let rp2040 = SYS_CLOCK_VREG_1_30
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_307P2).allowedVregs(ceiling: rp2040),
                       [12, 13, 14, 15])
        XCTAssertEqual(SysClockModeInfo.info(for: SYS_CLOCK_MODE_480).allowedVregs(ceiling: rp2040),
                       [15])
    }

    func testAcceptsMirrorsFirmwareValidation() {
        let stock = SysClockModeInfo.info(for: SYS_CLOCK_MODE_307P2)
        let fast = SysClockModeInfo.info(for: SYS_CLOCK_MODE_480)

        // 0xFF ("mode default") is always valid, on either platform.
        XCTAssertTrue(stock.accepts(vregSelection: SYS_CLOCK_VREG_DEFAULT, ceiling: SYS_CLOCK_VREG_1_30))
        XCTAssertTrue(fast.accepts(vregSelection: SYS_CLOCK_VREG_DEFAULT, ceiling: SYS_CLOCK_VREG_1_50))

        // At or above the mode's default, up to the ceiling.
        XCTAssertTrue(stock.accepts(vregSelection: 12, ceiling: SYS_CLOCK_VREG_1_30))
        XCTAssertTrue(stock.accepts(vregSelection: 15, ceiling: SYS_CLOCK_VREG_1_30))
        XCTAssertTrue(fast.accepts(vregSelection: 18, ceiling: SYS_CLOCK_VREG_1_50))

        // Undervolts are rejected outright, per mode.
        XCTAssertFalse(stock.accepts(vregSelection: 11, ceiling: SYS_CLOCK_VREG_1_50))
        XCTAssertFalse(fast.accepts(vregSelection: 14, ceiling: SYS_CLOCK_VREG_1_50))

        // The 1.35 - 1.50 V steps exist only where the platform allows them.
        XCTAssertFalse(stock.accepts(vregSelection: 16, ceiling: SYS_CLOCK_VREG_1_30))
        XCTAssertFalse(stock.accepts(vregSelection: 18, ceiling: SYS_CLOCK_VREG_1_30))
        XCTAssertTrue(stock.accepts(vregSelection: 16, ceiling: SYS_CLOCK_VREG_1_50))

        // Nothing above 1.50 V is offered at all.
        XCTAssertFalse(stock.accepts(vregSelection: 19, ceiling: SYS_CLOCK_VREG_1_50))
    }

    // MARK: - REQ_GET_SYS_CLOCK decode (8 bytes)

    func testStateDecode() {
        // active 480, stored 480, stored vreg 1.30 V raw, live vreg 1.30 V,
        // no fallback.
        let d = Data([2, 2, 15, 15, 0, 0, 0, 0])
        let s = try! XCTUnwrap(SysClockState.fromData(d))
        XCTAssertEqual(s.activeMode, SYS_CLOCK_MODE_480)
        XCTAssertEqual(s.storedMode, SYS_CLOCK_MODE_480)
        XCTAssertEqual(s.storedVregSelection, 15)
        XCTAssertEqual(s.liveVreg, 15)
        XCTAssertFalse(s.fallbackActive)
        XCTAssertFalse(s.isFallenBack)
    }

    /// The 0xFF sentinel survives the round trip unchanged - persisting the
    /// raw selection is what lets a stored setting keep following the mode's
    /// default.
    func testStateDecodePreservesDefaultSentinel() {
        let s = try! XCTUnwrap(SysClockState.fromData(Data([1, 1, 0xFF, 13, 0, 0, 0, 0])))
        XCTAssertEqual(s.storedVregSelection, SYS_CLOCK_VREG_DEFAULT)
        // ...and resolves to the mode's default for display.
        XCTAssertEqual(s.storedVreg, 13)
    }

    /// A stored voltage below the mode's floor (only reachable from a foreign
    /// host or a corrupt directory) resolves to the default, matching
    /// `sys_clock_resolve_vreg`.
    func testStoredVregResolutionRejectsUndervolt() {
        let s = try! XCTUnwrap(SysClockState.fromData(Data([2, 2, 12, 15, 0, 0, 0, 0])))
        XCTAssertEqual(s.storedVregSelection, 12)   // raw value preserved
        XCTAssertEqual(s.storedVreg, 15)            // resolved to the 480 MHz floor
    }

    /// Active and stored differ exactly when a fallback boot is in force.
    func testFallbackDetection() {
        let fellBack = try! XCTUnwrap(SysClockState.fromData(Data([0, 2, 0xFF, 12, 1, 0, 0, 0])))
        XCTAssertTrue(fellBack.fallbackActive)
        XCTAssertTrue(fellBack.isFallenBack)
        XCTAssertEqual(fellBack.activeInfo.label, "307.2 MHz")
        XCTAssertEqual(fellBack.storedInfo.label, "480 MHz")

        // A mismatch without the flag still counts (mid-switch/unconfirmed).
        let mismatch = try! XCTUnwrap(SysClockState.fromData(Data([0, 1, 0xFF, 12, 0, 0, 0, 0])))
        XCTAssertTrue(mismatch.isFallenBack)
    }

    func testStateDecodeShortReturnsNil() {
        XCTAssertNil(SysClockState.fromData(Data([0, 0, 0xFF, 12, 0, 0, 0])))
        XCTAssertNil(SysClockState.fromData(Data()))
    }

    /// An out-of-range mode means we're not talking to this feature - decode
    /// must fail rather than flip `sysClockSupported` on a foreign reply.
    func testStateDecodeRejectsInvalidMode() {
        XCTAssertNil(SysClockState.fromData(Data([3, 0, 0xFF, 12, 0, 0, 0, 0])))
        XCTAssertNil(SysClockState.fromData(Data([0, 9, 0xFF, 12, 0, 0, 0, 0])))
    }

    /// Decoding must be index-safe on a sliced Data (non-zero startIndex).
    func testStateDecodeSlicedData() {
        let padded = Data([0xAA, 0xBB]) + Data([1, 1, 0xFF, 13, 0, 0, 0, 0])
        let sliced = padded.subdata(in: 2..<padded.count)
        let s = try! XCTUnwrap(SysClockState.fromData(sliced))
        XCTAssertEqual(s.activeMode, SYS_CLOCK_MODE_384)
        XCTAssertEqual(s.liveVreg, 13)
    }

    // MARK: - SET payload

    /// The OUT payload is exactly {mode, vreg_sel}; anything else is a short
    /// read the firmware ignores.
    func testSetPayloadShape() {
        let payload = Data([SYS_CLOCK_MODE_384, SYS_CLOCK_VREG_DEFAULT])
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0], 1)
        XCTAssertEqual(payload[1], 0xFF)
    }

    // MARK: - Live-device reads (skip when no DSPi attached; read-only)

    /// REQ_GET_SYS_CLOCK returns a decodable 8-byte reply.
    func testSysClockReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_SYS_CLOCK, value: 0, index: 0, length: 8) else {
            throw XCTSkip("Firmware predates the selectable system clock (0x41 STALLed).")
        }
        XCTAssertEqual(d.count, 8)
        let s = try XCTUnwrap(SysClockState.fromData(d), "0x41 reply did not decode")
        XCTAssertLessThan(s.activeMode, UInt8(SYS_CLOCK_MODE_COUNT))
        XCTAssertLessThan(s.storedMode, UInt8(SYS_CLOCK_MODE_COUNT))
        // Bytes 5..7 are reserved and must be zero.
        XCTAssertEqual(Array(d[5..<8]), [0, 0, 0])
    }

    /// The active mode must agree with the clock the device actually reports
    /// through REQ_GET_STATUS sub-index 13 - the two are independent paths, so
    /// a mismatch means the mode table is wrong.
    func testActiveModeMatchesReportedClock() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_SYS_CLOCK, value: 0, index: 0, length: 8),
              let s = SysClockState.fromData(d) else {
            throw XCTSkip("Firmware predates the selectable system clock.")
        }
        guard let hzData = usb.getControlRequest(request: REQ_GET_STATUS, value: 13, index: 0, length: 4),
              hzData.count == 4 else {
            throw XCTSkip("REQ_GET_STATUS sub-index 13 unavailable.")
        }
        let hz = hzData.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(hz, s.activeInfo.hz,
                       "active mode \(s.activeMode) claims \(s.activeInfo.hz) Hz but the device reports \(hz) Hz")
    }

    /// The live vreg enum must agree with the millivolts reported through
    /// REQ_GET_STATUS sub-index 14 - again two independent paths.
    func testLiveVregMatchesReportedVoltage() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_SYS_CLOCK, value: 0, index: 0, length: 8),
              let s = SysClockState.fromData(d) else {
            throw XCTSkip("Firmware predates the selectable system clock.")
        }
        guard let mvData = usb.getControlRequest(request: REQ_GET_STATUS, value: 14, index: 0, length: 4),
              mvData.count == 4 else {
            throw XCTSkip("REQ_GET_STATUS sub-index 14 unavailable.")
        }
        let mv = Int(mvData.withUnsafeBytes { $0.load(as: UInt32.self) })
        let expected = try XCTUnwrap(sysClockVregMillivolts(s.liveVreg),
                                     "live vreg \(s.liveVreg) is off the 0.85-1.30 V ladder")
        XCTAssertEqual(mv, expected)
    }

    /// A device that isn't in the fallback latch runs exactly what it stores.
    func testStoredAndActiveAgreeWhenNotFallenBack() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_GET_SYS_CLOCK, value: 0, index: 0, length: 8),
              let s = SysClockState.fromData(d) else {
            throw XCTSkip("Firmware predates the selectable system clock.")
        }
        if !s.fallbackActive {
            XCTAssertEqual(s.activeMode, s.storedMode,
                           "no fallback flag, but the device runs mode \(s.activeMode) and stores \(s.storedMode)")
            XCTAssertEqual(s.liveVreg, s.storedVreg)
        }
    }

    /// The app refuses locally anything the firmware would STALL, so an
    /// undervolt never reaches the wire.
    func testViewModelRejectsInvalidCombinationsWithoutSending() throws {
        _ = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel
        // Undervolt, unknown mode, and a step past the top of the ladder are
        // all rejected on either platform.
        XCTAssertEqual(vm.setSysClock(mode: SYS_CLOCK_MODE_480, vregSelection: 12), .invalid)
        XCTAssertEqual(vm.setSysClock(mode: 3, vregSelection: SYS_CLOCK_VREG_DEFAULT), .invalid)
        XCTAssertEqual(vm.setSysClock(mode: SYS_CLOCK_MODE_307P2, vregSelection: 19), .invalid)
        // 1.35 V is RP2350-only.  Only assert the rejecting platform: on
        // RP2350 the call would reach the wire and actually raise the voltage.
        if vm.platformName != "RP2350" {
            XCTAssertEqual(vm.setSysClock(mode: SYS_CLOCK_MODE_307P2, vregSelection: 16), .invalid)
        }
    }
}
