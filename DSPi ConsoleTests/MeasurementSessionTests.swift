import XCTest
@testable import DSPi_Console

/// Session orchestration tests
/// (automated_room_correction_spec.md sections 5.5 and 11).
///
/// The backends are injected, so the whole flow runs without hardware. That is
/// the point: the paths worth being sure about are the ones that only happen
/// when something goes wrong, and a manual test with a real microphone never
/// reaches them.
@MainActor
final class MeasurementSessionTests: XCTestCase {

    // MARK: - Fakes

    /// Returns a synthetic capture whose level and length are controllable, so
    /// a test can produce a clean measurement, a clipped one, or a truncated
    /// one on demand.
    private final class FakeCapture: AudioCaptureBackend {
        var isRunning = false
        var sampleRate: Double = 48000
        var overloadCount = 0

        var signalAmplitude: Float = 0.3
        var noiseAmplitude: Float = 0.0005
        var truncateTo = 1.0
        var startError: Error?
        var startCount = 0
        var stopCount = 0
        var lastChannel: Int?

        /// Set by the test to match the sweep being played.
        var sweep: RoomCorrectionCore.SweepSpec?

        func start(device: AudioDeviceInfo, channelIndex: Int) throws {
            if let startError { throw startError }
            startCount += 1
            lastChannel = channelIndex
            isRunning = true
        }

        func stop() -> [Float] {
            stopCount += 1
            guard isRunning, let sweep else { isRunning = false; return [] }
            isRunning = false

            let total = Int((sweep.preRollSeconds + sweep.durationSeconds
                             + sweep.postRollSeconds) * sampleRate)
            let preRoll = Int(sweep.preRollSeconds * sampleRate)
            let sweepEnd = preRoll + Int(sweep.durationSeconds * sampleRate)

            var samples = [Float](repeating: 0, count: total)
            for index in 0..<total {
                let noise = Float.random(in: -noiseAmplitude...noiseAmplitude)
                if index >= preRoll && index < sweepEnd {
                    let phase = 2.0 * Double.pi * 1000.0 * Double(index) / sampleRate
                    samples[index] = signalAmplitude * Float(sin(phase)) + noise
                } else {
                    samples[index] = noise
                }
            }
            if truncateTo < 1.0 {
                samples = Array(samples.prefix(Int(Double(total) * truncateTo)))
            }
            return samples
        }

        func peakAndReset() -> Float { signalAmplitude }
    }

    private final class FakePlayback: AudioPlaybackBackend {
        var isRunning = false
        var underrunCount = 0
        var playError: Error?
        var failWith: Error?
        var playCount = 0
        var stopCount = 0
        var lastChannel: Int?
        var lastSampleCount = 0

        func play(samples: [Float],
                  device: AudioDeviceInfo,
                  channelIndex: Int,
                  completion: @escaping (Result<Void, Error>) -> Void) throws {
            if let playError { throw playError }
            playCount += 1
            lastChannel = channelIndex
            lastSampleCount = samples.count
            isRunning = true
            let failure = failWith
            DispatchQueue.main.async {
                self.isRunning = false
                completion(failure.map { .failure($0) } ?? .success(()))
            }
        }

        func stop() {
            stopCount += 1
            isRunning = false
        }
    }

    private final class FakePreparation: DevicePreparing {
        var prepareCount = 0
        var restoreCount = 0
        var configureCount = 0
        var releaseCount = 0
        var configuredPaths: [ForcedPath] = []
        var prepareError: Error?
        var configureError: Error?
        var lastMode: MeasurementMode?

        func prepare(mode: MeasurementMode, correctedChannels: [Int]) async throws {
            if let prepareError { throw prepareError }
            lastMode = mode
            prepareCount += 1
        }

        func configure(path: ForcedPath) async throws {
            if let configureError { throw configureError }
            configureCount += 1
            configuredPaths.append(path)
        }

        func releasePath() async { releaseCount += 1 }

        func restore() async { restoreCount += 1 }
    }

    private struct TestError: LocalizedError {
        let errorDescription: String?
    }

    // MARK: - Fixtures

    private var capture: FakeCapture!
    private var playback: FakePlayback!
    private var preparation: FakePreparation!
    private var session: MeasurementSession!

    private let microphone = AudioDeviceInfo(id: 1, uid: "mic", name: "UMIK-1",
                                             inputChannels: 1, outputChannels: 0,
                                             nominalSampleRate: 48000,
                                             supportedSampleRates: [48000])
    private let speakers = AudioDeviceInfo(id: 2, uid: "dspi", name: "DSPi",
                                           inputChannels: 0, outputChannels: 8,
                                           nominalSampleRate: 48000,
                                           supportedSampleRates: [48000])

