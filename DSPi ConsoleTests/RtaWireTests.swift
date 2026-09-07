import XCTest
@testable import DSPi_Console

/// Byte-exact wire-format tests for the spectrum analyser
/// (spectrum_analyser_spec.md).  The pure-logic tests need no device; the
/// live-device tests SKIP (never fail) when no DSPi is attached.
final class RtaWireTests: XCTestCase {

    // MARK: - Command surface (spec §5.1)

    func testRequestCodes() {
        XCTAssertEqual(REQ_RTA_SET_CONFIG, 0x08)
        XCTAssertEqual(REQ_RTA_GET_CONFIG, 0x09)
        XCTAssertEqual(REQ_RTA_GET_CAPS, 0x0A)
        XCTAssertEqual(REQ_RTA_GET_BANDS, 0x0B)
        XCTAssertEqual(REQ_RTA_GET_BINS, 0x0C)
        XCTAssertEqual(REQ_RTA_GET_STATUS, 0x0D)
        XCTAssertEqual(REQ_RTA_CONTROL, 0x0E)
        XCTAssertEqual(REQ_RTA_GET_BANDS_ALL, 0x0F)
    }

    /// The analyser took 0x08-0x0F, immediately below the subharmonic block at
    /// 0x10-0x1F and above the auxiliary-output block at 0x02-0x07.  A
    /// collision would silently point one feature's SET at another's handler.
    func testCodesDoNotCollideWithNeighbours() {
        let rta: Set<UInt8> = [REQ_RTA_SET_CONFIG, REQ_RTA_GET_CONFIG, REQ_RTA_GET_CAPS,
                               REQ_RTA_GET_BANDS, REQ_RTA_GET_BINS, REQ_RTA_GET_STATUS,
                               REQ_RTA_CONTROL, REQ_RTA_GET_BANDS_ALL]
        XCTAssertEqual(rta.count, 8, "the eight codes must be distinct")
        let subharm: Set<UInt8> = [REQ_SET_SUBHARM, REQ_GET_SUBHARM, REQ_GET_SUBHARM_METER]
        XCTAssertTrue(rta.isDisjoint(with: subharm))
        XCTAssertTrue(rta.allSatisfy { $0 >= 0x08 && $0 <= 0x0F })
    }

    func testWireSizes() {
        XCTAssertEqual(RTA_CONFIG_SIZE, 12)
        XCTAssertEqual(RTA_CAPS_SIZE, 16)
        XCTAssertEqual(RTA_BAND_FRAME_SIZE, 80)
        XCTAssertEqual(RTA_STATUS_SIZE, 24)
        XCTAssertEqual(RTA_BIN_HEADER_SIZE, 16)
        XCTAssertEqual(RTA_MAX_BANDS, 36)
        // Header + 1024 bins (2048 points) + the repeated sequence byte.
        XCTAssertEqual(RTA_BIN_FRAME_MAX, 1041)
    }

    // MARK: - RtaConfig (spec §5.2)

    func testConfigEncodesTwelveLittleEndianBytes() {
        let cfg = RtaConfig(tap: RTA_TAP_OUTPUT, channelMask: 0x0123, fftOrder: 10,
                            avgMs: 300, peakDecayDBs: 12, flags: 0)
        let d = cfg.toData()
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual(d[0], RTA_CFG_VERSION)
        XCTAssertEqual(d[1], RTA_TAP_OUTPUT)
        XCTAssertEqual(d[2], 0x23)              // channel_mask low byte
        XCTAssertEqual(d[3], 0x01)              // channel_mask high byte
        XCTAssertEqual(d[4], 10)
        XCTAssertEqual(d[5], 0)                 // reserved0
        XCTAssertEqual(d[6], 0x2C)              // avg_ms = 300, low byte
        XCTAssertEqual(d[7], 0x01)
        XCTAssertEqual(d[8], 12)
        XCTAssertEqual(d[9], 0)
        XCTAssertEqual(d[10], 0)                // reserved
        XCTAssertEqual(d[11], 0)
    }

    func testConfigRoundTrips() {
        let cfg = RtaConfig(tap: RTA_TAP_INPUT, channelMask: 0x00FF, fftOrder: 11,
                            avgMs: 1000, peakDecayDBs: 30, flags: RTA_FLAG_MANUAL)
        XCTAssertEqual(RtaConfig.fromData(cfg.toData()), cfg)
    }

