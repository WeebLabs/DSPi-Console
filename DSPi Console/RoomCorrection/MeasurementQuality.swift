import Foundation

/// Quality assessment for a single capture.
///
/// The spec is explicit that validity must not be reduced to one green check
/// (section 5.6), and the reason is practical: a measurement can be unusable
/// for several unrelated causes, and telling the user only "failed" leaves them
/// guessing which. Every metric here is retained and shown, and the verdict is
/// derived from them rather than replacing them.
struct CaptureQuality: Equatable {

    /// Highest absolute sample seen, in dBFS.
    var peakDbfs: Double = -120
    /// Number of samples at or beyond full scale.
    var clippedSampleCount: Int = 0

    /// Level of the pre-roll silence, which is the room plus the input chain.
    var noiseFloorDbfs: Double = -120
    /// Level of the swept portion.
    var signalDbfs: Double = -120
    /// Broadband signal-to-noise, in dB.
    var signalToNoiseDb: Double = 0

    /// Signal-to-noise per octave band. Low-frequency SNR is usually the
    /// binding constraint in a real room and is invisible in the broadband
    /// figure, which is dominated by the midrange.
    var bandSignalToNoiseDb: [(centreHz: Double, snrDb: Double)] = []

    /// Fraction of the expected capture that actually arrived. Short of 1 means
    /// the recording was truncated, and the tail of the impulse response with it.
    var completeness: Double = 1

    /// Dropped input buffers reported by the capture device.
    var captureDropouts: Int = 0
    /// Render callbacks that ran dry during playback.
    var playbackUnderruns: Int = 0
    /// Whether the DSPi latched a clip during the sweep.
    var deviceClipped: Bool = false

    /// Whether the microphone calibration spans the analysis range. Outside its
    /// range the core holds the endpoint value rather than extrapolating, so a
    /// short file is usable but the result is less trustworthy at the edges.
    var calibrationCoversRange: Bool = true
    var hasCalibration: Bool = true

    static func == (lhs: CaptureQuality, rhs: CaptureQuality) -> Bool {
        lhs.peakDbfs == rhs.peakDbfs
            && lhs.clippedSampleCount == rhs.clippedSampleCount
            && lhs.noiseFloorDbfs == rhs.noiseFloorDbfs
            && lhs.signalDbfs == rhs.signalDbfs
            && lhs.signalToNoiseDb == rhs.signalToNoiseDb
            && lhs.completeness == rhs.completeness
            && lhs.captureDropouts == rhs.captureDropouts
            && lhs.playbackUnderruns == rhs.playbackUnderruns
            && lhs.deviceClipped == rhs.deviceClipped
            && lhs.calibrationCoversRange == rhs.calibrationCoversRange
            && lhs.hasCalibration == rhs.hasCalibration
    }
}

/// What to do with a capture.
enum QualityVerdict: Equatable {
    /// Usable, with nothing worth mentioning.
    case pass
    /// Usable, but the user should know why it is not ideal.
    case warn([String])
    /// Not usable. Accepting it would produce a correction built on a
    /// measurement that does not describe the room.
    case fail([String])

    var isUsable: Bool {
        switch self {
        case .pass, .warn: return true
        case .fail: return false
        }
    }

    var messages: [String] {
        switch self {
        case .pass: return []
        case .warn(let reasons), .fail(let reasons): return reasons
        }
    }
}

/// Thresholds, gathered so they are stated once and can be tuned together.
struct QualityThresholds {
    /// Below this the measurement is rejected outright.
    var minimumSnrDb: Double = 15
    /// Below this it is usable but flagged.
    var recommendedSnrDb: Double = 30
    /// Peak above this risks clipping even if no sample actually hit full scale.
    var peakWarningDbfs: Double = -3
    /// Any less of the expected capture than this and the tail is gone.
    var minimumCompleteness: Double = 0.98

    /// For a signal judged on its broadband level, with no processing gain to
    /// come: the level check's noise burst, where what is measured is what the
    /// analysis gets.
    static let standard = QualityThresholds()

