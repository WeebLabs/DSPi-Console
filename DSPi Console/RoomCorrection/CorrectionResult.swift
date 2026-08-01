import Foundation

/// What one channel's correction actually achieved, in terms a user can act on.
///
/// The core reports metrics; this turns them into a judgement. Kept separate
/// from the view so the thresholds - what counts as an improvement, when to
/// warn about boost - are testable and live in one place rather than being
/// scattered through formatting code.
struct CorrectionSummary: Equatable {
    let channel: Int
    let before: Double
    let after: Double
    let filterCount: Int
    let shelfCount: Int
    let trimDb: Double
    let maxBoostDb: Double
    let maxCutDb: Double
    let transitionHz: Double
    let transitionEstimated: Bool

    /// Error reduction as a percentage of what was there.
    ///
    /// Reported alongside the dB figures rather than instead of them: a
    /// percentage flatters a bad starting point, and a dB figure means nothing
    /// to most people on its own.
    var improvementPercent: Double {
        guard before > 0.01 else { return 0 }
        return max(0, (before - after) / before * 100)
    }

    var improvementDb: Double { before - after }

    enum Outcome: Equatable {
        case improved
        /// Measurably better, but not by enough to hear.
        case marginal
        /// The fit could not improve on the untreated response.
        case noBenefit
    }

    /// Half a decibel of RMSE is roughly where a change stops being arguable.
    /// Below that the honest answer is that the room was already close to the
    /// target, not that the tool did something clever.
    var outcome: Outcome {
        if improvementDb >= 1.0 { return .improved }
        if improvementDb >= 0.2 { return .marginal }
        return .noBenefit
    }

    var headline: String {
        switch outcome {
        case .improved:
            return String(format: "%.1f dB closer to target", improvementDb)
        case .marginal:
            return "Only slightly changed"
        case .noBenefit:
            return "No improvement to make"
        }
    }

    var explanation: String {
        switch outcome {
        case .improved:
            return String(format: "Deviation from the target fell from %.1f dB to "
                          + "%.1f dB across the corrected band.", before, after)
        case .marginal:
            return String(format: "Deviation went from %.1f dB to %.1f dB. That is a "
                          + "real change but a small one, and you may not hear it.",
                          before, after)
        case .noBenefit:
            return "This channel already sits about as close to the target as the "
                 + "filters can bring it. Applying the correction is not wrong, but "
                 + "it will not do much."
        }
    }

    /// Things the user should know before applying, most consequential first.
    var cautions: [String] {
        var found: [String] = []

        if maxBoostDb > 0.5 {
            found.append(String(
                format: "Boosts by up to %.1f dB. Boost asks the driver for output it "
                      + "may not have, and costs the same headroom whether or not it "
                      + "gets it.", maxBoostDb))
        }
        if trimDb < -0.5 {
            found.append(String(
                format: "Takes %.1f dB of level to make room for the correction, which "
                      + "Apply puts on this channel's gain. This is expected, not a "
                      + "fault: cuts and boosts both need headroom, and the system will "
                      + "be that much quieter until you turn it up.", -trimDb))
        }
        if !transitionEstimated {
            found.append("The transition between modal and statistical behaviour could "
                         + "not be estimated from these positions, so a default was "
                         + "used. More positions would make it measurable.")
        }
        return found
    }

    init(channel: Int,
         metrics: RoomCorrectionCore.Metrics,
         uncorrected: RoomCorrectionCore.Metrics,
         trimDb: Double,
         transitionHz: Double,
         transitionEstimated: Bool) {
        self.channel = channel
        // The reliable figure, not the raw one: the raw worst-position error
        // includes bands where the positions disagree so completely that no
        // filter could serve them all, and reporting it would make every
        // correction look like a failure.
        self.before = uncorrected.reliableWorstPositionRmseDb
        self.after = metrics.reliableWorstPositionRmseDb
        self.filterCount = metrics.activeFilterCount
        self.shelfCount = metrics.shelfFilterCount
        self.trimDb = trimDb
        self.maxBoostDb = max(0, metrics.maxCombinedCorrectionDb)
        self.maxCutDb = max(0, -metrics.minCombinedCorrectionDb)
        self.transitionHz = transitionHz
        self.transitionEstimated = transitionEstimated
    }

    /// Memberwise, for tests and previews.
    init(channel: Int, before: Double, after: Double, filterCount: Int,
         shelfCount: Int = 0, trimDb: Double = 0, maxBoostDb: Double = 0,
         maxCutDb: Double = 0, transitionHz: Double = 200,
         transitionEstimated: Bool = true) {
        self.channel = channel
        self.before = before
        self.after = after
        self.filterCount = filterCount
        self.shelfCount = shelfCount
        self.trimDb = trimDb
        self.maxBoostDb = maxBoostDb
        self.maxCutDb = maxCutDb
        self.transitionHz = transitionHz
        self.transitionEstimated = transitionEstimated
    }
}

extension CorrectionDesign {
    /// A summary per fitted channel, in order.
    func summaries() -> [CorrectionSummary] {
        fittedChannels.compactMap { channel in
            guard let fit = fits[channel],
                  let metrics = try? fit.metrics,
                  let uncorrected = try? fit.uncorrectedMetrics else { return nil }
            let transition = (try? fit.transition) ?? (hz: 0, estimated: false)
            return CorrectionSummary(channel: channel,
                                     metrics: metrics,
                                     uncorrected: uncorrected,
                                     trimDb: (try? fit.trimDb) ?? 0,
                                     transitionHz: transition.hz,
                                     transitionEstimated: transition.estimated)
        }
    }
}