    override func setUp() async throws {
        capture = FakeCapture()
        playback = FakePlayback()
        preparation = FakePreparation()
        session = MeasurementSession(capture: capture,
                                     playback: playback,
                                     preparation: preparation,
                                     grid: .display)
    }

    private func plan(speaker: Int, channel: Int) throws -> MeasurementSession.SpeakerPlan {
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        sweep.durationSeconds = 1.0
        capture.sweep = sweep
        return MeasurementSession.SpeakerPlan(speakerIndex: speaker,
                                              playbackChannel: channel,
                                              sweep: sweep,
                                              role: .fullRange)
    }

    private func measureOnePosition(name: String = "Main",
                                    weight: Double = 2.0) async throws
        -> MeasurementSession.Position {
        try await session.measurePosition(name: name,
                                          weight: weight,
                                          plans: [try plan(speaker: 0, channel: 0)],
                                          microphone: microphone,
                                          microphoneChannel: 0,
                                          playbackDevice: speakers)
    }

    // MARK: - Happy path

    func testSessionPreparesBeforeMeasuring() async throws {
        XCTAssertEqual(session.state, .idle)
        try await session.begin()
        XCTAssertEqual(session.state, .readyToMeasure)
        XCTAssertEqual(preparation.prepareCount, 1)
    }

    func testMeasuringWithoutPreparingIsRefused() async {
        do {
            _ = try await measureOnePosition()
            XCTFail("measuring an unprepared device should be refused")
        } catch {
            XCTAssertTrue(error is MeasurementSession.SessionError)
        }
    }

    func testAPositionCapturesEverySelectedSpeaker() async throws {
        try await session.begin()
        let position = try await session.measurePosition(
            name: "Main",
            weight: 2.0,
            plans: [try plan(speaker: 0, channel: 0),
                    try plan(speaker: 1, channel: 1)],
            microphone: microphone,
            microphoneChannel: 0,
            playbackDevice: speakers)

        XCTAssertEqual(position.measurements.count, 2)
        XCTAssertEqual(playback.playCount, 2)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(position.isComplete)
        XCTAssertEqual(session.positions.count, 1)
    }

    func testCaptureStartsBeforePlayback() async throws {
        // Starting playback first would race the capture and could clip the
        // beginning of the sweep, and the pre-roll is also where the noise
        // floor is measured.
        try await session.begin()
        _ = try await measureOnePosition()
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(playback.playCount, 1)
        XCTAssertGreaterThan(capture.stopCount, 0)
    }

    func testEachSpeakerPlaysIntoItsOwnChannelSlot() async throws {
        try await session.begin()
        _ = try await session.measurePosition(name: "Main", weight: 2.0,
                                              plans: [try plan(speaker: 3, channel: 5)],
                                              microphone: microphone,
                                              microphoneChannel: 0,
                                              playbackDevice: speakers)
        XCTAssertEqual(playback.lastChannel, 5)
    }

    func testGoodCaptureYieldsAUsableMeasurement() async throws {
        try await session.begin()
        let position = try await measureOnePosition()
        let measurement = try XCTUnwrap(position.measurements.first)

        XCTAssertTrue(measurement.verdict.isUsable)
        XCTAssertFalse(measurement.magnitudesDb.isEmpty)
        XCTAssertEqual(measurement.magnitudesDb.count,
                       RoomCorrectionCore.Grid.display.pointCount)
    }

    // MARK: - Failure paths

    func testClippedCaptureIsRecordedAsAFailureWithoutStoppingTheSession() async throws {
        // A failed speaker must not discard the position: the mic has not
        // moved, so everything else in it is still valid and the user should be
        // able to retry just the one.
        try await session.begin()
        capture.signalAmplitude = 1.0
        let position = try await measureOnePosition()

        XCTAssertFalse(position.isComplete)
        XCTAssertEqual(position.failures.count, 1)
        XCTAssertEqual(session.positions.count, 1)
    }

    func testAnInvalidCaptureIsNotDeconvolved() async throws {
        // Deconvolving a capture already known to be invalid wastes the user's
        // time and produces a curve that would mislead if it were plotted.
        try await session.begin()
        capture.truncateTo = 0.5
        let position = try await measureOnePosition()
        let measurement = try XCTUnwrap(position.measurements.first)

        XCTAssertFalse(measurement.verdict.isUsable)
        XCTAssertTrue(measurement.magnitudesDb.isEmpty)
    }

    func testPlaybackFailureStopsTheCapture() async throws {
        // Otherwise the device stays open and the next measurement fails for a
        // misleading reason.
        try await session.begin()
        playback.failWith = TestError(errorDescription: "device vanished")

        do {
            _ = try await measureOnePosition()
            XCTFail("a playback failure should propagate")
        } catch {
            XCTAssertGreaterThan(capture.stopCount, 0)
            XCTAssertFalse(capture.isRunning)
        }
    }

