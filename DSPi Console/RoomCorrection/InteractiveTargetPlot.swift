import AppKit
import SwiftUI

/// The house curve, edited where it is drawn.
///
/// Three kinds of handle, deliberately doing three different jobs:
///
/// - the **curtains** at each edge bound where correction is applied at all
/// - the **shelf handles** lift or cut everything below or above their frequency
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

    @State private var drag: TargetPlotHandle?
    @State private var hovering: TargetPlotHandle?
    /// Where a click would put a point, previewed while the pointer is over
    /// empty plot.
    @State private var ghost: CGPoint?

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
            let tester = hitTester(axis: axis, scale: scale, in: size)

            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)
                curtains(axis: axis, in: size)

                ForEach(Array(responses.enumerated()), id: \.offset) { _, response in
                    axis.path(response, scale: scale, in: size)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                }

                axis.path(curve, scale: scale, in: size)
                    .stroke(Color.accentColor, lineWidth: 2)

                ghostPoint
                shelfHandles(axis: axis, scale: scale, in: size)
                anchorHandles(axis: axis, scale: scale, in: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(tester: tester, axis: axis, scale: scale, in: size))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hovering = tester.handle(at: location)
                    // Only where a click would actually add one.
                    ghost = (hovering == nil && drag == nil && contains(location, in: size))
                        ? location : nil
                case .ended:
                    hovering = nil
                    ghost = nil
                }
                updateCursor()
            }
            .overlay(
                RightClickCatcher { location in
                    removePoint(at: location, tester: tester)
                }
            )
        }
    }

    // MARK: - Curves

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

    /// The bands outside the correction range, shaded flat.
    ///
    /// The correction does fade over half an octave beyond each curtain rather
    /// than stopping dead, but drawing that as a gradient made the boundary
    /// itself hard to see - and the boundary is the thing being dragged.
    private func curtains(axis: FrequencyAxis, in size: CGSize) -> some View {
        let lowEdge = axis.x(forHz: design.target.lowCurtainHz, in: size.width)
        let highEdge = axis.x(forHz: design.target.highCurtainHz, in: size.width)

        // Darker than the plot rather than lighter, so the excluded band reads
        // as switched off. Black at this opacity still separates from the
        // plot's own fill in dark mode without going pitch black in light.
        //
        // Positioned explicitly rather than laid out: a ZStack with offsets put
        // the shading in the middle of the plot instead of at its edges.
        let veil = Color.black.opacity(0.42)
        return ZStack {
            if lowEdge > 0 {
                veil.frame(width: lowEdge, height: size.height)
                    .position(x: lowEdge / 2, y: size.height / 2)
            }
            if highEdge < size.width {
                veil.frame(width: size.width - highEdge, height: size.height)
                    .position(x: (size.width + highEdge) / 2, y: size.height / 2)
            }
            curtainEdge(at: lowEdge, in: size, handle: .lowCurtain)
            curtainEdge(at: highEdge, in: size, handle: .highCurtain)
        }
        .allowsHitTesting(false)
    }

    private func curtainEdge(at x: CGFloat, in size: CGSize,
                             handle: TargetPlotHandle) -> some View {
        let active = drag == handle || hovering == handle
        return Rectangle()
            .fill(active ? Color.accentColor : Color.primary.opacity(0.4))
            .frame(width: active ? 2 : 1, height: size.height)
            .position(x: x, y: size.height / 2)
    }

    // MARK: - Handles

    private func shelfHandles(axis: FrequencyAxis, scale: FrequencyPlotScale,
                              in size: CGSize) -> some View {
        ZStack {
            labelledHandle(at: shelfPoint(forBass: true, axis: axis, scale: scale, in: size),
                           handle: .bassShelf, label: "Bass", in: size)
            labelledHandle(at: shelfPoint(forBass: false, axis: axis, scale: scale, in: size),
                           handle: .trebleShelf, label: "Treble", in: size)
        }
    }

    /// A shelf handle sits on the curve at its own transition frequency, which
    /// is where the shelf actually begins to act.
    private func shelfPoint(forBass bass: Bool, axis: FrequencyAxis,
                            scale: FrequencyPlotScale, in size: CGSize) -> CGPoint {
        let hz = bass ? design.target.bassTransitionHz : design.target.trebleTransitionHz
        return CGPoint(x: axis.x(forHz: hz, in: size.width),
                       y: scale.clampedY(forDb: curveValue(atHz: hz), in: size.height))
    }

    private func curveValue(atHz hz: Double) -> Double {
        let curve = design.previewTargetCurve()
        guard let index = design.grid.frequencies.enumerated()
            .min(by: { abs(log($0.element / hz)) < abs(log($1.element / hz)) })?.offset,
              curve.indices.contains(index) else { return 0 }
        return curve[index]
    }

    /// Named on the plot, because an unlabelled dot on a curve is not a control
    /// anyone will find. The label sits away from the plot edge so it stays
    /// readable when the handle is dragged to an extreme.
    private func labelledHandle(at point: CGPoint, handle: TargetPlotHandle,
                                label: String, in size: CGSize) -> some View {
        let active = drag == handle || hovering == handle
        let diameter: CGFloat = active ? 12 : 10
        return ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: diameter, height: diameter)
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
        }
        .position(point)
        .overlay(
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .position(x: min(max(point.x, 22), size.width - 22),
                          y: max(point.y - 14, 8))
        )
        .allowsHitTesting(false)
    }

    private func anchorHandles(axis: FrequencyAxis, scale: FrequencyPlotScale,
                               in size: CGSize) -> some View {
        ForEach(design.anchors) { anchor in
            let selected = selectedAnchor == anchor.id
            let active = drag == .anchor(anchor.id) || hovering == .anchor(anchor.id)
            let diameter: CGFloat = active || selected ? 11 : 8
            ZStack {
                Circle()
                    .fill(selected ? Color.white : Color.accentColor)
                    .frame(width: diameter, height: diameter)
                Circle()
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.85),
                            lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
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

    /// Where a click would land a point.
    ///
    /// Hollow rather than filled, so it reads as a preview rather than as a
    /// point that has already been placed.
    @ViewBuilder
    private var ghostPoint: some View {
        if let ghost {
            Circle()
                .stroke(Color.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 11, height: 11)
                .position(ghost)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Hit testing

    private func hitTester(axis: FrequencyAxis, scale: FrequencyPlotScale,
                           in size: CGSize) -> TargetPlotHitTester {
        var points: [(handle: TargetPlotHandle, position: CGPoint)] =
            design.anchors.map {
                (.anchor($0.id), anchorPoint($0, axis: axis, scale: scale, in: size))
            }
        points.append((.bassShelf,
                       shelfPoint(forBass: true, axis: axis, scale: scale, in: size)))
        points.append((.trebleShelf,
                       shelfPoint(forBass: false, axis: axis, scale: scale, in: size)))

        return TargetPlotHitTester(
            points: points,
            verticals: [
                (.lowCurtain, axis.x(forHz: design.target.lowCurtainHz, in: size.width)),
                (.highCurtain, axis.x(forHz: design.target.highCurtainHz, in: size.width)),
            ],
            grabRadius: grabRadius)
    }

    private func contains(_ location: CGPoint, in size: CGSize) -> Bool {
        location.x >= 0 && location.x <= size.width
            && location.y >= 0 && location.y <= size.height
    }

    // MARK: - Gestures

    /// One gesture for both dragging and clicking.
    ///
    /// A `DragGesture` with no minimum distance claims the press immediately,
    /// so a separate `onTapGesture` never fires - which is why clicking to add
    /// a point did nothing. A press that ends without moving is the click.
    private func dragGesture(tester: TargetPlotHitTester, axis: FrequencyAxis,
                             scale: FrequencyPlotScale, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    drag = tester.handle(at: value.startLocation)
                    ghost = nil
                    updateCursor()
                }
                guard let drag else { return }
                apply(drag, at: value.location, axis: axis, scale: scale, in: size)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 3
                if !moved {
                    click(at: value.startLocation, tester: tester,
                          axis: axis, scale: scale, in: size)
                }
                drag = nil
                updateCursor()
            }
    }

    private func click(at location: CGPoint, tester: TargetPlotHitTester,
                       axis: FrequencyAxis, scale: FrequencyPlotScale, in size: CGSize) {
        if let hit = tester.handle(at: location) {
            if case .anchor(let id) = hit { selectedAnchor = id } else { selectedAnchor = nil }
            return
        }
        guard contains(location, in: size) else { return }
        design.addAnchor(atHz: axis.hz(forX: location.x, in: size.width),
                         curveValueDb: scale.db(forY: location.y, in: size.height))
        selectedAnchor = design.anchors.first {
            abs($0.freqHz - axis.hz(forX: location.x, in: size.width)) < 1
        }?.id
    }

    private func removePoint(at location: CGPoint, tester: TargetPlotHitTester) {
        guard case .anchor(let id) = tester.handle(at: location),
              let anchor = design.anchors.first(where: { $0.id == id }) else { return }
        design.removeAnchor(anchor)
        if selectedAnchor == id { selectedAnchor = nil }
    }

    private func apply(_ handle: TargetPlotHandle, at location: CGPoint,
                       axis: FrequencyAxis, scale: FrequencyPlotScale, in size: CGSize) {
        let hz = axis.hz(forX: location.x, in: size.width)
        let db = scale.db(forY: location.y, in: size.height)

        switch handle {
        case .lowCurtain:
            // Kept clear of the high curtain, or the correction band inverts
            // and nothing is corrected at all.
            design.target.lowCurtainHz = min(max(hz, 15), design.target.highCurtainHz / 2)
        case .highCurtain:
            design.target.highCurtainHz = max(min(hz, 20000), design.target.lowCurtainHz * 2)
        case .bassShelf:
            design.target.bassTransitionHz = min(max(hz, 30), 400)
            design.target.bassGainDb = clamp(db - shapeWithoutShelf(bass: true, atHz: hz),
                                             -12, 15)
        case .trebleShelf:
            design.target.trebleTransitionHz = min(max(hz, 1500), 16000)
            design.target.trebleGainDb = clamp(db - shapeWithoutShelf(bass: false, atHz: hz),
                                               -12, 12)
        case .anchor(let id):
            guard let anchor = design.anchors.first(where: { $0.id == id }) else { return }
            selectedAnchor = id
            design.moveAnchor(anchor,
                              toHz: min(max(hz, design.grid.minHz), design.grid.maxHz),
                              curveValueDb: db)
        }
    }

    /// The curve with one shelf flattened, so dragging its handle sets the
    /// shelf to exactly the height it was dropped at rather than adding to
    /// whatever it already was.
    private func shapeWithoutShelf(bass: Bool, atHz hz: Double) -> Double {
        var bare = design.target
        if bass { bare.bassGainDb = 0 } else { bare.trebleGainDb = 0 }
        let anchors = design.anchors.map { ($0.freqHz, $0.gainDb) }
        guard let curve = try? RoomCorrectionCore.evaluateTarget(bare, anchors: anchors,
                                                                 grid: design.grid),
              let index = design.grid.frequencies.enumerated()
                  .min(by: { abs(log($0.element / hz)) < abs(log($1.element / hz)) })?.offset,
              curve.indices.contains(index)
        else { return 0 }
        return curve[index]
    }

    /// Says what a handle will do before it is grabbed.
    ///
    /// A curtain moves only horizontally, so it gets the resize cursor; points
    /// and shelf handles move in both axes, so they get the open hand. Set
    /// rather than pushed: a push/pop stack is easy to leave unbalanced when
    /// the pointer leaves during a drag.
    private func updateCursor() {
        switch drag ?? hovering {
        case .lowCurtain, .highCurtain:
            NSCursor.resizeLeftRight.set()
        case .bassShelf, .trebleShelf, .anchor:
            NSCursor.openHand.set()
        case nil:
            NSCursor.arrow.set()
        }
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
