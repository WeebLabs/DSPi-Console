import SwiftUI

// MARK: - Shared channel colour

/// The colour a channel's curve is drawn in on the response graph.  Used by the
/// Bode curves and by the spectrum drawn behind them, so a channel's live
/// spectrum can never end up a different colour from its own response.
func eqCurveColor(eqCh: Int, chOut1: Int) -> Color {
    if eqCh < chOut1 { return MatrixInput.color(for: eqCh) }
    let outIdx = eqCh - chOut1
    return MatrixOutput.all.indices.contains(outIdx) ? MatrixOutput.all[outIdx].color : .accentColor
}

// MARK: - Overlay

/// The live spectrum, drawn inside the filter-response graph instead of in a
/// strip of its own.
///
/// The two pictures share only the frequency axis.  The response curves are
/// relative dB about zero and the spectrum is absolute dBFS, so the spectrum
/// gets its own vertical mapping (the analyser's floor at the bottom of the
/// plot, its ceiling at the top) and is drawn as a translucent fill under the
/// curves rather than as another line competing with them.
///
/// It always shows one channel: the one being edited on a channel page, or the
/// one picked as "Dashboard FFT" on the dashboard.  That channel gets the bands
/// in the bass and the raw FFT bins above them, with the peak-hold contour from
/// the bands.
struct GraphSpectrumOverlay: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    /// EQ channels the graph is currently drawing, in its own numbering.
    let visibleEqChannels: [Int]
    /// The channel being edited, if any: it gets the fine picture to itself.
    let activeEqChannel: Int?
    let minFreq: Float
    let maxFreq: Float

    var body: some View {
        if engine.supported, let plan = plan {
            GraphSpectrumCanvas(
                plan: plan, configuration: RtaDisplayConfiguration(engine: engine),
                frames: engine.snapshot.frames.filter { key, _ in plan.channels.contains { $0.rta == Int(key) } }
                    .mapValues { $0.displayFrame },
                bins: plan.wantsBins ? engine.snapshot.bins?.displayFrame : nil,
                chOut1: vm.chOut1, minFreq: minFreq, maxFreq: maxFreq,
                scale: RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB),
                tau: rtaFallTau(engine, settings.rtaSmoothing), showPeak: settings.rtaShowPeakHold,
                glow: settings.showGraphGlow, opacity: settings.rtaGraphOpacity)
                .equatable()
                .allowsHitTesting(false)
                .rtaWatching(engine, plan.request)
                .transition(.opacity)
        }
    }

    // MARK: What to ask the device for

    /// One channel to draw, in both numberings: the graph's EQ channel and the
    /// analyser's channel at the chosen tap.
    struct Channel: Equatable {
        let eq: Int
        let rta: Int
    }

    struct Plan: Equatable {
        let tap: UInt8
        let channels: [Channel]
        let wantsBins: Bool

        var request: RtaRequest {
            RtaRequest(tap: tap,
                       mask: channels.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1.rta)) },
                       wantsBins: wantsBins)
        }
    }

    /// How many channels this device's analyser has at a tap.  A mask bit for a
    /// channel the device does not have is a rejected configuration, so the
    /// selection is clamped to what the caps report.
    private func channelCount(tap: UInt8) -> Int {
        let n = tap == RTA_TAP_INPUT ? Int(engine.caps.inputChannels) : Int(engine.caps.outputChannels)
        return n > 0 ? n : (tap == RTA_TAP_INPUT ? vm.numMatrixInputs : vm.numOutputChannels)
    }

    private func channel(forEq eqCh: Int) -> Channel? {
        let tap: UInt8 = eqCh < vm.chOut1 ? RTA_TAP_INPUT : RTA_TAP_OUTPUT
        let rta = eqCh < vm.chOut1 ? eqCh : eqCh - vm.chOut1
        guard rta >= 0, rta < channelCount(tap: tap), rta < 16 else { return nil }
        return Channel(eq: eqCh, rta: rta)
    }

    /// The analyser configuration for the one channel the graph shows.
    ///
    /// On a channel page that is the edited channel, and hiding its curve hides
    /// its spectrum too.  The dashboard's channel is an explicit choice, so it
    /// is drawn whether or not its curve is visible.
    private var plan: Plan? {
        guard vm.isDeviceReady else { return nil }
        let eqCh: Int
        if let active = activeEqChannel {
            guard visibleEqChannels.contains(active) else { return nil }
            eqCh = active
        } else {
            eqCh = vm.eqChannel(for: vm.dashboardRtaSource)
        }
        guard let ch = channel(forEq: eqCh) else { return nil }
        return Plan(tap: eqCh < vm.chOut1 ? RTA_TAP_INPUT : RTA_TAP_OUTPUT,
                    channels: [ch], wantsBins: true)
    }

}

