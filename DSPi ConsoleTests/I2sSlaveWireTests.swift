import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the I2S clock-slave input mode
/// (i2s_slave_input_spec.md).  The pure-logic tests need no device; the
/// live-device tests SKIP (never fail) when no DSPi is attached.
final class I2sSlaveWireTests: XCTestCase {

    // MARK: - Constants (spec §4 "Vendor commands" / §6 "Persistence")

    func testRequestCodes() {
        XCTAssertEqual(REQ_SET_I2S_CLOCK_MODE, 0x88)
        XCTAssertEqual(REQ_GET_I2S_CLOCK_MODE, 0x89)
        XCTAssertEqual(REQ_GET_I2S_SLAVE_STATUS, 0x8A)
        XCTAssertEqual(I2S_CLOCK_MODE_MASTER, 0)
        XCTAssertEqual(I2S_CLOCK_MODE_SLAVE, 1)
    }

    /// V21 claims WireInputConfig byte +11 for i2s_clock_mode without changing
    /// the section or total size (still 5876 bytes, unchanged from V20).  Bytes
    /// +8/+9/+10 are already taken by the optional SPDIF 2/3 pins + enable mask.
    func testWireFormatSizing() {
        // V22 (Linkwitz Transform) reuses each WireBandParams' reserved bytes
        // for qp; sizes and this section's offsets are unchanged from V21.
        // V23 (Psychoacoustic Bass) appends a 24-byte section, growing the flat
        // layout 5876 -> 5900; this section's offsets are unchanged.
        XCTAssertEqual(WIRE_FORMAT_VERSION, 26)
        XCTAssertEqual(BULK_PARAMS_SIZE, 5944)
        XCTAssertEqual(WIRE_BULK_PARAMS_V19_SIZE, 5876)
        // The clock-mode byte is byte +11 within the 16-byte WireInputConfig.
        XCTAssertEqual(BULK_INPUT_I2S_CLOCK_MODE_OFFSET, BULK_INPUT_CONFIG_OFFSET + 11)
        // Still inside the input-config section, ahead of the next section (LG).
        XCTAssertLessThan(BULK_INPUT_I2S_CLOCK_MODE_OFFSET, BULK_LG_OFFSET)
    }

    // MARK: - I2sSlaveStatus.fromData (spec §4, 16 bytes, LE)

