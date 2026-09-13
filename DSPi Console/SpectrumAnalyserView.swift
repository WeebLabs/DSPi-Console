import SwiftUI

// MARK: - Shared scale

/// The vertical scale every analyser view shares: dBFS at the top, the floor at
/// the bottom, and a normalised 0...1 for drawing in between.
struct RtaScale: Equatable {
    var floorDB: Double
    var ceilingDB: Double

    func norm(_ db: Double) -> Double {
        guard ceilingDB > floorDB else { return 0 }
        return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
    }
}

/// Frequencies worth labelling on a third-octave axis: the 1-2-5 sequence, so
/// the labels stay readable at the widths these views actually get.
private let rtaLabelledCentres: [Double] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

private func rtaShortHz(_ hz: Double) -> String {
    hz >= 1000 ? "\(Int((hz / 1000).rounded()))k" : "\(Int(hz.rounded()))"
}

// MARK: - Subscription

private struct RtaRenderingActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var rtaRenderingActive: Bool {
        get { self[RtaRenderingActiveKey.self] }
        set { self[RtaRenderingActiveKey.self] = newValue }
    }
}

/// Watches the analyser for as long as the view is on screen.
///
/// The device has one FFT engine, so a view cannot simply ask for a picture -
/// it registers what it wants and the engine reconciles every request into a
/// single configuration.  Dropping the last subscription stops the analyser on
/// the device, which is what keeps it free when nobody is looking at it.
private struct RtaWatch: ViewModifier {
    let engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    let request: RtaRequest
    let active: Bool
    @State private var token: UUID? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.rtaRenderingActive, active)
            .onAppear {
                updateSubscription()
            }
            .onDisappear {
                if let t = token { engine.release(t); token = nil }
            }
            .onChange(of: active) { _ in updateSubscription() }
            .onChange(of: request) { newValue in
                if let t = token { engine.update(t, to: newValue) }
            }
    }
    private func updateSubscription() {
        if active {
            // Also refresh options when a retained, hidden window resumes.
            engine.setOptions(settings.rtaOptions)
            if token == nil { token = engine.subscribe(request) }
        } else if let t = token {
            engine.release(t)
            token = nil
        }
    }
}

extension View {
    /// Subscribe to the analyser while this view is visible.
    func rtaWatching(_ engine: RtaEngine, _ request: RtaRequest, active: Bool = true) -> some View {
        modifier(RtaWatch(engine: engine, request: request, active: active))
    }
}

// MARK: - Frame-rate interpolation

/// Glides the analyser displays between device frames.
///
/// The peak meters get this for free: they are SwiftUI shapes, so a
/// `.animation(.linear)` on the level carries them between polls.  A `Canvas`
/// has no implicit animation to attach to, and the analyser steps harder than
/// the meters do anyway - the device refreshes one channel every rotation
/// interval, which runs from a few milliseconds with one channel at 256 points
/// to a couple of hundred with nine at 1024.  Without interpolation most polls
/// redraw the identical picture and then it jumps.
///
/// One pole per band, stepped by real elapsed time so a dropped display frame
/// catches up instead of lagging.  The fall is slower than the rise, because a
/// spectrum that blunts its transients is harder to read than one that lingers
/// a moment on the way down.  The time constant comes from the device's own
/// refresh interval, so it follows the transform size and the channel count
/// rather than assuming either.
final class RtaBarSmoother {
    private var values: [Double] = []
    private var lastTime: Date? = nil
    private var identity: Int = .min

    /// Step toward `target` and return the smoothed values.
    ///
    /// `identity` is anything that means "these are different numbers now" -
    /// the channel and the band count - so switching channel snaps to the new
    /// picture rather than sliding across from the old one, which would read
    /// as the new channel briefly showing the old one's level.
    ///
    /// A `riseTau` or `fallTau` of zero moves instantly in that direction,
    /// which is what a peak-hold cap wants on the way up.
    func step(now: Date, target: [Double], identity: Int,
              riseTau: TimeInterval, fallTau: TimeInterval) -> [Double] {
        if identity != self.identity || values.count != target.count {
            self.identity = identity
            values = target
            lastTime = now
            return values
        }
        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        lastTime = now
        guard dt > 0 else { return values }
        let riseK = riseTau > 0 ? 1 - exp(-dt / riseTau) : 1
        let fallK = fallTau > 0 ? 1 - exp(-dt / fallTau) : 1
        for i in values.indices {
            let t = target[i]
            values[i] += (t - values[i]) * (t > values[i] ? riseK : fallK)
        }
        return values
    }
}

/// The two filters one bars view needs, held together so a single `@State`
/// carries both across redraws.
final class RtaSmoothingState {
    let cache = RtaRenderCache()
    let bars = RtaBarSmoother()
    let caps = RtaBarSmoother()
}

/// Interpolate at 60 fps independently of the device frame/poll cadence.
let rtaFrameInterval: TimeInterval = 1.0 / 60.0

