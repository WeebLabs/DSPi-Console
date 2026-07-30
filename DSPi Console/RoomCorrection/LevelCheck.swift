import Foundation

/// Runs the level check: the step that decides whether the room, the
/// microphone and the playback level can produce a measurement worth having.
///
/// It exists as its own object rather than living in the view because the
/// sequence is stateful and interruptible, and because the decisions it makes -
/// how loud is loud enough, when to refuse - are the kind of thing that has to
/// be testable without a room attached.
///
/// Backends are injected for the same reason the rest of the measurement path
/// injects them: the logic here has to survive being lifted onto WASAPI
/// (spec section 9.2), and it has to run in a test with no audio hardware.
@MainActor
final class LevelCheckController: ObservableObject {

    enum Stage: Equatable {
        case idle
        case measuringNoiseFloor
        /// Between the two captures, so the user can stop moving about.
        case ready
        case playingTone
        case done
        /// Stepping through every channel to record its level.
        case measuringChannels
        case channelsMeasured

        var isBusy: Bool {
            self == .measuringNoiseFloor || self == .playingTone
                || self == .measuringChannels
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var noiseFloorDbfs: Double?
    @Published private(set) var result: LevelCheckResult?
    @Published private(set) var errorMessage: String?
    /// One entry per channel, once the level pass has run.
    @Published private(set) var channelLevels: [ChannelLevel] = []

    /// Live input peak, for the meter. Updated while a capture is running.
    @Published private(set) var inputPeakDbfs: Double = -120

    /// Playback level for the test tone and, once accepted, for the sweeps.
    ///
    /// Starts well down: the first thing this step does is make a noise, and
    /// making it quietly is the recoverable mistake.
    @Published var playbackLevelDbfs: Double = -24

    /// How long to listen for the noise floor.
    ///
    /// Long enough to average over a fridge compressor or a passing car, short
    /// enough that nobody skips it.
    var noiseFloorSeconds: Double = 4
    var toneSeconds: Double = 3

    private let capture: AudioCaptureBackend
    private let playback: AudioPlaybackBackend
    private let thresholds: QualityThresholds

    /// Watches for the measurement chain moving underneath a level pass.
    ///
    /// Injected so a test can drive a gain change, which CoreAudio gives no way
    /// to fake, and so the guard's own rules stay testable separately.
    let chainGuard: MeasurementChainGuard
    private var meterTask: Task<Void, Never>?

    init(capture: AudioCaptureBackend,
         playback: AudioPlaybackBackend,
         thresholds: QualityThresholds = .standard,
         chainGuard: MeasurementChainGuard? = nil) {
        self.capture = capture
        self.playback = playback
        self.thresholds = thresholds
        self.chainGuard = chainGuard ?? MeasurementChainGuard()
    }

    // MARK: - Findings

    /// The noise floor read on its own, before any tone has been played.
    ///
    /// Worth stating separately: a room that is too noisy cannot be fixed by
    /// turning the sweep up, and the user should learn that before they spend
    /// twenty minutes measuring.
    var noiseFloorVerdict: NoiseFloorVerdict? {
        guard let noiseFloorDbfs else { return nil }
        return NoiseFloorVerdict(dbfs: noiseFloorDbfs)
    }

    /// What to do about the current level, or nil if it is fine as it is.
    var suggestedLevelChangeDb: Double? {
        result.flatMap { LevelCheck.suggestedLevelChangeDb(for: $0, thresholds: thresholds) }
    }

    /// True when the measured tone is good enough to sweep with.
    var isLevelAcceptable: Bool {
        guard let result else { return false }
        return !result.clipped && result.estimatedSnrDb >= thresholds.minimumSnrDb
    }

    /// Why the level is not acceptable, in the order worth fixing.
    var problems: [String] {
        guard let result else { return [] }
        var found: [String] = []
        if result.clipped {
            found.append("The microphone input is clipping. Lower the playback level, "
                         + "or reduce the microphone's input gain.")
        }
        if result.estimatedSnrDb < thresholds.minimumSnrDb {
            found.append(String(
                format: "Only %.0f dB above the noise floor. Below about %.0f dB the "
                      + "correction starts describing the room's noise rather than its "
                      + "response.",
                result.estimatedSnrDb, thresholds.minimumSnrDb))
        }
        if !result.clipped && result.headroomDb < 3 {
            found.append(String(format: "Only %.1f dB of headroom. A sweep peaks higher "
                                + "than this tone does.", result.headroomDb))
        }
        return found
    }

    // MARK: - Running

    /// Listen to the room with nothing playing.
    func measureNoiseFloor(microphone: AudioDeviceInfo, channel: Int) async {
        guard !stage.isBusy else { return }
        stage = .measuringNoiseFloor
        errorMessage = nil
        result = nil

        // The chain is pinned here rather than at the level pass, because the
        // noise floor is itself a measurement everything downstream is compared
        // against.
        chainGuard.start(device: microphone.id, uid: microphone.uid)

        do {
            try capture.start(device: microphone, channelIndex: channel)
            startMetering()
            try await sleep(noiseFloorSeconds)
            stopMetering()
            let samples = capture.stop()

            guard !samples.isEmpty else {
                fail("The microphone produced no audio. Check that it is not muted.")
                return
            }
            noiseFloorDbfs = LevelCheck.noiseFloor(from: samples)
            stage = .ready
        } catch {
            _ = capture.stop()
            fail(error.localizedDescription)
        }
    }

    /// Play a tone at the current level and see what comes back.
    ///
    /// The noise floor has to exist first: without it there is no SNR, and a
    /// peak level on its own says nothing about whether a sweep will survive
    /// the room.
    func measureTone(microphone: AudioDeviceInfo,
                     micChannel: Int,
                     playbackDevice: AudioDeviceInfo,
                     playbackChannel: Int,
                     sampleRate: Double) async {
        guard !stage.isBusy else { return }
        guard let noiseFloor = noiseFloorDbfs else {
            fail("Measure the noise floor first.")
            return
        }
        stage = .playingTone
        errorMessage = nil

        let tone = Self.toneSamples(seconds: toneSeconds,
                                    sampleRate: sampleRate,
                                    levelDbfs: playbackLevelDbfs)
        do {
            // Capture first, always: starting playback first races the capture
            // and can clip the beginning of the tone.
            try capture.start(device: microphone, channelIndex: micChannel)
            startMetering()
            try playback.play(samples: tone,
                              device: playbackDevice,
                              channelIndex: playbackChannel) { _ in }

            // Listen slightly past the end so the room's decay is included
            // rather than truncated into the measurement.
            try await sleep(toneSeconds + 0.4)
            playback.stop()
            stopMetering()
            let recorded = capture.stop()

            guard !recorded.isEmpty else {
                fail("The microphone produced no audio while the tone played.")
                return
            }
            if playback.underrunCount > 0 || capture.overloadCount > 0 {
                // Not merely degraded: a gap in either direction moves samples
                // relative to each other, and the level read from it is not the
                // level that was played.
                fail("Audio dropped out during the test. Close other audio "
                     + "applications and try again.")
                return
            }
            result = LevelCheck.assess(toneSamples: recorded, noiseFloorDbfs: noiseFloor)
            stage = .done
        } catch {
            playback.stop()
            _ = capture.stop()
            fail(error.localizedDescription)
        }
    }

    /// Take the tool's advice.
    func applySuggestedLevel() {
        guard let change = suggestedLevelChangeDb else { return }
        playbackLevelDbfs = (playbackLevelDbfs + change).clamped(to: -60...(-3))
    }

    func cancel() {
        playback.stop()
        _ = capture.stop()
        stopMetering()
        stage = noiseFloorDbfs == nil ? .idle : .ready
    }

    /// Discard the tone result but keep the noise floor.
    ///
    /// Re-listening to a quiet room after every level change is a waste of the
    /// user's time; the floor does not move because the tone got louder.
    func retryTone() {
        result = nil
        errorMessage = nil
        if noiseFloorDbfs != nil { stage = .ready }
    }

    // MARK: - Channel levels

    /// Measures every channel's in-band spectral level at the main position.
    ///
    /// The stimulus is limited to each channel's comparison band, so the
    /// captured RMS *is* the in-band level and no spectrum estimate is needed.
    /// Dividing by the band's width in octaves makes the figure independent of
    /// how wide that band is, which is what lets a subwoofer be compared
    /// against a midband channel at all.
    func measureChannelLevels(_ targets: [(speaker: Int,
                                           playbackChannel: Int,
                                           role: RoomCorrectionCore.SpeakerRole)],
                              microphone: AudioDeviceInfo,
                              micChannel: Int,
                              playbackDevice: AudioDeviceInfo,
                              sampleRate: Double) async -> [ChannelLevel] {
        guard !stage.isBusy, noiseFloorDbfs != nil else { return [] }

        // Checked before anything is played as well as from the listeners: a
        // listener installed a moment after a change would miss it entirely,
        // and a level set measured across a gain change is worse than none.
        if let violation = chainGuard.check(currentUID: microphone.uid) {
            fail(violation.explanation + " Restore it and measure again.")
            return []
        }

        stage = .measuringChannels
        errorMessage = nil
        channelLevels = []

        var measured: [ChannelLevel] = []
        for target in targets {
            let band = Self.band(for: target.role)
            let tone = Self.toneSamples(seconds: toneSeconds,
                                        sampleRate: sampleRate,
                                        levelDbfs: playbackLevelDbfs,
                                        band: band)
            do {
                try capture.start(device: microphone, channelIndex: micChannel)
                startMetering()
                try playback.play(samples: tone,
                                  device: playbackDevice,
                                  channelIndex: target.playbackChannel) { _ in }
                try await sleep(toneSeconds + 0.4)
                playback.stop()
                stopMetering()
                let recorded = capture.stop()

                guard !recorded.isEmpty else {
                    fail("No audio came back while measuring the level of channel "
                         + "\(target.speaker + 1).")
                    return []
                }
                if playback.underrunCount > 0 || capture.overloadCount > 0 {
                    fail("Audio dropped out while measuring channel "
                         + "\(target.speaker + 1). Close other audio applications "
                         + "and try again.")
                    return []
                }

                // Re-checked per channel: a pass over eight channels takes
                // long enough for someone to reach for a knob partway through,
                // and the channels measured either side of that are on
                // different scales.
                if let violation = chainGuard.check(currentUID: microphone.uid) {
                    fail(violation.explanation + " Restore it and measure again.")
                    return []
                }

                measured.append(ChannelLevel(
                    speakerIndex: target.speaker,
                    levelDb: Self.spectralLevel(of: recorded, band: band),
                    role: target.role,
                    bandHz: band))
            } catch {
                playback.stop()
                _ = capture.stop()
                fail(error.localizedDescription)
                return []
            }
        }

        channelLevels = measured
        stage = .channelsMeasured
        return measured
    }

    /// The band a channel is compared over.
    ///
    /// A subwoofer cannot be compared in the full-range band, having no output
    /// there, so it is measured over its own passband instead. The figures stay
    /// comparable because the level is per octave.
    static func band(for role: RoomCorrectionCore.SpeakerRole) -> ClosedRange<Double> {
        role == .subwoofer ? 20...80 : ChannelLevelMatch.fullRangeBand
    }

    /// In-band level per octave, in dB relative to full scale.
    ///
    /// The width division is what makes the figure band-independent: without it
    /// a narrow-band subwoofer would read quiet purely for covering less
    /// ground.
    static func spectralLevel(of samples: [Float],
                              band: ClosedRange<Double>) -> Double {
        let total = MeasurementQualityAnalyzer.dbfs(MeasurementQualityAnalyzer.rms(samples))
        let octaves = log2(band.upperBound / band.lowerBound)
        guard octaves > 0 else { return total }
        return total - 10 * log10(octaves)
    }

    // MARK: - Internals

    /// Every caller has already stopped whatever it started, so this only
    /// records the reason. Stopping again here double-stopped the device.
    private func fail(_ message: String) {
        stopMetering()
        errorMessage = message
        stage = noiseFloorDbfs == nil ? .idle : .ready
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let peak = self.capture.peakAndReset()
                self.inputPeakDbfs = MeasurementQualityAnalyzer.dbfs(Double(peak))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    /// Puts the controller into a given state without running a capture.
    ///
    /// Only for tests and previews: the published findings are read-only from
    /// outside precisely so nothing in the app can invent one.
    func stubNoiseFloor(_ dbfs: Double) {
        noiseFloorDbfs = dbfs
        stage = .ready
    }

    func stubResult(_ value: LevelCheckResult) {
        result = value
        stage = .done
    }

    /// Overridable so tests do not spend real seconds waiting.
    var sleep: (_ seconds: Double) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A band-limited noise burst rather than a sine.
    ///
    /// A single tone lands on whatever the room does at that one frequency,
    /// which in a small room can be a 20 dB null - so a sine reads the level as
    /// hopeless in one position and clipping a metre away. Noise across the
    /// range averages that out and is a far better predictor of how a sweep
    /// will actually fare.
    /// The band used when none is given: wide enough to predict how a
    /// full-range sweep will fare, narrow enough to keep the energy where the
    /// speaker can reproduce it.
    static let defaultToneBand: ClosedRange<Double> = 30...12000

    static func toneSamples(seconds: Double,
                            sampleRate: Double,
                            levelDbfs: Double,
                            band: ClosedRange<Double> = defaultToneBand) -> [Float] {
        let count = max(1, Int(seconds * sampleRate))
        let amplitude = pow(10.0, levelDbfs / 20.0)

        // A fixed generator, so the same level setting produces the same test
        // twice and a user comparing two readings is comparing like with like.
        var state: UInt64 = 0x2545F4914F6CDD1D
        var white = [Double](repeating: 0, count: count)
        for index in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            white[index] = Double(Int64(bitPattern: state)) / Double(Int64.max)
        }

        // Four cascaded one-pole sections each way, giving about 24 dB per
        // octave outside the band.
        //
        // A single pole leaks badly, and leakage is not harmless here: a level
        // reading is only comparable between channels if each one is measured
        // over the band it is supposed to be measured over. Energy below 200 Hz
        // in a midband stimulus excites the woofer and reads as midband level.
        let stages = 4
        let lowCoefficient = exp(-2.0 * Double.pi * band.lowerBound / sampleRate)
        let highCoefficient = exp(-2.0 * Double.pi * band.upperBound / sampleRate)

        var shaped = white
        for _ in 0..<stages {
            var state = 0.0
            for index in 0..<count {
                state = shaped[index] + lowCoefficient * state
                shaped[index] = shaped[index] - (1 - lowCoefficient) * state
            }
        }
        for _ in 0..<stages {
            var state = 0.0
            for index in 0..<count {
                state = (1 - highCoefficient) * shaped[index] + highCoefficient * state
                shaped[index] = state
            }
        }

        // Normalize to the requested peak: the filtering above changes the
        // amplitude by an amount that depends on the sample rate, and the user
        // asked for a level, not for whatever fell out.
        let peak = shaped.reduce(0.0) { Swift.max($0, abs($1)) }
        guard peak > 0 else { return [Float](repeating: 0, count: count) }
        let scale = amplitude / peak

        // A short fade at each end: a noise burst starting at full amplitude is
        // a click, which reads as a peak that the tone itself never reached.
        let fade = Swift.min(count / 4, Int(0.02 * sampleRate))
        return (0..<count).map { index in
            var value = shaped[index] * scale
            if fade > 0 {
                if index < fade { value *= Double(index) / Double(fade) }
                let fromEnd = count - 1 - index
                if fromEnd < fade { value *= Double(fromEnd) / Double(fade) }
            }
            return Float(value)
        }
    }
}

/// How liveable the measured noise floor is.
///
/// Stated in dBFS because that is what was measured; converting to SPL would
/// need a calibrated microphone sensitivity, and inventing one would put a
/// confident absolute number in front of the user that is not true.
struct NoiseFloorVerdict: Equatable {
    let dbfs: Double

    enum Rating: Equatable { case quiet, acceptable, noisy, tooNoisy }

    var rating: Rating {
        switch dbfs {
        case ..<(-70): return .quiet
        case ..<(-55): return .acceptable
        case ..<(-40): return .noisy
        default: return .tooNoisy
        }
    }

    var summary: String {
        switch rating {
        case .quiet:
            return "Quiet. The full frequency range should measure cleanly."
        case .acceptable:
            return "Workable. Expect the deepest bass to be the least certain part "
                 + "of the measurement."
        case .noisy:
            return "Noisy. Turn off anything you can - fans, fridges, air "
                 + "conditioning - or the correction will partly describe them."
        case .tooNoisy:
            return "Too noisy to measure reliably. Check that the microphone gain "
                 + "is not set very high, then quieten the room."
        }
    }

    /// A noisy room can still be measured, just less well; refusing outright
    /// would be wrong, since the user may have no quieter time available.
    var blocksMeasurement: Bool { rating == .tooNoisy }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