    /// A device that predates the analyser answers nothing; a short read must
    /// not be decoded into a plausible-looking configuration.
    func testConfigRejectsShortAndWrongVersion() {
        XCTAssertNil(RtaConfig.fromData(Data(repeating: 0, count: 11)))
        var d = RtaConfig().toData()
        d[0] = 1
        XCTAssertNil(RtaConfig.fromData(d))
    }

    func testConfigPointsFollowOrder() {
        XCTAssertEqual(RtaConfig(fftOrder: 8).points, 256)
        XCTAssertEqual(RtaConfig(fftOrder: 9).points, 512)
        XCTAssertEqual(RtaConfig(fftOrder: 10).points, 1024)
        XCTAssertEqual(RtaConfig(fftOrder: 11).points, 2048)
    }

    // MARK: - RtaCaps

    private func capsBytes(version: UInt8 = RTA_CFG_VERSION, orderMin: UInt8 = 8, orderMax: UInt8 = 11,
                           orderDefault: UInt8 = 10,
                           dynamicRange: UInt8 = 120) -> Data {
        var d = Data(count: RTA_CAPS_SIZE)
        d[0] = version
        d[1] = 8                    // input_channels
        d[2] = 9                    // output_channels
        d[3] = orderMin
        d[4] = orderMax
        d[5] = orderDefault
        d[6] = 0                    // reserved0
        d[7] = UInt8(RTA_MAX_BANDS)
        d[8] = RTA_LEVEL_ZERO_DBFS
        d[9] = dynamicRange
        d[10] = 0x88; d[11] = 0x13  // idle_timeout_ms = 5000
        d[12] = 0x11; d[13] = 0x04  // max_bin_frame = 1041
        return d
    }

    func testCapsDecode() {
        let caps = RtaCaps.fromData(capsBytes())
        XCTAssertEqual(caps?.inputChannels, 8)
        XCTAssertEqual(caps?.outputChannels, 9)
        XCTAssertEqual(caps?.fftOrderMax, 11)
        XCTAssertEqual(caps?.levelZero, RTA_LEVEL_ZERO_DBFS)
        XCTAssertEqual(caps?.dynamicRangeDB, 120)
        XCTAssertEqual(caps?.idleTimeoutMs, 5000)
        XCTAssertEqual(caps?.maxBinFrame, 1041)
        XCTAssertEqual(Int(caps?.maxBinFrame ?? 0), RTA_BIN_FRAME_MAX)
    }

    /// A zeroed buffer is what a stubbed-out handler returns; it must read as
    /// "no analyser" rather than as a device with a zero-point of 0.
    func testCapsRejectsZeroVersionAndShortReads() {
        XCTAssertNil(RtaCaps.fromData(capsBytes(version: 0)))
        XCTAssertNil(RtaCaps.fromData(Data(repeating: 0xFF, count: 15)))
    }

    // MARK: - Level encoding (spec §2.3)

    /// 243 is 0 dBFS, each step is half a decibel, and 255 is the +6 dBFS
    /// ceiling that exists because upmix rows and hot EQ can exceed full scale.
    func testLevelEncodingAnchorPoints() {
        let engine = RtaEngine(usb: AppState.shared.usb)
        XCTAssertEqual(engine.levelDB(243), 0.0, accuracy: 0.0001)
        XCTAssertEqual(engine.levelDB(255), 6.0, accuracy: 0.0001)
        XCTAssertEqual(engine.levelDB(203), -20.0, accuracy: 0.0001)
        XCTAssertEqual(engine.levelDB(0), -121.5, accuracy: 0.0001)
        XCTAssertEqual(engine.floorDB, -121.5, accuracy: 0.0001)
    }

    // MARK: - RtaBandFrame

