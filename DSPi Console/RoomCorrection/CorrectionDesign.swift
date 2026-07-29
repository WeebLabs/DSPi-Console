import Combine
import Foundation

/// Holds the target curve and the fits derived from it.
///
/// One fit per corrected channel, all sharing one target: a house curve that
/// differed per speaker would be a tone control, not a room correction. The
/// fits are rebuilt when the target changes rather than being recomputed inside
/// the view, so the expensive part happens once per edit and not once per
/// redraw.
@MainActor
final class CorrectionDesign: ObservableObject {

    @Published var preset: RoomCorrectionCore.TargetPreset = .natural {
        didSet {
            guard preset != oldValue else { return }
            // A preset replaces the macro controls wholesale, which is the
            // point of it; anchors are the user's own edits and survive.
            target = RoomCorrectionCore.Target(preset: preset)
            invalidate()
        }
    }

    @Published var target = RoomCorrectionCore.Target(preset: .natural) {
        didSet { invalidate() }
    }

    /// Free-form points on top of the macro controls, lowest first.
    @Published private(set) var anchors: [Anchor] = []

    @Published var options = RoomCorrectionCore.FitOptions() {
        didSet { invalidate() }
    }

    /// The fit per channel index, once computed.
    @Published private(set) var fits: [Int: RoomCorrectionCore.Fit] = [:]
    @Published private(set) var isFitting = false
    @Published private(set) var errorMessage: String?

    /// True when the fits no longer reflect the current target.
    @Published private(set) var isStale = true

    struct Anchor: Identifiable, Equatable {
        let id = UUID()
        var freqHz: Double
        var gainDb: Double
    }

    let grid: RoomCorrectionCore.Grid

    init(grid: RoomCorrectionCore.Grid = .display) {
        self.grid = grid
    }

    // MARK: - Anchors

    /// Anchors are kept sorted and one-per-frequency.
    ///
    /// Two anchors at the same frequency is not a curve the user can mean, and
    /// letting them stack would make the second one look ignored.
    func addAnchor(freqHz: Double, gainDb: Double) {
        let rounded = (freqHz * 10).rounded() / 10
        if let existing = anchors.firstIndex(where: { abs($0.freqHz - rounded) < 0.5 }) {
            anchors[existing].gainDb = gainDb
        } else {
            anchors.append(Anchor(freqHz: rounded, gainDb: gainDb))
            anchors.sort { $0.freqHz < $1.freqHz }
        }
        invalidate()
    }

    func removeAnchor(_ anchor: Anchor) {
        anchors.removeAll { $0.id == anchor.id }
        invalidate()
    }

    func updateAnchor(_ anchor: Anchor, gainDb: Double) {
        guard let index = anchors.firstIndex(where: { $0.id == anchor.id }) else { return }
        anchors[index].gainDb = gainDb
        invalidate()
    }

    func clearAnchors() {
        guard !anchors.isEmpty else { return }
        anchors.removeAll()
        invalidate()
    }

    // MARK: - Fitting

    private func invalidate() {
        isStale = true
    }

    /// Build a fit for every channel that has usable measurements.
    ///
    /// Channels with nothing usable are skipped rather than fitted to noise:
    /// a correction derived from a failed measurement is worse than no
    /// correction, because it is applied with the same confidence.
    func recompute(from session: MeasurementSession,
                   channels: [Int],
                   sampleRateHz: Double,
                   platform: RoomCorrectionCore.Platform) {
        isFitting = true
        errorMessage = nil
        defer { isFitting = false }

        var built: [Int: RoomCorrectionCore.Fit] = [:]
        var failures: [String] = []

        for channel in channels {
            do {
                // On the design's grid, not the session's: the curves read
                // back from this fit are plotted against `grid.frequencies`,
                // and a length mismatch makes the plot draw nothing at all.
                let fit = try session.makeFit(forSpeaker: channel,
                                              sampleRateHz: sampleRateHz,
                                              platform: platform,
                                              grid: grid)
                guard fit.positionCount > 0 else { continue }

                try fit.setTarget(target)
                for anchor in anchors {
                    try fit.addTargetAnchor(freqHz: anchor.freqHz, gainDb: anchor.gainDb)
                }
                try fit.fit(options)
                built[channel] = fit
            } catch {
                failures.append("Channel \(channel + 1): \(error.localizedDescription)")
            }
        }

        fits = built
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isStale = false
    }

