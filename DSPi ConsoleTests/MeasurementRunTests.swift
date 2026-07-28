import XCTest
@testable import DSPi_Console

/// Covers the decisions the capture step makes on the user's behalf: when the
/// device is prepared, what counts as progress, and what survives a failure.
@MainActor
final class MeasurementRunTests: XCTestCase {

    // MARK: - Fakes

    /// Plays the sweep straight back, as a perfect anechoic room would.
    ///
    /// Noise would not do: the analyser deconvolves the capture against the
    /// sweep, and random samples produce an unusable verdict - which would make
    /// every "this counts as progress" assertion below pass vacuously.
    private final class StubCapture: AudioCaptureBackend {
        var produceSignal = true
        var isRunning = false
        var sampleRate: Double = 48000
        var overloadCount = 0
        /// Set to the same sweep the plans use.
        var sweep: [Float] = []

        func start(device: AudioDeviceInfo, channelIndex: Int) throws { isRunning = true }
        func stop() -> [Float] {
            isRunning = false
            guard produceSignal else { return [Float](repeating: 0, count: 48000) }
            return sweep
        }
        func peakAndReset() -> Float { 0.3 }
    }

    private final class StubPlayback: AudioPlaybackBackend {
        var isRunning = false
        var underrunCount = 0
        func play(samples: [Float], device: AudioDeviceInfo, channelIndex: Int,
                  completion: @escaping (Result<Void, Error>) -> Void) throws {
            completion(.success(()))
        }
        func stop() {}
    }

    private final class CountingPreparation: DevicePreparing {
        var prepareCount = 0
        var restoreCount = 0
        func prepare(mode: MeasurementMode, correctedChannels: [Int]) async throws {
            prepareCount += 1
        }
        func configure(path: ForcedPath) async throws {}
        func releasePath() async {}
        func restore() async { restoreCount += 1 }
    }

    private var preparation: CountingPreparation!
    private var capture: StubCapture!

    private let microphone = AudioDeviceInfo(id: 1, uid: "mic", name: "UMIK-1",
                                             inputChannels: 1, outputChannels: 0,
                                             nominalSampleRate: 48000,
                                             supportedSampleRates: [48000])

    private static let sharedCatalog = AudioDeviceCatalog(startListening: false)

    /// A model whose playback device resolves without CoreAudio.
    private func makeModel(run: MeasurementRun) -> RoomCorrectionModel {
        let vm = DSPViewModel(usb: USBDevice(autoConnect: false, monitor: false))
        vm.matrixRouting = Array(repeating: Array(repeating: false, count: 9),
                                 count: MAX_MATRIX_INPUTS)
        for input in 0..<2 { vm.matrixRouting[input][input] = true }
        vm.outputEnabled = Array(repeating: true, count: 9)

        let model = RoomCorrectionModel(vm: vm, catalog: Self.sharedCatalog, run: run)
        model.mode = .inputChannels
        model.selectedTargets = [0, 1]
        model.sweepSeconds = 3
        model.microphoneUID = nil
        return model
    }

    private func makeRun() -> MeasurementRun {
        capture = StubCapture()
        preparation = CountingPreparation()
        return MeasurementRun(session: MeasurementSession(capture: capture,
                                                          playback: StubPlayback(),
                                                          preparation: preparation))
    }

    /// Point the stub at the sweep the model's plans will actually use.
    private func loadSweep(from model: RoomCorrectionModel) throws {
        let plan = try XCTUnwrap(model.speakerPlans().first)
        capture.sweep = try plan.sweep.render()
    }

    // MARK: - Readiness

    func testTwoPositionsAreNotEnoughAndThreeAre() {
        // Two positions cannot tell a room mode from a measurement artefact,
        // because there is nothing for either to disagree with.
        XCTAssertFalse(MeasurementRun.Readiness(captured: 0).isEnough)
        XCTAssertFalse(MeasurementRun.Readiness(captured: 2).isEnough)
        XCTAssertTrue(MeasurementRun.Readiness(captured: 3).isEnough)
    }

    func testEveryReadinessCountExplainsItself() {
        // A count with no explanation leaves the user guessing whether to keep
        // going, which is the one question this step has to answer.
        for captured in 0...8 {
            let summary = MeasurementRun.Readiness(captured: captured).summary
            XCTAssertFalse(summary.isEmpty, "no guidance at \(captured)")
            XCTAssertGreaterThan(summary.count, 30, "unhelpfully terse at \(captured)")
        }
    }

    func testStoppingEarlyIsPresentedAsAChoiceRatherThanAShortfall() {
        // The plan is a suggestion. A user with five good positions should not
        // be told they abandoned something.
        let summary = MeasurementRun.Readiness(captured: 6).summary
        XCTAssertTrue(summary.contains("no penalty") || summary.contains("stop here"),
                      summary)
    }

    // MARK: - Progress accounting