    private func bandFrameBytes(channel: UInt8 = 3, seq: UInt8 = 7, nBands: UInt8 = 31,
                                ageMs: UInt16 = 42) -> Data {
        var d = Data(count: RTA_BAND_FRAME_SIZE)
        d[0] = RTA_CFG_VERSION
        d[1] = channel
        d[2] = seq
        d[3] = nBands
        d[4] = UInt8(ageMs & 0xFF); d[5] = UInt8(ageMs >> 8)
        d[6] = 0; d[7] = 0                              // reserved
        for i in 0..<RTA_MAX_BANDS {
            d[8 + i] = UInt8(100 + i)                    // avg
            d[8 + RTA_MAX_BANDS + i] = UInt8(140 + i)    // peak
        }
        return d
    }

    func testBandFrameDecode() {
        let f = RtaBandFrame.fromData(bandFrameBytes())
        XCTAssertEqual(f?.channel, 3)
        XCTAssertEqual(f?.seq, 7)
        XCTAssertEqual(f?.nBands, 31)
        XCTAssertEqual(f?.ageMs, 42)
        XCTAssertEqual(f?.avg.count, RTA_MAX_BANDS)
        XCTAssertEqual(f?.peak.count, RTA_MAX_BANDS)
        XCTAssertEqual(f?.avg.first, 100)
        XCTAssertEqual(f?.avg.last, UInt8(100 + RTA_MAX_BANDS - 1))
        XCTAssertEqual(f?.peak.first, 140)
        XCTAssertEqual(f?.hasData, true)
    }

    /// 0xFFFF means the channel has never produced a frame, which a display
    /// must tell apart from a channel that is genuinely silent.
    func testBandFrameNeverRefreshed() {
        let f = RtaBandFrame.fromData(bandFrameBytes(ageMs: 0xFFFF))
        XCTAssertEqual(f?.hasData, false)
    }

    /// GET_BANDS_ALL is a run of whole frames, each naming its own channel, so
    /// the parser needs nothing from the live mask to unpack it.
    func testBandFramesParseBackToBackAtOffsets() {
        var all = Data()
        all.append(bandFrameBytes(channel: 0, seq: 1))
        all.append(bandFrameBytes(channel: 4, seq: 2))
        all.append(bandFrameBytes(channel: 8, seq: 3))
        var seen: [UInt8: UInt8] = [:]
        var off = 0
        while off + RTA_BAND_FRAME_SIZE <= all.count {
            if let f = RtaBandFrame.fromData(all, at: off) { seen[f.channel] = f.seq }
            off += RTA_BAND_FRAME_SIZE
        }
        XCTAssertEqual(seen, [0: 1, 4: 2, 8: 3])
    }

    func testBandFrameRejectsShortRead() {
        XCTAssertNil(RtaBandFrame.fromData(Data(repeating: 1, count: 79)))
        XCTAssertNil(RtaBandFrame.fromData(bandFrameBytes(), at: 8))
    }

    // MARK: - RtaBinFrame (spec §5.1, the seq head/tail protocol)

    private func binFrameBytes(seq: UInt8 = 9, nBins: Int = 8, order: UInt8 = 10,
                               rate: UInt32 = 48000, tail: UInt8? = nil) -> Data {
        var d = Data(count: RTA_BIN_HEADER_SIZE + nBins + 1)
        d[0] = RTA_CFG_VERSION
        d[1] = 2                         // channel
        d[2] = seq
        d[3] = order                     // fft_order
        d[4] = UInt8(rate & 0xFF); d[5] = UInt8((rate >> 8) & 0xFF)
        d[6] = UInt8((rate >> 16) & 0xFF); d[7] = UInt8(rate >> 24)
        d[8] = UInt8(nBins & 0xFF); d[9] = UInt8(nBins >> 8)
        // bytes 10..15 reserved
        for i in 0..<nBins { d[RTA_BIN_HEADER_SIZE + i] = UInt8(truncatingIfNeeded: 200 + i) }
        d[RTA_BIN_HEADER_SIZE + nBins] = tail ?? seq
        return d
    }

    func testBinFrameDecode() {
        let f = RtaBinFrame.fromData(binFrameBytes())
        XCTAssertEqual(f?.channel, 2)
        XCTAssertEqual(f?.seq, 9)
        XCTAssertEqual(f?.sampleRateHz, 48000)
        XCTAssertEqual(f?.bins.count, 8)
        XCTAssertEqual(f?.bins.first, 200)
    }

