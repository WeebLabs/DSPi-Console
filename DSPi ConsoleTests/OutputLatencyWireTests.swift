import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the output latency setting
/// (REQ_OUTPUT_LATENCY, current_architecture.md "Output Latency").  Pure logic;
/// no device needed.
final class OutputLatencyWireTests: XCTestCase {

    func testConstants() {
        XCTAssertEqual(REQ_OUTPUT_LATENCY, 0x03)
        XCTAssertEqual(OUTPUT_LATENCY_GET_STATUS, 0)
        XCTAssertEqual(OUTPUT_LATENCY_GET_OPTIONS, 1)
        XCTAssertEqual(OUTPUT_LATENCY_STATUS_SIZE, 12)
        XCTAssertEqual(OUTPUT_LATENCY_OPTION_SIZE, 8)
        XCTAssertEqual(OUTPUT_LATENCY_DEFAULT_ID, 5)
    }

    /// A low-latency request on USB: stored as 1, running as 2 ms (ID 3),
    /// 96 frames at 48 kHz, apply finished.
    func testStatusParses() {
        let d = Data([0x01, 0x03, 0xD0, 0x07, 0x60, 0x00, 0x30, 0x00, 0x00, 0x07, 0x00, 0x00])
        let st = OutputLatencyStatus.fromData(d)
        XCTAssertEqual(st, OutputLatencyStatus(requestedId: 1, effectiveId: 3, effectiveUs: 2000,
                                               targetFrames: 96, batchFrames: 48,
                                               pending: false, optionCount: 7))
        XCTAssertNil(OutputLatencyStatus.fromData(d.prefix(11)))
    }

    func testStatusParsesFromSlice() {
        var d = Data([0xEE, 0xEE])
        d.append(Data([0x05, 0x05, 0xA0, 0x0F, 0xC0, 0x00, 0x30, 0x00, 0x01, 0x07, 0x00, 0x00]))
        let st = OutputLatencyStatus.fromData(d.dropFirst(2))
        XCTAssertEqual(st?.effectiveUs, 4000)
        XCTAssertEqual(st?.targetFrames, 192)
        XCTAssertEqual(st?.pending, true)
    }

    func testOptionTableParses() {
        // 0.67 ms stream-only, unavailable on USB (runs as 2 ms); then 8 ms
        // available but clamped to 3.66 ms at 96 kHz.  A trailing partial entry
        // is dropped.
        let d = Data([0x01, 0x01, 0x9B, 0x02, 0x4D, 0x01, 0xD0, 0x07,
                      0x07, 0x80, 0x40, 0x1F, 0xE8, 0x03, 0x4C, 0x0E,
                      0x02, 0x01])
        let table = OutputLatencyOption.tableFromData(d)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table[0], OutputLatencyOption(id: 1, flags: 0x01, latencyUs: 667, batchUs: 333, effectiveUs: 2000))
        XCTAssertTrue(table[0].streamOnly)
        XCTAssertFalse(table[0].available)
        XCTAssertEqual(table[1].latencyUs, 8000)
        XCTAssertEqual(table[1].effectiveUs, 3660)
        XCTAssertFalse(table[1].streamOnly)
        XCTAssertTrue(table[1].available)
    }

    func testLatencyFormatting() {
        XCTAssertEqual(formatLatencyMs(667), "0.67 ms")
        XCTAssertEqual(formatLatencyMs(4000), "4 ms")
        XCTAssertEqual(formatLatencyMs(3660), "3.66 ms")
        XCTAssertEqual(formatGapUs(325), "325 µs")
        XCTAssertEqual(formatGapUs(102_400), "102.4 ms")
    }
}