    /// For a swept sine.
    ///
    /// The figure recorded here is the *raw broadband* ratio, which is not the
    /// signal to noise of the finished measurement. Deconvolution concentrates
    /// the sweep's energy at each frequency into the impulse response while the
    /// noise stays spread across the whole recording, so a sweep of several
    /// seconds gains tens of decibels over the raw number. Holding a sweep to a
    /// noise burst's threshold rejects measurements that deconvolve cleanly.
    ///
    /// The honest quantity would be the signal to noise of the deconvolved
    /// response, which the core does not currently report. Until it does, these
    /// thresholds are set where the raw figure stops being recoverable rather
    /// than where it would need to be if there were no processing gain.
    static let sweep = QualityThresholds(minimumSnrDb: 6,
                                         recommendedSnrDb: 20)
}

// MARK: - Analysis

enum MeasurementQualityAnalyzer {

    /// Assess a capture against the sweep it was supposed to record.
    ///
    /// `expectedSamples` is what the sweep asked for; comparing against the
    /// actual length is how a truncated recording is caught, which otherwise
    /// looks like a perfectly good measurement of a room with no reverberation.
    static func analyze(recording: [Float],
                        sweep: RoomCorrectionCore.SweepSpec,
                        captureSampleRate: Double,
                        captureDropouts: Int = 0,
                        playbackUnderruns: Int = 0,
                        deviceClipped: Bool = false,
                        calibration: RoomCorrectionCore.Calibration? = nil,
                        analysisRange: ClosedRange<Double> = 20...20000) -> CaptureQuality {
        var quality = CaptureQuality()
        quality.captureDropouts = captureDropouts
        quality.playbackUnderruns = playbackUnderruns
        quality.deviceClipped = deviceClipped

        if let calibration {
            quality.hasCalibration = true
            quality.calibrationCoversRange = calibration.covers(minHz: analysisRange.lowerBound,
                                                                maxHz: analysisRange.upperBound)
        } else {
            quality.hasCalibration = false
            quality.calibrationCoversRange = false
        }

        guard !recording.isEmpty, captureSampleRate > 0 else { return quality }

        // Expected length is computed at the *capture* rate, not the playback
        // rate. The two devices are independent, and using the wrong one would
        // report a false truncation on any system where they differ.
        let expectedSeconds = sweep.preRollSeconds + sweep.durationSeconds + sweep.postRollSeconds
        let expectedSamples = Int(expectedSeconds * captureSampleRate)
        quality.completeness = expectedSamples > 0
            ? min(1.0, Double(recording.count) / Double(expectedSamples))
            : 1.0

        var peak: Float = 0
        var clipped = 0
        for sample in recording {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            if magnitude >= 0.999 { clipped += 1 }
        }
        quality.peakDbfs = dbfs(Double(peak))
        quality.clippedSampleCount = clipped

        let noiseEnd = min(recording.count, Int(sweep.preRollSeconds * captureSampleRate))
        let noise = Array(recording[0..<max(0, noiseEnd)])
        let signalStart = noiseEnd
        let signalEnd = min(recording.count,
                            signalStart + Int(sweep.durationSeconds * captureSampleRate))
        let signal = signalStart < signalEnd ? Array(recording[signalStart..<signalEnd]) : []

        quality.noiseFloorDbfs = dbfs(rms(noise))
        quality.signalDbfs = dbfs(rms(signal))
        quality.signalToNoiseDb = quality.signalDbfs - quality.noiseFloorDbfs

        if !noise.isEmpty && !signal.isEmpty {
            quality.bandSignalToNoiseDb = octaveBandSnr(signal: signal,
                                                        noise: noise,
                                                        sampleRate: captureSampleRate,
                                                        range: analysisRange)
        }

        return quality
    }

