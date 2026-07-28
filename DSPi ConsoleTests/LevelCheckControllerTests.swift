import XCTest
@testable import DSPi_Console

/// Drives the level check with fake audio hardware.
///
/// The point of this step is to refuse a measurement that would waste the
/// user's evening, so the tests that matter are the refusals: a room too noisy
/// to measure, an input that clips, a dropout that makes the reading a lie.
@MainActor
final class LevelCheckControllerTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeCapture: AudioCaptureBackend {
        /// What `stop()` hands back. Default is a plausible quiet room.
        var samples: [Float] = [Float](repeating: 0.001, count: 4800)
        var startError: Error?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var isRunning = false
        var sampleRate: Double = 48000
        var overloadCount = 0

        func start(device: AudioDeviceInfo, channelIndex: Int) throws {
            startCount += 1
            if let startError { throw startError }
            isRunning = true
        }
        func stop() -> [Float] {
            stopCount += 1
            isRunning = false
            return samples
        }
        func peakAndReset() -> Float { 0.05 }
    }

    private final class FakePlayback: AudioPlaybackBackend {
        private(set) var played: [Float] = []
        private(set) var playCount = 0
        private(set) var stopCount = 0
        var playError: Error?
        var isRunning = false
        var underrunCount = 0

        func play(samples: [Float], device: AudioDeviceInfo, channelIndex: Int,
                  completion: @escaping (Result<Void, Error>) -> Void) throws {
            playCount += 1
            if let playError { throw playError }
            played = samples
            isRunning = true
        }
        func stop() { stopCount += 1; isRunning = false }
    }

    private var capture: FakeCapture!
    private var playback: FakePlayback!

    private let microphone = AudioDeviceInfo(id: 1, uid: "mic", name: "UMIK-1",
                                             inputChannels: 1, outputChannels: 0,
                                             nominalSampleRate: 48000,
                                             supportedSampleRates: [48000])
    private let dspi = AudioDeviceInfo(id: 2, uid: "dspi", name: "DSPi",
                                       inputChannels: 0, outputChannels: 8,
                                       nominalSampleRate: 48000,
                                       supportedSampleRates: [48000])

    /// No real waiting: the controller's timings are seconds long by design.
    private func makeController() -> LevelCheckController {
        capture = FakeCapture()
        playback = FakePlayback()
        let controller = LevelCheckController(capture: capture, playback: playback)
        controller.sleep = { _ in }
        return controller
    }

    /// Noise at a known RMS, so an expected SNR can be asserted.
    private func noise(rms: Double, count: Int = 48000) -> [Float] {
        var state: UInt64 = 88172645463325252
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let uniform = Double(Int64(bitPattern: state)) / Double(Int64.max)
            // Uniform on -1...1 has RMS 1/sqrt(3).
            return Float(uniform * rms * 1.7320508)
        }
    }

    // MARK: - Noise floor

    func testNoiseFloorIsMeasuredAndRated() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)     // about -70 dBFS

        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        XCTAssertEqual(controller.stage, .ready)
        let floor = try? XCTUnwrap(controller.noiseFloorDbfs)
        XCTAssertEqual(floor ?? 0, -70, accuracy: 1.5)
        XCTAssertEqual(controller.noiseFloorVerdict?.rating, .quiet)
    }

    func testASilentMicrophoneIsReportedRatherThanMeasured() async {
        // An empty capture is a muted or misrouted microphone. Reading it as a
        // spectacularly quiet room would send the user off to measure with no
        // signal at all.
        let controller = makeController()
        capture.samples = []

        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        XCTAssertNil(controller.noiseFloorDbfs)
        XCTAssertEqual(controller.stage, .idle)
        XCTAssertTrue(controller.errorMessage?.contains("no audio") ?? false,
                      controller.errorMessage ?? "no message")
    }

    func testAFailedCaptureStopsTheDeviceAndReportsWhy() async {
        let controller = makeController()
        capture.startError = AudioEngineError.deviceUnavailable("UMIK-1")

        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        XCTAssertEqual(controller.stage, .idle)
        XCTAssertTrue(controller.errorMessage?.contains("UMIK-1") ?? false)
        XCTAssertEqual(capture.stopCount, 1, "the capture must not be left running")
    }

    func testAVeryNoisyRoomBlocksMeasuringButAMerelyNoisyOneDoesNot() {
        // Refusing outright at the first sign of noise would be wrong: a user
        // may have no quieter time available, and a noisy measurement is worse
        // than a quiet one rather than worthless.
        XCTAssertFalse(NoiseFloorVerdict(dbfs: -45).blocksMeasurement)
        XCTAssertEqual(NoiseFloorVerdict(dbfs: -45).rating, .noisy)
        XCTAssertTrue(NoiseFloorVerdict(dbfs: -30).blocksMeasurement)
        XCTAssertEqual(NoiseFloorVerdict(dbfs: -80).rating, .quiet)
        XCTAssertEqual(NoiseFloorVerdict(dbfs: -60).rating, .acceptable)
    }

    // MARK: - Tone

    func testTheToneRefusesWithoutANoiseFloor() async {
        // Without one there is no SNR, and a peak level alone says nothing
        // about whether a sweep will survive the room.
        let controller = makeController()

        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertEqual(playback.playCount, 0, "nothing should have been played")
        XCTAssertNil(controller.result)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testCaptureStartsBeforePlayback() async {
        // Playing first races the capture and can clip the start of the tone.
        let order = Recorder()
        let controller = LevelCheckController(capture: OrderedCapture(order),
                                              playback: ObservingPlayback(order))
        controller.sleep = { _ in }

        await controller.measureNoiseFloor(microphone: microphone, channel: 0)
        order.events.removeAll()
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertEqual(order.events.first, "capture",
                       "capture must be armed first: \(order.events)")
    }

    func testAGoodToneIsAccepted() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)         // -70 dBFS floor
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        capture.samples = noise(rms: 0.05)           // about -26 dBFS, so ~44 dB SNR
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertEqual(controller.stage, .done)
        XCTAssertTrue(controller.isLevelAcceptable)
        XCTAssertTrue(controller.problems.isEmpty, "\(controller.problems)")
        XCTAssertNil(controller.suggestedLevelChangeDb, "nothing to fix")
    }

    func testClippingIsCaughtAndTheSuggestionIsToComeDown() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        var clipping = noise(rms: 0.3)
        clipping[100] = 1.0
        capture.samples = clipping
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertFalse(controller.isLevelAcceptable)
        XCTAssertEqual(controller.suggestedLevelChangeDb, -6)
        XCTAssertTrue(controller.problems.first?.contains("clipping") ?? false,
                      "clipping must be the first thing reported: \(controller.problems)")
    }

    func testTooLittleSignalIsRejectedAndTheSuggestionIsToComeUp() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.01)           // about -40 dBFS floor
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        capture.samples = noise(rms: 0.014)          // only a few dB above it
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertFalse(controller.isLevelAcceptable)
        let change = try? XCTUnwrap(controller.suggestedLevelChangeDb)
        XCTAssertGreaterThan(change ?? 0, 0, "the level should be raised")
        XCTAssertTrue(controller.problems.contains { $0.contains("noise floor") },
                      "\(controller.problems)")
    }

    func testADropoutInvalidatesTheReadingRatherThanDegradingIt() async {
        // A gap in either direction moves samples relative to each other, so
        // the level read from the capture is not the level that was played.
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        capture.samples = noise(rms: 0.05)
        playback.underrunCount = 1
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertNil(controller.result, "a dropped-out capture must not produce a level")
        XCTAssertTrue(controller.errorMessage?.contains("dropped out") ?? false)
        XCTAssertEqual(controller.stage, .ready, "the floor survives; the tone does not")
    }

    func testPlaybackIsStoppedEvenWhenTheToneFails() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        capture.samples = []
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        XCTAssertGreaterThan(playback.stopCount, 0, "a tone must never be left playing")
    }

    // MARK: - Level suggestion

    func testApplyingASuggestionMovesTheLevelAndStaysInRange() async {
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)

        var clipping = noise(rms: 0.3)
        clipping[0] = 1.0
        capture.samples = clipping
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        controller.playbackLevelDbfs = -6
        controller.applySuggestedLevel()
        XCTAssertEqual(controller.playbackLevelDbfs, -12)

        // And never past the ends of the slider.
        controller.playbackLevelDbfs = -58
        controller.applySuggestedLevel()
        XCTAssertGreaterThanOrEqual(controller.playbackLevelDbfs, -60)
    }

    func testRetryingTheToneKeepsTheNoiseFloor() async {
        // The floor does not move because the tone got louder, and re-listening
        // to a quiet room after every level change wastes the user's time.
        let controller = makeController()
        capture.samples = noise(rms: 0.0003)
        await controller.measureNoiseFloor(microphone: microphone, channel: 0)
        capture.samples = noise(rms: 0.05)
        await controller.measureTone(microphone: microphone, micChannel: 0,
                                     playbackDevice: dspi, playbackChannel: 0,
                                     sampleRate: 48000)

        controller.retryTone()

        XCTAssertNil(controller.result)
        XCTAssertNotNil(controller.noiseFloorDbfs)
        XCTAssertEqual(controller.stage, .ready)
    }

    // MARK: - The test signal itself

    func testTheToneHitsTheRequestedPeakLevel() {
        for level in [-30.0, -18.0, -6.0] {
            let samples = LevelCheckController.toneSamples(seconds: 1,
                                                           sampleRate: 48000,
                                                           levelDbfs: level)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertEqual(20 * log10(Double(peak)), level, accuracy: 0.1,
                           "a user setting a level should get that level")
        }
    }

    func testTheToneIsIdenticalEachTime() {
        // Two readings at the same setting have to be comparable, which they
        // are not if the signal differs between them.
        let first = LevelCheckController.toneSamples(seconds: 0.5, sampleRate: 48000,
                                                     levelDbfs: -20)
        let second = LevelCheckController.toneSamples(seconds: 0.5, sampleRate: 48000,
                                                      levelDbfs: -20)
        XCTAssertEqual(first, second)
    }

    func testTheToneStartsAndEndsSilently() {
        // A burst starting at full amplitude is a click, which reads as a peak
        // the tone itself never reached.
        let samples = LevelCheckController.toneSamples(seconds: 1, sampleRate: 48000,
                                                       levelDbfs: -12)
        XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertEqual(samples.last ?? 1, 0, accuracy: 1e-6)
    }

    func testTheToneIsBroadbandRatherThanASingleFrequency() {
        // A sine lands on whatever the room does at one frequency, which in a
        // small room can be a deep null - so the level reads as hopeless in one
        // position and clipping a metre away.
        let samples = LevelCheckController.toneSamples(seconds: 1, sampleRate: 48000,
                                                       levelDbfs: -12)
        // Zero crossings far above what any single audio-band tone produces.
        var crossings = 0
        for index in 1..<samples.count where samples[index - 1].sign != samples[index].sign {
            crossings += 1
        }
        XCTAssertGreaterThan(crossings, 2000,
                             "the signal should be noise-like, not a tone")
    }

    // MARK: - Ordering helpers

    private final class Recorder { var events: [String] = [] }

    private final class OrderedCapture: AudioCaptureBackend {
        private let recorder: Recorder
        init(_ recorder: Recorder) { self.recorder = recorder }
        var isRunning = false
        var sampleRate: Double = 48000
        var overloadCount = 0
        func start(device: AudioDeviceInfo, channelIndex: Int) throws {
            recorder.events.append("capture")
        }
        func stop() -> [Float] { [Float](repeating: 0.01, count: 4800) }
        func peakAndReset() -> Float { 0 }
    }

    private final class ObservingPlayback: AudioPlaybackBackend {
        private let recorder: Recorder
        init(_ recorder: Recorder) { self.recorder = recorder }
        var isRunning = false
        var underrunCount = 0
        func play(samples: [Float], device: AudioDeviceInfo, channelIndex: Int,
                  completion: @escaping (Result<Void, Error>) -> Void) throws {
            recorder.events.append("play")
        }
        func stop() {}
    }
}