    func testStatusDecode() {
        // state=3 (LOCKED), clock_mode=1 (slave), lock=5, loss=2,
        // detected=48000 (0x0000BB80), measured=48001 (0x0000BB81).
        let data = Data([0x03, 0x01, 0x05, 0x02,
                         0x80, 0xBB, 0x00, 0x00,
                         0x81, 0xBB, 0x00, 0x00,
                         0x00, 0x00, 0x00, 0x00])
        let s = I2sSlaveStatus.fromData(data)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.state, 3)
        XCTAssertEqual(s?.clockMode, 1)
        XCTAssertEqual(s?.isSlave, true)
        XCTAssertEqual(s?.isLocked, true)
        XCTAssertEqual(s?.lockCount, 5)
        XCTAssertEqual(s?.lossCount, 2)
        XCTAssertEqual(s?.detectedRate, 48000)
        XCTAssertEqual(s?.measuredHz, 48001)
    }

    func testStatusDecodeZeroed() {
        // Master mode / no clocks reports all zeros.
        let s = I2sSlaveStatus.fromData(Data(count: 16))
        XCTAssertEqual(s, I2sSlaveStatus())
        XCTAssertEqual(s?.isSlave, false)
        XCTAssertEqual(s?.isLocked, false)
        XCTAssertEqual(s?.detectedRateString, "-")
        XCTAssertEqual(s?.measuredHzString, "-")
    }

    func testStatusDecodeShortReturnsNil() {
        XCTAssertNil(I2sSlaveStatus.fromData(Data(count: 15)))
    }

    /// Reading from a non-zero start index (a sliced Data) must honor
    /// `startIndex`, not assume index 0.
    func testStatusDecodeSlicedData() {
        var buf = Data([0xFF, 0xFF])            // junk prefix
        buf.append(Data([0x01, 0x01, 0x00, 0x00,   // ACQUIRING, slave
                         0x00, 0x00, 0x00, 0x00,   // detected = 0 (not locked)
                         0x44, 0xAC, 0x00, 0x00,   // measured = 44100
                         0x00, 0x00, 0x00, 0x00]))
        let s = I2sSlaveStatus.fromData(buf.suffix(16))
        XCTAssertEqual(s?.state, 1)
        XCTAssertEqual(s?.clockMode, 1)
        XCTAssertEqual(s?.detectedRate, 0)
        XCTAssertEqual(s?.measuredHz, 44100)
        // Detected rate hidden until LOCKED, even though measured is nonzero.
        XCTAssertEqual(s?.detectedRateString, "-")
        XCTAssertEqual(s?.measuredHzString, "44.1 kHz")
    }

    // MARK: - stateString (settings + stats indicators)

    func testStateStrings() {
        XCTAssertEqual(I2sSlaveStatus(state: 0).stateString, "Inactive")
        XCTAssertEqual(I2sSlaveStatus(state: 1).stateString, "Acquiring")
        XCTAssertEqual(I2sSlaveStatus(state: 2).stateString, "Relocking")
        XCTAssertEqual(I2sSlaveStatus(state: 3).stateString, "Locked")
        // Only LOCKED (state 3) counts as locked - note this differs from the
        // SPDIF machine where LOCKED is state 2.
        XCTAssertTrue(I2sSlaveStatus(state: 3).isLocked)
        XCTAssertFalse(I2sSlaveStatus(state: 2).isLocked)
    }

    // MARK: - NOTIFY_EVT_I2S_SLAVE_STATE packet shape (spec §5)

    /// The v2 event is 9 bytes (not 8): [0x02, 0x09, flags, seq, state,
    /// rate_LE(4)].  We decode the same payload the InterruptMonitor dispatch
    /// does — state at byte 4, little-endian detected rate at bytes 5..8.
    func testNotifyPacketFields() {
        let pkt: [UInt8] = [0x02, 0x09, 0x00, 0x2A, 0x03, 0x80, 0xBB, 0x00, 0x00]
        XCTAssertEqual(pkt.count, 9)
        XCTAssertEqual(pkt[0], 0x02)                 // version
        XCTAssertEqual(pkt[1], 0x09)                 // NOTIFY_EVT_I2S_SLAVE_STATE
        XCTAssertEqual(pkt[4], 0x03)                 // state = LOCKED
        let rate = UInt32(pkt[5]) | (UInt32(pkt[6]) << 8) | (UInt32(pkt[7]) << 16) | (UInt32(pkt[8]) << 24)
        XCTAssertEqual(rate, 48000)                  // detected rate (LOCKED)
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// REQ_GET_I2S_CLOCK_MODE returns a valid 0/1 byte and matches the mode
    /// mirrored in the status packet's clock_mode field.
    func testClockModeReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_MODE, value: 0, index: 2, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-slave mode (0x89 STALLed).")
        }
        XCTAssertLessThanOrEqual(mode, 1, "clock mode must be 0 (master) or 1 (slave)")

        guard let st = usb.getControlRequest(request: REQ_GET_I2S_SLAVE_STATUS, value: 0, index: 2, length: 16),
              let status = I2sSlaveStatus.fromData(st) else {
            throw XCTSkip("REQ_GET_I2S_SLAVE_STATUS STALLed.")
        }
        XCTAssertEqual(st.count, 16)
        XCTAssertEqual(status.clockMode, mode, "0x8A clock_mode must match 0x89")
    }

    /// Status invariants: a LOCKED slave reports a supported detected rate; an
    /// unlocked state reports detected_rate = 0.
    func testSlaveStatusInvariants() throws {
        let usb = try HardwareTest.requireDevice()
        guard let st = usb.getControlRequest(request: REQ_GET_I2S_SLAVE_STATUS, value: 0, index: 2, length: 16),
              let status = I2sSlaveStatus.fromData(st) else {
            throw XCTSkip("Firmware predates I2S clock-slave mode.")
        }
        if status.isLocked {
            XCTAssertTrue([44100, 48000, 96000].contains(status.detectedRate),
                          "LOCKED implies a supported snapped rate, got \(status.detectedRate)")
        } else {
            XCTAssertEqual(status.detectedRate, 0, "detected_rate is 0 unless LOCKED")
        }
    }

    /// Re-setting the current clock mode is a no-op that must not STALL on
    /// supported firmware (the SET is fire-and-forget OUT, deferred-applied).
    func testSetCurrentClockModeIdempotent() throws {
        let usb = try HardwareTest.requireDevice()
        guard let m = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_MODE, value: 0, index: 2, length: 1),
              let mode = m.first else {
            throw XCTSkip("Firmware predates I2S clock-slave mode.")
        }
        // OUT transfer; sendControlRequest is fire-and-forget, so just confirm
        // the round-trip GET still reports the same live mode afterwards.
        usb.sendControlRequest(request: REQ_SET_I2S_CLOCK_MODE, value: 0, index: 2, data: Data([mode]))
        guard let after = usb.getControlRequest(request: REQ_GET_I2S_CLOCK_MODE, value: 0, index: 2, length: 1),
              let m2 = after.first else {
            throw XCTSkip("GET after SET STALLed.")
        }
        XCTAssertEqual(m2, mode, "re-setting the current mode must leave it unchanged")
    }
}
