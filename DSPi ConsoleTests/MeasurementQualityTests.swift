import XCTest
@testable import DSPi_Console

/// Measurement quality and level check
/// (automated_room_correction_spec.md sections 5.4 and 5.6).
///
/// The point of this layer is that a capture can be unusable for several
/// unrelated reasons, and the user needs to know which. So these tests check
/// not only that a bad capture is rejected, but that the rejection names the
/// cause, and that a merely imperfect capture is still accepted.
final class MeasurementQualityTests: XCTestCase {

    private let sampleRate = 48000.0

    private func sweepSpec(duration: Double = 2.0) throws -> RoomCorrectionCore.SweepSpec {
        var spec = try RoomCorrectionCore.SweepSpec(sampleRateHz: sampleRate, role: .fullRange)
        spec.durationSeconds = duration
        return spec
    }

    /// A capture with a chosen signal level and noise floor.
    private func synthesize(sweep: RoomCorrectionCore.SweepSpec,
                            signalAmplitude: Float,
                            noiseAmplitude: Float,
                            truncateTo fraction: Double = 1.0) -> [Float] {
        let total = Int((sweep.preRollSeconds + sweep.durationSeconds
                         + sweep.postRollSeconds) * sampleRate)
        let preRoll = Int(sweep.preRollSeconds * sampleRate)
        let sweepEnd = preRoll + Int(sweep.durationSeconds * sampleRate)

        var generator = SystemRandomNumberGenerator()
        var samples = [Float](repeating: 0, count: total)
        for index in 0..<total {
            // Deterministic-ish noise is unnecessary here; only levels matter.
            let noise = Float.random(in: -noiseAmplitude...noiseAmplitude, using: &generator)
            if index >= preRoll && index < sweepEnd {
                let phase = 2.0 * Double.pi * 1000.0 * Double(index) / sampleRate
                samples[index] = signalAmplitude * Float(sin(phase)) + noise
            } else {
                samples[index] = noise
            }
        }
        if fraction < 1.0 {
            samples = Array(samples.prefix(Int(Double(total) * fraction)))
        }
        return samples
    }

    // MARK: - Metrics

    func testCleanCaptureMeasuresItsOwnLevels() throws {
        let sweep = try sweepSpec()
        // 0.3 peak sine is about -13 dBFS peak, -16 dBFS RMS; noise at 0.0005
        // is roughly -70 dBFS, so SNR should be comfortably over 40 dB.
        let recording = synthesize(sweep: sweep, signalAmplitude: 0.3, noiseAmplitude: 0.0005)
        let quality = MeasurementQualityAnalyzer.analyze(recording: recording,
                                                         sweep: sweep,
                                                         captureSampleRate: sampleRate)

        XCTAssertEqual(quality.clippedSampleCount, 0)
        XCTAssertEqual(quality.peakDbfs, -10.5, accuracy: 2.0)
        XCTAssertGreaterThan(quality.signalToNoiseDb, 40)
        XCTAssertEqual(quality.completeness, 1.0, accuracy: 0.01)
        XCTAssertFalse(quality.bandSignalToNoiseDb.isEmpty)
    }

    func testCompletenessCatchesATruncatedRecording() throws {
        // A truncated capture otherwise looks like a perfectly good measurement
        // of a room with no reverberation, which is the worst kind of failure:
        // plausible and wrong.
        let sweep = try sweepSpec()
        let recording = synthesize(sweep: sweep, signalAmplitude: 0.3,
                                   noiseAmplitude: 0.0005, truncateTo: 0.7)
        let quality = MeasurementQualityAnalyzer.analyze(recording: recording,
                                                         sweep: sweep,
                                                         captureSampleRate: sampleRate)
        XCTAssertEqual(quality.completeness, 0.7, accuracy: 0.02)
        XCTAssertFalse(MeasurementQualityAnalyzer.verdict(for: quality).isUsable)
    }

    func testCompletenessUsesTheCaptureRateNotThePlaybackRate() throws {
        // The two devices are independent. Using the playback rate to size the
        // expectation would report a false truncation on any system where they
        // differ, which is most of them.
        let sweep = try sweepSpec()
        let recording = synthesize(sweep: sweep, signalAmplitude: 0.3, noiseAmplitude: 0.0005)

        // Same recording, assessed as if captured at 44.1 kHz: it is now longer
        // than expected, so completeness saturates at 1 rather than exceeding it.
        let quality = MeasurementQualityAnalyzer.analyze(recording: recording,
                                                         sweep: sweep,
                                                         captureSampleRate: 44100)
        XCTAssertEqual(quality.completeness, 1.0, accuracy: 1e-9)
    }

