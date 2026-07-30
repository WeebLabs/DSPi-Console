import Foundation

/// One channel's verification sweep, measured with the correction live.
struct VerificationResult: Identifiable, Equatable {
    let speakerIndex: Int
    /// Measured with the filters active, referenced to the prediction so the
    /// two can be compared on shape rather than on absolute level.
    let measuredDb: [Double]
    let predictedDb: [Double]
    let targetDb: [Double]
    /// Worst absolute difference between measured and predicted, over the
    /// corrected band.
    let worstDeviationDb: Double
    /// Root mean square of the same difference, which is the fairer summary.
    let rmsDeviationDb: Double
    /// True when this channel was measured with its crossover switched off, so
    /// the prediction describes a configuration nobody is listening to.
    let crossoverWasBypassed: Bool
    /// In-band spectral level from the *raw* measurement, for comparing
    /// channels against each other.
    ///
    /// Taken before `measuredDb` is referenced to the prediction, since that
    /// referencing deliberately removes the absolute level the shape comparison
    /// does not want and this one entirely depends on.
    let bandLevelDb: Double
    let role: RoomCorrectionCore.SpeakerRole

    var id: Int { speakerIndex }

    /// A verification is about whether the model held, not about whether the
    /// room is good. Anything under about 3 dB RMS means the filters are doing
    /// what was predicted; beyond that something is wrong with the path rather
    /// than with the correction.
    var agreesWithPrediction: Bool { rmsDeviationDb <= 3.0 }

    var summary: String {
        if crossoverWasBypassed {
            return "Measured with the crossover back on, so it will not match a "
                 + "prediction made without it."
        }
        return agreesWithPrediction
            ? String(format: "Measured response matches the prediction to %.1f dB RMS.",
                     rmsDeviationDb)
            : String(format: "Measured response differs from the prediction by %.1f dB "
                     + "RMS. Check the routing and that the correct speaker is playing.",
                     rmsDeviationDb)
    }
}

/// Whether the channels came out at the same level.
///
/// Compared to each other in one back-to-back pass rather than against the
/// levels recorded earlier. Drift that would ruin an absolute comparison -
/// temperature, a nudged microphone, an altered gain - is common to every
/// channel in a single pass and cancels, which is what makes a tight tolerance
/// defensible here where the same figure against a twenty-minute-old
/// measurement would fail routinely.
struct LevelAgreement: Equatable {

    struct Deviation: Identifiable, Equatable {
        let speakerIndex: Int
        let deviationDb: Double
        var id: Int { speakerIndex }
    }

    /// Each channel against the median, for naming the outlier and for the
    /// residual offsets.
    let deviations: [Deviation]
    /// The spread between the loudest and quietest comparable channel.
    ///
    /// The headline figure, because the spec's tolerance is on the
    /// channel-to-channel difference. Deviation from the median would halve it:
    /// two channels 1 dB apart each sit 0.5 dB from their own median and would
    /// pass a 0.5 dB test while being audibly unbalanced against each other.
    let worstDeviationDb: Double
    /// Channels left out, and why: a subwoofer is on its own datum, and a
    /// channel measured without its crossover cannot be compared with one that
    /// has its crossover on.
    let excluded: [Int]

    static let passWithinDb = 0.5
    /// Above this a residual pass would be chasing something physical rather
    /// than converging.
    static let retryableBelowDb = 2.0

    var passes: Bool { deviations.count < 2 || worstDeviationDb <= Self.passWithinDb }
    var isRetryable: Bool { !passes && worstDeviationDb < Self.retryableBelowDb }

    init(results: [VerificationResult]) {
        let comparable = results.filter { !$0.crossoverWasBypassed && $0.role != .subwoofer }
        excluded = results.filter { $0.crossoverWasBypassed || $0.role == .subwoofer }
            .map(\.speakerIndex)

        guard comparable.count >= 2 else {
            deviations = comparable.map { .init(speakerIndex: $0.speakerIndex,
                                                deviationDb: 0) }
            worstDeviationDb = 0
            return
        }

        // Against the median, so one stray channel is reported as the outlier
        // rather than shifting the reference and implicating every other one.
        let sorted = comparable.map(\.bandLevelDb).sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

        deviations = comparable
            .map { .init(speakerIndex: $0.speakerIndex,
                         deviationDb: $0.bandLevelDb - median) }
            .sorted { $0.speakerIndex < $1.speakerIndex }
        worstDeviationDb = (sorted.last ?? 0) - (sorted.first ?? 0)
    }