/// Turns the smoothing preference into a fall time constant for a given
/// rotation interval.  Zero means the preference is off and the views draw the
/// device's numbers directly.
///
/// Roughly one rotation interval to travel most of the way, so a bar is still
/// moving when the next frame for that channel lands.  Clamped at both ends: a
/// single channel at 96 kHz would otherwise be back to a step, and nine
/// channels at 1024 points would turn to syrup.
func rtaFallTau(refreshInterval: TimeInterval, amount: Double) -> TimeInterval {
    guard amount > 0 else { return 0 }
    return min(0.40, max(0.035, refreshInterval * amount))
}

func rtaFallTau(_ engine: RtaEngine, _ amount: Double) -> TimeInterval {
    rtaFallTau(refreshInterval: engine.channelRefreshInterval, amount: amount)
}

/// Whether an FFT of `fftOrder` points at `sampleRateHz` has any bin inside the
/// third-octave band centred on `centreHz`.
///
/// Band edges come from the nominal centre (centre / 2^(1/6) to centre x
/// 2^(1/6)) rather than from the device's own table, so this is a display
/// heuristic: callers apply it only to a band already reading the floor, where
/// it can explain an empty band but never hide a live one.
func rtaBandHasBin(centreHz: Double, sampleRateHz: Double, fftOrder: Int) -> Bool {
    guard centreHz > 0, sampleRateHz > 0, fftOrder > 0 else { return true }
    let edge = pow(2.0, 1.0 / 6.0)
    let lo = centreHz / edge, hi = centreHz * edge
    let binHz = sampleRateHz / Double(1 << fftOrder)
    guard binHz > 0 else { return true }
    // DC belongs to no band, so the search starts at bin 1.
    let firstBin = max(1.0, (lo / binHz).rounded(.up))
    return firstBin * binHz <= hi
}

/// Bass bands are continuously populated. Higher bands follow the firmware's
/// exact FFT geometry: base-10 centre 1000 * 10^((i - 20) / 10), edges at
/// 10^(+/-0.05), DC and Nyquist excluded.
func rtaBandIsPopulated(band i: Int, sampleRateHz: Double, fftOrder: Int,
                        bassBands: Int = RTA_BASS_BANDS) -> Bool {
    if i >= 0 && i < bassBands { return true }
    guard i >= 0, sampleRateHz > 0, fftOrder > 0 else { return true }
    let fc = 1000.0 * pow(10.0, Double(i - 20) / 10.0)
    let lo = fc * pow(10.0, -0.05), hi = fc * pow(10.0, 0.05)
    let n = Double(1 << fftOrder)
    let binHz = sampleRateHz / n
    let firstBin = max(1.0, (lo / binHz).rounded(.up))
    let lastBin = min(n / 2 - 1, (hi / binHz).rounded(.down))
    return firstBin <= lastBin
}

// MARK: - Third-octave bars

/// One channel's third-octave picture.
///
/// Bands are equally spaced on a logarithmic frequency axis by construction, so
/// they are drawn as equal-width bars; the axis labels come from the device's
/// own band-centre table rather than a table of our own, so the picture and the
/// labels can never disagree about where a band sits.
struct RtaBandsView: View, Equatable {
    @Environment(\.rtaRenderingActive) private var renderingActive
    let configuration: RtaDisplayConfiguration
    let fallTau: TimeInterval
    let frame: RtaBandFrame?
    let color: Color
    let scale: RtaScale
    var showPeakHold: Bool = true
    /// Axis labels and the dB grid: on in the full-size views, off where the
    /// bars are too small for them to be readable.
    var showLabels: Bool = false

    private var bandCount: Int {
        let n = Int(frame?.nBands ?? 0)
        return n > 0 ? min(n, RTA_MAX_BANDS) : max(configuration.centres.count, 34)
    }

    private var visibleBands: [Int] {
        smoothing.cache.visibleBands(configuration: configuration, count: bandCount)
    }

    init(engine: RtaEngine, frame: RtaBandFrame?, color: Color, scale: RtaScale,
         showPeakHold: Bool = true, showLabels: Bool = false) {
        configuration = RtaDisplayConfiguration(engine: engine)
        fallTau = rtaFallTau(engine, AppSettings.shared.rtaSmoothing)
        self.frame = frame?.displayFrame
        self.color = color
        self.scale = scale
        self.showPeakHold = showPeakHold
        self.showLabels = showLabels
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.fallTau == rhs.fallTau
            && lhs.frame == rhs.frame && lhs.color == rhs.color && lhs.scale == rhs.scale
            && lhs.showPeakHold == rhs.showPeakHold && lhs.showLabels == rhs.showLabels
    }

    /// One pole per band, carried across redraws.  A reference type in
    /// `@State`, so SwiftUI keeps it for the life of this view without
    /// observing it: stepping the filter must not invalidate the view that
    /// stepped it, or the two would chase each other every frame.
    @State private var smoothing = RtaSmoothingState()