    /// The frame carries its sequence number twice and takes no lock; a
    /// disagreement means the engine republished mid-read, and the host must
    /// discard rather than draw half of each frame.
    func testBinFrameRejectsTornRead() {
        XCTAssertNil(RtaBinFrame.fromData(binFrameBytes(seq: 9, tail: 10)))
    }

    /// 0xFF is the in-progress marker the engine writes before it fills a
    /// frame, never a published sequence number.
    func testBinFrameRejectsInProgressMarker() {
        XCTAssertNil(RtaBinFrame.fromData(binFrameBytes(seq: 0xFF)))
    }

    func testBinFrameRejectsTruncatedBody() {
        var d = binFrameBytes()
        d.removeLast(3)
        XCTAssertNil(RtaBinFrame.fromData(d))
    }

    /// Bin k of an N-point transform is centred at k * rate / N.
    func testBinFrequencies() {
        let f = RtaBinFrame.fromData(binFrameBytes(nBins: 512))!
        XCTAssertEqual(f.frequency(ofBin: 0), 0, accuracy: 0.001)
        XCTAssertEqual(f.frequency(ofBin: 1), 48000.0 / 1024.0, accuracy: 0.001)
        XCTAssertEqual(f.frequency(ofBin: 512), 24000, accuracy: 0.001)
        // The largest frame the device can publish: 2048 points, 1041 bytes.
        let big = RtaBinFrame.fromData(binFrameBytes(nBins: 1024, order: 11))!
        XCTAssertEqual(big.bins.count, 1024)
        XCTAssertEqual(big.frequency(ofBin: 1), 48000.0 / 2048.0, accuracy: 0.001)
    }

    // MARK: - RtaStatus

    private func statusBytes(state: UInt8 = RTA_STATE_CAPTURING, liveCount: UInt8 = 4,
                             firstBand: UInt8 = 12) -> Data {
        var d = Data(count: RTA_STATUS_SIZE)
        d[0] = RTA_CFG_VERSION
        d[1] = state
        d[2] = RTA_TAP_OUTPUT
        d[3] = 2                        // channel
        d[4] = 0                        // reserved0
        d[5] = liveCount
        d[6] = 0x0F; d[7] = 0x00        // live_mask
        d[8] = 46;   d[9] = 0           // frames_per_s
        d[10] = 0x10; d[11] = 0x27      // busy_us_per_s = 10000 (one percent)
        d[12] = 0x70; d[13] = 0x01      // last_frame_us = 368
        d[14] = 0x0A; d[15] = 0x00      // idle_ms
        d[16] = 0x80; d[17] = 0xBB; d[18] = 0x00; d[19] = 0x00   // 48000
        d[20] = firstBand
        return d
    }

    func testStatusDecode() {
        let s = RtaStatus.fromData(statusBytes())
        XCTAssertEqual(s?.state, RTA_STATE_CAPTURING)
        XCTAssertEqual(s?.tap, RTA_TAP_OUTPUT)
        XCTAssertEqual(s?.channel, 2)
        XCTAssertEqual(s?.liveCount, 4)
        XCTAssertEqual(s?.liveMask, 0x000F)
        XCTAssertEqual(s?.framesPerSecond, 46)
        XCTAssertEqual(s?.busyUsPerSecond, 10000)
        XCTAssertEqual(s?.lastFrameUs, 368)
        XCTAssertEqual(s?.sampleRateHz, 48000)
        XCTAssertEqual(s?.isRunning, true)
    }

    /// Bands below first_band read 0 on the wire and are drawn as empty slots
    /// rather than as silence.
    func testFirstResolvedBand() {
        let s = RtaStatus.fromData(statusBytes(firstBand: 12))!
        XCTAssertEqual(s.firstResolvedBand, 12)
        let all = RtaStatus.fromData(statusBytes(firstBand: 0))!
        XCTAssertEqual(all.firstResolvedBand, 0)
    }

    func testStatusRejectsShortRead() {
        XCTAssertNil(RtaStatus.fromData(Data(repeating: 1, count: 23)))
    }

    // MARK: - Options clamping

