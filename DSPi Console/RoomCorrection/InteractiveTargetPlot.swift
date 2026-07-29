import SwiftUI

/// The house curve, edited where it is drawn.
///
/// Three kinds of handle, deliberately doing three different jobs:
///
/// - the **curtains** at each edge bound where correction is applied at all
/// - the **shelf handles** on the curve ends lift or cut everything beyond them
/// - the **points** pull the curve through one place
///
/// Keeping "everything below here" and "here specifically" as separate gestures
/// is most of what makes this understandable: a point that could also do a
/// shelf's job would leave the user unsure which one they had just used.
struct InteractiveTargetPlot: View {
    @ObservedObject var design: CorrectionDesign

    /// Faint measured averages, one per speaker. A single target has to serve
    /// all of them, so all of them are worth seeing while it is chosen.
    let measured: [[Double]]

    @Binding var selectedAnchor: UUID?

    @State private var drag: DragTarget?
    @State private var hovering: DragTarget?

    private enum DragTarget: Equatable {
        case lowCurtain
        case highCurtain
        case bassShelf
        case trebleShelf
        case anchor(UUID)
    }

    /// Within this many points a handle takes the gesture.
    private let grabRadius: CGFloat = 11

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let axis = FrequencyAxis(frequencies: design.grid.frequencies)
            let curve = design.previewTargetCurve()
            let responses = referenced(measured, to: curve)
            let scale = FrequencyPlotScale(fitting: curve + responses.flatMap { $0 },
                                           minimumHalfRange: 8)

            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)
                curtains(axis: axis, in: size)

                ForEach(Array(responses.enumerated()), id: \.offset) { _, response in
                    axis.path(response, scale: scale, in: size)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                }

                axis.path(curve, scale: scale, in: size)
                    .stroke(Color.accentColor, lineWidth: 2)

                shelfHandles(axis: axis, scale: scale, in: size)
                anchorHandles(axis: axis, scale: scale, in: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(axis: axis, scale: scale, in: size))
            .onTapGesture { location in
                handleTap(at: location, axis: axis, scale: scale, in: size)
            }
        }
    }

    /// Measured responses shifted onto the target's level.
    ///
    /// A measurement is absolute dBFS - around 75 - while a target sits near
    /// zero. Plotted as they come, the scale spans both and neither is legible.
    /// Only shape is being compared here, so each is referenced to its own mean
    /// and then to the target's.
    private func referenced(_ responses: [[Double]], to target: [Double]) -> [[Double]] {
        guard !target.isEmpty else { return [] }
        let targetMean = target.reduce(0, +) / Double(target.count)
        return responses.compactMap { response in
            guard !response.isEmpty else { return nil }
            let mean = response.reduce(0, +) / Double(response.count)
            return response.map { $0 - mean + targetMean }
        }
    }

    // MARK: - Curtains

    /// Shaded out to each side, with a gradient across the taper.
    ///
    /// The curtain is not a cliff: correction fades over half an octave, since
    /// a hard edge puts a step in the error curve and the optimizer spends a
    /// filter on it. Drawing it as a hard edge would promise behaviour the
    /// core deliberately does not have.
    private func curtains(axis: FrequencyAxis, in size: CGSize) -> some View {
        // The taper runs outward from the curtain, not inward: buildCorrectionMask
        // fades on `log2(lowCurtainHz / f)`, so correction is at full weight at
        // the curtain frequency and reaches zero half an octave beyond it. Shading
        // the inside would show the band as smaller than it is.
        let taper = pow(2.0, 0.5)
        let lowEdge = axis.x(forHz: design.target.lowCurtainHz, in: size.width)
        let lowFullyOut = axis.x(forHz: design.target.lowCurtainHz / taper, in: size.width)
        let highEdge = axis.x(forHz: design.target.highCurtainHz, in: size.width)
        let highFullyOut = axis.x(forHz: design.target.highCurtainHz * taper, in: size.width)

        // A neutral veil rather than a darkening one. The plot background is
        // already near-black in dark mode, so shading with black is invisible
        // there; `primary` resolves light-on-dark and dark-on-light, so the
        // region reads as masked off in both themes.
        //
        // Positioned explicitly rather than laid out: a ZStack with offsets put
        // the shading in the middle of the plot instead of at its edges.
        let veil = Color.primary.opacity(0.16)
        return ZStack {
            if lowFullyOut > 0 {
                veil.frame(width: lowFullyOut, height: size.height)
                    .position(x: lowFullyOut / 2, y: size.height / 2)
            }
            if lowEdge > lowFullyOut {
                LinearGradient(colors: [veil, Color.primary.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: lowEdge - lowFullyOut, height: size.height)
                    .position(x: (lowEdge + lowFullyOut) / 2, y: size.height / 2)
            }

            if highFullyOut < size.width {
                veil.frame(width: size.width - highFullyOut, height: size.height)
                    .position(x: (size.width + highFullyOut) / 2, y: size.height / 2)
            }
            if highFullyOut > highEdge {
                LinearGradient(colors: [Color.primary.opacity(0), veil],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: highFullyOut - highEdge, height: size.height)
                    .position(x: (highEdge + highFullyOut) / 2, y: size.height / 2)
            }

            curtainEdge(at: lowEdge, in: size, target: .lowCurtain)
            curtainEdge(at: highEdge, in: size, target: .highCurtain)
        }
        .allowsHitTesting(false)
    }

    private func curtainEdge(at x: CGFloat, in size: CGSize,
                             target: DragTarget) -> some View {
        let active = drag == target || hovering == target
        return Rectangle()
            .fill(active ? Color.accentColor : Color.primary.opacity(0.4))
            .frame(width: active ? 2 : 1, height: size.height)
            .position(x: x, y: size.height / 2)
    }

    // MARK: - Shelf handles

    private func shelfHandles(axis: FrequencyAxis, scale: FrequencyPlotScale,
                              in size: CGSize) -> some View {
        ZStack {
            handle(at: shelfPoint(forBass: true, axis: axis, scale: scale, in: size),
                   target: .bassShelf, label: "Bass")
            handle(at: shelfPoint(forBass: false, axis: axis, scale: scale, in: size),
                   target: .trebleShelf, label: "Treble")
        }
    }

    /// A shelf handle sits on the curve at its own transition frequency, which
    /// is where the shelf actually begins to act.
    private func shelfPoint(forBass bass: Bool, axis: FrequencyAxis,
                            scale: FrequencyPlotScale, in size: CGSize) -> CGPoint {
        let hz = bass ? design.target.bassTransitionHz : design.target.trebleTransitionHz
        let curve = design.previewTargetCurve()
        let frequencies = design.grid.frequencies
        let index = frequencies.enumerated()
            .min { abs(log($0.element / hz)) < abs(log($1.element / hz)) }?.offset
        let db = index.flatMap { curve.indices.contains($0) ? curve[$0] : nil } ?? scale.centre
        return CGPoint(x: axis.x(forHz: hz, in: size.width),
                       y: scale.clampedY(forDb: db, in: size.height))
    }

    private func handle(at point: CGPoint, target: DragTarget, label: String) -> some View {
        let active = drag == target || hovering == target
        return ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: active ? 11 : 9, height: active ? 11 : 9)
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                .frame(width: active ? 11 : 9, height: active ? 11 : 9)
        }
        .position(point)
        .allowsHitTesting(false)
    }

    // MARK: - Anchor handles

    private func anchorHandles(axis: FrequencyAxis, scale: FrequencyPlotScale,
                               in size: CGSize) -> some View {
        ForEach(design.anchors) { anchor in
            let selected = selectedAnchor == anchor.id
            let active = drag == .anchor(anchor.id) || hovering == .anchor(anchor.id)
            ZStack {
                Circle()
                    .fill(selected ? Color.white : Color.accentColor)
                    .frame(width: active || selected ? 11 : 8,
                           height: active || selected ? 11 : 8)
                Circle()
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.85),
                            lineWidth: 1.5)
                    .frame(width: active || selected ? 11 : 8,
                           height: active || selected ? 11 : 8)
            }
            .position(anchorPoint(anchor, axis: axis, scale: scale, in: size))
            .allowsHitTesting(false)
        }
    }

    private func anchorPoint(_ anchor: CorrectionDesign.Anchor, axis: FrequencyAxis,
                             scale: FrequencyPlotScale, in size: CGSize) -> CGPoint {
        CGPoint(x: axis.x(forHz: anchor.freqHz, in: size.width),
                y: scale.clampedY(forDb: design.curveValue(of: anchor), in: size.height))
    }

    // MARK: - Gestures

    private func dragGesture(axis: FrequencyAxis, scale: FrequencyPlotScale,
                             in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = drag ?? hitTest(value.startLocation, axis: axis,
                                              scale: scale, in: size)
                drag = current
                guard let current else { return }
                apply(current, at: value.location, axis: axis, scale: scale, in: size)
            }
            .onEnded { _ in drag = nil }
    }

    /// Points win over curtains where they overlap: a point is a small target
    /// the user placed deliberately, a curtain edge is a full-height line that
    /// is easy to hit anywhere else along its length.
    private func hitTest(_ location: CGPoint, axis: FrequencyAxis,
                         scale: FrequencyPlotScale, in size: CGSize) -> DragTarget? {
        for anchor in design.anchors {
            if distance(location, anchorPoint(anchor, axis: axis, scale: scale,
                                              in: size)) < grabRadius {
                return .anchor(anchor.id)
            }
        }
        for (isBass, target) in [(true, DragTarget.bassShelf), (false, .trebleShelf)] {
            if distance(location, shelfPoint(forBass: isBass, axis: axis, scale: scale,
                                             in: size)) < grabRadius {
                return target
            }
        }
        if abs(location.x - axis.x(forHz: design.target.lowCurtainHz,
                                   in: size.width)) < grabRadius {
            return .lowCurtain
        }
        if abs(location.x - axis.x(forHz: design.target.highCurtainHz,
                                   in: size.width)) < grabRadius {
            return .highCurtain
        }
        return nil
    }

    private func apply(_ target: DragTarget, at location: CGPoint, axis: FrequencyAxis,
                       scale: FrequencyPlotScale, in size: CGSize) {
        let hz = axis.hz(forX: location.x, in: size.width)
        let db = scale.db(forY: location.y, in: size.height)

        switch target {
        case .lowCurtain:
            // Kept clear of the high curtain, or the correction band inverts
            // and nothing is corrected at all.
            design.target.lowCurtainHz = min(max(hz, 15), design.target.highCurtainHz / 2)
        case .highCurtain:
            design.target.highCurtainHz = max(min(hz, 20000), design.target.lowCurtainHz * 2)
        case .bassShelf:
            design.target.bassTransitionHz = min(max(hz, 30), 400)
            design.target.bassGainDb = clamp(db - macroWithoutBass(atHz: hz), -12, 15)
        case .trebleShelf:
            design.target.trebleTransitionHz = min(max(hz, 1500), 16000)
            design.target.trebleGainDb = clamp(db - macroWithoutTreble(atHz: hz), -12, 12)
        case .anchor(let id):
            guard let anchor = design.anchors.first(where: { $0.id == id }) else { return }
            selectedAnchor = id
            design.moveAnchor(anchor,
                              toHz: min(max(hz, design.grid.minHz), design.grid.maxHz),
                              curveValueDb: db)
        }
    }

    /// The curve with this shelf flattened, so dragging the handle sets the
    /// shelf to exactly the height the user dropped it at rather than adding to
    /// whatever it already was.
    private func macroWithoutBass(atHz hz: Double) -> Double {
        var bare = design.target
        bare.bassGainDb = 0
        return value(of: bare, atHz: hz)
    }

    private func macroWithoutTreble(atHz hz: Double) -> Double {
        var bare = design.target
        bare.trebleGainDb = 0
        return value(of: bare, atHz: hz)
    }

    private func value(of target: RoomCorrectionCore.Target, atHz hz: Double) -> Double {
        let anchors = design.anchors.map { ($0.freqHz, $0.gainDb) }
        guard let curve = try? RoomCorrectionCore.evaluateTarget(target, anchors: anchors,
                                                                 grid: design.grid),
              let index = design.grid.frequencies.enumerated()
                  .min(by: { abs(log($0.element / hz)) < abs(log($1.element / hz)) })?.offset,
              curve.indices.contains(index)
        else { return 0 }
        return curve[index]
    }

    private func handleTap(at location: CGPoint, axis: FrequencyAxis,
                           scale: FrequencyPlotScale, in size: CGSize) {
        if let hit = hitTest(location, axis: axis, scale: scale, in: size) {
            if case .anchor(let id) = hit { selectedAnchor = id } else { selectedAnchor = nil }
            return
        }
        // Empty space adds a point where it was clicked, which is the only
        // discoverable way to make the first one.
        design.addAnchor(atHz: axis.hz(forX: location.x, in: size.width),
                         curveValueDb: scale.db(forY: location.y, in: size.height))
        selectedAnchor = design.anchors.last?.id
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