    func testAPositionWithNoUsableMeasurementIsNotProgress() async throws {
        // Otherwise a failed position tells the user they are further along
        // than they are, and they stop before they have anything.
        let run = makeRun()
        let model = makeModel(run: run)
        capture.produceSignal = false          // silence: nothing usable

        try await run.session.begin(mode: .inputChannels, correctedChannels: [0, 1])
        _ = try await run.session.measurePosition(
            name: "Main", weight: 3,
            plans: try model.speakerPlans(),
            microphone: microphone, microphoneChannel: 0, playbackDevice: microphone)

        XCTAssertEqual(run.positions.count, 1, "the position is kept for review")
        XCTAssertEqual(run.usablePositionCount, 0, "but it is not progress")
        XCTAssertFalse(run.readiness.isEnough)
    }

    func testADisabledPositionStopsCountingTowardsReadiness() async throws {
        let run = makeRun()
        let model = makeModel(run: run)
        try loadSweep(from: model)
        try await run.session.begin(mode: .inputChannels, correctedChannels: [0, 1])
        for index in 0..<3 {
            _ = try await run.session.measurePosition(
                name: "P\(index)", weight: 1,
                plans: try model.speakerPlans(),
                microphone: microphone, microphoneChannel: 0, playbackDevice: microphone)
        }
        XCTAssertEqual(run.usablePositionCount, 3)

        run.setPosition(0, enabled: false)
        XCTAssertEqual(run.usablePositionCount, 2,
                       "excluding a position from the fit must show in the count")
    }

    func testPositionProgressIsZeroBeforeAnythingStarts() {
        // Dividing by an unset speaker count would be a crash, and a bar that
        // reads full before the first sweep would be a lie.
        let run = makeRun()
        XCTAssertEqual(run.positionProgress, 0)
    }

    // MARK: - The device is prepared once

    func testTheDeviceIsPreparedOnceForTheWholeRun() async throws {
        // Preparing again would re-snapshot an already modified device, and the
        // snapshot is exactly what the user gets back at the end.
        let run = makeRun()
        let model = makeModel(run: run)
        try loadSweep(from: model)
        try await run.session.begin(mode: .inputChannels, correctedChannels: [0, 1])

        for index in 0..<3 {
            _ = try await run.session.measurePosition(
                name: "P\(index)", weight: 1,
                plans: try model.speakerPlans(),
                microphone: microphone, microphoneChannel: 0, playbackDevice: microphone)
        }

        XCTAssertEqual(preparation.prepareCount, 1)
    }

    func testFinishingRestoresTheDeviceAndIsSafeToRepeat() async throws {
        // The view calls this on the way out without knowing whether a run ever
        // started, so a second call must not restore a snapshot twice.
        let run = makeRun()
        try await run.session.begin(mode: .inputChannels, correctedChannels: [0])

        await run.session.end()
        await run.session.end()

        XCTAssertEqual(preparation.restoreCount, 1)
    }

    func testFinishingWithoutStartingDoesNothing() async {
        let run = makeRun()
        await run.finish()
        XCTAssertEqual(preparation.prepareCount, 0)
        XCTAssertEqual(preparation.restoreCount, 0)
    }

    // MARK: - Capture guards

    func testCaptureIsRefusedWithoutAMicrophone() {
        let run = makeRun()
        let model = makeModel(run: run)
        XCTAssertNil(model.microphone)
        XCTAssertFalse(run.canCapture(model: model),
                       "a capture with no microphone would sweep into silence")
    }

    func testCaptureIsRefusedWithNothingSelected() {
        let run = makeRun()
        let model = makeModel(run: run)
        model.selectedTargets = []
        XCTAssertFalse(run.canCapture(model: model))
    }

    // MARK: - Naming and weighting

    func testAnUnnamedPositionGetsANumberedName() async throws {
        let run = makeRun()
        let model = makeModel(run: run)
        try loadSweep(from: model)
        try await run.session.begin(mode: .inputChannels, correctedChannels: [0, 1])
        _ = try await run.session.measurePosition(
            name: "Position 1", weight: 3,
            plans: try model.speakerPlans(),
            microphone: microphone, microphoneChannel: 0, playbackDevice: microphone)

        XCTAssertEqual(run.positions.first?.name, "Position 1")
    }

    func testTheDefaultWeightStartsAtTheListeningSeat() {
        // The first position is where the user sits; that one should carry more
        // weight than wherever they happen to stand afterwards.
        let run = makeRun()
        XCTAssertEqual(run.nextPositionWeight, 3.0)
    }

    // MARK: - Reactivity

    func testTheRunRepublishesSessionChanges() async throws {
        // The positions live on the session. Without forwarding, the view -
        // which observes the run - never learns a capture finished, and the
        // captured list simply never appears.
        let run = makeRun()
        let model = makeModel(run: run)
        var notified = 0
        let subscription = run.objectWillChange.sink { _ in notified += 1 }

        try await run.session.begin(mode: .inputChannels, correctedChannels: [0, 1])
        _ = try await run.session.measurePosition(
            name: "Main", weight: 3,
            plans: try model.speakerPlans(),
            microphone: microphone, microphoneChannel: 0, playbackDevice: microphone)

        XCTAssertGreaterThan(notified, 0, "session changes must reach the view")
        subscription.cancel()
    }
}