/// A value-only boundary keeps unrelated meter and analyser telemetry updates
/// out of the animated canvas. Only the selected channels enter this view.
private struct GraphSpectrumCanvas: View, Equatable {
    @Environment(\.rtaRenderingActive) private var renderingActive
    let plan: GraphSpectrumOverlay.Plan
    let configuration: RtaDisplayConfiguration
    let frames: [UInt8: RtaBandFrame]
    let bins: RtaBinFrame?
    let chOut1: Int
    let minFreq: Float
    let maxFreq: Float
    let scale: RtaScale
    let tau: TimeInterval
    let showPeak: Bool
    let glow: Bool
    let opacity: Double
    @State private var smoothing = RtaCurveSmoothing()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.plan == rhs.plan && lhs.configuration == rhs.configuration
            && lhs.frames == rhs.frames && lhs.bins == rhs.bins && lhs.chOut1 == rhs.chOut1
            && lhs.minFreq == rhs.minFreq && lhs.maxFreq == rhs.maxFreq && lhs.scale == rhs.scale
            && lhs.tau == rhs.tau && lhs.showPeak == rhs.showPeak
            && lhs.glow == rhs.glow && lhs.opacity == rhs.opacity
    }

    var body: some View {
        if tau > 0 {
            TimelineView(.animation(minimumInterval: rtaFrameInterval, paused: !renderingActive)) { timeline in
                canvas(now: timeline.date)
            }
        } else {
            canvas(now: nil)
        }
    }

    private func canvas(now: Date?) -> some View {
        // Allow asynchronous presentation; data preparation is cached separately.
        return Canvas(rendersAsynchronously: true) { ctx, size in
            let plot = CGRect(origin: .zero, size: size)
            guard plot.width > 4, plot.height > 4, configuration.tap == plan.tap else { return }

            let curves = RtaCurveBuilder(configuration: configuration, smoothing: smoothing,
                                         minFreq: Double(minFreq), maxFreq: Double(maxFreq),
                                         plot: plot, scale: scale, now: now, tau: tau)
            var traces: [Trace] = []
            for channel in plan.channels {
                let colour = eqCurveColor(eqCh: channel.eq, chOut1: chOut1)
                let band = frames[UInt8(clamping: channel.rta)]

                let bands = (band?.hasData ?? false)
                    ? curves.bandPoints(band!, peak: false, channel: channel.rta)
                    : []
                var curve = bands
                var dense = false
                if plan.wantsBins {
                    let bins = self.bins.flatMap { Int($0.channel) == channel.rta ? $0 : nil }
                        .map { curves.binPoints($0, channel: channel.rta) } ?? []
                    curve = curves.blend(bands: bands, bins: bins)
                    // Until a bin frame arrives the blend is just the bands.
                    dense = bins.count > 1
                }
                var trace = Trace(colour: colour)
                if curve.count > 1 {
                    // The blended series is already one point per pixel:
                    // smoothing it only adds overshoot around a tone.  The
                    // thirty-odd band points need it, or they read as a chain
                    // of facets beside the response curves.
                    let path = dense ? polyline(through: curve)
                                     : smoothPath(through: curve, clampedTo: plot)
                    var fill = path
                    fill.addLine(to: CGPoint(x: curve[curve.count - 1].x, y: plot.maxY))
                    fill.addLine(to: CGPoint(x: curve[0].x, y: plot.maxY))
                    fill.closeSubpath()
                    trace.curve = path
                    trace.fill = fill
                    trace.start = curve[0].x
                }

                // Peak hold rides on top as a thin contour, from the bands in
                // both modes: they carry a peak at every selection size.
                if showPeak, let band, band.hasData {
                    let peak = curves.bandPoints(band, peak: true, channel: channel.rta)
                    if peak.count > 1 {
                        trace.peak = smoothPath(through: peak, clampedTo: plot)
                        trace.start = min(trace.start, peak[0].x)
                    }
                }
                if trace.curve != nil || trace.peak != nil { traces.append(trace) }
            }

            draw(traces, in: ctx, plot: plot, opacity: opacity, glow: glow)
        }
    }

    /// One channel's finished paths, collected before anything is drawn so that
    /// every channel can share the same offscreen layers.
    private struct Trace {
        let colour: Color
        var curve: Path?
        var fill: Path?
        var peak: Path?
        /// Left end of the data, where the fade begins.
        var start: CGFloat = .infinity
    }

    /// A context in which everything fades in across the first 30 points to
    /// the right of `x0`.
    ///
    /// The spectrum begins at the lowest frequency the transform resolves, and
    /// cutting it off there leaves a hard vertical wall in the middle of the
    /// graph.  A fade is also the honest way to end it: there is no data below
    /// that frequency, and sloping the curve down to the floor instead would
    /// draw a roll-off that was never measured.
    private func fading(_ ctx: GraphicsContext, plot: CGRect, from x0: CGFloat) -> GraphicsContext {
        // Data that starts off the left edge has no wall to hide.
        guard x0 > plot.minX + 1 else { return ctx }
        var faded = ctx
        faded.clipToLayer { layer in
            layer.fill(Path(plot), with: .linearGradient(
                Gradient(stops: [.init(color: .black.opacity(0), location: 0),
                                 .init(color: .black, location: 1)]),
                startPoint: CGPoint(x: x0, y: 0),
                endPoint: CGPoint(x: x0 + 30, y: 0)))
        }
        return faded
    }

    /// Fill, glow, edge and peak contour for every channel.
    ///
    /// Each fade and each blur is a full-plot offscreen layer, and redrawing
    /// one per channel thirty times a second is what made scrolling stutter.
    /// Channels whose data starts at the same place (every band picture does)
    /// share one fade layer, and all their glows share one blur.  Within a
    /// group every fill is drawn before any line, so no channel's fill washes
    /// over another's edge.
    private func draw(_ traces: [Trace], in context: GraphicsContext, plot: CGRect,
                      opacity: Double, glow: Bool) {
        let groups = Dictionary(grouping: traces) { Int($0.start.rounded()) }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let ctx = fading(context, plot: plot, from: group.map(\.start).min()!)

            for trace in group {
                guard let fill = trace.fill else { continue }
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [trace.colour.opacity(0.34 * opacity),
                                      trace.colour.opacity(0.02 * opacity)]),
                    startPoint: CGPoint(x: 0, y: plot.minY),
                    endPoint: CGPoint(x: 0, y: plot.maxY)))
            }

            if glow {
                // The filter applies to the one layer draw, so the blur runs
                // once for the whole group rather than once per stroke.
                var soft = ctx
                soft.addFilter(.blur(radius: 4))
                soft.drawLayer { layer in
                    for trace in group {
                        guard let curve = trace.curve else { continue }
                        layer.stroke(curve, with: .color(trace.colour.opacity(0.35 * opacity)),
                                     lineWidth: 2)
                    }
                }
            }

            for trace in group {
                if let curve = trace.curve {
                    ctx.stroke(curve, with: .color(trace.colour.opacity(0.55 * opacity)),
                               style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
                if let peak = trace.peak {
                    ctx.stroke(peak, with: .color(trace.colour.opacity(0.35 * opacity)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
        }
    }

}

// MARK: - Curve building

/// Turns the analyser's frames into points on a logarithmic frequency axis.
///
/// Shared by the graph overlay and the analyser window's FFT view, so both draw
/// the same picture at the same resolution: the bass bank's bands where the
/// bins are too coarse, the bins above them, one point per pixel column.
struct RtaCurveBuilder {
    let configuration: RtaDisplayConfiguration
    let smoothing: RtaCurveSmoothing
    let minFreq: Double
    let maxFreq: Double
    let plot: CGRect
    let scale: RtaScale
    /// The display frame being drawn, or nil to draw the device's numbers
    /// without interpolation.
    let now: Date?
    let tau: TimeInterval

    func x(_ hz: Double) -> CGFloat {
        guard minFreq > 0, maxFreq > minFreq else { return plot.minX }
        let logMin = log10(minFreq), logMax = log10(maxFreq)
        return plot.minX + CGFloat((log10(max(hz, 1)) - logMin) / (logMax - logMin)) * plot.width
    }

    func y(_ db: Double) -> CGFloat {
        plot.maxY - plot.height * CGFloat(scale.norm(db))
    }

    /// The third-octave picture as points on the plot.  Bands that hold no FFT
    /// bin at the current size are left out rather than drawn at the floor, so
    /// the curve starts where the measurement does instead of climbing out of
    /// the bottom-left corner.
    func bandPoints(_ frame: RtaBandFrame, peak: Bool, channel: Int) -> [CGPoint] {
        let centres = configuration.centres
        guard !centres.isEmpty else { return [] }
        let slots = min(Int(frame.nBands) > 0 ? Int(frame.nBands) : centres.count, RTA_MAX_BANDS)
        let source = peak ? frame.peak : frame.avg
        var levels = [Double](repeating: scale.floorDB, count: slots)
        for i in 0..<slots where i < source.count { levels[i] = configuration.levelDB(source[i]) }

        if let now {
            // A peak cap that eased upward would stop being a peak.
            levels = smoothing.smoother(channel: channel, kind: peak ? 1 : 0)
                .step(now: now, target: levels, identity: channel << 8 | slots,
                      riseTau: peak ? 0 : tau * 0.4, fallTau: tau)
        }

        let visible = smoothing.cache.visibleBands(configuration: configuration, count: slots)
        let positions = smoothing.cache.bandPositions(centres: centres, minFreq: minFreq,
                                                       maxFreq: maxFreq, width: plot.width)

        // One band either side of the visible range is kept, so the curve runs
        // off the plot edges instead of stopping (and fading) just inside them.
        var points: [CGPoint] = []
        points.reserveCapacity(visible.count)
        var below: CGPoint?
        for i in visible where i < centres.count {
            let hz = centres[i]
            let point = CGPoint(x: plot.minX + positions[i], y: y(levels[i]))
            if hz < minFreq { below = point; continue }
            if let b = below { points.append(b); below = nil }
            points.append(point)
            if hz > maxFreq { break }
        }
        return points
    }

    /// One channel's picture from both products: the bands below the top of
    /// the bass bank, where they are continuous and the bins are too coarse
    /// (47 Hz apart at 1024 points) to resolve a third-octave, and the finer
    /// bins above it, crossfaded over one octave so there is no step.
    ///
    /// Returns one point per pixel column.  Where only one product has data
    /// (below the first bin, or before a bin frame arrives) it is used alone.
    func blend(bands: [CGPoint], bins: [CGPoint]) -> [CGPoint] {
        guard bins.count > 1 else { return bands }
        let columns = max(Int(plot.width.rounded()), 2)

        // binPoints supplies a contiguous span of columns. Index it directly
        // instead of allocating and filling a second full-width array per draw.
        let firstBinColumn = Int((bins[0].x - plot.minX).rounded())
        let bandY = columnSamples(of: bands, columns: columns)

        let centres = configuration.centres
        let bass = configuration.bassBands
        var loX = -CGFloat.infinity, hiX = -CGFloat.infinity
        if bass > 0, bass <= centres.count {
            loX = x(centres[bass - 1])
            hiX = x(centres[min(bass + 2, centres.count - 1)])
        }

        var points: [CGPoint] = []
        points.reserveCapacity(columns)
        for c in 0..<columns {
            let x = plot.minX + CGFloat(c)
            let y: CGFloat
            let binIndex = c - firstBinColumn
            let binY: CGFloat? = bins.indices.contains(binIndex) ? bins[binIndex].y : nil
            switch (bandY[c], binY) {
            case let (a?, b?):
                let w = hiX > loX ? min(max((x - loX) / (hiX - loX), 0), 1) : 1
                y = a + (b - a) * w
            case let (a?, nil): y = a
            case let (nil, b?): y = b
            default: continue
            }
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    /// The Catmull-Rom curve through `points` sampled at every pixel column it
    /// spans, so the band picture can be mixed with the per-column bins while
    /// looking the same as the smoothed multichannel curve.
    private func columnSamples(of points: [CGPoint], columns: Int) -> [CGFloat?] {
        smoothing.cache.sampleBands(points, plot: plot, columns: columns)
    }

    /// The bins, averaged over time (see `RtaBinAverage`) and smoothed across
    /// frequency (see `rtaSmoothBins`), as one point per pixel column, taking
    /// the loudest bin that lands in each: above a few hundred hertz several bins share a column,
    /// and a maximum is the only summary that keeps a tone from disappearing
    /// between columns.  Columns between two bins - which is most of them at
    /// the bottom of a log axis - are interpolated rather than carried
    /// forward, so the low end is a slope and not a staircase.
    func binPoints(_ frame: RtaBinFrame, channel: Int) -> [CGPoint] {
        guard frame.bins.count > 1 else { return [] }
        let smoothed = frame.smoothedLevelsDB ?? rtaSmoothBins(
            frame.levelsDB ?? frame.bins.map { configuration.levelDB($0) },
            octaves: rtaBinSmoothingOctaves)
        let projection = smoothing.cache.projectBins(smoothed, geometry: .init(
            count: frame.bins.count, sampleRateHz: frame.sampleRateHz,
            minFreq: minFreq, maxFreq: maxFreq, width: plot.width))
        let firstFilled = projection.firstColumn
        var span = projection.levels
        guard span.count > 1 else { return [] }
        if let now {
            span = smoothing.smoother(channel: channel, kind: 2)
                .step(now: now, target: span, identity: channel << 16 | span.count,
                      riseTau: tau * 0.4, fallTau: tau)
        }

        return span.enumerated().map { offset, db in
            CGPoint(x: plot.minX + CGFloat(firstFilled + offset), y: y(db))
        }
    }
}

// MARK: - Frequency smoothing

/// Width each FFT bin is averaged over.  Bins are evenly spaced, so the treble
/// otherwise shows far finer detail than the third-octave bass bands beside it.
let rtaBinSmoothingOctaves = 1.0 / 6.0

/// Each bin's level averaged in power over `octaves` centred on it.  Where that
/// window is narrower than a bin, as it is across the low end, the bin is left
/// alone.  A pure tone high in the treble is spread over its window and reads low.
func rtaSmoothBins(_ levelsDB: [Double], octaves: Double) -> [Double] {
    let n = levelsDB.count
    guard octaves > 0, n > 2 else { return levelsDB }
    var prefix = [Double](repeating: 0, count: n + 1)
    for k in 0..<n { prefix[k + 1] = prefix[k] + pow(10, levelsDB[k] / 10) }
    // Bin frequency is proportional to its index, so the window is a ratio.
    let half = pow(2, octaves / 2)
    var out = levelsDB
    for k in 1..<n {
        let lo = max(1, Int((Double(k) / half).rounded(.up)))
        let hi = min(n - 1, Int((Double(k) * half).rounded(.down)))
        guard hi > lo else { continue }
        let mean = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        out[k] = 10 * log10(max(mean, 1e-30))
    }
    return out
}

// MARK: - Smoothing state

/// The per-channel filters a curve view needs: an average and a peak contour
/// for the band picture, and one for the bin picture.  Held together so a
/// single `@State` carries the lot across redraws.
final class RtaCurveSmoothing {
    let cache = RtaRenderCache()
    private var filters: [Int: RtaBarSmoother] = [:]

    /// `kind` separates the series a channel can have: 0 average bands,
    /// 1 peak bands, 2 bins.  Each needs its own pole.
    func smoother(channel: Int, kind: Int) -> RtaBarSmoother {
        let key = channel << 4 | kind
        if let existing = filters[key] { return existing }
        let made = RtaBarSmoother()
        filters[key] = made
        return made
    }
}

// MARK: - Curve smoothing

/// Straight segments through the given points, for a series that already has a
/// point per pixel column.
func polyline(through points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    return path
}

/// A Catmull-Rom curve through the given points, converted to cubic Béziers.
///
/// The band picture is only about thirty points wide, so joining them with
/// straight lines reads as a chain of facets next to the response curves beside
/// it.  Control points are clamped into the plot so the curve's overshoot
/// cannot dive below the baseline it will be filled down to.
func smoothPath(through points: [CGPoint], clampedTo rect: CGRect) -> Path {
    var path = Path()
    guard points.count > 1 else { return path }
    func clampY(_ y: CGFloat) -> CGFloat { min(max(y, rect.minY), rect.maxY) }

    path.move(to: points[0])
    for i in 0..<(points.count - 1) {
        let p0 = i > 0 ? points[i - 1] : points[i]
        let p1 = points[i]
        let p2 = points[i + 1]
        let p3 = i + 2 < points.count ? points[i + 2] : p2
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clampY(p1.y + (p2.y - p0.y) / 6))
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clampY(p2.y - (p3.y - p1.y) / 6))
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}