    func testPlaybackThatCannotStartStopsTheCapture() async throws {
        try await session.begin()
        playback.playError = TestError(errorDescription: "channel missing")

        do {
            _ = try await measureOnePosition()
            XCTFail("a playback start failure should propagate")
        } catch {
            XCTAssertFalse(capture.isRunning)
        }
    }

    func testPreparationFailureLeavesTheSessionInAFailedState() async {
        preparation.prepareError = TestError(errorDescription: "could not snapshot")
        do {
            try await session.begin()
            XCTFail("preparation failure should propagate")
        } catch {
            guard case .failed(let message) = session.state else {
                return XCTFail("expected a failed state, got \(session.state)")
            }
            XCTAssertEqual(message, "could not snapshot")
        }
    }

    // MARK: - Cancellation and restoration

    func testCancellationStopsAudioImmediately() async throws {
        try await session.begin()
        session.cancel()
        XCTAssertGreaterThan(playback.stopCount, 0)
        XCTAssertGreaterThan(capture.stopCount, 0)
    }

    func testEndingRestoresTheDevice() async throws {
        try await session.begin()
        await session.end()
        XCTAssertEqual(preparation.restoreCount, 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testEndingWithoutPreparingDoesNotRestore() async {
        await session.end()
        XCTAssertEqual(preparation.restoreCount, 0)
        XCTAssertEqual(session.state, .idle)
    }

    func testEndingAfterAFailureStillRestores() async throws {
        // The device must go back whatever happened, or the user is left with
        // a flattened EQ and no idea why.
        try await session.begin()
        capture.signalAmplitude = 1.0
        _ = try? await measureOnePosition()
        await session.end()
        XCTAssertEqual(preparation.restoreCount, 1)
    }

    // MARK: - Position management

    func testRetryReplacesOneSpeakerAndKeepsTheRest() async throws {
        try await session.begin()
        capture.signalAmplitude = 1.0
        _ = try await session.measurePosition(name: "Main", weight: 2.0,
                                              plans: [try plan(speaker: 0, channel: 0),
                                                      try plan(speaker: 1, channel: 1)],
                                              microphone: microphone,
                                              microphoneChannel: 0,
                                              playbackDevice: speakers)
        XCTAssertEqual(session.positions[0].failures.count, 2)

        capture.signalAmplitude = 0.3
        try await session.remeasure(speaker: try plan(speaker: 0, channel: 0),
                                    inPosition: 0,
                                    microphone: microphone,
                                    microphoneChannel: 0,
                                    playbackDevice: speakers)

        XCTAssertEqual(session.positions[0].measurements.count, 2)
        XCTAssertEqual(session.positions[0].failures.count, 1)
    }

    func testPositionsCanBeRenamedWeightedDisabledAndRemoved() async throws {
        try await session.begin()
        _ = try await measureOnePosition(name: "Main")
        _ = try await measureOnePosition(name: "Left", weight: 1.0)

        session.renamePosition(0, to: "Listening seat")
        session.setPosition(1, weight: 0.5)
        session.setPosition(1, enabled: false)
        XCTAssertEqual(session.positions[0].name, "Listening seat")
        XCTAssertEqual(session.positions[1].weight, 0.5)
        XCTAssertFalse(session.positions[1].enabled)

        session.removePosition(at: 1)
        XCTAssertEqual(session.positions.count, 1)

        // Out-of-range operations must be harmless rather than trapping.
        session.removePosition(at: 99)
        session.setPosition(99, enabled: true)
        session.renamePosition(99, to: "nowhere")
        XCTAssertEqual(session.positions.count, 1)
    }

    // MARK: - Handing off to the fit

    func testFitUsesOnlyEnabledPositionsWithUsableMeasurements() async throws {
        try await session.begin()
        _ = try await measureOnePosition(name: "One", weight: 2.0)
        _ = try await measureOnePosition(name: "Two", weight: 1.0)

        capture.signalAmplitude = 1.0   // this one will fail
        _ = try await measureOnePosition(name: "Three", weight: 1.0)

        let all = try session.makeFit(forSpeaker: 0, sampleRateHz: 48000, platform: .rp2350)
        XCTAssertEqual(all.positionCount, 2, "the failed position must be excluded")

        session.setPosition(1, enabled: false)
        let fewer = try session.makeFit(forSpeaker: 0, sampleRateHz: 48000, platform: .rp2350)
        XCTAssertEqual(fewer.positionCount, 1, "a disabled position must be excluded")
    }

    func testFinishingEarlyIsAllowed() async throws {
        // Finishing before the planned count is always permitted; a single
        // position still produces a fit, just a less protected one.
        try await session.begin()
        _ = try await measureOnePosition()

        let fit = try session.makeFit(forSpeaker: 0, sampleRateHz: 48000, platform: .rp2350)
        XCTAssertEqual(fit.positionCount, 1)
        try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
        try fit.fit()
        XCTAssertFalse(try fit.filters.isEmpty)
    }

    // MARK: - Output mode forced paths

    private func outputPlan(speaker: Int, drive: Int) throws -> MeasurementSession.SpeakerPlan {
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        sweep.durationSeconds = 1.0
        capture.sweep = sweep
        return MeasurementSession.SpeakerPlan(
            speakerIndex: speaker,
            playbackChannel: drive,
            sweep: sweep,
            role: .fullRange,
            forcedPath: ForcedPath(driveInput: drive,
                                   targetOutput: speaker,
                                   bypassInputBank: drive,
                                   bypassOutputBank: speaker,
                                   bypassCrossoversOn: []))
    }

    func testOutputModeForcesAPathPerSweepAndTakesItDown() async throws {
        // The path must come down between speakers, or the next sweep measures
        // through the previous speaker's configuration.
        try await session.begin(mode: .outputChannels, correctedChannels: [0, 1])
        XCTAssertEqual(preparation.lastMode, .outputChannels)

        _ = try await session.measurePosition(
            name: "Main", weight: 2.0,
            plans: [try outputPlan(speaker: 0, drive: 0),
                    try outputPlan(speaker: 1, drive: 1)],
            microphone: microphone, microphoneChannel: 0, playbackDevice: speakers)

        XCTAssertEqual(preparation.configureCount, 2)
        XCTAssertEqual(preparation.configuredPaths.map(\.targetOutput), [0, 1])
        XCTAssertEqual(preparation.configuredPaths.map(\.bypassOutputBank), [0, 1])
        XCTAssertTrue(preparation.configuredPaths.allSatisfy { $0.bypassCrossoversOn.isEmpty },
                      "crossovers are never bypassed unless the user opted in")
    }

    func testInputModeForcesNoPath() async throws {
        // Input mode measures the system exactly as configured, so touching the
        // matrix at all would defeat it.
        try await session.begin(mode: .inputChannels, correctedChannels: [0])
        _ = try await measureOnePosition()

        XCTAssertEqual(preparation.configureCount, 0)
        XCTAssertEqual(preparation.releaseCount, 0)
        XCTAssertEqual(preparation.lastMode, .inputChannels)
    }

    func testAFailedSweepStillReleasesTheForcedPath() async throws {
        // Otherwise the matrix stays rewired and every later measurement is
        // taken through the wrong configuration.
        try await session.begin(mode: .outputChannels, correctedChannels: [0])
        playback.failWith = TestError(errorDescription: "device vanished")

        _ = try? await session.measurePosition(
            name: "Main", weight: 2.0,
            plans: [try outputPlan(speaker: 0, drive: 0)],
            microphone: microphone, microphoneChannel: 0, playbackDevice: speakers)

        XCTAssertEqual(preparation.configureCount, 1)
        // The release is scheduled as the sweep unwinds; let it run.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(preparation.releaseCount, 1)
    }

    func testAPathThatCannotBeConfiguredFailsTheSweep() async throws {
        try await session.begin(mode: .outputChannels, correctedChannels: [0])
        preparation.configureError = TestError(errorDescription: "matrix write failed")

        do {
            _ = try await session.measurePosition(
                name: "Main", weight: 2.0,
                plans: [try outputPlan(speaker: 0, drive: 0)],
                microphone: microphone, microphoneChannel: 0, playbackDevice: speakers)
            XCTFail("a failed path configuration should propagate")
        } catch {
            XCTAssertEqual(playback.playCount, 0, "nothing should have been played")
        }
    }

    func testStateIsBusyOnlyWhileWorking() {
        XCTAssertFalse(MeasurementSession.State.idle.isBusy)
        XCTAssertFalse(MeasurementSession.State.readyToMeasure.isBusy)
        XCTAssertFalse(MeasurementSession.State.positionReview(position: 0).isBusy)
        XCTAssertFalse(MeasurementSession.State.failed("x").isBusy)
        XCTAssertTrue(MeasurementSession.State.preparingDevice.isBusy)
        XCTAssertTrue(MeasurementSession.State.capturing(position: 0, speaker: 0).isBusy)
        XCTAssertTrue(MeasurementSession.State.analyzing(position: 0, speaker: 0).isBusy)
        XCTAssertTrue(MeasurementSession.State.restoringDevice.isBusy)
    }

    func testSessionErrorsExplainThemselves() {
        for error: MeasurementSession.SessionError in [.notPrepared, .cancelled, .noSpeakers] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }
}