    /// The offset that would bring each channel the rest of the way.
    ///
    /// Only meaningful once, and only when the residual is small: a larger one
    /// means something physical changed and applying it would chase noise.
    var residualOffsets: [Int: Double] {
        guard isRetryable else { return [:] }
        return Dictionary(uniqueKeysWithValues:
            deviations.map { ($0.speakerIndex, -$0.deviationDb) })
    }

    var summary: String {
        if deviations.count < 2 {
            return "Only one channel could be compared, so there is no level "
                 + "agreement to report."
        }
        if passes {
            return String(format: "Channels agree to %.2f dB, within the %.1f dB "
                          + "tolerance.", worstDeviationDb, Self.passWithinDb)
        }
        if isRetryable {
            return String(format: "Channels differ by up to %.2f dB. One more small "
                          + "adjustment should close it.", worstDeviationDb)
        }
        return String(format: "Channels differ by up to %.2f dB, which is more than a "
                      + "residual adjustment should be asked to fix. Check that nothing "
                      + "moved and that each sweep played through the speaker it was "
                      + "meant to.", worstDeviationDb)
    }
}

/// Runs the verification sweeps after a successful apply.
///
/// Spec section 5: "It repeats a sweep at the main position with the new
/// filters active and overlays measured-after, predicted-after, and target."
/// This is the strongest check available for a routing mistake, a gain change
/// or a poor model, and it is the specific capability that device-side
/// generation could never have provided.
@MainActor
final class CorrectionVerifier: ObservableObject {

    enum State: Equatable {
        case idle
        case sweeping(speaker: Int, done: Int, of: Int)
        case finished
        case failed(String)