    /// A preference carried over from the other platform must never become a
    /// configuration the device STALLs: the caps fold into the options at
    /// every connect.
    func testOptionsAreEqualByValue() {
        XCTAssertEqual(RtaOptions(), RtaOptions())
        XCTAssertNotEqual(RtaOptions(fftOrder: 9), RtaOptions(fftOrder: 10))
    }

    // MARK: - Which bands the transform can measure

    /// A third-octave band near the bottom of the scale is narrower than one
    /// FFT bin, so it contains no bin and can only read the floor.  The gaps
    /// are patchy rather than a clean cutoff, which is why the display cannot
    /// work from `RtaStatus.fastFirstBand` alone.
    func testBandsWithNoBinAt48kAnd1024Points() {
        // Bin spacing is 46.875 Hz here.
        let empty: [Double] = [20, 25, 31.5, 40, 63, 80, 125, 160]
        let filled: [Double] = [50, 100, 200, 250, 500, 1000, 4000, 16000]
        for hz in empty {
            XCTAssertFalse(rtaBandHasBin(centreHz: hz, sampleRateHz: 48000, fftOrder: 10),
                           "the \(hz) Hz band holds no bin at 1024 points / 48 kHz")
        }
        for hz in filled {
            XCTAssertTrue(rtaBandHasBin(centreHz: hz, sampleRateHz: 48000, fftOrder: 10),
                          "the \(hz) Hz band does hold a bin at 1024 points / 48 kHz")
        }
    }

    /// 50 Hz is the band the user notices, because it works while the 40 Hz
    /// band directly below it does not: bin 1 lands at 46.875 Hz, inside the
    /// 50 Hz band's 44.5-56.1 Hz span and above the 40 Hz band's 44.9 Hz top.
    func testFortyHertzIsEmptyWhileFiftyIsNot() {
        XCTAssertFalse(rtaBandHasBin(centreHz: 40, sampleRateHz: 48000, fftOrder: 10))
        XCTAssertTrue(rtaBandHasBin(centreHz: 50, sampleRateHz: 48000, fftOrder: 10))
    }

    /// Halving the transform size doubles the bin spacing, so more bands empty
    /// out - including the 50 Hz one.
    func testSmallerTransformEmptiesMoreBands() {
        XCTAssertTrue(rtaBandHasBin(centreHz: 50, sampleRateHz: 48000, fftOrder: 10))
        XCTAssertFalse(rtaBandHasBin(centreHz: 50, sampleRateHz: 48000, fftOrder: 9))
        XCTAssertFalse(rtaBandHasBin(centreHz: 50, sampleRateHz: 48000, fftOrder: 8))
    }

    /// The full-rate transform resolves a band once a bin centre falls inside
    /// its edges: at 48 kHz, 2048 points reach the 25 Hz band and 1024 points
    /// the 50 Hz band.  The firmware's generated table is the authority; this
    /// heuristic only explains a band that already reads the floor.
    func testBandHasBinFollowsTheTransformSize() {
        XCTAssertTrue(rtaBandHasBin(centreHz: 25, sampleRateHz: 48000, fftOrder: 11))
        XCTAssertTrue(rtaBandHasBin(centreHz: 50, sampleRateHz: 48000, fftOrder: 10))
        XCTAssertFalse(rtaBandHasBin(centreHz: 40, sampleRateHz: 48000, fftOrder: 10))
        XCTAssertFalse(rtaBandHasBin(centreHz: 20, sampleRateHz: 48000, fftOrder: 11))
    }

    /// Exact population per band, matching scripts/gen_rta_tables.py in the
    /// firmware repo: at 48 kHz, 1024 points populate 50 and 100 Hz but not 63
    /// or 80 Hz; 2048 points start at 25 Hz; 512 points start at 100 Hz.
    func testBandIsPopulatedMatchesFirmwareTables() {
        XCTAssertFalse(rtaBandIsPopulated(band: 0, sampleRateHz: 48000, fftOrder: 11))   // 20 Hz
        XCTAssertTrue(rtaBandIsPopulated(band: 1, sampleRateHz: 48000, fftOrder: 11))    // 25 Hz
        XCTAssertTrue(rtaBandIsPopulated(band: 4, sampleRateHz: 48000, fftOrder: 10))    // 50 Hz
        XCTAssertFalse(rtaBandIsPopulated(band: 5, sampleRateHz: 48000, fftOrder: 10))   // 63 Hz
        XCTAssertFalse(rtaBandIsPopulated(band: 6, sampleRateHz: 48000, fftOrder: 10))   // 80 Hz
        XCTAssertTrue(rtaBandIsPopulated(band: 7, sampleRateHz: 48000, fftOrder: 10))    // 100 Hz
        XCTAssertFalse(rtaBandIsPopulated(band: 6, sampleRateHz: 48000, fftOrder: 9))    // 80 Hz
        XCTAssertTrue(rtaBandIsPopulated(band: 7, sampleRateHz: 48000, fftOrder: 9))     // 100 Hz
        XCTAssertTrue(rtaBandIsPopulated(band: 30, sampleRateHz: 48000, fftOrder: 10))   // 20 kHz
    }

