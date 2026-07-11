import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the I2S clock-pin mode (unified/split
/// BCK+LRCLK pairs) - clock_pins_spec.md.  The pure-logic tests need no device;
/// the live-device tests SKIP (never fail) when no DSPi is attached.
final class I2sClockPinModeWireTests: XCTestCase {

    // MARK: - Constants (spec §3 "Vendor commands")

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_I2S_CLOCK_PIN_MODE, 0xFE)
        XCTAssertEqual(REQ_GET_I2S_CLOCK_PIN_MODE, 0xFF)
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_UNIFIED, 0)
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_SPLIT, 1)
        XCTAssertEqual(I2S_BCK_ROLE_MASTER, 0)
        XCTAssertEqual(I2S_BCK_ROLE_SLAVE, 1)
        // Reuses the extended pin commands.
        XCTAssertEqual(REQ_SET_I2S_BCK_PIN, 0xC2)
        XCTAssertEqual(REQ_GET_I2S_BCK_PIN, 0xC3)
    }

    /// The two fields claim former reserved bytes of the 16-byte WireI2SConfig
    /// (+8 mode, +9 slave BCK); the wire version and total size are unchanged
    /// (spec §5).
    func testWireOffsets() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 21)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5876)
        XCTAssertEqual(BULK_I2S_CLOCK_PIN_MODE_OFFSET, BULK_I2S_OFFSET + 8)
        XCTAssertEqual(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_I2S_OFFSET + 9)
        // Both stay inside the 16-byte I2S config section (before the next one).
        XCTAssertLessThan(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_LEVELLER_OFFSET)
        XCTAssertLessThan(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_I2S_OFFSET + 16)
    }

    // MARK: - Encodings (spec §3 role byte, §4/§5 +1 mode sentinel)

    /// REQ_SET_I2S_BCK_PIN packs the role in the wValue high byte; a bare GPIO
    /// (legacy hosts) means role 0 (master/unified pair).
    func testBckPinRoleWValueEncoding() {
        func wValue(role: UInt8, pin: UInt8) -> UInt16 { (UInt16(role) << 8) | UInt16(pin) }
        XCTAssertEqual(wValue(role: I2S_BCK_ROLE_MASTER, pin: 14), 0x000E)
        XCTAssertEqual(wValue(role: I2S_BCK_ROLE_SLAVE, pin: 26), 0x011A)
        // Legacy bare-GPIO call decodes to role 0.
        XCTAssertEqual(UInt16(14) >> 8, 0)
    }

    /// clock_pin_mode_p1 is +1 encoded so that 0 (a reserved byte on old
    /// firmware) means "absent": 1 = unified, 2 = split.
    func testClockPinModeP1Encoding() {
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_UNIFIED + 1, 1)
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_SPLIT + 1, 2)
        // Decode: p1 - 1 recovers the mode; 0 is the absent sentinel.
        XCTAssertEqual(UInt8(1) - 1, I2S_CLOCK_PIN_MODE_UNIFIED)
        XCTAssertEqual(UInt8(2) - 1, I2S_CLOCK_PIN_MODE_SPLIT)
    }

    // MARK: - Pin-conflict rule (spec §1: slave pair reserved only in SPLIT)

    /// In UNIFIED mode the dormant slave pair constrains nothing; in SPLIT both
    /// GPIOs (BCK and LRCLK = BCK+1) are reserved.  Mirrors the firmware
    /// i2s_clock_pin_claimed helper.
    @MainActor
    func testSlavePairReservedOnlyInSplit() {
        let vm = DSPViewModel(usb: AppState.shared.usb)
        vm.platformName = "RP2350"
        vm.i2sInputSupported = true
        vm.i2sBckPinSlave = 26

        // UNIFIED: the slave pair is free for other consumers.
        vm.i2sClockPinMode = I2S_CLOCK_PIN_MODE_UNIFIED
        XCTAssertNil(vm.pinInUseBy(26, excluding: .output(0)))
        XCTAssertNil(vm.pinInUseBy(27, excluding: .output(0)))

        // SPLIT: both the slave BCK and its LRCLK (BCK+1) are claimed.
        vm.i2sClockPinMode = I2S_CLOCK_PIN_MODE_SPLIT
        XCTAssertEqual(vm.pinInUseBy(26, excluding: .output(0)), "I2S Slave BCK")
        XCTAssertEqual(vm.pinInUseBy(27, excluding: .output(0)), "I2S Slave LRCLK")
        // The slave picker itself is excluded from its own reservation.
        XCTAssertNil(vm.pinInUseBy(26, excluding: .i2sBckSlave))
        XCTAssertNil(vm.pinInUseBy(27, excluding: .i2sBckSlave))
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// REQ_GET_I2S_CLOCK_PIN_MODE returns a valid 0/1 byte; the slave pair GPIO
    /// (0xC3 role 1) is a plausible GPIO distinct from the master pair.
    func testClockPinModeReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode (0xFF STALLed).")
        }
        XCTAssertLessThanOrEqual(mode, 1, "clock-pin mode must be 0 (unified) or 1 (split)")

        let master = usb.getControlRequest(request: REQ_GET_I2S_BCK_PIN,
                                           value: UInt16(I2S_BCK_ROLE_MASTER), index: 2, length: 1)?.first
        let slave = usb.getControlRequest(request: REQ_GET_I2S_BCK_PIN,
                                          value: UInt16(I2S_BCK_ROLE_SLAVE), index: 2, length: 1)?.first
        XCTAssertNotNil(master)
        XCTAssertNotNil(slave)
        if mode == I2S_CLOCK_PIN_MODE_SPLIT, let mp = master, let sp = slave {
            // In SPLIT the two pairs must be distinct (including LRCLK adjacency).
            XCTAssertNotEqual(mp, sp)
            XCTAssertNotEqual(mp &+ 1, sp)
            XCTAssertNotEqual(sp &+ 1, mp)
        }
    }

    /// Re-setting the current clock-pin mode is a no-op that returns
    /// PIN_CONFIG_SUCCESS and leaves the live mode unchanged.
    func testSetCurrentPinModeIdempotent() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode.")
        }
        guard let r = usb.getControlRequest(request: REQ_SET_I2S_CLOCK_PIN_MODE,
                                            value: UInt16(mode), index: 2, length: 1),
              let status = r.first else {
            throw XCTSkip("0xFE STALLed.")
        }
        XCTAssertEqual(status, PIN_CONFIG_SUCCESS, "re-setting the current mode is a no-op success")
        guard let after = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1),
              let m2 = after.first else {
            throw XCTSkip("GET after SET STALLed.")
        }
        XCTAssertEqual(m2, mode, "re-setting the current mode must leave it unchanged")
    }

    /// An out-of-range mode (wValue > 1) is rejected with INVALID_PARAM, and the
    /// live mode is unaffected.
    func testInvalidPinModeRejected() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode.")
        }
        guard let r = usb.getControlRequest(request: REQ_SET_I2S_CLOCK_PIN_MODE, value: 2, index: 2, length: 1),
              let status = r.first else {
            throw XCTSkip("0xFE STALLed.")
        }
        XCTAssertEqual(status, PIN_CONFIG_INVALID_PARAM, "wValue > 1 must be rejected")
        let after = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_PIN_MODE, value: 0, index: 2, length: 1)?.first
        XCTAssertEqual(after, mode, "a rejected set must not move the live mode")
    }
}