    /// Turn metrics into a decision.
    ///
    /// Failures are the conditions under which the measurement does not
    /// describe the room; warnings are conditions under which it does, but less
    /// well than it could.
    /// Defaults to the sweep thresholds, because every caller here is judging a
    /// sweep. The level check passes `.standard` explicitly for its noise burst.
    static func verdict(for quality: CaptureQuality,
                        thresholds: QualityThresholds = .sweep) -> QualityVerdict {
        var failures: [String] = []
        var warnings: [String] = []

        if quality.clippedSampleCount > 0 {
            failures.append("The microphone input clipped on \(quality.clippedSampleCount) "
                            + "samples. Lower the level and measure again.")
        }
        if quality.deviceClipped {
            failures.append("The DSPi reported clipping during the sweep. Lower the output "
                            + "level and measure again.")
        }
        if quality.captureDropouts > 0 {
            failures.append("The recording dropped \(quality.captureDropouts) buffers, so part "
                            + "of the response is missing.")
        }
        if quality.playbackUnderruns > 0 {
            failures.append("Playback ran dry \(quality.playbackUnderruns) times, so the sweep "
                            + "that reached the speaker was not the one that was measured against.")
        }
        if quality.completeness < thresholds.minimumCompleteness {
            let percent = Int((quality.completeness * 100).rounded())
            failures.append("Only \(percent)% of the expected recording arrived, so the tail of "
                            + "the response is missing.")
        }
        if quality.signalToNoiseDb < thresholds.minimumSnrDb {
            failures.append(String(format: "The sweep was only %.0f dB above the noise floor, "
                                   + "which is too little for the deconvolution to recover a "
                                   + "clean response. Raise the level, raise the microphone "
                                   + "gain, or quieten the room.", quality.signalToNoiseDb))
        }

        if failures.isEmpty {
            if quality.signalToNoiseDb < thresholds.recommendedSnrDb {
                warnings.append(String(format: "The sweep was %.0f dB above the noise floor. "
                                       + "%.0f dB or more gives the deepest bass more margin, "
                                       + "though the sweep recovers a good deal below that.",
                                       quality.signalToNoiseDb, thresholds.recommendedSnrDb))
            }
            if quality.peakDbfs > thresholds.peakWarningDbfs {
                warnings.append(String(format: "The input peaked at %.1f dBFS, close to clipping.",
                                       quality.peakDbfs))
            }
            if !quality.hasCalibration {
                warnings.append("No microphone calibration is loaded, so the measured tonal "
                                + "balance is only as accurate as the microphone.")
            } else if !quality.calibrationCoversRange {
                warnings.append("The calibration file does not cover the whole analysis range; "
                                + "outside it the last known value is held rather than "
                                + "extrapolated.")
            }
            // Low-frequency SNR is usually the binding constraint and is
            // invisible in the broadband figure, which the midrange dominates.
            if let worst = quality.bandSignalToNoiseDb
                .filter({ $0.centreHz <= 125 })
                .min(by: { $0.snrDb < $1.snrDb }),
               worst.snrDb < thresholds.recommendedSnrDb {
                warnings.append(String(format: "Signal-to-noise at %.0f Hz is only %.0f dB, so "
                                       + "the bass correction will be less reliable than the rest.",
                                       worst.centreHz, worst.snrDb))
            }
        }

        if !failures.isEmpty { return .fail(failures) }
        if !warnings.isEmpty { return .warn(warnings) }
        return .pass
    }

