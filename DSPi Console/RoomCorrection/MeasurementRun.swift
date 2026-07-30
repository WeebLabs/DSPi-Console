import Combine
import Foundation

/// Drives a `MeasurementSession` through a series of microphone positions.
///
/// The session knows how to capture and analyse; this knows when to begin, when
/// there is enough, and what to do when a capture fails. Those are the
/// decisions a user experiences, and they are kept out of the view so they can
/// be tested without a room.
@MainActor
final class MeasurementRun: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPositionName: String?
    @Published private(set) var speakersInPosition = 0
    @Published private(set) var speakersDone = 0

    /// Editable before each capture, so a position can be named as it is taken
    /// rather than renamed afterwards from memory.
    @Published var nextPositionName = ""
    @Published var nextPositionWeight = 3.0

    let session: MeasurementSession

    /// True once `begin` has run, so the device is only prepared once per run
    /// rather than per position.
    private var started = false

    private var sessionChanges: AnyCancellable?

    init(session: MeasurementSession) {
        self.session = session
        // The positions live on the session, which is a separate observable
        // object. Without this the view - which observes the run - never learns
        // that a capture finished, and the captured list simply never appears.
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var positions: [MeasurementSession.Position] { session.positions }

    /// Positions that contribute to the fit.
    ///
    /// A position with no usable measurement in it is not progress, however
    /// long it took, so counting it would tell the user they are further along
    /// than they are.
    var usablePositionCount: Int {
        positions.filter { $0.enabled && $0.measurements.contains { $0.verdict.isUsable } }
            .count
    }

    var positionProgress: Double {
        guard speakersInPosition > 0 else { return 0 }
        return Double(speakersDone) / Double(speakersInPosition)
    }

    /// How far through the plan, and whether that is enough.
    var readiness: Readiness { Readiness(captured: usablePositionCount) }

    struct Readiness {
        let captured: Int

        /// Below three the spatial average is barely an average: two positions
        /// cannot tell a room mode from a measurement artefact, because there
        /// is nothing to disagree with.
        var isEnough: Bool { captured >= 3 }

        var summary: String {
            switch captured {
            case 0:
                return "Nothing captured yet. The first position should be where you "
                     + "actually sit."
            case 1:
                return "One position describes one point in the room. At least three "
                     + "are needed before a correction can tell a room mode from a "
                     + "measurement artefact."
            case 2:
                return "Two positions. One more and the spatial average starts to mean "
                     + "something."
            case 3...4:
                return "Enough to correct with. More positions will make the result "
                     + "less sensitive to exactly where the microphone sat."
            default:
                return "A solid set. You can keep going, or stop here - there is no "
                     + "penalty for stopping early."
            }
        }
    }

    func activityDescription(targetName: (Int) -> String) -> String {
        switch session.state {
        case .preparingDevice: return "Preparing the device."
        case .restoringDevice: return "Restoring your settings."
        case .capturing(_, let speaker): return "Sweeping \(targetName(speaker))."
        case .analyzing(_, let speaker): return "Analysing \(targetName(speaker))."
        default: return "Working."
        }
    }

    // MARK: - Capturing

    func canCapture(model: RoomCorrectionModel) -> Bool {
        !isRunning
            && model.microphone != nil
            && model.playbackDevice != nil
            && !model.selectedTargets.isEmpty
    }

    func capture(model: RoomCorrectionModel) {
        guard canCapture(model: model),
              let microphone = model.microphone,
              let playbackDevice = model.playbackDevice else { return }

        let name = nextPositionName.trimmingCharacters(in: .whitespaces)
        let positionName = name.isEmpty ? "Position \(positions.count + 1)" : name
        let weight = nextPositionWeight

        Task { await run(model: model,
                         microphone: microphone,
                         playbackDevice: playbackDevice,
                         name: positionName,
                         weight: weight) }
    }

    private func run(model: RoomCorrectionModel,
                     microphone: AudioDeviceInfo,
                     playbackDevice: AudioDeviceInfo,
                     name: String,
                     weight: Double) async {
        isRunning = true
        errorMessage = nil
        currentPositionName = name
        defer {
            isRunning = false
            currentPositionName = nil
        }

        do {
            let plans = try model.speakerPlans()
            speakersInPosition = plans.count
            speakersDone = 0

            // Prepared once for the whole run, not per position: preparing
            // again would re-snapshot a device that is already modified, and
            // the snapshot is what the user gets back at the end.
            if !started {
                // Before the device is touched: this is the gain structure the
                // correction will be calculated against.
                model.captureGainBaselineIfNeeded()
                try await session.begin(mode: model.mode,
                                        correctedChannels: Array(model.selectedTargets))
                started = true
            }

            try await session.measurePosition(name: name,
                                              weight: weight,
                                              plans: plans,
                                              microphone: microphone,
                                              microphoneChannel: model.microphoneChannel,
                                              playbackDevice: playbackDevice,
                                              calibration: model.calibration)
            speakersDone = speakersInPosition
            nextPositionName = ""
            // The first position is the listening seat; the rest are not, and
            // defaulting every one to the highest weight would quietly bias the
            // fit toward wherever the user happened to stand.
            nextPositionWeight = 2.0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry(_ failure: MeasurementSession.SpeakerMeasurement,
               in positionIndex: Int,
               model: RoomCorrectionModel) {
        guard !isRunning,
              let microphone = model.microphone,
              let playbackDevice = model.playbackDevice,
              let plan = try? model.speakerPlans()
                  .first(where: { $0.speakerIndex == failure.speakerIndex })
        else { return }

        Task {
            isRunning = true
            errorMessage = nil
            defer { isRunning = false }
            do {
                try await session.remeasure(speaker: plan,
                                            inPosition: positionIndex,
                                            microphone: microphone,
                                            microphoneChannel: model.microphoneChannel,
                                            playbackDevice: playbackDevice,
                                            calibration: model.calibration)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        session.cancel()
    }

    /// End the run and give the device back.
    ///
    /// Idempotent, so the view can call it on the way out without having to
    /// know whether the run ever started.
    func finish() async {
        guard started else { return }
        started = false
        await session.end()
    }

    // MARK: - Position management

    func removePosition(at index: Int) {
        session.removePosition(at: index)
    }

    func setPosition(_ index: Int, enabled: Bool) {
        session.setPosition(index, enabled: enabled)
    }
}
