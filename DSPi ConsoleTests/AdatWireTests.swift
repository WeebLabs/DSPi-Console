import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the ADAT bulk output feature
/// (adat_output_spec.md).  The pure-logic tests need no device; the
/// live-device tests SKIP (never fail) when no DSPi is attached.
final class AdatWireTests: XCTestCase {

    // MARK: - Constants (spec §"Vendor commands" / §"Bulk params")

    func testRequestCodes() {
        XCTAssertEqual(VC.OUTPUT.ADAT_TX_ENABLE.id, 0x0430)
        XCTAssertEqual(VC.OUTPUT.ADAT_TX_PIN.id, 0x0431)
        XCTAssertEqual(VC.OUTPUT.ADAT_TX_STATUS.id, 0x0432)
        XCTAssertEqual(ADAT_PIN_DEFAULT, 12)
    }

    /// V18 grew WireLevellerConfig from 16 to 20 bytes (channel masks), shifting
    /// every section after the leveller by +4 and the flat layout 5872 -> 5876.
    /// V21 added the I2S clock-mode byte inside WireInputConfig without changing
    /// the total size.
    func testWireFormatSizing() {
        // V20 repurposes the crossfeed reserved byte as output_pair_mask; sizes
        // are unchanged from V19.  V21 reuses a WireInputConfig reserved byte.
        // V22 (Linkwitz Transform) reuses WireBandParams reserved bytes as qp.
        // V23 (Psychoacoustic Bass) appends WirePsybassParams (24 bytes), growing
        // the flat layout 5876 -> 5900; the ADAT section is no longer the last.
        XCTAssertEqual(WIRE_FORMAT_VERSION, 32)
        XCTAssertEqual(BULK_PARAMS_SIZE, 6136)
        XCTAssertEqual(WIRE_BULK_PARAMS_V19_SIZE, 5876)
        XCTAssertEqual(BULK_ADAT_OFFSET, 5868)
        // ADAT ends at 5876 - where the V23 psybass section now begins.
        XCTAssertEqual(BULK_ADAT_OFFSET + 8, WIRE_BULK_PARAMS_V19_SIZE)
        XCTAssertEqual(BULK_ADAT_OFFSET + 8, BULK_PSYBASS_OFFSET)
        // It sits immediately after the crossover section (crossovers[17][4]).
        XCTAssertEqual(BULK_CROSSOVER_OFFSET + WIRE_MAX_CHANNELS * WIRE_MAX_XOVER_BANDS * WIRE_BAND_PARAMS_SIZE,
                       BULK_ADAT_OFFSET)
    }

    // MARK: - AdatStatus.fromData (spec §"AdatStatus", 8 bytes, LE)