    /// Levels in dBFS, one per band slot, with no frame reading as silence so
    /// the bars rise into view rather than appearing at full height.
    private func targets() -> (avg: [Double], peak: [Double]) {
        let n = bandCount
        guard let frame else {
            return (Array(repeating: scale.floorDB, count: n),
                    Array(repeating: scale.floorDB, count: n))
        }
        var avg = [Double](repeating: scale.floorDB, count: n)
        var peak = avg
        for i in 0..<n {
            if i < frame.avg.count { avg[i] = configuration.levelDB(frame.avg[i]) }
            if i < frame.peak.count { peak[i] = configuration.levelDB(frame.peak[i]) }
        }
        return (avg, peak)
    }

    /// Distinguishes one channel's numbers from another's, so a channel change
    /// snaps instead of sliding over from the channel before it.
    private var seriesIdentity: Int { Int(frame?.channel ?? 0xFF) << 8 | visibleBands.count }

    var body: some View {
        let target = targets()
        ZStack {
            if showLabels {
                RtaBandGrid(scale: scale, centres: configuration.centres, visible: visibleBands).equatable()
            }
            if fallTau > 0 {
                TimelineView(.animation(minimumInterval: rtaFrameInterval, paused: !renderingActive)) { timeline in
                    canvas(now: timeline.date, target: target)
                }
            } else {
                canvas(now: nil, target: target)
            }
        }
    }

    private func canvas(now: Date?, target t: (avg: [Double], peak: [Double])) -> some View {
        let identity = seriesIdentity
        let tau = fallTau
        // Allow asynchronous presentation; data preparation is cached separately.
        return Canvas(rendersAsynchronously: true) { ctx, size in
            let labelHeight: CGFloat = showLabels ? 12 : 0
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - labelHeight))
            guard plot.height > 2, bandCount > 0 else { return }

            // Stepped here rather than in `body`: the renderer runs once per
            // drawn frame, which is exactly the cadence the filter wants, and
            // it cannot trigger another view update.
            let avg: [Double]
            let peak: [Double]
            if let now {
                avg = smoothing.bars.step(now: now, target: t.avg, identity: identity,
                                          riseTau: tau * 0.4, fallTau: tau)
                // A peak cap that eased upward would stop being a peak; only
                // its fall is interpolated, and the device is already decaying
                // it at the rate the user chose.
                peak = smoothing.caps.step(now: now, target: t.peak, identity: identity,
                                           riseTau: 0, fallTau: tau)
            } else {
                avg = t.avg
                peak = t.peak
            }

            let visible = visibleBands
            guard !visible.isEmpty else { return }
            let slot = plot.width / CGFloat(visible.count)
            let gap = min(2.0, max(0.5, slot * 0.18))
            let barWidth = max(1, slot - gap)

            for (pos, i) in visible.enumerated() {
                let x = plot.minX + CGFloat(pos) * slot + gap / 2
                guard i < avg.count else { continue }

                let level = scale.norm(avg[i])
                if level > 0.001 {
                    let h = plot.height * CGFloat(level)
                    let bar = CGRect(x: x, y: plot.maxY - h, width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: min(1.5, barWidth / 3)),
                             with: .linearGradient(
                                Gradient(colors: [color.opacity(0.95), color.opacity(0.45)]),
                                startPoint: CGPoint(x: 0, y: bar.minY),
                                endPoint: CGPoint(x: 0, y: plot.maxY)))
                }

                if showPeakHold, i < peak.count {
                    let p = scale.norm(peak[i])
                    if p > 0.001 {
                        let y = plot.maxY - plot.height * CGFloat(p)
                        let cap = CGRect(x: x, y: max(plot.minY, y - 1), width: barWidth, height: 1.5)
                        ctx.fill(Path(cap), with: .color(color.opacity(0.9)))
                    }
                }
            }

        }
    }

}

private struct RtaBandGrid: View, Equatable {
    let scale: RtaScale
    let centres: [Double]
    let visible: [Int]

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 12))
            guard plot.height > 2, !visible.isEmpty else { return }
            drawGrid(ctx, plot)
            drawFrequencyLabels(ctx, plot, bands: visible, slot: plot.width / CGFloat(visible.count),
                                labelY: size.height - 11)
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ plot: CGRect) {
        // A line every 12 dB: close enough to read a level off, sparse enough
        // that the bars stay the loudest thing in the picture.
        var db = (scale.ceilingDB / 12).rounded(.down) * 12
        while db > scale.floorDB {
            let y = plot.maxY - plot.height * CGFloat(scale.norm(db))
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.35 : 0.12)),
                       lineWidth: db == 0 ? 1 : 0.5)
            ctx.draw(Text("\(Int(db))").font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6)),
                     at: CGPoint(x: plot.maxX - 2, y: y - 6), anchor: .topTrailing)
            db -= 12
        }
    }

    private func drawFrequencyLabels(_ ctx: GraphicsContext, _ plot: CGRect,
                                     bands: [Int], slot: CGFloat, labelY: CGFloat) {
        guard !centres.isEmpty else { return }
        for (pos, i) in bands.enumerated() where i < centres.count {
            let hz = centres[i]
            // The table carries nominal centres rounded to whole hertz, so 31.5
            // arrives as 31 or 32; match on proportion rather than equality.
            guard rtaLabelledCentres.contains(where: { abs(hz - $0) < $0 * 0.03 }) else { continue }
            let x = plot.minX + (CGFloat(pos) + 0.5) * slot
            ctx.draw(Text(rtaShortHz(hz)).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: x, y: labelY), anchor: .top)
        }
    }
}