    // MARK: - Reading back

    /// A curve for plotting, on the design grid.
    func curve(_ which: RoomCorrectionCore.Curve, channel: Int) -> [Double] {
        guard let fit = fits[channel] else { return [] }
        return (try? fit.curve(which)) ?? []
    }

    func metrics(channel: Int) -> RoomCorrectionCore.Metrics? {
        guard let fit = fits[channel] else { return nil }
        return try? fit.metrics
    }

    func uncorrectedMetrics(channel: Int) -> RoomCorrectionCore.Metrics? {
        guard let fit = fits[channel] else { return nil }
        return try? fit.uncorrectedMetrics
    }

    func filters(channel: Int) -> [FilterParams] {
        guard let fit = fits[channel] else { return [] }
        return (try? fit.filters) ?? []
    }

    func trimDb(channel: Int) -> Double {
        guard let fit = fits[channel] else { return 0 }
        return (try? fit.trimDb) ?? 0
    }

    /// Channels with a usable fit, in order.
    var fittedChannels: [Int] { fits.keys.sorted() }

    /// The target curve alone, evaluated without any measurement.
    ///
    /// Lets the design view draw the house curve before anything is measured,
    /// which is when most of the deciding actually happens.
    func previewTargetCurve() -> [Double] {
        // Evaluated directly rather than through a session: session curves are
        // only readable after a fit, and a fit needs positions that do not
        // exist yet at the point the curve is being chosen.
        (try? RoomCorrectionCore.evaluateTarget(target,
                                                anchors: anchors.map { ($0.freqHz, $0.gainDb) },
                                                grid: grid)) ?? []
    }
}

// MARK: - Describing a target in words

extension RoomCorrectionCore.Target {
    /// Plain-language summary of what this curve does.
    ///
    /// The macro controls are precise but abstract; a user choosing between
    /// them benefits more from knowing that a tilt of -0.8 dB per octave is
    /// "noticeably warm" than from the number alone.
    var summary: String {
        var parts: [String] = []

        switch tiltDbPerOctave {
        case ..<(-1.2): parts.append("strongly downward tilted")
        case ..<(-0.6): parts.append("noticeably warm")
        case ..<(-0.15): parts.append("gently downward tilted")
        case ..<0.15: parts.append("flat")
        default: parts.append("tilted upward, which is unusual for a room")
        }

        if bassGainDb >= 1 {
            parts.append(String(format: "with %.0f dB of lift below %.0f Hz",
                                bassGainDb, bassTransitionHz))
        } else if bassGainDb <= -1 {
            parts.append(String(format: "with %.0f dB of cut below %.0f Hz",
                                -bassGainDb, bassTransitionHz))
        }

        if trebleGainDb >= 1 {
            parts.append(String(format: "and %.0f dB of lift above %.0f kHz",
                                trebleGainDb, trebleTransitionHz / 1000))
        } else if trebleGainDb <= -1 {
            parts.append(String(format: "and %.0f dB of cut above %.0f kHz",
                                -trebleGainDb, trebleTransitionHz / 1000))
        }

        return parts.joined(separator: " ") + "."
    }
}

extension RoomCorrectionCore.TargetPreset {
    var explanation: String {
        switch self {
        case .flat:
            return "No tilt at all. Correct on paper, and usually bright in a real "
                 + "room, because a room's reverberant field falls with frequency and "
                 + "a flat measurement puts that energy back."
        case .natural:
            return "A gentle downward tilt, close to what most listeners settle on and "
                 + "to what Harman's listening research found preferred."
        case .studio:
            return "A shallower tilt for nearfield monitoring, where less of what you "
                 + "hear is the room."
        case .bassWarm:
            return "The natural tilt with extra weight below the transition. Suits "
                 + "listening at low volume, where the ear needs more bass to hear "
                 + "the same balance."
        }
    }
}
