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

    @Published var options = CorrectionDesign.defaultFitOptions {
        didSet { invalidate() }
    }

    /// What the Target step starts on.
    ///
    /// The core's own default is cut-only, which is the conservative reading of
    /// spec 7.3 and what the acceptance corpus is scored against. Console starts
    /// at 6 dB instead: a dip every seat agrees on is worth filling, and leaving
    /// the budget at zero means the level of the whole correction is pinned by
    /// the deepest dip nobody chose to fill.
    ///
    /// Deliberately a product decision made here rather than a change to the
    /// core default, so the core keeps the documented conservative behaviour and
    /// the corpus keeps measuring it.
    ///
    /// This does not raise `combinedCeilingDb`. Boost the fit generates is still
    /// brought back under the ceiling by the trim, so this buys correction shape
    /// at the cost of channel level rather than buying level - and spec 7.3
    /// keeps the ceiling where it is until the firmware signal path and its
    /// saturation behaviour are verified.
    static var defaultFitOptions: RoomCorrectionCore.FitOptions {
        var options = RoomCorrectionCore.FitOptions()
        options.boostLimitDb = 6
        // Q 2 is about two-thirds of an octave, which cannot reach a narrow
        // dip at all.  Measured on a room with one: raising this to 4 improved
        // shape more than doubling the boost budget did, and costs no extra
        // level.  Still guarded by the reliability floor, which refuses boost
        // of any width where the positions disagree.
        options.maxBoostQ = 4
        return options
    }

    /// Settings for the fixed-pole comparison.
    ///
    /// The design this produces cannot be written to the hardware, so changing
    /// these never affects what would be applied - only what is drawn beside it.
    @Published var parallelOptions = RoomCorrectionCore.ParallelOptions() {
        didSet { invalidate() }
    }

    /// Whether to design the fixed-pole bank alongside each fit.
    ///
    /// Off by default: it roughly doubles the time a recompute takes and
    /// answers a research question rather than a product one.
    @Published var comparesFixedPole = false {
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

    /// The grid everything here is expressed on.
    ///
    /// Adopted from the session when there is one, because measurements are
    /// analysed on the session's grid and a fit only accepts positions of that
    /// length. Having a separate plotting grid meant every fit was rejected
    /// for a length mismatch, and the failure was silent.
    private(set) var grid: RoomCorrectionCore.Grid

    init(grid: RoomCorrectionCore.Grid = .standard) {
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

    /// The curve with no points on it: tilt and shelves alone.
    ///
    /// The reference a dropped point is measured against. The curve passes
    /// exactly through each point, so a point's offset is simply where the user
    /// put it minus where the shape already was - no iteration, and no
    /// interaction between points to unpick.
    func macroCurve() -> [Double] {
        (try? RoomCorrectionCore.evaluateTarget(target, anchors: [], grid: grid)) ?? []
    }

    /// Where the shape sits at one frequency, interpolated onto the grid.
    func macroValue(atHz hz: Double) -> Double {
        let curve = macroCurve()
        guard !curve.isEmpty else { return 0 }
        let frequencies = grid.frequencies
        guard let index = frequencies.enumerated()
            .min(by: { abs(log($0.element / hz)) < abs(log($1.element / hz)) })?.offset
        else { return 0 }
        return curve[index]
    }

    /// Where a point sits on the curve, in dB, for drawing and dragging.
    ///
    /// The UI never shows the stored offset: setting one number and seeing a
    /// different one is what made this control hard to reason about.
    func curveValue(of anchor: Anchor) -> Double {
        macroValue(atHz: anchor.freqHz) + anchor.gainDb
    }

    /// Put a point at a place on the curve.
    func addAnchor(atHz hz: Double, curveValueDb: Double) {
        addAnchor(freqHz: hz, gainDb: curveValueDb - macroValue(atHz: hz))
    }

    /// Move a point to a place on the curve, in one edit.
    ///
    /// Frequency and value together, because a drag changes both and applying
    /// them separately would evaluate the shape twice against a half-moved
    /// point.
    func moveAnchor(_ anchor: Anchor, toHz hz: Double, curveValueDb: Double) {
        let rounded = (hz * 10).rounded() / 10
        let offset = curveValueDb - macroValue(atHz: rounded)

        // A point dragged onto another is the user aiming at one place twice.
        // Removed first, then the survivor is found again by identity: holding
        // an index across the removal would point at the wrong element, or off
        // the end when the collision sat earlier in the array.
        anchors.removeAll { $0.id != anchor.id && abs(log2($0.freqHz / rounded)) < 0.02 }

        guard let index = anchors.firstIndex(where: { $0.id == anchor.id }) else { return }
        anchors[index].freqHz = rounded
        anchors[index].gainDb = offset
        anchors.sort { $0.freqHz < $1.freqHz }
        invalidate()
    }

    /// Back to the preset, points and all.
    func resetCurve() {
        anchors.removeAll()
        target = RoomCorrectionCore.Target(preset: preset)
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


        // Follow the session, so the curves read back below are the same
        // length as the frequencies they are plotted against.
        grid = session.grid

        var built: [Int: RoomCorrectionCore.Fit] = [:]
        var failures: [String] = []

        for channel in channels {
            do {
                let fit = try session.makeFit(forSpeaker: channel,
                                              sampleRateHz: sampleRateHz,
                                              platform: platform)
                guard fit.positionCount > 0 else { continue }

                try fit.setTarget(target)
                for anchor in anchors {
                    try fit.addTargetAnchor(freqHz: anchor.freqHz, gainDb: anchor.gainDb)
                }
                try fit.fit(options)
                if comparesFixedPole {
                    // A failure here must not lose the real correction, which is
                    // the thing the user came for.
                    do { try fit.designParallel(parallelOptions) } catch {
                        failures.append("Channel \(channel + 1) fixed-pole comparison: "
                                        + error.localizedDescription)
                    }
                }
                built[channel] = fit
            } catch {
                failures.append("Channel \(channel + 1): \(error.localizedDescription)")
            }
        }

        fits = built
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        } else if built.isEmpty {
            // Nothing failed and nothing was produced, which from the user's
            // side is a button that did nothing at all.
            errorMessage = "None of the selected channels have a usable measurement "
                         + "to correct. Go back to Measurements and capture at least "
                         + "one position."
        }
        isStale = false
    }

    // MARK: - Reading back

    /// A curve for plotting, on the design grid.
    func curve(_ which: RoomCorrectionCore.Curve, channel: Int) -> [Double] {
        guard let fit = fits[channel] else { return [] }
        return (try? fit.curve(which)) ?? []
    }

    /// The fixed-pole bank's predicted correction, or empty when it was not
    /// designed for this channel.
    func parallelCurve(channel: Int) -> [Double] {
        guard let fit = fits[channel], fit.hasParallelDesign else { return [] }
        return (try? fit.curve(.parallelCorrection)) ?? []
    }

    func parallelMetrics(channel: Int) -> RoomCorrectionCore.Metrics? {
        guard let fit = fits[channel], fit.hasParallelDesign else { return nil }
        return try? fit.parallelMetrics
    }

    func parallelTrimDb(channel: Int) -> Double? {
        guard let fit = fits[channel], fit.hasParallelDesign else { return nil }
        return try? fit.parallelTrimDb
    }

    func parallelSections(channel: Int) -> [RoomCorrectionCore.ParallelSection] {
        guard let fit = fits[channel], fit.hasParallelDesign else { return [] }
        return (try? fit.parallelSections) ?? []
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