// MARK: - Raw FFT bins

/// The most recent frame's raw magnitude bins on a logarithmic frequency axis.
///
/// The frame belongs to whichever channel was transformed last, so the views
/// that show it ask for a single channel; bin k is centred at
/// k * sample rate / N, which is 47 Hz apart at 1024 points and 48 kHz.
struct RtaBinsView: View, Equatable {
    @Environment(\.rtaRenderingActive) private var renderingActive
    let configuration: RtaDisplayConfiguration
    let fallTau: TimeInterval
    let binFrame: RtaBinFrame?
    /// The same channel's band frame.  Its bass bands carry the picture below
    /// the bins' reach, exactly as the graph overlay does.
    let bandFrame: RtaBandFrame?
    /// The channel being drawn; a bin frame from any other channel is ignored.
    let channel: Int
    let color: Color
    let scale: RtaScale
    var showPeakHold: Bool = true
    var showLabels: Bool = true

    /// The lowest band the device reports, which the bass bank measures
    /// continuously, so the axis starts where the measurement does.
    private var minHz: Double { max(configuration.centres.first ?? 10, 1) }

    private var maxHz: Double {
        if let f = binFrame, f.sampleRateHz > 0 { return Double(f.sampleRateHz) / 2 }
        let rate = configuration.sampleRateHz
        return rate > 0 ? Double(rate) / 2 : 20000
    }

    /// Band, peak and bin filters for the one channel; see `RtaBarSmoother`.
    @State private var smoothing = RtaCurveSmoothing()

    init(engine: RtaEngine, binFrame: RtaBinFrame?, bandFrame: RtaBandFrame?,
         channel: Int, color: Color, scale: RtaScale,
         showPeakHold: Bool = true, showLabels: Bool = true) {
        configuration = RtaDisplayConfiguration(engine: engine)
        fallTau = rtaFallTau(engine, AppSettings.shared.rtaSmoothing)
        self.binFrame = binFrame?.displayFrame
        self.bandFrame = bandFrame?.displayFrame
        self.channel = channel
        self.color = color
        self.scale = scale
        self.showPeakHold = showPeakHold
        self.showLabels = showLabels
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.fallTau == rhs.fallTau
            && lhs.binFrame == rhs.binFrame && lhs.bandFrame == rhs.bandFrame
            && lhs.channel == rhs.channel && lhs.color == rhs.color && lhs.scale == rhs.scale
            && lhs.showPeakHold == rhs.showPeakHold && lhs.showLabels == rhs.showLabels
    }

    var body: some View {
        ZStack {
            RtaBinGrid(scale: scale, minHz: minHz, maxHz: maxHz, showLabels: showLabels).equatable()
            if fallTau > 0 {
                TimelineView(.animation(minimumInterval: rtaFrameInterval, paused: !renderingActive)) { timeline in
                    canvas(now: timeline.date)
                }
            } else {
                canvas(now: nil)
            }
        }
    }

    private func canvas(now: Date?) -> some View {
        let tau = fallTau
        // Allow asynchronous presentation; data preparation is cached separately.
        return Canvas(rendersAsynchronously: true) { ctx, size in
            let labelHeight: CGFloat = showLabels ? 12 : 0
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - labelHeight))
            guard plot.width > 4, plot.height > 4 else { return }

            guard maxHz > minHz else { return }

            // The same picture the graph overlay draws for one channel: bass
            // bands crossfading into bins, one point per pixel column.
            let curves = RtaCurveBuilder(configuration: configuration, smoothing: smoothing,
                                         minFreq: minHz, maxFreq: maxHz,
                                         plot: plot, scale: scale, now: now, tau: tau)
            let bands = bandFrame.flatMap { $0.hasData ? curves.bandPoints($0, peak: false, channel: channel) : nil } ?? []
            let bins = binFrame.flatMap { Int($0.channel) == channel ? curves.binPoints($0, channel: channel) : nil } ?? []
            let curve = curves.blend(bands: bands, bins: bins)

