import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the test signal generator structs
/// (test_signals_spec.md §3 / §13).  Pure logic - no device needed.
final class SiggenWireTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - SiggenConfig (spec §13 example payloads)

    /// Spec §13.1: 1 kHz sine at -20 dBFS on channels 0+1, until stopped.
    func testConfigSineExampleBytes() {
        let cfg = SiggenConfig(signalType: SIGGEN_SINE, channelMask: 0x0003,
                               levelDB: -20.0, p1: 1000.0)
        let expected = "01 00 03 00 00 00 00 00 00 00 a0 c1 00 00 00 00 " +
                       "00 00 00 00 00 00 7a 44 00 00 00 00 00 00 00 00 " +
                       "00 00 00 00"
        XCTAssertEqual(hex(cfg.toData()), expected)
        XCTAssertEqual(cfg.toData().count, 36)
        XCTAssertEqual(SiggenConfig.fromData(cfg.toData()), cfg)
    }

    /// Spec §13.2: same as 13.1 with channel 1 polarity-inverted.
    func testConfigInvertMaskExampleBytes() {
        let cfg = SiggenConfig(signalType: SIGGEN_SINE, channelMask: 0x0003,
                               invertMask: 0x0002, levelDB: -20.0, p1: 1000.0)
        let expected = "01 00 03 00 02 00 00 00 00 00 a0 c1 00 00 00 00 " +
                       "00 00 00 00 00 00 7a 44 00 00 00 00 00 00 00 00 " +
                       "00 00 00 00"
        XCTAssertEqual(hex(cfg.toData()), expected)
        XCTAssertEqual(SiggenConfig.fromData(cfg.toData()), cfg)
    }

    /// Spec §13.3: 20 Hz - 20 kHz log sweep, 10 s, channel 2, repeated 3x.
    func testConfigLogSweepExampleBytes() {
        let cfg = SiggenConfig(signalType: SIGGEN_SWEEP_LOG, channelMask: 0x0004,
                               levelDB: -6.0, durationMS: 10000, repeatCount: 3,
                               p1: 20.0, p2: 20000.0)
        let expected = "01 04 04 00 00 00 00 00 00 00 c0 c0 10 27 00 00 " +
                       "03 00 00 00 00 00 a0 41 00 40 9c 46 00 00 00 00 " +
                       "00 00 00 00"
        XCTAssertEqual(hex(cfg.toData()), expected)
        XCTAssertEqual(SiggenConfig.fromData(cfg.toData()), cfg)
    }

    /// Spec §13.4: channel-ID walk on all channels, one pass, 120 ms blips.
    func testConfigChannelIdExampleBytes() {
        let cfg = SiggenConfig(signalType: SIGGEN_CHANNEL_ID, channelMask: 0xFFFF,
                               levelDB: -12.0, repeatCount: 1, p1: 120.0)
        let expected = "01 0e ff ff 00 00 00 00 00 00 40 c1 00 00 00 00 " +
                       "01 00 00 00 00 00 f0 42 00 00 00 00 00 00 00 00 " +
                       "00 00 00 00"
        XCTAssertEqual(hex(cfg.toData()), expected)
        XCTAssertEqual(SiggenConfig.fromData(cfg.toData()), cfg)
    }

    func testConfigFlagsAndGapRoundTrip() {
        let cfg = SiggenConfig(signalType: SIGGEN_PINK, channelMask: 0x01FF,
                               invertMask: 0x0055,
                               flags: SIGGEN_FLAG_RAW | SIGGEN_FLAG_DECORR | SIGGEN_FLAG_WALK,
                               levelDB: -120.0, durationMS: 0xDEADBEEF,
                               repeatCount: 0xFFFF, gapMS: 1234,
                               p1: 1.5, p2: -2.25, p3: 0.125, p4: 65536.0)
        let d = cfg.toData()
        XCTAssertEqual(d.count, 36)
        XCTAssertEqual(d[6], 0x07)
        XCTAssertEqual(SiggenConfig.fromData(d), cfg)
    }

    func testConfigFromDataRejectsShortPayload() {
        XCTAssertNil(SiggenConfig.fromData(Data(count: 35)))
        XCTAssertNotNil(SiggenConfig.fromData(Data(count: 36)))
    }

    /// fromData must honor a non-zero Data.startIndex (slices).
    func testConfigFromDataSlice() {
        let cfg = SiggenConfig(signalType: SIGGEN_TONE_PAIR, channelMask: 0x0003,
                               levelDB: -18.0, p1: 60, p2: 7000, p3: 4)
        var padded = Data([0xAA, 0xBB])
        padded.append(cfg.toData())
        XCTAssertEqual(SiggenConfig.fromData(padded.dropFirst(2)), cfg)
    }

    // MARK: - SiggenStatus

    func testStatusParse() {
        // version=1, state=RUN, type=SWEEP_LOG, walk ch 3, elapsed 65536 ms,
        // cycles 2, stop_reason NONE, current_freq 440.0 (0x43DC0000).
        let bytes: [UInt8] = [
            0x01, 0x02, 0x04, 0x03,
            0x00, 0x00, 0x01, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xDC, 0x43,
        ]
        let st = SiggenStatus.fromData(Data(bytes))
        XCTAssertNotNil(st)
        XCTAssertEqual(st?.state, SIGGEN_STATE_RUN)
        XCTAssertEqual(st?.signalType, SIGGEN_SWEEP_LOG)
        XCTAssertEqual(st?.activeChannel, 3)
        XCTAssertEqual(st?.elapsedMS, 65536)
        XCTAssertEqual(st?.cyclesDone, 2)
        XCTAssertEqual(st?.stopReason, SIGGEN_STOP_NONE)
        XCTAssertEqual(st?.currentFreq, 440.0)
        XCTAssertEqual(st?.isRunning, true)
        XCTAssertNil(SiggenStatus.fromData(Data(count: 15)))
    }

    func testStatusIdleNotWalking() {
        let bytes: [UInt8] = [
            0x01, 0x00, 0x0E, 0xFF,
            0x10, 0x00, 0x00, 0x00,
            0x05, 0x00, 0x02, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let st = SiggenStatus.fromData(Data(bytes))
        XCTAssertEqual(st?.isRunning, false)
        XCTAssertEqual(st?.activeChannel, 0xFF)
        XCTAssertEqual(st?.stopReason, SIGGEN_STOP_COMPLETED)
        XCTAssertEqual(st?.currentFreq, 0)
    }

    // MARK: - SiggenCapsHeader

    func testCapsHeaderParseRP2350() {
        // version=1, 15 types, 9 outputs, multitone 16, mask 0x01FF.
        let bytes: [UInt8] = [0x01, 0x0F, 0x09, 0x10, 0xFF, 0x01, 0x00, 0x00]
        let caps = SiggenCapsHeader.fromData(Data(bytes))
        XCTAssertEqual(caps?.version, 1)
        XCTAssertEqual(caps?.typeCount, 15)
        XCTAssertEqual(caps?.outputChannels, 9)
        XCTAssertEqual(caps?.multitoneMax, 16)
        XCTAssertEqual(caps?.validChannelMask, 0x01FF)
        XCTAssertNil(SiggenCapsHeader.fromData(Data(count: 7)))
    }

    // MARK: - SiggenTypeDesc

    /// Builds a 62-byte descriptor with the spec §3.4 layout (13-byte
    /// unaligned param records) and checks every field survives parsing.
    func testTypeDescParseUnalignedFloats() {
        var d = Data(count: 62)
        d[0] = SIGGEN_SWEEP_STEP
        for (i, c) in "swp-stp".utf8.enumerated() { d[1 + i] = c }   // NUL-padded name
        d[9] = SIGGEN_TIMING_SWEEP
        func putParam(_ index: Int, _ semantic: UInt8, _ min: Float, _ max: Float, _ def: Float) {
            let o = 10 + index * 13
            d[o] = semantic
            for (j, v) in [min, max, def].enumerated() {
                let bits = v.bitPattern
                for k in 0..<4 { d[o + 1 + j * 4 + k] = UInt8((bits >> (8 * k)) & 0xFF) }
            }
        }
        putParam(0, SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20)
        putParam(1, SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20000)
        putParam(2, SIGGEN_PARAM_COUNT, 1, 24, 3)
        putParam(3, SIGGEN_PARAM_MS, 20, 10000, 250)

        let desc = SiggenTypeDesc.fromData(d)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.id, SIGGEN_SWEEP_STEP)
        XCTAssertEqual(desc?.name, "swp-stp")
        XCTAssertEqual(desc?.timingModel, SIGGEN_TIMING_SWEEP)
        XCTAssertEqual(desc?.params.count, 4)
        XCTAssertEqual(desc?.params[0].semantic, SIGGEN_PARAM_FREQ_HZ)
        XCTAssertEqual(desc?.params[0].def, 20)
        XCTAssertEqual(desc?.params[1].max, 30000)
        XCTAssertEqual(desc?.params[2].semantic, SIGGEN_PARAM_COUNT)
        XCTAssertEqual(desc?.params[2].max, 24)
        XCTAssertEqual(desc?.params[3].def, 250)
        XCTAssertEqual(desc?.params[3].isUsed, true)
        XCTAssertNil(SiggenTypeDesc.fromData(Data(count: 61)))
    }

    func testTypeDescUnusedParams() {
        var d = Data(count: 62)
        d[0] = SIGGEN_WHITE
        for (i, c) in "white".utf8.enumerated() { d[1 + i] = c }
        d[9] = SIGGEN_TIMING_CONTINUOUS
        let desc = SiggenTypeDesc.fromData(d)
        XCTAssertEqual(desc?.name, "white")
        XCTAssertEqual(desc?.params.allSatisfy { !$0.isUsed }, true)
    }
}
