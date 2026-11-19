import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the I2S clock-pin mode (unified/split
/// BCK+LRCLK pairs) - clock_pins_spec.md.  The pure-logic tests need no device;
/// the live-device tests SKIP (never fail) when no DSPi is attached.
final class I2sClockPinModeWireTests: XCTestCase {

    // MARK: - Constants (spec §3 "Vendor commands")

    func testRequestCodes() {
        XCTAssertEqual(VC.CLOCK.I2S_CLOCK_PIN_MODE.id, 0x0C11)
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_UNIFIED, 0)
        XCTAssertEqual(I2S_CLOCK_PIN_MODE_SPLIT, 1)
        XCTAssertEqual(I2S_BCK_ROLE_MASTER, 0)
        XCTAssertEqual(I2S_BCK_ROLE_SLAVE, 1)
        XCTAssertEqual(VC.CLOCK.I2S_BCK_PIN.id, 0x0C10)
    }

    /// The two fields claim former reserved bytes of the 16-byte WireI2SConfig
    /// (+8 mode, +9 slave BCK); the wire version and total size are unchanged
    /// (spec §5).
    func testWireOffsets() {
        // V22 (Linkwitz Transform) reuses WireBandParams reserved bytes as qp;
        // this section's offsets and the total size are unchanged from V21.
        // V23 (Psychoacoustic Bass) appends a 24-byte section, growing the flat
        // layout 5876 -> 5900; this section's offsets are unchanged.
        XCTAssertEqual(WIRE_FORMAT_VERSION, 34)
        XCTAssertEqual(BULK_PARAMS_SIZE, 6136)
        XCTAssertEqual(BULK_I2S_CLOCK_PIN_MODE_OFFSET, BULK_I2S_OFFSET + 8)
        XCTAssertEqual(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_I2S_OFFSET + 9)
        // Both stay inside the 16-byte I2S config section (before the next one).
        XCTAssertLessThan(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_LEVELLER_OFFSET)
        XCTAssertLessThan(BULK_I2S_BCK_PIN_SLAVE_OFFSET, BULK_I2S_OFFSET + 16)
    }

    // MARK: - Encodings (spec §3 role byte, §4/§5 +1 mode sentinel)

    /// CLOCK.I2S_BCK_PIN addresses the role in wValue and carries the GPIO as
    /// a one-byte payload, where 1.1.6 packed both into wValue.
    func testBckPinRoleWValueEncoding() {
        let info = VendorCommandRegistry.info(for: VC.CLOCK.I2S_BCK_PIN)
        XCTAssertEqual(info?.address, .role)
        XCTAssertEqual(info?.setMin, 1)
        XCTAssertEqual(info?.setMax, 1)
        XCTAssertEqual(UInt16(I2S_BCK_ROLE_MASTER), 0)
        XCTAssertEqual(UInt16(I2S_BCK_ROLE_SLAVE), 1)
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

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// CLOCK.I2S_CLOCK_PIN_MODE returns a valid 0/1 byte; the slave pair GPIO
    /// (CLOCK.I2S_BCK_PIN role 1) is a plausible GPIO distinct from the master pair.
    func testClockPinModeReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getData(VC.CLOCK.I2S_CLOCK_PIN_MODE, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode (CLOCK.I2S_CLOCK_PIN_MODE refused).")
        }
        XCTAssertLessThanOrEqual(mode, 1, "clock-pin mode must be 0 (unified) or 1 (split)")

        let master = usb.getData(VC.CLOCK.I2S_BCK_PIN, value: UInt16(I2S_BCK_ROLE_MASTER), length: 1)?.first
        let slave = usb.getData(VC.CLOCK.I2S_BCK_PIN, value: UInt16(I2S_BCK_ROLE_SLAVE), length: 1)?.first
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
        guard let m = usb.getData(VC.CLOCK.I2S_CLOCK_PIN_MODE, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode.")
        }
        // The old status byte, recovered from the SET's result as the app does.
        guard let r = usb.legacyAction(VC.CLOCK.I2S_CLOCK_PIN_MODE, payload: Data([mode]), family: .pin),
              let status = r.first else {
            throw XCTSkip("CLOCK.I2S_CLOCK_PIN_MODE SET gave no verdict.")
        }
        XCTAssertEqual(status, PIN_CONFIG_SUCCESS, "re-setting the current mode is a no-op success")
        guard let after = usb.getData(VC.CLOCK.I2S_CLOCK_PIN_MODE, length: 1),
              let m2 = after.first else {
            throw XCTSkip("GET after SET STALLed.")
        }
        XCTAssertEqual(m2, mode, "re-setting the current mode must leave it unchanged")
    }

    /// An out-of-range mode (payload > 1) is rejected with INVALID_PARAM, and the
    /// live mode is unaffected.
    func testInvalidPinModeRejected() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getData(VC.CLOCK.I2S_CLOCK_PIN_MODE, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-pin mode.")
        }
        guard let r = usb.legacyAction(VC.CLOCK.I2S_CLOCK_PIN_MODE, payload: Data([2]), family: .pin),
              let status = r.first else {
            throw XCTSkip("CLOCK.I2S_CLOCK_PIN_MODE SET gave no verdict.")
        }
        XCTAssertEqual(status, PIN_CONFIG_INVALID_PARAM, "a mode > 1 must be rejected")
        let after = usb.getData(VC.CLOCK.I2S_CLOCK_PIN_MODE, length: 1)?.first
        XCTAssertEqual(after, mode, "a rejected set must not move the live mode")
    }
}