    /// Nonsense in, "assume it is measurable" out - the heuristic is only ever
    /// used to explain a band that is already reading the floor, so failing
    /// open can never grey out live data.
    func testBandHasBinFailsOpenOnNonsense() {
        XCTAssertTrue(rtaBandHasBin(centreHz: 0, sampleRateHz: 48000, fftOrder: 10))
        XCTAssertTrue(rtaBandHasBin(centreHz: 1000, sampleRateHz: 0, fftOrder: 10))
        XCTAssertTrue(rtaBandHasBin(centreHz: 1000, sampleRateHz: 48000, fftOrder: 0))
    }

    // MARK: - Display interpolation

    /// The smoothing time constant tracks the rotation interval, so one channel
    /// and nine channels both glide rather than one stepping and the other
    /// crawling.  Zero switches it off entirely.
    func testFallTauTracksRefreshIntervalAndClamps() {
        XCTAssertEqual(rtaFallTau(refreshInterval: 0.19, amount: 0), 0)
        // One channel at 1024 points / 48 kHz: 21 ms, below the floor.
        XCTAssertEqual(rtaFallTau(refreshInterval: 0.021, amount: 0.6), 0.035, accuracy: 0.0001)
        // Nine channels: 192 ms, inside the range.
        XCTAssertEqual(rtaFallTau(refreshInterval: 0.192, amount: 0.6), 0.1152, accuracy: 0.0001)
        // Absurdly long rotation, clamped at the top.
        XCTAssertEqual(rtaFallTau(refreshInterval: 5.0, amount: 1.0), 0.40, accuracy: 0.0001)
    }

    /// The first call adopts the target outright: there is nothing to glide
    /// from, and easing up from zero would flash the whole display on connect.
    func testSmootherAdoptsTheFirstFrame() {
        let s = RtaBarSmoother()
        let out = s.step(now: Date(), target: [-20, -30], identity: 1, riseTau: 0.1, fallTau: 0.1)
        XCTAssertEqual(out, [-20, -30])
    }

    /// A step lands between the old value and the new one, never past it.
    func testSmootherMovesPartwayTowardTheTarget() {
        let s = RtaBarSmoother()
        let t0 = Date()
        _ = s.step(now: t0, target: [-60], identity: 1, riseTau: 0.1, fallTau: 0.1)
        let out = s.step(now: t0.addingTimeInterval(0.033), target: [-20],
                         identity: 1, riseTau: 0.1, fallTau: 0.1)
        XCTAssertGreaterThan(out[0], -60)
        XCTAssertLessThan(out[0], -20)
    }

    /// Repeated steps converge, so a held level settles rather than creeping.
    func testSmootherConverges() {
        let s = RtaBarSmoother()
        var t = Date()
        _ = s.step(now: t, target: [-60], identity: 1, riseTau: 0.05, fallTau: 0.05)
        var out: [Double] = []
        for _ in 0..<60 {
            t = t.addingTimeInterval(1.0 / 30.0)
            out = s.step(now: t, target: [-20], identity: 1, riseTau: 0.05, fallTau: 0.05)
        }
        XCTAssertEqual(out[0], -20, accuracy: 0.01)
    }

