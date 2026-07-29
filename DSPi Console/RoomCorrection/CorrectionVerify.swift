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
                                         crossoverWasBypassed:
                                            bypassedCrossovers.contains(speaker)))
            }

            await session.end()
            results = collected
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

    private func compare(speaker: Int,
                         measured: [Double],
                         crossoverWasBypassed: Bool) -> VerificationResult {
        let predicted = predictedCurve(for: speaker)
        let target = design.curve(.target, channel: speaker)
        let weight = design.curve(.maskWeight, channel: speaker)

        guard measured.count == predicted.count, !measured.isEmpty else {
            return VerificationResult(speakerIndex: speaker,
                                      measuredDb: measured,
                                      predictedDb: predicted,
                                      targetDb: target,
                                      worstDeviationDb: 0,
                                      rmsDeviationDb: 0,
                                      crossoverWasBypassed: crossoverWasBypassed)
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
            crossoverWasBypassed: crossoverWasBypassed)
    }

    /// Measured plus correction, which is what the fit predicts will be heard.
    private func predictedCurve(for speaker: Int) -> [Double] {
        let measured = design.curve(.powerAverage, channel: speaker)
        let correction = design.curve(.correction, channel: speaker)
        guard measured.count == correction.count else { return [] }
        return zip(measured, correction).map(+)
    }
}

