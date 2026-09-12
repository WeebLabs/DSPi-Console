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
/// One channel selected gets the bands in the bass and the raw FFT bins above
/// it, which is the finer picture; more than one uses the bands throughout,
/// because the device publishes bins for whichever channel it transformed last
/// and a multichannel selection would make them rotate.  The peak-hold contour
/// always comes from the bands, which carry it at every selection size.
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

    /// One filter per channel, carried across redraws.  A reference type in
    /// `@State` so stepping it cannot invalidate the view that stepped it.
    @State private var smoothing = GraphSpectrumSmoothing()

    var body: some View {
        if engine.supported, let plan = plan {
            spectrum(plan)
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

    /// The single analyser configuration that covers what the graph is showing.
    ///
    /// There is one FFT engine and it works at one tap, so a graph showing both
    /// inputs and outputs cannot have both: the selected channel wins, and
    /// failing that the outputs do, which is what the graph is usually being
    /// read for.
    private var plan: Plan? {
        guard vm.isDeviceReady, !visibleEqChannels.isEmpty else { return nil }
        if let active = activeEqChannel, visibleEqChannels.contains(active),
           let ch = channel(forEq: active) {
            return Plan(tap: ch.eq < vm.chOut1 ? RTA_TAP_INPUT : RTA_TAP_OUTPUT,
                        channels: [ch], wantsBins: true)
        }
        let outputs = visibleEqChannels.filter { $0 >= vm.chOut1 }
        let tap: UInt8 = outputs.isEmpty ? RTA_TAP_INPUT : RTA_TAP_OUTPUT
        let eqChannels = outputs.isEmpty ? visibleEqChannels : outputs
        let channels = eqChannels.sorted().compactMap { channel(forEq: $0) }
        guard !channels.isEmpty else { return nil }
        return Plan(tap: tap, channels: channels, wantsBins: channels.count == 1)
    }

    // MARK: Drawing

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    @ViewBuilder
    private func spectrum(_ plan: Plan) -> some View {
        let tau = rtaFallTau(engine, settings.rtaSmoothing)
        if tau > 0 {
            TimelineView(.animation(minimumInterval: rtaFrameInterval)) { timeline in
                canvas(plan, now: timeline.date, tau: tau)
            }
        } else {
            canvas(plan, now: nil, tau: 0)
        }
    }

    private func canvas(_ plan: Plan, now: Date?, tau: TimeInterval) -> some View {
        // Read outside the renderer so a new frame invalidates the view; the
        // closure itself only draws.
        let snapshot = engine.snapshot
        let scale = self.scale
        let showPeak = settings.rtaShowPeakHold
        let glow = settings.showGraphGlow
        let opacity = settings.rtaGraphOpacity

        return Canvas(rendersAsynchronously: false) { ctx, size in
            let plot = CGRect(origin: .zero, size: size)
            guard plot.width > 4, plot.height > 4, snapshot.tap == plan.tap else { return }

            for channel in plan.channels {
                let colour = eqCurveColor(eqCh: channel.eq, chOut1: vm.chOut1)
                let band = snapshot.frames[UInt8(clamping: channel.rta)]

                let bands = (band?.hasData ?? false)
                    ? bandPoints(band!, plot: plot, scale: scale, peak: false,
                                 now: now, tau: tau, channel: channel.rta)
                    : []
                var curve = bands
                var dense = false
                if plan.wantsBins {
                    let bins = snapshot.bins.flatMap { Int($0.channel) == channel.rta ? $0 : nil }
                        .map { binPoints($0, plot: plot, scale: scale,
                                         now: now, tau: tau, channel: channel.rta) } ?? []
                    curve = blend(bands: bands, bins: bins, plot: plot)
                    dense = true
                }
                if curve.count > 1 {
                    // The blended series is already one point per pixel:
                    // smoothing it only adds overshoot around a tone.  The
                    // thirty-odd band points need it, or they read as a chain
                    // of facets beside the response curves.
                    draw(curve, in: ctx, plot: plot, colour: colour,
                         opacity: opacity, glow: glow, smooth: !dense)
                }

                // Peak hold rides on top as a thin contour, from the bands in
                // both modes: they carry a peak at every selection size.
                if showPeak, let band, band.hasData {
                    let peak = bandPoints(band, plot: plot, scale: scale, peak: true,
                                          now: now, tau: tau, channel: channel.rta)
                    if peak.count > 1 {
                        fading(ctx, plot: plot, from: peak[0].x)
                            .stroke(smoothPath(through: peak, clampedTo: plot),
                                    with: .color(colour.opacity(0.35 * opacity)),
                                    style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    }
                }
            }
        }
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

    /// Fill, edge and glow for one channel's spectrum.
    private func draw(_ points: [CGPoint], in context: GraphicsContext, plot: CGRect,
                      colour: Color, opacity: Double, glow: Bool, smooth: Bool) {
        let ctx = fading(context, plot: plot, from: points[0].x)
        let path = smooth ? smoothPath(through: points, clampedTo: plot)
                          : polyline(through: points)
        var fill = path
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: plot.maxY))
        fill.addLine(to: CGPoint(x: points[0].x, y: plot.maxY))
        fill.closeSubpath()

        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [colour.opacity(0.34 * opacity), colour.opacity(0.02 * opacity)]),
            startPoint: CGPoint(x: 0, y: plot.minY),
            endPoint: CGPoint(x: 0, y: plot.maxY)))

        if glow {
            var soft = ctx
            soft.addFilter(.blur(radius: 4))
            soft.stroke(path, with: .color(colour.opacity(0.35 * opacity)), lineWidth: 2)
        }
        ctx.stroke(path, with: .color(colour.opacity(0.55 * opacity)),
                   style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    // MARK: Series

    private func xPos(_ hz: Double, width: CGFloat) -> CGFloat {
        let logMin = log10(Double(minFreq)), logMax = log10(Double(maxFreq))
        guard logMax > logMin else { return 0 }
        return CGFloat((log10(max(hz, 1)) - logMin) / (logMax - logMin)) * width
    }

    private func yPos(_ db: Double, plot: CGRect, scale: RtaScale) -> CGFloat {
        plot.maxY - plot.height * CGFloat(scale.norm(db))
    }

    /// The third-octave picture as points on the plot.  Bands that hold no FFT
    /// bin at the current size are left out rather than drawn at the floor, so
    /// the curve starts where the measurement does instead of climbing out of
    /// the bottom-left corner.
    private func bandPoints(_ frame: RtaBandFrame, plot: CGRect, scale: RtaScale,
                            peak: Bool, now: Date?, tau: TimeInterval,
                            channel: Int) -> [CGPoint] {
        let centres = engine.bandCentresHz
        guard !centres.isEmpty else { return [] }
        let slots = min(Int(frame.nBands) > 0 ? Int(frame.nBands) : centres.count, RTA_MAX_BANDS)
        let source = peak ? frame.peak : frame.avg
        var levels = [Double](repeating: scale.floorDB, count: slots)
        for i in 0..<slots where i < source.count { levels[i] = engine.levelDB(source[i]) }

        if let now {
            // A peak cap that eased upward would stop being a peak.
            levels = smoothing.smoother(channel: channel, kind: peak ? 1 : 0)
                .step(now: now, target: levels, identity: channel << 8 | slots,
                      riseTau: peak ? 0 : tau * 0.4, fallTau: tau)
        }

        let rate = engine.snapshot.status.sampleRateHz > 0
            ? Double(engine.snapshot.status.sampleRateHz) : 48000
        let order = Int(engine.options.fftOrder)
        let first = engine.snapshot.status.firstResolvedBand

        // One band either side of the visible range is kept, so the curve runs
        // off the plot edges instead of stopping (and fading) just inside them.
        var points: [CGPoint] = []
        var below: CGPoint?
        for i in 0..<slots where i >= first && i < centres.count {
            guard rtaBandIsPopulated(band: i, sampleRateHz: rate, fftOrder: order,
                                    bassBands: Int(engine.caps.bassBands)) else { continue }
            let hz = centres[i]
            let point = CGPoint(x: plot.minX + xPos(hz, width: plot.width),
                                y: yPos(levels[i], plot: plot, scale: scale))
            if hz < Double(minFreq) { below = point; continue }
            if let b = below { points.append(b); below = nil }
            points.append(point)
            if hz > Double(maxFreq) { break }
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
    private func blend(bands: [CGPoint], bins: [CGPoint], plot: CGRect) -> [CGPoint] {
        guard bins.count > 1 else { return bands }
        let columns = max(Int(plot.width.rounded()), 2)

        var binY = [CGFloat?](repeating: nil, count: columns)
        for p in bins {
            let c = Int((p.x - plot.minX).rounded())
            if c >= 0, c < columns { binY[c] = p.y }
        }
        let bandY = columnSamples(of: bands, columns: columns, plot: plot)

        let centres = engine.bandCentresHz
        let bass = Int(engine.caps.bassBands)
        var loX = -CGFloat.infinity, hiX = -CGFloat.infinity
        if bass > 0, bass <= centres.count {
            loX = plot.minX + xPos(centres[bass - 1], width: plot.width)
            hiX = plot.minX + xPos(centres[min(bass + 2, centres.count - 1)], width: plot.width)
        }

        var points: [CGPoint] = []
        for c in 0..<columns {
            let x = plot.minX + CGFloat(c)
            let y: CGFloat
            switch (bandY[c], binY[c]) {
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
    private func columnSamples(of points: [CGPoint], columns: Int, plot: CGRect) -> [CGFloat?] {
        var out = [CGFloat?](repeating: nil, count: columns)
        guard points.count > 1 else { return out }
        func slope(_ i: Int) -> CGFloat {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            return b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0
        }
        var seg = 0
        for c in 0..<columns {
            let x = plot.minX + CGFloat(c)
            guard x >= points[0].x, x <= points[points.count - 1].x else { continue }
            while seg < points.count - 2, x > points[seg + 1].x { seg += 1 }
            let p0 = points[seg], p1 = points[seg + 1]
            let h = p1.x - p0.x
            guard h > 0 else { out[c] = p0.y; continue }
            let t = (x - p0.x) / h, t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * p0.y + (t3 - 2 * t2 + t) * h * slope(seg)
                  + (-2 * t3 + 3 * t2) * p1.y + (t3 - t2) * h * slope(seg + 1)
            out[c] = min(max(y, plot.minY), plot.maxY)
        }
        return out
    }

    /// The raw bins as one point per pixel column, taking the loudest bin that
    /// lands in each: above a few hundred hertz several bins share a column,
    /// and a maximum is the only summary that keeps a tone from disappearing
    /// between columns.  Columns between two bins - which is most of them at
    /// the bottom of a log axis - are interpolated rather than carried
    /// forward, so the low end is a slope and not a staircase.
    private func binPoints(_ frame: RtaBinFrame, plot: CGRect, scale: RtaScale,
                           now: Date?, tau: TimeInterval, channel: Int) -> [CGPoint] {
        guard frame.bins.count > 1 else { return [] }
        let columns = max(Int(plot.width.rounded()), 2)
        var level = [Double](repeating: -.infinity, count: columns)
        for k in 1..<frame.bins.count {
            let hz = frame.frequency(ofBin: k)
            guard hz >= Double(minFreq), hz <= Double(maxFreq) else { continue }
            let c = min(max(Int(xPos(hz, width: plot.width).rounded()), 0), columns - 1)
            level[c] = max(level[c], engine.levelDB(frame.bins[k]))
        }

        guard let firstFilled = level.firstIndex(where: { $0.isFinite }),
              let lastFilled = level.lastIndex(where: { $0.isFinite }),
              lastFilled > firstFilled else { return [] }

        var previous = firstFilled
        for c in (firstFilled + 1)...lastFilled where level[c].isFinite {
            let gap = c - previous
            if gap > 1 {
                let a = level[previous], b = level[c]
                for g in 1..<gap {
                    level[previous + g] = a + (b - a) * Double(g) / Double(gap)
                }
            }
            previous = c
        }

        var span = Array(level[firstFilled...lastFilled])
        if let now {
            span = smoothing.smoother(channel: channel, kind: 2)
                .step(now: now, target: span, identity: channel << 16 | span.count,
                      riseTau: tau * 0.4, fallTau: tau)
        }

        return span.enumerated().map { offset, db in
            CGPoint(x: plot.minX + CGFloat(firstFilled + offset),
                    y: yPos(db, plot: plot, scale: scale))
        }
    }
}

// MARK: - Smoothing state

/// The per-channel filters one overlay needs: an average and a peak contour for
/// the band picture, and one for the bin picture.  Held together so a single
/// `@State` carries the lot across redraws.
final class GraphSpectrumSmoothing {
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