            if curve.count > 1 {
                // Until a bin frame arrives the curve is the thirty-odd bands,
                // which need smoothing; the blended series is already dense.
                let path = bins.count > 1 ? polyline(through: curve)
                                          : smoothPath(through: curve, clampedTo: plot)
                var fill = path
                fill.addLine(to: CGPoint(x: curve[curve.count - 1].x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: curve[0].x, y: plot.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.45), color.opacity(0.04)]),
                    startPoint: CGPoint(x: 0, y: plot.minY),
                    endPoint: CGPoint(x: 0, y: plot.maxY)))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }

            if showPeakHold, let bandFrame, bandFrame.hasData {
                let peak = curves.bandPoints(bandFrame, peak: true, channel: channel)
                if peak.count > 1 {
                    ctx.stroke(smoothPath(through: peak, clampedTo: plot),
                               with: .color(color.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
        }

    }

}

private struct RtaBinGrid: View, Equatable {
    let scale: RtaScale
    let minHz: Double
    let maxHz: Double
    let showLabels: Bool

    var body: some View {
        Canvas { ctx, size in
            let labelHeight: CGFloat = showLabels ? 12 : 0
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - labelHeight))
            guard plot.width > 4, plot.height > 4 else { return }
            drawGrid(ctx, plot, labelY: size.height - labelHeight + 1)
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ plot: CGRect, labelY: CGFloat) {
        var db = (scale.ceilingDB / 12).rounded(.down) * 12
        while db > scale.floorDB {
            let y = plot.maxY - plot.height * CGFloat(scale.norm(db))
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.35 : 0.12)),
                       lineWidth: db == 0 ? 1 : 0.5)
            if showLabels {
                ctx.draw(Text("\(Int(db))").font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6)),
                         at: CGPoint(x: plot.maxX - 2, y: y - 6), anchor: .topTrailing)
            }
            db -= 12
        }

        guard maxHz > minHz else { return }
        let logMin = log10(minHz), logMax = log10(maxHz)
        for hz in rtaLabelledCentres where hz >= minHz && hz <= maxHz {
            let px = plot.minX + CGFloat((log10(hz) - logMin) / (logMax - logMin)) * plot.width
            var line = Path()
            line.move(to: CGPoint(x: px, y: plot.minY))
            line.addLine(to: CGPoint(x: px, y: plot.maxY))
            ctx.stroke(line, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
            if showLabels {
                ctx.draw(Text(rtaShortHz(hz)).font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: px, y: labelY), anchor: .top)
            }
        }
    }
}

/// Explains the shaded slots wherever bars are drawn.  They are not silence:
/// a third-octave band down there is narrower than one FFT bin, so nothing
/// lands in it and it can only read the floor.
let rtaShadedBandHelp = """
Bass bands from 10–200 Hz are measured continuously. Shaded higher bands hold no \
FFT bin at the current transform size. Raise the transform size to fill more \
of them in.
"""

// MARK: - Reading helpers

extension RtaEngine {
    /// The latest frame for `channel`, but only when the snapshot was taken at
    /// the tap the caller is asking about.  There is one engine on the device,
    /// so a view on the other side of the matrix must draw nothing rather than
    /// draw somebody else's channel.
    func frame(channel: Int, tap: UInt8) -> RtaBandFrame? {
        guard snapshot.tap == tap else { return nil }
        return snapshot.frames[UInt8(clamping: channel)]
    }

    /// Human-readable rotation interval: how often one channel refreshes, which
    /// is the fill time times the number of live channels.
    var refreshDescription: String {
        let s = snapshot.status
        guard s.isRunning, s.liveCount > 0 else { return "idle" }
        let ms = Int((channelRefreshInterval * 1000).rounded())
        let channels = s.liveCount == 1 ? "1 channel" : "\(s.liveCount) channels"
        return "\(channels), each refreshed every \(ms) ms"
    }

    /// Whether this RTA band is measured by the continuous bank or FFT.
    /// Kept separate from raw-bin geometry so quiet bass remains measurable.
    func transformHasBin(inBand i: Int) -> Bool {
        guard i >= 0, i < bandCentresHz.count else { return true }
        let rate = snapshot.status.sampleRateHz > 0 ? Double(snapshot.status.sampleRateHz) : 48000
        return rtaBandIsPopulated(band: i, sampleRateHz: rate,
                                  fftOrder: Int(options.fftOrder), bassBands: Int(caps.bassBands))
    }

    /// The centre of the lowest band this configuration can measure at all, for
    /// the note that tells the user what a larger transform would buy.
    var lowestMeasurableCentreHz: Double? {
        let first = snapshot.status.firstResolvedBand
        guard first > 0, first < bandCentresHz.count else { return nil }
        return bandCentresHz[first]
    }