        var isBusy: Bool { if case .sweeping = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var results: [VerificationResult] = []
    /// Whether the channels came out level with each other.
    @Published private(set) var levelAgreement: LevelAgreement?
    /// True once a residual pass has been used, so it is offered only once.
    @Published private(set) var residualApplied = false

    private let session: MeasurementSession
    private let design: CorrectionDesign

    init(session: MeasurementSession, design: CorrectionDesign) {
        self.session = session
        self.design = design
    }

    /// Sweeps each applied channel once, at the main listening position.
    ///
    /// One position, not the whole set: this confirms the write took and the
    /// path is what was assumed. Repeating the whole campaign would be a second
    /// measurement, and the correction is not recalculated from it.
    func verify(plans: [ChannelApplyPlan],
                model: RoomCorrectionModel,
                bypassedCrossovers: Set<Int>) async {
        guard !state.isBusy else { return }
        guard let microphone = model.microphone,
              let playbackDevice = model.playbackDevice else {
            state = .failed("The microphone or the DSPi is no longer available.")
            return
        }
        guard !plans.isEmpty else {
            state = .failed("Nothing was applied, so there is nothing to verify.")
            return
        }

        results = []
        var collected: [VerificationResult] = []

        do {
            // Nothing is flattened: the filters being live is the point.
            try await session.begin(mode: model.mode, correctedChannels: [])

            for (index, plan) in plans.enumerated() {
                state = .sweeping(speaker: plan.speakerIndex, done: index, of: plans.count)

                let speaker = plan.speakerIndex
                let sweepPlan = try verificationPlan(for: speaker, model: model)
                try await session.remeasure(speaker: sweepPlan,
                                            inPosition: verificationPosition(),
                                            microphone: microphone,
                                            microphoneChannel: model.microphoneChannel,
                                            playbackDevice: playbackDevice,
                                            calibration: model.calibration)

                guard let measured = session.positions.last?.measurements
                    .first(where: { $0.speakerIndex == speaker }),
                      measured.verdict.isUsable else {
                    state = .failed("The verification sweep of "
                                    + "\(model.targetName(speaker)) was not usable.")
                    await session.end()
                    return
                }

                collected.append(compare(speaker: speaker,
                                         measured: measured.magnitudesDb,
                                         role: model.targetRoles[speaker] ?? .fullRange,
                                         crossoverWasBypassed:
                                            bypassedCrossovers.contains(speaker)))
            }

            await session.end()
            results = collected
            levelAgreement = LevelAgreement(results: collected)
            state = .finished
        } catch {
            await session.end()
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    /// A sweep that isolates the channel but leaves the correction running.
    private func verificationPlan(for speaker: Int,
                                  model: RoomCorrectionModel) throws -> MeasurementSession.SpeakerPlan {
        let rate = model.vm.sampleRateHz > 0 ? Double(model.vm.sampleRateHz) : 48000
        let role = model.targetRoles[speaker] ?? .fullRange
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: rate, role: role)
        sweep.durationSeconds = model.sweepSeconds

        switch model.mode {
        case .inputChannels:
            return MeasurementSession.SpeakerPlan(speakerIndex: speaker,
                                                  playbackChannel: speaker,
                                                  sweep: sweep,
                                                  role: role)
        case .outputChannels:
            let path = model.routing.verificationPath(forOutput: speaker)
            return MeasurementSession.SpeakerPlan(speakerIndex: speaker,
                                                  playbackChannel: path.driveInput,
                                                  sweep: sweep,
                                                  role: role,
                                                  forcedPath: path)
        }
    }

    /// Verification writes into a scratch position rather than the measurement
    /// set, so it can never be folded into the correction it is checking.
    private func verificationPosition() -> Int {
        if let existing = session.positions.firstIndex(where: { $0.name == Self.scratchName }) {
            return existing
        }
        session.stubPositions(session.positions + [
            .init(name: Self.scratchName, measurements: [], weight: 0, enabled: false)
        ])
        return session.positions.count - 1
    }

    private static let scratchName = "Verification"

    /// Records that the one permitted residual adjustment has been used.
    func markResidualApplied() { residualApplied = true }

    private func compare(speaker: Int,
                         measured: [Double],
                         role: RoomCorrectionCore.SpeakerRole,
                         crossoverWasBypassed: Bool) -> VerificationResult {
        let predicted = predictedCurve(for: speaker)
        let target = design.curve(.target, channel: speaker)
        let weight = design.curve(.maskWeight, channel: speaker)

        // From the raw measurement, before any referencing: the level
        // comparison is the one thing here that depends on absolute level.
        let band = LevelCheckController.band(for: role)
        let bandLevel = (try? RoomCorrectionCore.bandLevel(measured, grid: design.grid,
                                                          band: band)) ?? 0

        guard measured.count == predicted.count, !measured.isEmpty else {
            return VerificationResult(speakerIndex: speaker,
                                      measuredDb: measured,
                                      predictedDb: predicted,
                                      targetDb: target,
                                      worstDeviationDb: 0,
                                      rmsDeviationDb: 0,
                                      crossoverWasBypassed: crossoverWasBypassed,
                                      bandLevelDb: bandLevel,
                                      role: role)
        }

        // Both referenced to their own means: the comparison is about whether
        // the shape came out as modelled, and an absolute level difference
        // between two sessions says nothing about that.
        let measuredMean = measured.reduce(0, +) / Double(measured.count)
        let predictedMean = predicted.reduce(0, +) / Double(predicted.count)

        var worst = 0.0
        var sumSquares = 0.0
        var totalWeight = 0.0
        for index in measured.indices {
            // Weighted by the correction mask, so the roll-off outside the
            // corrected band is not counted as a failure to match.
            let bandWeight = weight.indices.contains(index) ? weight[index] : 1
            guard bandWeight > 0.01 else { continue }
            let difference = (measured[index] - measuredMean)
                - (predicted[index] - predictedMean)
            worst = max(worst, abs(difference))
            sumSquares += bandWeight * difference * difference
            totalWeight += bandWeight
        }

        return VerificationResult(
            speakerIndex: speaker,
            measuredDb: measured.map { $0 - measuredMean + predictedMean },
            predictedDb: predicted,
            targetDb: target,
            worstDeviationDb: worst,
            rmsDeviationDb: totalWeight > 0 ? sqrt(sumSquares / totalWeight) : 0,
            crossoverWasBypassed: crossoverWasBypassed,
            bandLevelDb: bandLevel,
            role: role)
    }

    /// Measured plus correction, which is what the fit predicts will be heard.
    private func predictedCurve(for speaker: Int) -> [Double] {
        let measured = design.curve(.powerAverage, channel: speaker)
        let correction = design.curve(.correction, channel: speaker)
        guard measured.count == correction.count else { return [] }
        return zip(measured, correction).map(+)
    }
}