    func testEmptyRecordingDoesNotCrash() throws {
        let quality = MeasurementQualityAnalyzer.analyze(recording: [],
                                                         sweep: try sweepSpec(),
                                                         captureSampleRate: sampleRate)
        XCTAssertEqual(quality.peakDbfs, -120)
    }

    // MARK: - Verdicts

    func testClippingFailsAndSaysSo() throws {
        let sweep = try sweepSpec()
        var recording = synthesize(sweep: sweep, signalAmplitude: 0.5, noiseAmplitude: 0.0005)
        recording[recording.count / 2] = 1.0

        let quality = MeasurementQualityAnalyzer.analyze(recording: recording,
                                                         sweep: sweep,
                                                         captureSampleRate: sampleRate)
        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)
        XCTAssertFalse(verdict.isUsable)
        XCTAssertTrue(verdict.messages.contains { $0.lowercased().contains("clip") },
                      "\(verdict.messages)")
    }

    func testLowSignalToNoiseFails() throws {
        let sweep = try sweepSpec()
        let recording = synthesize(sweep: sweep, signalAmplitude: 0.01, noiseAmplitude: 0.008)
        let quality = MeasurementQualityAnalyzer.analyze(recording: recording,
                                                         sweep: sweep,
                                                         captureSampleRate: sampleRate)
        XCTAssertLessThan(quality.signalToNoiseDb, 15)
        XCTAssertFalse(MeasurementQualityAnalyzer.verdict(for: quality).isUsable)
    }

    func testModerateSignalToNoiseWarnsButStaysUsable() throws {
        // Between the 15 dB floor and the 30 dB recommendation the measurement
        // is still worth having; refusing it would be worse than flagging it.
        var quality = CaptureQuality()
        quality.signalToNoiseDb = 22
        quality.completeness = 1
        quality.peakDbfs = -12

        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)
        XCTAssertTrue(verdict.isUsable)
        if case .warn = verdict {} else { XCTFail("expected a warning, got \(verdict)") }
    }

    func testDropoutsAndUnderrunsAreFailuresNotWarnings() {
        var dropped = CaptureQuality()
        dropped.signalToNoiseDb = 50
        dropped.captureDropouts = 2
        XCTAssertFalse(MeasurementQualityAnalyzer.verdict(for: dropped).isUsable)

        var underran = CaptureQuality()
        underran.signalToNoiseDb = 50
        underran.playbackUnderruns = 1
        let verdict = MeasurementQualityAnalyzer.verdict(for: underran)
        XCTAssertFalse(verdict.isUsable)
        // The reason matters: the sweep that reached the speaker was not the
        // one the analysis deconvolved against.
        XCTAssertTrue(verdict.messages.contains { $0.contains("measured against") },
                      "\(verdict.messages)")
    }

    func testDeviceClippingIsAFailure() {
        var quality = CaptureQuality()
        quality.signalToNoiseDb = 50
        quality.deviceClipped = true
        XCTAssertFalse(MeasurementQualityAnalyzer.verdict(for: quality).isUsable)
    }

    func testMissingCalibrationWarnsWithoutRejecting() {
        var quality = CaptureQuality()
        quality.signalToNoiseDb = 50
        quality.hasCalibration = false
        quality.calibrationCoversRange = false

        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)
        XCTAssertTrue(verdict.isUsable)
        XCTAssertTrue(verdict.messages.contains { $0.lowercased().contains("calibration") })
    }

    func testPerfectCaptureProducesNoMessages() {
        var quality = CaptureQuality()
        quality.signalToNoiseDb = 55
        quality.peakDbfs = -12
        quality.completeness = 1
        XCTAssertEqual(MeasurementQualityAnalyzer.verdict(for: quality), .pass)
    }

    func testFailuresSuppressWarningsSoTheCauseIsClear() {
        // With several things wrong at once, listing warnings alongside the
        // blocking cause buries it.
        var quality = CaptureQuality()
        quality.clippedSampleCount = 10
        quality.signalToNoiseDb = 5
        quality.hasCalibration = false

        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)
        XCTAssertFalse(verdict.isUsable)
        XCTAssertFalse(verdict.messages.contains { $0.lowercased().contains("calibration") })
    }

    func testLowFrequencySnrIsFlaggedSeparately() {
        // Bass SNR is usually the binding constraint and is invisible in the
        // broadband figure, which the midrange dominates.
        var quality = CaptureQuality()
        quality.signalToNoiseDb = 45
        quality.peakDbfs = -12
        quality.completeness = 1
        quality.bandSignalToNoiseDb = [(31.25, 12), (63, 20), (1000, 50)]

        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)
        XCTAssertTrue(verdict.isUsable)
        XCTAssertTrue(verdict.messages.contains { $0.contains("31") || $0.contains("bass") },
                      "\(verdict.messages)")
    }

    // MARK: - Band SNR

    func testBandSnrLocatesEnergyInTheRightBand() {
        // A 1 kHz tone against broadband noise must show its best SNR in the
        // 1 kHz band, not somewhere else.
        let duration = 1.0
        let count = Int(duration * sampleRate)
        var generator = SystemRandomNumberGenerator()

        var signal = [Float](repeating: 0, count: count)
        var noise = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let phase = 2.0 * Double.pi * 1000.0 * Double(index) / sampleRate
            signal[index] = 0.3 * Float(sin(phase))
                + Float.random(in: -0.001...0.001, using: &generator)
            noise[index] = Float.random(in: -0.001...0.001, using: &generator)
        }

        let bands = MeasurementQualityAnalyzer.octaveBandSnr(signal: signal,
                                                             noise: noise,
                                                             sampleRate: sampleRate,
                                                             range: 20...20000)
        let best = bands.max { $0.snrDb < $1.snrDb }
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.centreHz ?? 0, 1000, accuracy: 1.0)
    }

    // MARK: - Level check

    func testLevelCheckMeasuresNoiseFloorAndSnr() {
        var generator = SystemRandomNumberGenerator()
        let silence = (0..<4800).map { _ in
            Float.random(in: -0.001...0.001, using: &generator)
        }
        let floor = LevelCheck.noiseFloor(from: silence)
        XCTAssertLessThan(floor, -50)

        let tone = (0..<4800).map { index -> Float in
            0.2 * Float(sin(2.0 * Double.pi * 500.0 * Double(index) / sampleRate))
        }
        let result = LevelCheck.assess(toneSamples: tone, noiseFloorDbfs: floor)
        XCTAssertFalse(result.clipped)
        XCTAssertGreaterThan(result.estimatedSnrDb, 30)
        XCTAssertGreaterThan(result.headroomDb, 6)
    }

    func testLevelCheckSuggestsAReductionWhenClipping() {
        let result = LevelCheckResult(noiseFloorDbfs: -70, peakDbfs: 0,
                                      rmsDbfs: -6, estimatedSnrDb: 64, clipped: true)
        let change = LevelCheck.suggestedLevelChangeDb(for: result)
        XCTAssertNotNil(change)
        XCTAssertLessThan(change ?? 0, 0)
    }

    func testLevelCheckSuggestsAnIncreaseWhenQuietWithHeadroom() {
        let result = LevelCheckResult(noiseFloorDbfs: -50, peakDbfs: -40,
                                      rmsDbfs: -45, estimatedSnrDb: 5, clipped: false)
        let change = LevelCheck.suggestedLevelChangeDb(for: result)
        XCTAssertNotNil(change)
        XCTAssertGreaterThan(change ?? 0, 0)
    }

    func testLevelCheckNeverSuggestsAnIncreaseThatWouldClip() {
        // Headroom binds, not SNR. Suggesting more level because the room is
        // noisy, when there is no headroom left, would trade a poor measurement
        // for an invalid one.
        let result = LevelCheckResult(noiseFloorDbfs: -20, peakDbfs: -1,
                                      rmsDbfs: -6, estimatedSnrDb: 14, clipped: false)
        let change = LevelCheck.suggestedLevelChangeDb(for: result) ?? 0
        XCTAssertLessThanOrEqual(change, 0)
    }

    func testLevelCheckIsHappyWhenNothingNeedsChanging() {
        let result = LevelCheckResult(noiseFloorDbfs: -70, peakDbfs: -12,
                                      rmsDbfs: -18, estimatedSnrDb: 52, clipped: false)
        XCTAssertNil(LevelCheck.suggestedLevelChangeDb(for: result))
    }
}