    // MARK: - Signal helpers

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot()
    }

    static func dbfs(_ amplitude: Double) -> Double {
        amplitude <= 1e-12 ? -120 : 20 * log10(amplitude)
    }

    /// Per-octave signal-to-noise.
    ///
    /// Uses the app's existing verified biquad design rather than a new filter
    /// implementation: a second-order high-pass and low-pass in cascade give a
    /// serviceable octave band, and reusing `DSPMath` means this cannot drift
    /// from the filter maths the rest of the app already trusts.
    static func octaveBandSnr(signal: [Float],
                              noise: [Float],
                              sampleRate: Double,
                              range: ClosedRange<Double>) -> [(centreHz: Double, snrDb: Double)] {
        var results: [(centreHz: Double, snrDb: Double)] = []
        var centre = 31.25
        while centre <= range.upperBound && centre < sampleRate * 0.4 {
            defer { centre *= 2 }
            guard centre >= range.lowerBound else { continue }

            let low = centre / sqrt(2.0)
            let high = min(centre * sqrt(2.0), sampleRate * 0.45)
            guard high > low else { continue }

            let signalLevel = rms(bandpass(signal, lowHz: low, highHz: high, sampleRate: sampleRate))
            let noiseLevel = rms(bandpass(noise, lowHz: low, highHz: high, sampleRate: sampleRate))
            results.append((centre, dbfs(signalLevel) - dbfs(noiseLevel)))
        }
        return results
    }

    private static func bandpass(_ samples: [Float],
                                 lowHz: Double,
                                 highHz: Double,
                                 sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var highPass = FilterParams()
        highPass.type = .highPass
        highPass.freq = Float(lowHz)
        highPass.q = 0.707

        var lowPass = FilterParams()
        lowPass.type = .lowPass
        lowPass.freq = Float(highHz)
        lowPass.q = 0.707

        var output = apply(highPass, to: samples, sampleRate: sampleRate)
        output = apply(lowPass, to: output, sampleRate: sampleRate)
        return output
    }

    /// Transposed direct form II, matching the structure the device runs.
    private static func apply(_ params: FilterParams,
                              to samples: [Float],
                              sampleRate: Double) -> [Float] {
        let coefficients = DSPMath.calculateCoefficients(p: params, rate: sampleRate)
        var z1 = 0.0
        var z2 = 0.0
        var output = [Float](repeating: 0, count: samples.count)
        for index in 0..<samples.count {
            let x = Double(samples[index])
            let y = coefficients.b0 * x + z1
            z1 = coefficients.b1 * x - coefficients.a1 * y + z2
            z2 = coefficients.b2 * x - coefficients.a2 * y
            output[index] = Float(y)
        }
        return output
    }
}

// MARK: - Level check

/// The pre-measurement level check.
///
/// Its job is to stop an invalid or unsafe session before it starts, which is
/// cheaper for the user than discovering after nine positions that everything
/// clipped.
struct LevelCheckResult: Equatable {
    var noiseFloorDbfs: Double
    var peakDbfs: Double
    var rmsDbfs: Double
    var estimatedSnrDb: Double
    var clipped: Bool

    /// Headroom between the current peak and full scale.
    var headroomDb: Double { -peakDbfs }
}

enum LevelCheck {
    /// Measure the room's noise floor from a silent capture.
    static func noiseFloor(from samples: [Float]) -> Double {
        MeasurementQualityAnalyzer.dbfs(MeasurementQualityAnalyzer.rms(samples))
    }

    /// Assess a test-tone capture against a previously measured noise floor.
    static func assess(toneSamples: [Float], noiseFloorDbfs: Double) -> LevelCheckResult {
        var peak: Float = 0
        var clipped = false
        for sample in toneSamples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            if magnitude >= 0.999 { clipped = true }
        }
        let rmsDbfs = MeasurementQualityAnalyzer.dbfs(MeasurementQualityAnalyzer.rms(toneSamples))
        return LevelCheckResult(noiseFloorDbfs: noiseFloorDbfs,
                                peakDbfs: MeasurementQualityAnalyzer.dbfs(Double(peak)),
                                rmsDbfs: rmsDbfs,
                                estimatedSnrDb: rmsDbfs - noiseFloorDbfs,
                                clipped: clipped)
    }

    /// Suggest a playback level change.
    ///
    /// Returns a delta in dB rather than an absolute level, because the
    /// relationship between playback level and captured level depends on the
    /// amplifier, the speaker and the room, none of which we know.
    static func suggestedLevelChangeDb(for result: LevelCheckResult,
                                       thresholds: QualityThresholds = .standard) -> Double? {
        if result.clipped { return -6 }
        // Aim for a comfortable peak, but never suggest an increase that would
        // clip: headroom is the binding constraint, not SNR.
        if result.estimatedSnrDb < thresholds.recommendedSnrDb {
            let wanted = thresholds.recommendedSnrDb - result.estimatedSnrDb
            let available = max(0, result.headroomDb - 6)
            let increase = min(wanted, available)
            return increase >= 1 ? increase : nil
        }
        if result.peakDbfs > thresholds.peakWarningDbfs { return -3 }
        return nil
    }
}