    /// How long one channel waits between frames: the time its capture buffer
    /// takes to fill, times the number of channels sharing the rotation.  This
    /// is the interval the displays interpolate across, so their smoothing
    /// tracks the size and the selection rather than being a fixed guess.
    var channelRefreshInterval: TimeInterval {
        let s = snapshot.status
        if s.framesPerSecond > 0 {
            return Double(max(Int(s.liveCount), 1)) / Double(s.framesPerSecond)
        }
        let rate = s.sampleRateHz > 0 ? Double(s.sampleRateHz) : 48000
        let points = Double(1 << Int(options.fftOrder))
        return points / rate * Double(max(Int(s.liveCount), 1))
    }
}

// MARK: - Inline strips

/// The one channel the dashboard's spectrum shows, picked with "Dashboard FFT"
/// in the sidebar's context menu.  Held as a tap and an index rather than an
/// EQ channel, because the EQ numbering of outputs moves with the input count.
enum RtaDashboardSource: Equatable {
    case input(Int)
    case output(Int)

    var storageKey: String {
        switch self {
        case .input(let n):  return "in:\(n)"
        case .output(let n): return "out:\(n)"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), n >= 0 else { return nil }
        switch parts[0] {
        case "in":  self = .input(n)
        case "out": self = .output(n)
        default:    return nil
        }
    }

    var tap: UInt8 {
        switch self {
        case .input:  return RTA_TAP_INPUT
        case .output: return RTA_TAP_OUTPUT
        }
    }

    /// The analyser's channel at `tap`: the input row, or the matrix output.
    var index: Int {
        switch self {
        case .input(let n), .output(let n): return n
        }
    }
}

extension DSPViewModel {
    /// The dashboard's spectrum channel: the stored choice while it is live on
    /// this device, otherwise the first enabled output, otherwise input 1.
    var dashboardRtaSource: RtaDashboardSource {
        if let stored = RtaDashboardSource(storageKey: AppSettings.shared.rtaDashboardSourceKey),
           isLiveRtaSource(stored) {
            return stored
        }
        if let first = (0..<numOutputChannels).first(where: { $0 < outputEnabled.count && outputEnabled[$0] }) {
            return .output(first)
        }
        return .input(0)
    }

    func setDashboardRtaSource(_ source: RtaDashboardSource) {
        AppSettings.shared.rtaDashboardSourceKey = source.storageKey
    }

    private func isLiveRtaSource(_ source: RtaDashboardSource) -> Bool {
        switch source {
        case .input(let n):  return n < numMatrixInputs
        case .output(let n): return n < numOutputChannels && n < outputEnabled.count && outputEnabled[n]
        }
    }

    func eqChannel(for source: RtaDashboardSource) -> Int {
        switch source {
        case .input(let n):  return n
        case .output(let n): return eqChannel(forOutput: n)
        }
    }
}

/// The strip a channel page carries above its filter table: the one channel
/// being edited, at the tap it lives on.
struct ChannelSpectrumStrip: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var analyserController: SpectrumAnalyserWindowController
    let title: String
    let channel: Int
    let tap: UInt8
    let color: Color

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    var body: some View {
        if engine.supported {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text("SPECTRUM - \(title.uppercased())")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let f = engine.frame(channel: channel, tap: tap), !f.hasData {
                        Text("waiting for audio")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Button {
                        analyserController.show(vm: vm)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Open the Spectrum Analyser window")
                }
                RtaBandsView(engine: engine,
                             frame: engine.frame(channel: channel, tap: tap),
                             color: color,
                             scale: scale,
                             showPeakHold: settings.rtaShowPeakHold,
                             showLabels: true).equatable()
                    .frame(height: 96)
                    .help(rtaShadedBandHelp)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: 1))
            .rtaWatching(engine, RtaRequest(tap: tap, mask: UInt16(1) << UInt16(channel)))
        }
    }
}

// MARK: - Window controller

class SpectrumAnalyserWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false
    @Published private(set) var isRendering: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = SpectrumAnalyserView(vm: vm, engine: vm.rta)
                .environmentObject(self)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Spectrum Analyser"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 620, height: 420)
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
        updateRenderingVisibility()
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
        updateRenderingVisibility()
    }

    func toggle(vm: DSPViewModel) {
        isVisible ? hide() : show(vm: vm)
    }
}

extension SpectrumAnalyserWindowController: NSWindowDelegate {
    private func updateRenderingVisibility() {
        let active = isVisible && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        if isRendering != active { isRendering = active }
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        updateRenderingVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateRenderingVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateRenderingVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateRenderingVisibility() }
}

// MARK: - Analyser window

/// The full-size analyser: the same engine as the inline strips, with the
/// channel selection, the two products (third-octave bands and raw bins) and
/// every option the device owns exposed in one place.
struct SpectrumAnalyserView: View {
    @EnvironmentObject private var windowController: SpectrumAnalyserWindowController
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared

    enum Mode: String, CaseIterable, Identifiable {
        case bands = "RTA"
        case bins = "FFT"
        var id: Self { self }
    }

    @State private var mode: Mode = .bands
    @State private var tap: UInt8 = RTA_TAP_OUTPUT
    @State private var selected: Set<Int> = []
    @State private var binChannel: Int = 0

