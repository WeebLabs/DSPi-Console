import Foundation

/// Orchestrates one room-correction measurement session.
///
/// The audio backends and the device preparation are injected as protocols, so
/// the whole flow - including cancellation and failure paths - can be driven in
/// tests without hardware. That matters more here than anywhere else in the
/// feature: the paths worth being sure about are the ones that only happen when
/// something goes wrong, and those are exactly the ones a manual test with a
/// real microphone never reaches.
///
/// See `Documentation/automated_room_correction_spec.md` sections 5.5 and 11.
@MainActor
final class MeasurementSession: ObservableObject {

    /// Where the session is. Mirrors the state machine in section 11.
    enum State: Equatable {
        case idle
        case preparingDevice
        case readyToMeasure
        /// Measuring one speaker at one position.
        case capturing(position: Int, speaker: Int)
        case analyzing(position: Int, speaker: Int)
        /// A position finished; the user decides whether to keep it.
        case positionReview(position: Int)
        case restoringDevice
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparingDevice, .capturing, .analyzing, .restoringDevice: return true
            case .idle, .readyToMeasure, .positionReview, .failed: return false
            }
        }
    }

    /// One speaker's response at one position.
    struct SpeakerMeasurement: Identifiable {
        let id = UUID()
        let speakerIndex: Int
        let magnitudesDb: [Double]
        let quality: CaptureQuality
        let verdict: QualityVerdict
        let latencySeconds: Double
    }

    /// All speakers measured at one microphone position.
    struct Position: Identifiable {
        let id = UUID()
        var name: String
        var measurements: [SpeakerMeasurement]
        /// The main listening position carries more weight in the fit.
        var weight: Double
        var enabled: Bool = true

        var isComplete: Bool { measurements.allSatisfy { $0.verdict.isUsable } }
        var failures: [SpeakerMeasurement] { measurements.filter { !$0.verdict.isUsable } }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var positions: [Position] = []
    /// Progress within the current position, for the UI.
    @Published private(set) var speakersRemaining: Int = 0

    private let capture: AudioCaptureBackend
    private let playback: AudioPlaybackBackend
    private let preparation: DevicePreparing
    /// The grid measurements are analysed on, and therefore the only grid
    /// a fit or a plot of them can use.
    let grid: RoomCorrectionCore.Grid

    private var cancelled = false
    private var prepared = false
    private(set) var mode: MeasurementMode = .inputChannels

    init(capture: AudioCaptureBackend,
         playback: AudioPlaybackBackend,
         preparation: DevicePreparing,
         grid: RoomCorrectionCore.Grid = .standard) {
        self.capture = capture
        self.playback = playback
        self.preparation = preparation
        self.grid = grid
    }

    // MARK: - Session lifecycle

    /// Snapshot and prepare the device.
    ///
    /// Nothing is measured until this succeeds, because a measurement taken
    /// through live dynamics or a live input bank describes something other
    /// than the room.
    func begin(mode: MeasurementMode = .inputChannels,
               correctedChannels: [Int] = []) async throws {
        guard !state.isBusy else { return }
        cancelled = false
        self.mode = mode
        state = .preparingDevice
        do {
            try await preparation.prepare(mode: mode, correctedChannels: correctedChannels)
            prepared = true
            state = .readyToMeasure
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Put the device back exactly as it was.
    ///
    /// Called on success, cancellation and failure alike. The only path that
    /// legitimately skips it is one where preparation never happened.
    func end() async {
        guard prepared else {
            state = .idle
            return
        }
        state = .restoringDevice
        await preparation.restore()
        prepared = false
        state = .idle
    }

    /// Ask the session to stop at the next safe point.
    ///
    /// Stops the audio immediately, because leaving a sweep playing while the
    /// user has asked for it to stop is its own kind of failure.
    func cancel() {
        cancelled = true
        playback.stop()
        _ = capture.stop()
    }

    // MARK: - Measuring

    struct SpeakerPlan {
        /// Index in the current mode's numbering: an input, or an output.
        let speakerIndex: Int
        /// USB input channel to play the sweep into. Host playback can only
        /// drive inputs, so this is always an input index whichever mode is
        /// running.
        let playbackChannel: Int
        let sweep: RoomCorrectionCore.SweepSpec
        let role: RoomCorrectionCore.SpeakerRole
        /// The temporary configuration this sweep needs. Output mode only.
        let forcedPath: ForcedPath?

        init(speakerIndex: Int,
             playbackChannel: Int,
             sweep: RoomCorrectionCore.SweepSpec,
             role: RoomCorrectionCore.SpeakerRole,
             forcedPath: ForcedPath? = nil) {
            self.speakerIndex = speakerIndex
            self.playbackChannel = playbackChannel
            self.sweep = sweep
            self.role = role
            self.forcedPath = forcedPath
        }
    }

    enum SessionError: LocalizedError {
        case notPrepared
        case cancelled
        case noSpeakers

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "The device has not been prepared for measurement."
            case .cancelled:
                return "The measurement was cancelled."
            case .noSpeakers:
                return "No speakers were selected to measure."
            }
        }
    }

    /// Measure every selected speaker at one microphone position.
    ///
    /// A position is a transaction: it is added to the session only when every
    /// speaker in it has been attempted, and the user is shown which ones
    /// failed rather than having the whole position silently discarded.
    @discardableResult
    func measurePosition(name: String,
                         weight: Double,
                         plans: [SpeakerPlan],
                         microphone: AudioDeviceInfo,
                         microphoneChannel: Int,
                         playbackDevice: AudioDeviceInfo,
                         calibration: RoomCorrectionCore.Calibration? = nil) async throws -> Position {
        guard prepared else { throw SessionError.notPrepared }
        guard !plans.isEmpty else { throw SessionError.noSpeakers }

        cancelled = false
        let positionIndex = positions.count
        var measurements: [SpeakerMeasurement] = []
        speakersRemaining = plans.count

        for plan in plans {
            if cancelled { throw SessionError.cancelled }
            state = .capturing(position: positionIndex, speaker: plan.speakerIndex)

            let recording = try await recordSweep(plan: plan,
                                                  microphone: microphone,
                                                  microphoneChannel: microphoneChannel,
                                                  playbackDevice: playbackDevice)
            if cancelled { throw SessionError.cancelled }

            state = .analyzing(position: positionIndex, speaker: plan.speakerIndex)
            measurements.append(analyze(recording: recording,
                                        plan: plan,
                                        calibration: calibration))
            speakersRemaining = max(0, speakersRemaining - 1)
        }

        let position = Position(name: name, measurements: measurements, weight: weight)
        positions.append(position)
        state = .positionReview(position: positionIndex)
        return position
    }

    /// Re-measure one speaker within an already captured position.
    ///
    /// Retrying a single failed speaker is much cheaper for the user than
    /// redoing the position, and the mic has not moved, so the rest of the
    /// position stays valid.
    func remeasure(speaker plan: SpeakerPlan,
                   inPosition positionIndex: Int,
                   microphone: AudioDeviceInfo,
                   microphoneChannel: Int,
                   playbackDevice: AudioDeviceInfo,
                   calibration: RoomCorrectionCore.Calibration? = nil) async throws {
        guard prepared else { throw SessionError.notPrepared }
        guard positions.indices.contains(positionIndex) else { return }

        state = .capturing(position: positionIndex, speaker: plan.speakerIndex)
        let recording = try await recordSweep(plan: plan,
                                              microphone: microphone,
                                              microphoneChannel: microphoneChannel,
                                              playbackDevice: playbackDevice)
        if cancelled { throw SessionError.cancelled }

        state = .analyzing(position: positionIndex, speaker: plan.speakerIndex)
        let measurement = analyze(recording: recording, plan: plan, calibration: calibration)

        if let existing = positions[positionIndex].measurements
            .firstIndex(where: { $0.speakerIndex == plan.speakerIndex }) {
            positions[positionIndex].measurements[existing] = measurement
        } else {
            positions[positionIndex].measurements.append(measurement)
        }
        state = .positionReview(position: positionIndex)
    }

    // MARK: - Position management

    func removePosition(at index: Int) {
        guard positions.indices.contains(index) else { return }
        positions.remove(at: index)
    }

    /// A disabled position is retained in the project but excluded from the
    /// fit, so a user can try excluding one without losing the measurement.
    func setPosition(_ index: Int, enabled: Bool) {
        guard positions.indices.contains(index) else { return }
        positions[index].enabled = enabled
    }

    func setPosition(_ index: Int, weight: Double) {
        guard positions.indices.contains(index) else { return }
        positions[index].weight = weight
    }

    func renamePosition(_ index: Int, to name: String) {
        guard positions.indices.contains(index) else { return }
        positions[index].name = name
    }

    /// Build a fit from everything measured so far for one speaker.
    ///
    /// Finishing before the planned position count is always allowed, so this
    /// works with however many positions exist.
    func makeFit(forSpeaker speakerIndex: Int,
                 sampleRateHz: Double,
                 platform: RoomCorrectionCore.Platform) throws -> RoomCorrectionCore.Fit {
        let fit = try RoomCorrectionCore.Fit(grid: grid,
                                            sampleRateHz: sampleRateHz,
                                            platform: platform)
        for position in positions where position.enabled {
            guard let measurement = position.measurements
                .first(where: { $0.speakerIndex == speakerIndex }),
                  measurement.verdict.isUsable else { continue }
            try fit.addPosition(magnitudesDb: measurement.magnitudesDb,
                                weight: position.weight,
                                enabled: true)
        }
        return fit
    }

    /// Seeds positions without capturing anything.
    ///
    /// Only for previews and render tests: `positions` is otherwise read-only
    /// from outside precisely so nothing in the app can invent a measurement.
    func stubPositions(_ value: [Position]) {
        positions = value
        prepared = true
    }

    // MARK: - Internals

    private func recordSweep(plan: SpeakerPlan,
                             microphone: AudioDeviceInfo,
                             microphoneChannel: Int,
                             playbackDevice: AudioDeviceInfo) async throws -> [Float] {
        let samples = try plan.sweep.render()

        // Output mode measures through a path it builds. Taking it down again
        // is unconditional, including on failure, or the next sweep measures
        // through the previous speaker's configuration.
        //
        // Released with an await rather than from a `defer`, which cannot await
        // and so could only fire the release into a detached task - leaving the
        // next `configure` free to run first and giving exactly the stale path
        // this is here to prevent.
        if let path = plan.forcedPath {
            try await preparation.configure(path: path)
        }

        do {
            let recording = try await playAndCapture(samples: samples,
                                                     plan: plan,
                                                     microphone: microphone,
                                                     microphoneChannel: microphoneChannel,
                                                     playbackDevice: playbackDevice)
            if plan.forcedPath != nil { await preparation.releasePath() }
            return recording
        } catch {
            if plan.forcedPath != nil { await preparation.releasePath() }
            throw error
        }
    }

    private func playAndCapture(samples: [Float],
                                plan: SpeakerPlan,
                                microphone: AudioDeviceInfo,
                                microphoneChannel: Int,
                                playbackDevice: AudioDeviceInfo) async throws -> [Float] {
        // Capture first, always. Starting playback first would race the capture
        // and could clip the beginning of the sweep, and the pre-roll silence
        // is also where the noise floor is measured.
        try capture.start(device: microphone, channelIndex: microphoneChannel)

        do {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try playback.play(samples: samples,
                                      device: playbackDevice,
                                      channelIndex: plan.playbackChannel) { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            // Stop the capture whatever went wrong, or the device stays open
            // and the next measurement fails for a misleading reason.
            _ = capture.stop()
            throw error
        }

        return capture.stop()
    }

    private func analyze(recording: [Float],
                         plan: SpeakerPlan,
                         calibration: RoomCorrectionCore.Calibration?) -> SpeakerMeasurement {
        let quality = MeasurementQualityAnalyzer.analyze(
            recording: recording,
            sweep: plan.sweep,
            captureSampleRate: capture.sampleRate,
            captureDropouts: capture.overloadCount,
            playbackUnderruns: playback.underrunCount,
            calibration: calibration)
        let verdict = MeasurementQualityAnalyzer.verdict(for: quality)

        var magnitudes: [Double] = []
        var latency = 0.0
        // Deconvolving a capture already known to be invalid wastes the user's
        // time and produces a curve that would be misleading if plotted.
        if verdict.isUsable,
           let analysis = try? RoomCorrectionCore.analyze(recording: recording,
                                                          sweep: plan.sweep,
                                                          grid: grid) {
            magnitudes = analysis.magnitudesDb
            latency = analysis.latencySeconds
            if let calibration {
                try? calibration.apply(to: &magnitudes, frequencies: grid.frequencies)
            }
        }

        return SpeakerMeasurement(speakerIndex: plan.speakerIndex,
                                  magnitudesDb: magnitudes,
                                  quality: quality,
                                  verdict: verdict,
                                  latencySeconds: latency)
    }
}

// MARK: - Device preparation

/// Puts the device into a measurable state and back again.
///
/// A protocol so the session can be tested without USB, and so the rules about
/// what must be switched off live in one implementation rather than being
/// scattered through the flow.
///
/// Two levels, because output mode needs both. The session-wide pair snapshots
/// and disables the things that hold for the whole run - dynamics, the upmixer,
/// the input banks being corrected. The per-sweep pair forces the temporary
/// path that output mode measures through, and takes it down again, once per
/// speaker. Input mode uses only the session-wide pair, since it measures the
/// system exactly as the user has it.
///
/// See `Documentation/room_correction_measurement_modes.md`.
protocol DevicePreparing {
    /// Snapshot to the recovery journal, then disable everything that would
    /// make the measurement describe something other than the room.
    func prepare(mode: MeasurementMode, correctedChannels: [Int]) async throws

    /// Force the temporary path for one output-mode sweep: one input to one
    /// output at unity gain, non-inverted, nothing else routed, with the driven
    /// input's and target output's PEQ bypassed.
    ///
    /// Not called in input mode.
    func configure(path: ForcedPath) async throws

    /// Undo one forced path, before the next is applied.
    ///
    /// Routing is restored first, because anything that depends on it is
    /// meaningless until it is back.
    func releasePath() async

    /// Restore the snapshot and clear the journal, but only once the device is
    /// verified back.
    func restore() async
}

extension DevicePreparing {
    /// Input mode needs no forced path, so these default to nothing rather
    /// than forcing every implementation to write two empty methods.
    func configure(path: ForcedPath) async throws {}
    func releasePath() async {}
}