    /// A peak cap is passed riseTau 0: it must jump straight to a new peak, or
    /// it stops being a peak, while still easing on the way down.
    func testZeroRiseTauSnapsUpButStillEasesDown() {
        let s = RtaBarSmoother()
        let t0 = Date()
        _ = s.step(now: t0, target: [-60], identity: 1, riseTau: 0, fallTau: 0.2)
        let up = s.step(now: t0.addingTimeInterval(0.033), target: [-10],
                        identity: 1, riseTau: 0, fallTau: 0.2)
        XCTAssertEqual(up[0], -10, accuracy: 0.0001)
        let down = s.step(now: t0.addingTimeInterval(0.066), target: [-60],
                          identity: 1, riseTau: 0, fallTau: 0.2)
        XCTAssertGreaterThan(down[0], -60)
        XCTAssertLessThan(down[0], -10)
    }

    /// Switching channel must snap.  Sliding across would show the new channel
    /// briefly wearing the old channel's levels, which is simply wrong data.
    func testSmootherSnapsWhenTheSeriesChanges() {
        let s = RtaBarSmoother()
        let t0 = Date()
        _ = s.step(now: t0, target: [-60, -60], identity: 1, riseTau: 0.2, fallTau: 0.2)
        let out = s.step(now: t0.addingTimeInterval(0.033), target: [-10, -10],
                         identity: 2, riseTau: 0.2, fallTau: 0.2)
        XCTAssertEqual(out, [-10, -10])
    }

    /// A resize changes the number of columns; the series is replaced rather
    /// than half-filtered against values that meant a different frequency.
    func testSmootherSnapsWhenTheSeriesLengthChanges() {
        let s = RtaBarSmoother()
        let t0 = Date()
        _ = s.step(now: t0, target: [-60, -60], identity: 1, riseTau: 0.2, fallTau: 0.2)
        let out = s.step(now: t0.addingTimeInterval(0.033), target: [-10, -10, -10],
                         identity: 1, riseTau: 0.2, fallTau: 0.2)
        XCTAssertEqual(out, [-10, -10, -10])
    }

    /// Two draws at the same instant must not double-step: a zero or negative
    /// dt leaves the values alone.
    func testSmootherIgnoresARepeatedTimestamp() {
        let s = RtaBarSmoother()
        let t0 = Date()
        _ = s.step(now: t0, target: [-60], identity: 1, riseTau: 0.1, fallTau: 0.1)
        let first = s.step(now: t0.addingTimeInterval(0.033), target: [-20],
                           identity: 1, riseTau: 0.1, fallTau: 0.1)
        let again = s.step(now: t0.addingTimeInterval(0.033), target: [-20],
                           identity: 1, riseTau: 0.1, fallTau: 0.1)
        XCTAssertEqual(first, again)
    }

    // MARK: - Live device (spec §5.1)