    func testStatusDecode() {
        // enabled=1, active=1, pin=12, rate_ok=1, resync=0x0105 (261), slip=0x0002 (2)
        let data = Data([0x01, 0x01, 0x0C, 0x01, 0x05, 0x01, 0x02, 0x00])
        let s = AdatStatus.fromData(data)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.enabled, true)
        XCTAssertEqual(s?.active, true)
        XCTAssertEqual(s?.pin, 12)
        XCTAssertEqual(s?.rateOk, true)
        XCTAssertEqual(s?.resyncCount, 261)
        XCTAssertEqual(s?.slipCount, 2)
    }

    func testStatusDecodeZeroed() {
        // RP2040 (engine compiled out) reports all zeros.
        let s = AdatStatus.fromData(Data(count: 8))
        XCTAssertEqual(s, AdatStatus())
        XCTAssertEqual(s?.enabled, false)
        XCTAssertEqual(s?.active, false)
    }

    func testStatusDecodeShortReturnsNil() {
        XCTAssertNil(AdatStatus.fromData(Data(count: 7)))
    }

    /// Reading from a non-zero start index (a sliced Data) must honor
    /// `startIndex`, not assume index 0.
    func testStatusDecodeSlicedData() {
        var buf = Data([0xFF, 0xFF])            // junk prefix
        buf.append(Data([0x01, 0x00, 0x1A, 0x00, 0x00, 0x00, 0x00, 0x00]))
        let s = AdatStatus.fromData(buf.suffix(8))
        XCTAssertEqual(s?.enabled, true)
        XCTAssertEqual(s?.active, false)
        XCTAssertEqual(s?.pin, 26)
    }

    // MARK: - stateString (Outputs-page status row)

    func testStateStrings() {
        XCTAssertEqual(AdatStatus(enabled: false).stateString, "Disabled")
        XCTAssertEqual(AdatStatus(enabled: true, active: true, rateOk: true).stateString, "Streaming")
        XCTAssertEqual(AdatStatus(enabled: true, active: false, rateOk: false).stateString,
                       "Suspended (rate above 48 kHz)")
        XCTAssertEqual(AdatStatus(enabled: true, active: false, rateOk: true).stateString, "Enabled")
    }

    // MARK: - NOTIFY_EVT_ADAT_STATE packet shape (spec §"Notify event")

    /// The v2 event is 8 bytes: [0x02, 0x08, flags, seq, enabled, active, pin, 0].
    /// We decode the same three payload bytes the InterruptMonitor dispatch does.
    func testNotifyPacketFields() {
        let pkt: [UInt8] = [0x02, 0x08, 0x00, 0x2A, 0x01, 0x00, 0x0C, 0x00]
        XCTAssertEqual(pkt[0], 0x02)                 // version
        XCTAssertEqual(pkt[1], 0x08)                 // NOTIFY_EVT_ADAT_STATE
        XCTAssertEqual(pkt[4] != 0, true)            // enabled
        XCTAssertEqual(pkt[5] != 0, false)           // active (suspended)
        XCTAssertEqual(pkt[6], 0x0C)                 // pin = 12
    }

    // MARK: - Live-device round-trips (skip when no DSPi attached)

    /// OUTPUT.ADAT_TX_STATUS returns a well-formed 8-byte struct whose fields are
    /// internally consistent.  On RP2040 it's all zeros, which is still valid.
    func testAdatStatusReadable() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getData(VC.OUTPUT.ADAT_TX_STATUS, length: 8),
              let status = AdatStatus.fromData(d) else {
            throw XCTSkip("Firmware predates ADAT bulk output (OUTPUT.ADAT_TX_STATUS refused).")
        }
        XCTAssertEqual(d.count, 8)
        // An active stream implies it's enabled and at a supported rate.
        if status.active {
            XCTAssertTrue(status.enabled, "active stream must be enabled")
            XCTAssertTrue(status.rateOk, "active stream must be at 44.1/48 kHz")
        }
    }

    /// The configured enable byte and pin byte agree with the
    /// status struct's mirror fields.
    func testAdatConfigConsistency() throws {
        let usb = try HardwareTest.requireDevice()
        guard let en = usb.getData(VC.OUTPUT.ADAT_TX_ENABLE, length: 1),
              let pin = usb.getData(VC.OUTPUT.ADAT_TX_PIN, length: 1),
              let st = usb.getData(VC.OUTPUT.ADAT_TX_STATUS, length: 8),
              let status = AdatStatus.fromData(st) else {
            throw XCTSkip("Firmware predates ADAT bulk output.")
        }
        XCTAssertEqual((en.first ?? 0) != 0, status.enabled)
        XCTAssertEqual(pin.first ?? 0, status.pin)
    }

    /// Setting the ADAT pin to its current value is a no-op success; restores
    /// nothing because it never changes.  Verifies the SET is accepted on
    /// supported firmware.  The pin travels in the payload, where 0 is GPIO 0
    /// and 0xFF asks for the default.
    func testAdatPinSetIdempotent() throws {
        let usb = try HardwareTest.requireDevice()
        guard let pin = usb.getData(VC.OUTPUT.ADAT_TX_PIN, length: 1),
              let current = pin.first else {
            throw XCTSkip("Firmware predates ADAT bulk output or reported no pin.")
        }
        let status = usb.setAndWait(VC.OUTPUT.ADAT_TX_PIN, data: Data([current]))
        XCTAssertEqual(status, .ok, "re-setting the current ADAT pin should succeed, got \(status)")
    }
}