    // MARK: Channel model at the current tap

    /// Channels the analyser can be pointed at, in wire order.  The input tap
    /// counts live input rows, the output tap counts enabled outputs: the
    /// device drops anything that is not live from the rotation anyway, so
    /// offering a dead channel would only ever produce an empty graph.
    private var channels: [Int] {
        tap == RTA_TAP_INPUT
            ? Array(0..<vm.numMatrixInputs)
            : (0..<vm.numOutputChannels).filter { vm.outputEnabled[$0] }
    }

    private func channelName(_ ch: Int) -> String {
        let eqCh = tap == RTA_TAP_INPUT ? ch : vm.eqChannel(forOutput: ch)
        guard eqCh < vm.channelNames.count else { return "Ch \(ch + 1)" }
        return vm.channelNames[eqCh]
    }

    private func channelColor(_ ch: Int) -> Color {
        if tap == RTA_TAP_INPUT { return ChannelPalette.input(ch) }
        return ch == vm.pdmOutputIndex ? ChannelPalette.pdm : ChannelPalette.output(ch)
    }

    private var effectiveSelection: [Int] {
        let live = channels
        let picked = live.filter { selected.contains($0) }
        return picked.isEmpty ? live : picked
    }

    private var request: RtaRequest {
        if mode == .bins {
            let ch = channels.contains(binChannel) ? binChannel : (channels.first ?? 0)
            return RtaRequest(tap: tap, mask: UInt16(1) << UInt16(ch), wantsBins: true)
        }
        let mask = effectiveSelection.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1)) }
        return RtaRequest(tap: tap, mask: mask)
    }

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    /// Transform sizes this device offers.  Built as a range rather than taken
    /// from the caps directly so a device reporting a nonsensical pair cannot
    /// crash the picker.
    private var availableOrders: [Int] {
        let lo = Int(engine.caps.fftOrderMin), hi = Int(engine.caps.fftOrderMax)
        guard hi >= lo else { return [Int(engine.caps.fftOrderDefault)] }
        return Array(lo...hi)
    }

    /// The offered size nearest the stored preference, so a preference left
    /// behind by a device with a larger ceiling still selects something.
    private var selectedOrder: Int {
        guard let lo = availableOrders.first, let hi = availableOrders.last else { return settings.rtaFftOrder }
        return min(max(settings.rtaFftOrder, lo), hi)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !engine.supported {
                unsupportedNotice
            } else {
                controlBar
                Divider()
                display
                Divider()
                optionsBar
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .rtaWatching(engine, request, active: windowController.isRendering)
        .onAppear {
            // Everything at this tap by default: watching them all costs the
            // device no more than watching one.
            if selected.isEmpty { selected = Set(channels) }
            if !channels.contains(binChannel) { binChannel = channels.first ?? 0 }
        }
        .onChange(of: tap) { _ in
            selected = Set(channels)
            binChannel = channels.first ?? 0
        }
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Spectrum analyser unavailable")
                .font(.headline)
            Text(vm.isDeviceConnected
                 ? "The connected firmware does not provide a compatible analyser. Update the firmware to use it."
                 : "Connect a DSPi to use the analyser.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Third-octave bands, or one channel's FFT bins with the continuous bass bands beneath them")

            Picker("", selection: $tap) {
                Text("Inputs").tag(RTA_TAP_INPUT)
                Text("Outputs").tag(RTA_TAP_OUTPUT)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Inputs are tapped after the per-input EQ; outputs after gain and delay, which is exactly what the slot transmits")

            Divider().frame(height: 18)

            if mode == .bins {
                Picker("", selection: $binChannel) {
                    ForEach(channels, id: \.self) { ch in Text(channelName(ch)).tag(ch) }
                }
                .labelsHidden()
                .frame(width: 160)
            } else {
                channelChips
            }

            Spacer()

            Button("Reset Averaging") { engine.resetAveraging() }
                .controlSize(.small)
                .help("Clear the running average and the peak hold without disturbing the frame in flight")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var channelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(channels, id: \.self) { ch in
                    let on = selected.contains(ch)
                    Button {
                        if on { selected.remove(ch) } else { selected.insert(ch) }
                    } label: {
                        Text(channelName(ch))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(on ? channelColor(ch).opacity(0.28) : Color.secondary.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(on ? channelColor(ch).opacity(0.8) : Color.clear, lineWidth: 1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Display

    @ViewBuilder
    private var display: some View {
        ZStack {
            Color.black.opacity(0.20)
            if mode == .bins {
                // The channel the request asked for, not whichever channel the
                // last bin frame happens to name, so a stale frame is never
                // drawn in the new channel's colour.
                let ch = channels.contains(binChannel) ? binChannel : (channels.first ?? 0)
                RtaBinsView(engine: engine,
                            binFrame: engine.snapshot.tap == tap ? engine.snapshot.bins : nil,
                            bandFrame: engine.frame(channel: ch, tap: tap),
                            channel: ch,
                            color: channelColor(ch),
                            scale: scale,
                            showPeakHold: settings.rtaShowPeakHold).equatable()
                    .padding(10)
            } else {
                VStack(spacing: 6) {
                    ForEach(effectiveSelection, id: \.self) { ch in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle().fill(channelColor(ch)).frame(width: 5, height: 5)
                                Text(channelName(ch))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            RtaBandsView(engine: engine,
                                         frame: engine.frame(channel: ch, tap: tap),
                                         color: channelColor(ch),
                                         scale: scale,
                                         showPeakHold: settings.rtaShowPeakHold,
                                         showLabels: effectiveSelection.count <= 2).equatable()
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Options

    private var optionsBar: some View {
        HStack(alignment: .center, spacing: 16) {
            labelled("Size") {
                Picker("", selection: Binding(
                    get: { selectedOrder },
                    set: { settings.rtaFftOrder = $0; pushOptions() }
                )) {
                    ForEach(availableOrders, id: \.self) { o in
                        Text("\(1 << o)").tag(o)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
            }
            .help("Points in the FFT. More points improve FFT resolution but refresh less often. The RTA bass bands from 10–200 Hz are measured continuously at every size.")

            labelled("Averaging") {
                Picker("", selection: Binding(
                    get: { settings.rtaAvgMs },
                    set: { settings.rtaAvgMs = $0; pushOptions() }
                )) {
                    Text("Off").tag(0)
                    Text("50 ms").tag(50)
                    Text("125 ms").tag(125)
                    Text("300 ms").tag(300)
                    Text("1 s").tag(1000)
                    Text("3 s").tag(3000)
                }
                .labelsHidden()
                .frame(width: 90)
            }

            labelled("Peak hold") {
                Picker("", selection: Binding(
                    get: { settings.rtaPeakDecayDBs },
                    set: { settings.rtaPeakDecayDBs = $0; pushOptions() }
                )) {
                    Text("Off").tag(0)
                    Text("Slow").tag(4)
                    Text("Medium").tag(12)
                    Text("Fast").tag(30)
                }
                .labelsHidden()
                .frame(width: 90)
            }
            .disabled(!settings.rtaShowPeakHold)

            labelled("Floor") {
                Picker("", selection: $settings.rtaFloorDB) {
                    Text("-60 dB").tag(-60.0)
                    Text("-90 dB").tag(-90.0)
                    Text("-120 dB").tag(-120.0)
                }
                .labelsHidden()
                .frame(width: 90)
            }

            Toggle("Peaks", isOn: $settings.rtaShowPeakHold)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func pushOptions() {
        engine.setOptions(settings.rtaOptions)
    }

    // MARK: Status

    /// The lowest band this size resolves, when there is something below it
    /// that a larger transform would reach.
    private var lowBandHint: Double? {
        guard mode == .bands, engine.snapshot.status.isRunning,
              settings.rtaFftOrder < Int(engine.caps.fftOrderMax),
              let lowest = engine.lowestMeasurableCentreHz else { return nil }
        return lowest
    }

    private var statusBar: some View {
        let s = engine.snapshot.status
        return HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle()
                    .fill(s.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(s.isRunning ? "Running" : "Idle")
            }
            Text(engine.refreshDescription)
            if s.framesPerSecond > 0 {
                Text("\(s.framesPerSecond) frames/s")
            }
            if s.lastFrameUs > 0 {
                Text("transform \(s.lastFrameUs) \u{00B5}s")
            }
            if s.busyUsPerSecond > 0 {
                // Main-loop time, which the packet-callback CPU figure in Stats
                // cannot see; 10,000 microseconds per second is one percent.
                Text(String(format: "main loop %.1f%%", Double(s.busyUsPerSecond) / 10000.0))
            }
            if s.bassBusyUsPerSecond > 0 {
                Text(s.bassLoadDescription)
                    .help("Bass processing time summed across both cores. Already included in the audio CPU meters; ≥ means the counter is saturated.")
            }
            Spacer()
            if engine.configRejected {
                Label("Device refused this configuration", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            } else if let lowest = lowBandHint {
                // The shaded slots at the bottom of the scale have a remedy,
                // and it is one control away, so name it rather than leaving
                // the user to conclude the analyser is broken down there.
                Text("shaded bands below \(rtaShortHz(lowest)) Hz need a larger transform")
                    .foregroundColor(.orange)
            } else if engine.caps.dynamicRangeDB > 0 {
                Text(mode == .bins ? "\(engine.caps.dynamicRangeDB) dB FFT range"
                     : "\(engine.caps.dynamicRangeDB)/\(engine.caps.bassDynamicRangeDB) dB range")
                    .help("FFT / bass usable dynamic range. Bass bands use overlapping filters calibrated for tones.")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