    /// Reading the caps is the whole feature probe.  Firmware without the
    /// analyser STALLs it, which is a skip here rather than a failure.
    func testLiveCapsAgreeWithTheSpec() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: 0, index: 2,
                                            length: UInt16(RTA_CAPS_SIZE)),
              let caps = RtaCaps.fromData(d) else {
            throw XCTSkip("Connected firmware has no spectrum analyser.")
        }
        XCTAssertEqual(caps.version, RTA_CFG_VERSION)
        XCTAssertEqual(caps.levelZero, RTA_LEVEL_ZERO_DBFS)
        XCTAssertEqual(caps.maxBands, UInt8(RTA_MAX_BANDS))
        XCTAssertEqual(caps.idleTimeoutMs, 5000)
        XCTAssertGreaterThanOrEqual(caps.fftOrderMax, caps.fftOrderMin)
        XCTAssertLessThanOrEqual(Int(caps.maxBinFrame), RTA_BIN_FRAME_MAX)
    }

    /// The band-centre table is the single source of truth for where a band
    /// sits, so the app's axis labels come from it rather than a table of ours.
    func testLiveBandCentresAreThirdOctaveFrom20Hz() throws {
        let usb = try HardwareTest.requireDevice()
        guard let c = usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: 1, index: 2,
                                            length: UInt16(RTA_CENTRES_PER_CHUNK * 2)),
              c.count >= 8 else {
            throw XCTSkip("Connected firmware has no spectrum analyser.")
        }
        let b = [UInt8](c)
        var centres: [Double] = []
        for i in stride(from: 0, to: b.count - 1, by: 2) {
            centres.append(Double(UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
        }
        XCTAssertEqual(centres.first ?? 0, 20, accuracy: 0.5)
        // Third-octave spacing: each centre is 2^(1/3) times the one below it.
        let ratio = pow(2.0, 1.0 / 3.0)
        for i in 1..<min(centres.count, 12) {
            XCTAssertEqual(centres[i] / centres[i - 1], ratio, accuracy: 0.06,
                           "band \(i) at \(centres[i]) Hz is not a third-octave step")
        }
    }

    /// A configuration the spec calls valid must be accepted and read back, and
    /// the analyser must report itself running once band frames are read.
    func testLiveConfigRoundTripAndAutoStart() throws {
        let usb = try HardwareTest.requireDevice()
        guard let d = usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: 0, index: 2,
                                            length: UInt16(RTA_CAPS_SIZE)),
              let caps = RtaCaps.fromData(d) else {
            throw XCTSkip("Connected firmware has no spectrum analyser.")
        }

        let want = RtaConfig(tap: RTA_TAP_OUTPUT, channelMask: 0x0001,
                             fftOrder: caps.fftOrderDefault,
                             avgMs: 300, peakDecayDBs: 12, flags: 0)
        usb.sendControlRequest(request: REQ_RTA_SET_CONFIG, value: 0, index: 2, data: want.toData())

        // The device applies a staged config from its main loop, so give it a
        // few passes before reading back.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))

        let applied = usb.getControlRequest(request: REQ_RTA_GET_CONFIG, value: 0, index: 2,
                                            length: UInt16(RTA_CONFIG_SIZE))
            .flatMap(RtaConfig.fromData)
        XCTAssertEqual(applied?.tap, want.tap)
        XCTAssertEqual(applied?.channelMask, want.channelMask)
        XCTAssertEqual(applied?.fftOrder, want.fftOrder)

        // A band read counts as a read: it starts the analyser and keeps it
        // alive, which is why the Console never has to send START.
        let frame = usb.getControlRequest(request: REQ_RTA_GET_BANDS, value: 0, index: 2,
                                          length: UInt16(RTA_BAND_FRAME_SIZE))
            .flatMap { RtaBandFrame.fromData($0) }
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.channel, 0)
        XCTAssertGreaterThan(frame?.nBands ?? 0, 0)

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        let status = usb.getControlRequest(request: REQ_RTA_GET_STATUS, value: 0, index: 2,
                                           length: UInt16(RTA_STATUS_SIZE))
            .flatMap(RtaStatus.fromData)
        XCTAssertEqual(status?.isRunning, true, "a band read should have auto-started the analyser")
        XCTAssertEqual(status?.tap, RTA_TAP_OUTPUT)

        // Leave the device as we found it rather than spinning the analyser on
        // for the rest of the run.
        _ = usb.getControlRequest(request: REQ_RTA_CONTROL, value: RTA_CTL_STOP, index: 2, length: 1)
    }

    /// An empty channel mask is a STALL, not a silently-ignored configuration.
    func testLiveEmptyMaskIsRefused() throws {
        let usb = try HardwareTest.requireDevice()
        guard usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: 0, index: 2,
                                    length: UInt16(RTA_CAPS_SIZE)).flatMap(RtaCaps.fromData) != nil else {
            throw XCTSkip("Connected firmware has no spectrum analyser.")
        }
        let good = RtaConfig(tap: RTA_TAP_OUTPUT, channelMask: 0x0001)
        usb.sendControlRequest(request: REQ_RTA_SET_CONFIG, value: 0, index: 2, data: good.toData())
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))

        var empty = good
        empty.channelMask = 0
        usb.sendControlRequest(request: REQ_RTA_SET_CONFIG, value: 0, index: 2, data: empty.toData())
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))

        let applied = usb.getControlRequest(request: REQ_RTA_GET_CONFIG, value: 0, index: 2,
                                            length: UInt16(RTA_CONFIG_SIZE))
            .flatMap(RtaConfig.fromData)
        XCTAssertEqual(applied?.channelMask, 0x0001, "the refused config must not have been applied")
        _ = usb.getControlRequest(request: REQ_RTA_CONTROL, value: RTA_CTL_STOP, index: 2, length: 1)
    }
}
