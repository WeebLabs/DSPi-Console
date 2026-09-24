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

/// Hands `rtaRenderingActive` to its content from a view that is not equatable.
///
/// The analyser views are `.equatable()` so telemetry that does not change the
/// picture cannot redraw them, and SwiftUI then skips a view whose stored values
/// compare equal even when an environment value it reads has changed.  Read
/// inside such a view, the flag can go false while a window closes and never
/// come back when it reopens, leaving the bars paused until an unrelated frame
/// happens to differ.  Read here instead, the change still reaches the timeline
/// or Metal surface below.
struct RtaRenderingActiveReader<Content: View>: View {
    @Environment(\.rtaRenderingActive) private var active
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(active) }
}

/// Re-evaluates its content whenever the analyser's picture changes.  Only the
/// Canvas fallbacks need it: the Metal views follow the frames without SwiftUI.
struct RtaFrameFeedReader<Content: View>: View {
    @ObservedObject var feed: RtaFrameFeed
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
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
        guard dt > 0 else { return values }
        lastTime = now
        let riseK = riseTau > 0 ? 1 - exp(-dt / riseTau) : 1
        let fallK = fallTau > 0 ? 1 - exp(-dt / fallTau) : 1
        // A pointer loop: this runs for every band of every bar panel and curve
        // on every frame, and unoptimised builds do not specialise array
        // indices or subscripts.  Same arithmetic as `values[i] += ...`.
        let n = values.count
        target.withUnsafeBufferPointer { t in
            values.withUnsafeMutableBufferPointer { v in
                guard let tp = t.baseAddress, let vp = v.baseAddress else { return }
                var i = 0
                while i < n {
                    let ti = tp[i], vi = vp[i]
                    vp[i] = vi + (ti - vi) * (ti > vi ? riseK : fallK)
                    i += 1
                }
            }
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
    /// Where the frames come from.  Always the same engine, so left out of `==`.
    let engine: RtaEngine
    let tap: UInt8
    let channel: Int
    let configuration: RtaDisplayConfiguration
    /// The smoothing preference; the time constant is worked out when drawing.
    let smoothing: Double
    let color: Color
    let scale: RtaScale
    var showPeakHold: Bool = true
    /// Axis labels and the dB grid: on in the full-size views, off where the
    /// bars are too small for them to be readable.
    var showLabels: Bool = false
    /// The dB numbers beside the grid lines, when `showLabels` is on.  The
    /// inline strip leaves them out: the frequency axis is what it needs.
    var showLevelLabels: Bool = true
    /// The strip supplies one shared Metal surface above all its static grids.
    var drawsBars: Bool = true

    private var bandCount: Int { configuration.barCount }

    private var visibleBands: [Int] {
        renderState.cache.visibleBands(configuration: configuration, count: bandCount)
    }

    init(engine: RtaEngine, tap: UInt8, channel: Int, color: Color, scale: RtaScale,
         showPeakHold: Bool = true, showLabels: Bool = false, showLevelLabels: Bool = true,
         drawsBars: Bool = true) {
        self.engine = engine
        self.tap = tap
        self.channel = channel
        configuration = RtaDisplayConfiguration(engine: engine)
        smoothing = AppSettings.shared.rtaSmoothing
        self.color = color
        self.scale = scale
        self.showPeakHold = showPeakHold
        self.showLabels = showLabels
        self.showLevelLabels = showLevelLabels
        self.drawsBars = drawsBars
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tap == rhs.tap && lhs.channel == rhs.channel
            && lhs.configuration == rhs.configuration && lhs.smoothing == rhs.smoothing
            && lhs.color == rhs.color && lhs.scale == rhs.scale
            && lhs.showPeakHold == rhs.showPeakHold && lhs.showLabels == rhs.showLabels
            && lhs.showLevelLabels == rhs.showLevelLabels
            && lhs.drawsBars == rhs.drawsBars
    }

    /// One pole per band, carried across redraws.  A reference type in
    /// `@State`, so SwiftUI keeps it for the life of this view without
    /// observing it: stepping the filter must not invalidate the view that
    /// stepped it, or the two would chase each other every frame.
    @State private var renderState = RtaSmoothingState()

    /// Levels in dBFS, one per band slot, with no frame reading as silence so
    /// the bars rise into view rather than appearing at full height.
    private func targets(_ frame: RtaBandFrame?) -> (avg: [Double], peak: [Double]) {
        let n = bandCount
        guard let frame else {
            return (Array(repeating: scale.floorDB, count: n),
                    showPeakHold ? Array(repeating: scale.floorDB, count: n) : [])
        }
        var avg = [Double](repeating: scale.floorDB, count: n)
        var peak = showPeakHold ? avg : []
        for i in 0..<n {
            if i < frame.avg.count { avg[i] = configuration.levelDB(frame.avg[i]) }
            if showPeakHold, i < frame.peak.count { peak[i] = configuration.levelDB(frame.peak[i]) }
        }
        return (avg, peak)
    }

    /// Distinguishes one channel's numbers from another's, so a channel change
    /// snaps instead of sliding over from the channel before it.
    private var seriesIdentity: Int {
        Int(tap) << 24 | channel << 8 | bandCount
    }

    var body: some View {
        ZStack {
            if showLabels {
                RtaBandGrid(scale: scale, centres: configuration.centres, visible: visibleBands,
                            showLevelLabels: showLevelLabels).equatable()
            }
            // The active flag is read below the equatable boundary: see
            // `RtaRenderingActiveReader` for why reading it here would miss changes.
            RtaRenderingActiveReader { active in
                if drawsBars, RtaMetalBarResources.shared != nil {
                    GeometryReader { geometry in
                        RtaMetalBars(engine: engine, sources: [RtaMetalBarSource(
                            tap: tap, channel: channel, color: RtaMetalBarPanel.rgba(color),
                            scale: scale, smoothing: smoothing, showPeakHold: showPeakHold,
                            rect: CGRect(x: 0, y: 0, width: geometry.size.width,
                                         height: max(0, geometry.size.height - (showLabels ? 12 : 0))))],
                            active: active)
                    }
                } else if drawsBars {
                    // Without Metal the Canvas is the only renderer, so it has
                    // to follow each frame through SwiftUI.
                    RtaFrameFeedReader(feed: engine.frameFeed) {
                        let target = targets(engine.frame(channel: channel, tap: tap))
                        let tau = rtaFallTau(engine, smoothing)
                        if tau > 0 {
                            TimelineView(.animation(minimumInterval: rtaFrameInterval, paused: !active)) { timeline in
                                canvas(now: timeline.date, target: target, tau: tau)
                            }
                        } else {
                            canvas(now: nil, target: target, tau: 0)
                        }
                    }
                }
            }
        }
    }

    private func canvas(now: Date?, target t: (avg: [Double], peak: [Double]),
                        tau: TimeInterval) -> some View {
        let identity = seriesIdentity
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
                avg = renderState.bars.step(now: now, target: t.avg, identity: identity,
                                            riseTau: tau * 0.4, fallTau: tau)
                // A peak cap that eased upward would stop being a peak; only
                // its fall is interpolated, and the device is already decaying
                // it at the rate the user chose.
                peak = showPeakHold ? renderState.caps.step(now: now, target: t.peak, identity: identity,
                                                            riseTau: 0, fallTau: tau) : []
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
    let showLevelLabels: Bool

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
            if showLevelLabels {
                ctx.draw(Text("\(Int(db))").font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6)),
                         at: CGPoint(x: plot.maxX - 2, y: y - 6), anchor: .topTrailing)
            }
            db -= 12
        }
    }

    private func drawFrequencyLabels(_ ctx: GraphicsContext, _ plot: CGRect,
                                     bands: [Int], slot: CGFloat, labelY: CGFloat) {
        guard !centres.isEmpty else { return }
        struct Label { let hz: Double; let x: CGFloat; let text: String }
        var candidates: [Label] = []
        for (pos, i) in bands.enumerated() where i < centres.count {
            let hz = centres[i]
            // The table carries nominal centres rounded to whole hertz, so 31.5
            // arrives as 31 or 32; match on proportion rather than equality.
            guard let nominal = rtaLabelledCentres.first(where: { abs(hz - $0) < $0 * 0.03 }) else { continue }
            candidates.append(Label(hz: nominal, x: plot.minX + (CGFloat(pos) + 0.5) * slot,
                                    text: rtaShortHz(hz)))
        }

        // A narrow cell cannot fit every label.  Decades are placed first, then
        // the 2s and 5s between them wherever they clear what is already there
        // and the cell's edges, so a crowded axis thins out instead of
        // overprinting.  Widths are estimated from the 8 pt monospaced face.
        let charWidth: CGFloat = 4.9, gap: CGFloat = 4
        func span(_ label: Label) -> ClosedRange<CGFloat> {
            let half = CGFloat(label.text.count) * charWidth / 2
            return (label.x - half)...(label.x + half)
        }
        let decadeHz: Set<Double> = [10, 100, 1000, 10000]
        let decades = candidates.filter { decadeHz.contains($0.hz) }
        let others = candidates.filter { !decadeHz.contains($0.hz) }
        var placed: [ClosedRange<CGFloat>] = []
        for label in decades + others {
            let s = span(label)
            guard s.lowerBound >= plot.minX, s.upperBound <= plot.maxX,
                  !placed.contains(where: { s.lowerBound < $0.upperBound + gap && s.upperBound > $0.lowerBound - gap })
            else { continue }
            placed.append(s)
            ctx.draw(Text(label.text).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: label.x, y: labelY), anchor: .top)
        }
    }
}

// MARK: - Log-frequency grid

/// The dB lines and the 1-2-5 frequency lines on a logarithmic axis, with
/// optional labels, behind the analyser window's spectrum curves.
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
        let rate = display.sampleRateHz > 0 ? Double(display.sampleRateHz) : 48000
        return rtaBandIsPopulated(band: i, sampleRateHz: rate,
                                  fftOrder: Int(options.fftOrder), bassBands: Int(caps.bassBands))
    }

    /// The centre of the lowest band this configuration can measure at all, for
    /// the note that tells the user what a larger transform would buy.
    var lowestMeasurableCentreHz: Double? {
        let first = display.firstResolvedBand
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

// MARK: - Channel selection

/// The channels a page's spectrum shows: any number of channels, all at one tap.
/// Inputs and outputs are never mixed, because the device has one FFT engine
/// and it listens at one tap at a time.
struct RtaChannelSelection: Equatable {
    var tap: UInt8
    /// Channels at `tap` (input row, or matrix output index), ascending.
    private(set) var channels: [Int]

    init(tap: UInt8, channels: [Int]) {
        self.tap = tap
        self.channels = Array(Set(channels)).sorted()
    }

    static let none = RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [])

    var isEmpty: Bool { channels.isEmpty }

    var mask: UInt16 {
        channels.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1)) }
    }

    /// "in:0,2" or "out:1".  An empty list ("out:") is a deliberate choice of
    /// nothing.  A single channel is spelled the way the one-channel dashboard
    /// setting stored it, so that preference carries over unchanged.
    var storageKey: String {
        (tap == RTA_TAP_INPUT ? "in:" : "out:") + channels.map(String.init).joined(separator: ",")
    }

    init?(storageKey: String) {
        guard let colon = storageKey.firstIndex(of: ":") else { return nil }
        let tap: UInt8
        switch storageKey[..<colon] {
        case "in":  tap = RTA_TAP_INPUT
        case "out": tap = RTA_TAP_OUTPUT
        default:    return nil
        }
        var channels: [Int] = []
        for item in storageKey[storageKey.index(after: colon)...].split(separator: ",") {
            guard let n = Int(item), n >= 0, n < 16 else { return nil }
            channels.append(n)
        }
        self.init(tap: tap, channels: channels)
    }

    func contains(tap: UInt8, channel: Int) -> Bool {
        self.tap == tap && channels.contains(channel)
    }

    /// Whether a channel at `tap` can be checked without mixing taps.
    func accepts(tap: UInt8) -> Bool { isEmpty || self.tap == tap }

    /// This selection with one channel checked or unchecked.  A channel at the
    /// other tap is ignored rather than replacing the selection: the menu
    /// disables those items, so reaching here with one is a caller bug.
    func toggling(tap: UInt8, channel: Int) -> RtaChannelSelection {
        guard accepts(tap: tap) else { return self }
        let next = channels.contains(channel) && self.tap == tap
            ? channels.filter { $0 != channel }
            : (self.tap == tap ? channels : []) + [channel]
        return RtaChannelSelection(tap: tap, channels: next)
    }

    /// Only the channels in `live`, keeping the tap.
    func restricted(to live: [Int]) -> RtaChannelSelection {
        RtaChannelSelection(tap: tap, channels: channels.filter(live.contains))
    }

    /// Moving to the other side: the side being left becomes the remembered
    /// one, and the side being entered comes back as it was left, or empty if
    /// it was never used.  Asking for the side already showing changes nothing.
    static func switchingSides(active: RtaChannelSelection, remembered: RtaChannelSelection?,
                               to tap: UInt8) -> (active: RtaChannelSelection, remembered: RtaChannelSelection?) {
        guard tap != active.tap else { return (active, remembered) }
        let restored = remembered.flatMap { $0.tap == tap ? $0 : nil }
            ?? RtaChannelSelection(tap: tap, channels: [])
        return (restored, active)
    }
}

extension DSPViewModel {
    /// Channels the analyser can show at `tap`: every live input row, or every
    /// enabled output in sidebar order.  Clamped to what the caps report,
    /// because a mask bit for a channel the device lacks is a rejected config.
    func rtaChannels(tap: UInt8) -> [Int] {
        let reported = Int(tap == RTA_TAP_INPUT ? rta.caps.inputChannels : rta.caps.outputChannels)
        let limit = min(reported > 0 ? reported : 16, 16)
        if tap == RTA_TAP_INPUT { return Array(0..<min(numMatrixInputs, limit)) }
        return MatrixOutput.visible(for: platformName, slotTypes: outputSlotTypes)
            .map(\.index)
            .filter { $0 < limit && $0 < outputEnabled.count && outputEnabled[$0] }
    }

    /// The graph's EQ channel for a channel at `tap`.
    func rtaEqChannel(tap: UInt8, channel: Int) -> Int {
        tap == RTA_TAP_INPUT ? channel : eqChannel(forOutput: channel)
    }

    func rtaChannelName(tap: UInt8, channel: Int) -> String {
        let eqCh = rtaEqChannel(tap: tap, channel: channel)
        return eqCh < channelNames.count ? channelNames[eqCh] : "Ch \(channel + 1)"
    }

    /// The dashboard's selection, as stored, limited to channels live on this
    /// device.  Never chosen, or every chosen channel gone (an output since
    /// disabled, say), falls back to the first enabled output, then input 1.
    /// A stored empty selection stays empty: the user hid the spectrum.
    var dashboardRtaSelection: RtaChannelSelection {
        if let stored = RtaChannelSelection(storageKey: AppSettings.shared.rtaDashboardSelectionKey) {
            if stored.isEmpty { return stored }
            let live = stored.restricted(to: rtaChannels(tap: stored.tap))
            if !live.isEmpty { return live }
        }
        if let first = rtaChannels(tap: RTA_TAP_OUTPUT).first {
            return RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [first])
        }
        return RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [0])
    }

    /// The selection for whichever page is showing.  The dashboard's is
    /// remembered; a channel page's starts as its own channel each time one
    /// opens (see `resetRtaPageSelection`), so leaving a page returns the
    /// dashboard to exactly what it showed before.
    var rtaSelection: RtaChannelSelection {
        guard activeEqChannel != nil else { return dashboardRtaSelection }
        return rtaPageSelection.restricted(to: rtaChannels(tap: rtaPageSelection.tap))
    }

    func setRtaSelection(_ selection: RtaChannelSelection) {
        if activeEqChannel == nil {
            AppSettings.shared.rtaDashboardSelectionKey = selection.storageKey
        } else {
            rtaPageSelection = selection
            // Hiding the spectrum on one channel page keeps it hidden on the
            // next, rather than bringing it back every time a page opens.
            AppSettings.shared.rtaChannelPagesShowSpectrum = !selection.isEmpty
        }
    }

    /// Show the other side's channels, bringing back whatever was checked
    /// there when the user last left it.  This is not a hide, so it leaves the
    /// channel pages' show-spectrum preference alone.
    func switchRtaSide(to tap: UInt8) {
        if activeEqChannel == nil {
            let settings = AppSettings.shared
            // The stored form rather than the live one, so an output that is
            // disabled for now is still remembered for when it comes back.
            let active = RtaChannelSelection(storageKey: settings.rtaDashboardSelectionKey) ?? dashboardRtaSelection
            let next = RtaChannelSelection.switchingSides(
                active: active,
                remembered: RtaChannelSelection(storageKey: settings.rtaDashboardOtherSideKey),
                to: tap)
            settings.rtaDashboardSelectionKey = next.active.storageKey
            settings.rtaDashboardOtherSideKey = next.remembered?.storageKey ?? ""
        } else {
            let next = RtaChannelSelection.switchingSides(
                active: rtaPageSelection, remembered: rtaPageOtherSide, to: tap)
            rtaPageSelection = next.active
            rtaPageOtherSide = next.remembered
        }
    }

    /// Start a newly opened channel page on its own channel, or on nothing if
    /// the user hid the spectrum on channel pages.  Nothing is remembered for
    /// the other side yet.
    func resetRtaPageSelection(for eqCh: Int) {
        let tap = eqCh < chOut1 ? RTA_TAP_INPUT : RTA_TAP_OUTPUT
        let channel = eqCh < chOut1 ? eqCh : eqCh - chOut1
        rtaPageOtherSide = nil
        rtaPageSelection = AppSettings.shared.rtaChannelPagesShowSpectrum
            ? RtaChannelSelection(tap: tap, channels: [channel])
            : RtaChannelSelection(tap: tap, channels: [])
    }
}

// MARK: - Graph options popover

/// The gear at the graph's top-right corner.  It opens a popover rather than a
/// menu, so the channels can be shown as chips in their curve colours and the
/// drawing options as real switches.  It edits whichever page is showing, so
/// the same panel serves the dashboard and the channel pages.
struct GraphOptionsButton: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    /// Owned by the graph, which keeps the gear on screen while the popover is
    /// open even after the pointer has left the plot.
    @Binding var isOpen: Bool
    /// Nil in the pop-out window, which has nowhere further to pop out to.
    let onPopOut: (() -> Void)?

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(isOpen ? 0.95 : 0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(vm.activeEqChannel == nil ? "Graph options for the dashboard" : "Graph options for this channel page")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            GraphOptionsPanel(vm: vm, engine: engine,
                              onPopOut: onPopOut.map { popOut in { isOpen = false; popOut() } })
        }
    }
}

private struct GraphOptionsPanel: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    let onPopOut: (() -> Void)?

    private var onDashboard: Bool { vm.activeEqChannel == nil }

    /// The panel's two pages.  Reopening the popover builds a fresh panel, so
    /// it always opens on the main page.
    private enum Page { case main, setup }
    @State private var page = Page.main

    private func go(to next: Page) {
        withAnimation(.easeInOut(duration: 0.2)) { page = next }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch page {
            case .main:
                mainPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .setup:
                GraphSetupPage(inPopOutWindow: onPopOut == nil, onBack: { go(to: .main) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 280)
        .clipped()
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.supported && vm.isDeviceReady {
                channelSection
                    .padding(12)
                Divider()
                VStack(spacing: 0) {
                    GraphOptionsToggleRow(icon: "waveform.path", title: "FFT Graph",
                                          isOn: showBinding(.graph))
                    GraphOptionsToggleRow(icon: "chart.bar.fill", title: "RTA Bars",
                                          isOn: showBinding(.bars))
                }
                .padding(.vertical, 6)
            } else {
                Text(vm.isDeviceReady ? "This firmware has no spectrum analyser."
                                      : "Connect a DSPi to show its spectrum.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(12)
            }
            Divider()
            VStack(spacing: 0) {
                GraphOptionsActionRow(icon: "slider.horizontal.3", title: "Graph Setup",
                                      trailingIcon: "chevron.right") { go(to: .setup) }
                if let onPopOut {
                    GraphOptionsActionRow(icon: "arrow.down.backward.and.arrow.up.forward",
                                          title: "Pop Out Graph", action: onPopOut)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Channels

    /// Choosing a side is what keeps inputs and outputs apart: only one side's
    /// chips are ever on screen.  Each side keeps its own checked channels.
    private var tapBinding: Binding<UInt8> {
        Binding(get: { vm.rtaSelection.tap },
                set: { vm.switchRtaSide(to: $0) })
    }

    private var channelSection: some View {
        let selection = vm.rtaSelection
        let channels = vm.rtaChannels(tap: selection.tap)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SPECTRUM")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: tapBinding) {
                    Text("Inputs").tag(RTA_TAP_INPUT)
                    Text("Outputs").tag(RTA_TAP_OUTPUT)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if channels.isEmpty {
                Text(selection.tap == RTA_TAP_INPUT ? "No active inputs." : "No enabled outputs.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                // Two equal columns, so chips line up whatever the names.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)],
                          spacing: 6) {
                    ForEach(channels, id: \.self) { ch in
                        chip(ch, tap: selection.tap, on: selection.contains(tap: selection.tap, channel: ch))
                    }
                }
            }

            HStack {
                Text(summary(selection))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if !selection.isEmpty {
                    Button("Clear") { vm.setRtaSelection(RtaChannelSelection(tap: selection.tap, channels: [])) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func summary(_ selection: RtaChannelSelection) -> String {
        switch selection.channels.count {
        case 0:  return "Spectrum hidden"
        case 1:  return "1 channel"
        default: return "\(selection.channels.count) channels"
        }
    }

    private func chip(_ ch: Int, tap: UInt8, on: Bool) -> some View {
        let color = eqCurveColor(eqCh: vm.rtaEqChannel(tap: tap, channel: ch), chOut1: vm.chOut1)
        let name = vm.rtaChannelName(tap: tap, channel: ch)
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button {
            vm.setRtaSelection(vm.rtaSelection.toggling(tap: tap, channel: ch))
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.opacity(on ? 1 : 0.4))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .background(shape.fill(on ? color.opacity(0.22) : Color.primary.opacity(0.05)))
            .overlay(shape.stroke(on ? color.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(name)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    // MARK: Drawing

    private func showBinding(_ view: RtaSpectrumView) -> Binding<Bool> {
        Binding(get: { settings.rtaShows(view, onDashboard: onDashboard) },
                set: { settings.setRtaShows(view, onDashboard: onDashboard, $0) })
    }
}

/// A menu-like action row: highlighted under the pointer, icon aligned with the
/// switch rows above it (4 pt outside plus 8 pt inside matches their 12 pt).
private struct GraphOptionsActionRow: View {
    let icon: String
    let title: String
    /// A chevron for a row that opens another page rather than acting.
    var trailingIcon: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(hovered ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .foregroundColor(hovered ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovered = $0 }
    }
}

/// A labelled switch row, shared by both pages of the graph options panel.
private struct GraphOptionsToggleRow: View {
    var icon: String? = nil
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }
            Text(title)
                .font(.system(size: 12))
                // Text does not dim with its disabled switch on its own.
                .foregroundColor(isEnabled ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

/// The panel's second page: the graph's scale, grids and curve style, the same
/// preferences as the Graphing settings tab, adjustable while looking at the
/// graph they change.
private struct GraphSetupPage: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Offers the pop-out window's own follow-selection switch, which means
    /// nothing in the main window.
    let inPopOutWindow: Bool
    let onBack: () -> Void

    /// Fixed so slider rows line up whatever their labels and values say.
    private let labelWidth: CGFloat = 64
    private let valueWidth: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Text("Graph Setup")
                    .font(.system(size: 12, weight: .semibold))
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)

            Divider()

            sectionHeader("SCALE") {
                Button("Reset", action: resetScale)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
                    .help("Restore the default frequency and dB range")
            }
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    rowLabel("Frequency")
                    Picker("", selection: $settings.graphMinFreq) {
                        Text("10 Hz").tag(10.0)
                        Text("15 Hz").tag(15.0)
                        Text("20 Hz").tag(20.0)
                        Text("50 Hz").tag(50.0)
                        Text("100 Hz").tag(100.0)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 80)
                    Text("to")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $settings.graphMaxFreq) {
                        Text("5 kHz").tag(5000.0)
                        Text("10 kHz").tag(10000.0)
                        Text("20 kHz").tag(20000.0)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 80)
                    Spacer(minLength: 0)
                }
                sliderRow("Range", value: "\(Int(settings.graphDBRange)) dB",
                          binding: Binding(get: { settings.graphDBRange },
                                           set: { settings.graphDBRange = $0.rounded() }),
                          in: 10...100)
                sliderRow("Center", value: String(format: "%+.0f dB", settings.graphDBCenter),
                          binding: Binding(get: { settings.graphDBCenter },
                                           set: { settings.graphDBCenter = $0.rounded() }),
                          in: -40...20)
            }
            .padding(.horizontal, 12)

            sectionHeader("GRID & LABELS")
            GraphOptionsToggleRow(title: "Frequency Grid", isOn: $settings.showFrequencyGrid)
            GraphOptionsToggleRow(title: "Frequency Labels", isOn: $settings.showFrequencyLabels)
            GraphOptionsToggleRow(title: "dB Grid", isOn: $settings.showDBGrid)
            GraphOptionsToggleRow(title: "dB Labels", isOn: $settings.showDBLabels)
            sliderRow("Grid Opacity", value: "\(Int((settings.graphGridOpacity * 100).rounded()))%",
                      binding: $settings.graphGridOpacity, in: 0...2)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .disabled(!settings.showFrequencyGrid && !settings.showDBGrid)

            sectionHeader("CURVES")
            sliderRow("Line Width", value: String(format: "%.1f pt", settings.graphLineWidth),
                      binding: $settings.graphLineWidth, in: 1...4, step: 0.5)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            GraphOptionsToggleRow(title: "Glow", isOn: $settings.showGraphGlow)
            GraphOptionsToggleRow(title: "Phase Response", isOn: $settings.showPhase)
            GraphOptionsToggleRow(title: "Unwrap Phase", isOn: $settings.phaseUnwrapped)
                .disabled(!settings.showPhase)
            if inPopOutWindow {
                GraphOptionsToggleRow(title: "Follow Channel Selection",
                                      isOn: $settings.popoutGraphFollowsSelection)
            }

            Spacer().frame(height: 8)
        }
    }

    private func sectionHeader<Trailing: View>(_ title: String,
                                               @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .frame(width: labelWidth, alignment: .leading)
    }

    private func sliderRow(_ title: String, value: String, binding: Binding<Double>,
                           in range: ClosedRange<Double>, step: Double? = nil) -> some View {
        HStack(spacing: 6) {
            rowLabel(title)
            Group {
                if let step {
                    Slider(value: binding, in: range, step: step)
                } else {
                    Slider(value: binding, in: range)
                }
            }
            .controlSize(.small)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    /// The scale's @AppStorage defaults.  Grids and curve style are left alone:
    /// a reset of the axes should not also switch the phase trace off.
    private func resetScale() {
        settings.graphMinFreq = 15
        settings.graphMaxFreq = 20000
        settings.graphDBRange = 50
        settings.graphDBCenter = 0
    }
}

/// A tiny picture of a bar-strip layout: two rows of rounded cells in the given
/// number of columns, drawn in the current foreground colour.
private struct BarLayoutGlyph: View {
    let columns: Int
    var size = CGSize(width: 16, height: 10)

    var body: some View {
        let gap: CGFloat = size.width > 20 ? 2 : 1.5
        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: gap)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The bar strip's gear popover: how many columns the channels use, and the
/// full analyser window.
private struct BarStripOptionsPanel: View {
    @Binding var columns: Int
    /// Layout means nothing with a single channel, so it is left out then.
    let showsLayout: Bool
    let onOpenWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLayout {
                Text("LAYOUT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                HStack(spacing: 6) {
                    ForEach(1...4, id: \.self) { n in tile(n) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                Divider()
            }
            GraphOptionsActionRow(icon: "macwindow", title: "Open in Window", action: onOpenWindow)
                .padding(.vertical, 6)
        }
        .frame(width: 200)
    }

    private func tile(_ n: Int) -> some View {
        let on = columns == n
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button { columns = n } label: {
            VStack(spacing: 4) {
                BarLayoutGlyph(columns: n, size: CGSize(width: 22, height: 13))
                Text("\(n)")
                    .font(.system(size: 9, weight: on ? .semibold : .regular))
            }
            .foregroundColor(on ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(shape.fill(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(shape.stroke(on ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(n == 1 ? "Stack the channels in one column" : "Lay the channels out in up to \(n) columns")
    }
}

// MARK: - Bar strip

extension RtaMetalBarPanel {
    init(configuration: RtaDisplayConfiguration, tap: UInt8, channel: Int, frame: RtaBandFrame?,
         color: SIMD4<Float>, scale: RtaScale, fallTau: TimeInterval, showPeakHold: Bool,
         rect: CGRect, cache: RtaRenderCache) {
        // The same count the grid lays out, so bars and labels stay aligned.
        let count = configuration.barCount
        var levels = [Double](repeating: scale.floorDB, count: count)
        var peaks = showPeakHold ? levels : []
        if let frame {
            for i in levels.indices {
                if i < frame.avg.count { levels[i] = configuration.levelDB(frame.avg[i]) }
                if showPeakHold, i < frame.peak.count { peaks[i] = configuration.levelDB(frame.peak[i]) }
            }
        }
        self.init(identity: Int(tap) << 24 | channel << 8 | count,
                  rect: rect, levels: levels, peaks: peaks,
                  visible: cache.visibleBands(configuration: configuration, count: count),
                  color: color, floorDB: scale.floorDB, ceilingDB: scale.ceilingDB,
                  fallTau: fallTau, showPeakHold: showPeakHold)
    }
}

/// Shared with the static grid: padding 10, column gap 12, row gap 8,
/// name row 14 + spacing 2, and a 12-point frequency-label row below each plot.
/// `graphHeight` is one cell's bars plus that label row.
func rtaBarStripPlot(index: Int, count: Int, columns: Int, width: CGFloat,
                     graphHeight: CGFloat) -> CGRect {
    let columns = max(1, columns)
    let cellWidth = max(0, (width - 20 - CGFloat(columns - 1) * 12) / CGFloat(columns))
    return CGRect(x: 10 + CGFloat(index % columns) * (cellWidth + 12),
                  y: 10 + CGFloat(index / columns) * (14 + 2 + graphHeight + 8) + 14 + 2,
                  width: cellWidth, height: graphHeight - 12)
}

/// Third-octave bars for the selected channels, above the dashboard's cards or
/// a channel page's filter table, when the page has bars switched on.  One card
/// with a cell per channel, laid side by side before wrapping, so a larger
/// selection grows the card instead of stacking more cards.
///
/// There is no header row.  Each cell names its channel, which already says
/// whether these are inputs or outputs, and the options gear sits at the end of
/// the top-right cell's name row, so it costs no height and never covers bars.
struct SpectrumBarStrip: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var analyserController: SpectrumAnalyserWindowController

    @State private var optionsOpen = false
    @State private var isHovered = false

    /// Tall enough for the gear, and kept in every cell so rows line up.
    private let nameRowHeight: CGFloat = 14
    /// Kept clear at the end of every name row, so names truncate at the same
    /// point across a row whether or not the gear is in that cell.
    private let gearWidth: CGFloat = 16

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    private func color(_ selection: RtaChannelSelection, _ ch: Int) -> Color {
        eqCurveColor(eqCh: vm.rtaEqChannel(tap: selection.tap, channel: ch), chOut1: vm.chOut1)
    }

    private var chosenColumns: Int { min(max(settings.rtaBarColumns, 1), 4) }

    /// Side by side up to the user's chosen column count, then wrapping.  A
    /// selection smaller than that fills the width rather than leaving gaps.
    private func columnCount(_ n: Int) -> Int {
        min(max(n, 1), chosenColumns)
    }

    /// Limits for the dragged height of a single-channel cell.
    private static let barHeightRange: ClosedRange<Double> = 64...240

    /// One cell's bars plus its label row.  Several channels keep the three
    /// quarters they have always had of a lone channel's height, so one drag
    /// resizes both.
    private func cellHeight(single: Bool) -> CGFloat {
        let height = min(max(settings.rtaBarHeight, Self.barHeightRange.lowerBound),
                         Self.barHeightRange.upperBound)
        return CGFloat(single ? height : (height * 0.75).rounded())
    }

    var body: some View {
        let selection = vm.rtaSelection
        if engine.supported, vm.isDeviceReady, !selection.isEmpty,
           settings.rtaShows(.bars, onDashboard: vm.activeEqChannel == nil) {
            let count = selection.channels.count
            let single = count == 1
            let columns = columnCount(count)
            // Equal flexible columns and one fixed cell height, so cells line
            // up across rows whatever the channel names.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                      alignment: .leading, spacing: 8) {
                ForEach(selection.channels, id: \.self) { ch in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(color(selection, ch)).frame(width: 5, height: 5)
                            Text(vm.rtaChannelName(tap: selection.tap, channel: ch))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            // The slot the gear overlay lands on in the
                            // top-right cell.
                            Color.clear.frame(width: gearWidth, height: nameRowHeight)
                        }
                        .frame(height: nameRowHeight)
                        // Every cell carries its own frequency axis, since
                        // side-by-side cells share no row below them.
                        RtaBandsView(engine: engine, tap: selection.tap, channel: ch,
                                     color: color(selection, ch),
                                     scale: scale,
                                     showPeakHold: settings.rtaShowPeakHold,
                                     showLabels: true,
                                     showLevelLabels: false,
                                     drawsBars: RtaMetalBarResources.shared == nil).equatable()
                            .frame(height: cellHeight(single: single))
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(single ? color(selection, selection.channels[0]).opacity(0.3)
                                       : Color.secondary.opacity(0.2), lineWidth: 1))
            .overlay {
                if RtaMetalBarResources.shared != nil {
                    GeometryReader { geometry in
                        RtaMetalBars(engine: engine, sources: selection.channels.enumerated().map { index, ch in
                            RtaMetalBarSource(
                                tap: selection.tap, channel: ch,
                                color: RtaMetalBarPanel.rgba(color(selection, ch)), scale: scale,
                                smoothing: settings.rtaSmoothing,
                                showPeakHold: settings.rtaShowPeakHold,
                                rect: rtaBarStripPlot(index: index, count: count, columns: columns,
                                                     width: geometry.size.width,
                                                     graphHeight: cellHeight(single: single)))
                        })
                    }
                    .allowsHitTesting(false)
                }
            }
            // Tucked into the card's corner, inside the rounded edge.  Its span
            // still falls within the slot every name row keeps clear, so a long
            // name in the top-right cell stops short of it.  A single overlay
            // rather than a view inside that cell, so changing the layout from
            // the popover cannot move its anchor and close it.
            .overlay(alignment: .topTrailing) {
                gearButton(single: single)
                    .padding(6)
            }
            // Drag strip in the card's bottom padding, like the one under the
            // response graph, so resizing costs no extra height.
            .overlay(alignment: .bottom) {
                // Every row grows with the setting, and several channels by
                // three quarters of it, so scale the drag to keep the edge
                // under the cursor.
                let rows = (count + columns - 1) / columns
                GraphResizeHandleRepresentable(value: \.rtaBarHeight, range: Self.barHeightRange,
                                               pointsPerUnit: Double(rows) * (single ? 1 : 0.75))
                    .frame(height: 10)
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .rtaWatching(engine, RtaRequest(tap: selection.tap, mask: selection.mask))
        }
    }

    /// The layout and the analyser window are occasional choices, so the gear
    /// shows only on hover like the graph's, and holds while its popover is
    /// open.  Faded rather than removed, so the popover keeps its anchor.
    private func gearButton(single: Bool) -> some View {
        Button { optionsOpen.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(optionsOpen ? .primary : .secondary)
                .frame(width: gearWidth, height: nameRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Spectrum strip options")
        .opacity(isHovered || optionsOpen ? 1 : 0)
        .allowsHitTesting(isHovered || optionsOpen)
        .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
            BarStripOptionsPanel(
                columns: Binding(get: { chosenColumns }, set: { settings.rtaBarColumns = $0 }),
                showsLayout: !single,
                onOpenWindow: {
                    optionsOpen = false
                    analyserController.show(vm: vm)
                })
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
            let hosting = NSHostingView(rootView: view)
            // The window's size limits are set here, not derived from the
            // tree: left at its defaults the hosting view re-measures the
            // whole tree for them on every display cycle, which is most of
            // what a meter reading or a drag used to cost in this window.
            hosting.sizingOptions = []
            window?.contentView = hosting
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // This controller reuses its window and Metal views. An actual close
        // tears down MTKView's draw loop; ordering that same window front again
        // can leave it unpaused but without draw callbacks. Hide it instead,
        // just as toggle() does, so the retained renderers can resume.
        hide()
        return false
    }

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

/// A larger, separate view of the spectrum data the main window has asked for.
///
/// The main window decides what the engine does: the tap, the channels, and
/// whether there is a spectrum at all.  This window's registration always
/// matches the current page's selection, so it can never change that.  Within
/// that data it draws whatever the user likes: curves, bars or both, with any
/// of the page's channels hidden here only.  The engine options live in Settings.
struct SpectrumAnalyserView: View {
    @EnvironmentObject private var windowController: SpectrumAnalyserWindowController
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared

    enum DisplayMode: String, CaseIterable, Identifiable {
        case curves = "Curves"
        case bars = "Bars"
        case both = "Both"
        var id: Self { self }
    }

    private struct ChannelKey: Hashable {
        let tap: UInt8
        let channel: Int
    }

    @State private var mode: DisplayMode = .bars
    /// Channels hidden in this window only.  Drawing alone: nothing here ever
    /// reaches the engine.
    @State private var hidden: Set<ChannelKey> = []

    private var onDashboard: Bool { vm.activeEqChannel == nil }

    /// The window is kept rather than destroyed when closed, so its views never
    /// disappear; watching only while it is actually on screen is what lets the
    /// device stop the analyser when nothing else is looking.
    private var active: Bool { windowController.isRendering }

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    private var pageShowsSpectrum: Bool {
        settings.rtaShows(.graph, onDashboard: onDashboard) || settings.rtaShows(.bars, onDashboard: onDashboard)
    }

    private func color(_ tap: UInt8, _ ch: Int) -> Color {
        eqCurveColor(eqCh: vm.rtaEqChannel(tap: tap, channel: ch), chOut1: vm.chOut1)
    }

    private func isHidden(_ tap: UInt8, _ ch: Int) -> Bool {
        hidden.contains(ChannelKey(tap: tap, channel: ch))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.isDeviceReady || !engine.supported {
                unavailableNotice
            } else {
                let selection = vm.rtaSelection
                // With nothing shown on the page, the main window is asking the
                // engine for nothing, so there is no data here to present.
                let available = pageShowsSpectrum && !selection.isEmpty
                header(selection, available: available)
                Divider()
                if !available {
                    hiddenNotice(selection)
                } else {
                    let visible = selection.channels.filter { !isHidden(selection.tap, $0) }
                    Group {
                        if visible.isEmpty {
                            allHiddenNotice
                        } else {
                            VStack(spacing: 12) {
                                if mode != .bars { curves(selection) }
                                if mode != .curves { bars(selection, visible: visible) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxHeight: .infinity)
                    .background(Color.black.opacity(0.20))
                }
                Divider()
                statusBar(showsBars: available && mode != .curves)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { startFromPage() }
        .onChange(of: windowController.isVisible) { _, visible in
            if visible { startFromPage() }
        }
        // A channel that leaves the page's selection forgets it was hidden,
        // so it comes back visible if it is selected again.
        .onChange(of: vm.rtaSelection) { _, selection in
            hidden = hidden.filter { $0.tap == selection.tap && selection.channels.contains($0.channel) }
        }
    }

    /// Each time the window opens it starts out drawing what the page draws.
    private func startFromPage() {
        let graph = settings.rtaShows(.graph, onDashboard: onDashboard)
        let bars = settings.rtaShows(.bars, onDashboard: onDashboard)
        mode = graph && bars ? .both : (bars ? .bars : .curves)
    }

    // MARK: Header

    private var pageTitle: String {
        guard let eqCh = vm.activeEqChannel else { return "Dashboard" }
        return eqCh < vm.channelNames.count ? vm.channelNames[eqCh] : "Channel"
    }

    /// Which page is being mirrored, its channels as show/hide toggles (which
    /// are also the curves' legend), and how this window draws them.
    private func header(_ selection: RtaChannelSelection, available: Bool) -> some View {
        HStack(spacing: 10) {
            Text(pageTitle)
                .font(.system(size: 11, weight: .semibold))
            if available {
                Text(selection.tap == RTA_TAP_INPUT ? "Inputs" : "Outputs")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Divider().frame(height: 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selection.channels, id: \.self) { ch in
                            channelToggle(tap: selection.tap, channel: ch)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Picker("", selection: $mode) {
                ForEach(DisplayMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!available)
            .help("How this window draws the page's spectrum. It does not change the main window.")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func channelToggle(tap: UInt8, channel ch: Int) -> some View {
        let shown = !isHidden(tap, ch)
        return Button {
            let key = ChannelKey(tap: tap, channel: ch)
            if shown { hidden.insert(key) } else { hidden.remove(key) }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color(tap, ch).opacity(shown ? 1 : 0.25))
                    .frame(width: 6, height: 6)
                Text(vm.rtaChannelName(tap: tap, channel: ch))
                    .font(.system(size: 10))
                    .foregroundColor(shown ? .secondary : .secondary.opacity(0.4))
                    .strikethrough(!shown)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shown ? "Hide in this window" : "Show in this window")
    }

    // MARK: Display

    /// The response graph's spectrum without the filter curves: the same
    /// overlay the graph draws, over the analyser's dB grid, across the graph's
    /// frequency range so Graph Setup applies here too.  The overlay registers
    /// for the page's whole selection whatever is hidden here.
    private func curves(_ selection: RtaChannelSelection) -> some View {
        let minHz = settings.graphMinFreq
        let maxHz = settings.graphMaxFreq
        let hiddenHere = Set(selection.channels.filter { isHidden(selection.tap, $0) })
        return ZStack {
            RtaBinGrid(scale: scale, minHz: minHz, maxHz: maxHz, showLabels: true).equatable()
            // The grid keeps a 12 pt label row at the bottom; the overlay's plot
            // stops above it so both map the same dB scale to the same height.
            GraphSpectrumOverlay(vm: vm, engine: engine,
                                 minFreq: Float(minHz), maxFreq: Float(maxHz),
                                 active: active, hiddenChannels: hiddenHere)
                .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }

    /// The strip's bars for the visible channels, in its column layout, grown
    /// to fill the window.  Registered for the page's whole selection.
    private func bars(_ selection: RtaChannelSelection, visible: [Int]) -> some View {
        let count = visible.count
        let columns = min(max(count, 1), min(max(settings.rtaBarColumns, 1), 4))
        let rows = stride(from: 0, to: count, by: columns).map {
            Array(visible[$0..<min($0 + columns, count)])
        }
        return VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { ch in
                        barCell(tap: selection.tap, channel: ch)
                    }
                    // Keeps a short last row's cells as wide as the rows above.
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .rtaWatching(engine, RtaRequest(tap: selection.tap, mask: selection.mask), active: active)
    }

    private func barCell(tap: UInt8, channel ch: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color(tap, ch)).frame(width: 6, height: 6)
                Text(vm.rtaChannelName(tap: tap, channel: ch))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            RtaBandsView(engine: engine, tap: tap, channel: ch,
                         color: color(tap, ch),
                         scale: scale,
                         showPeakHold: settings.rtaShowPeakHold,
                         showLabels: true).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Notices

    private var unavailableNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Spectrum analyser unavailable")
                .font(.headline)
            Text(vm.isDeviceReady
                 ? "The connected firmware does not provide a compatible analyser. Update the firmware to use it."
                 : "Connect a DSPi to use the analyser.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func hiddenNotice(_ selection: RtaChannelSelection) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text(selection.isEmpty ? "No channels selected" : "Spectrum switched off")
                .font(.headline)
            Text("This window shows the spectrum of the \(onDashboard ? "dashboard" : "open channel page"). Choose channels and switch the spectrum on from the gear on the response graph.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var allHiddenNotice: some View {
        VStack(spacing: 6) {
            Text("Every channel is hidden in this window")
                .font(.headline)
            Text("Click a channel name above to show it again.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status

    private func statusBar(showsBars: Bool) -> some View {
        RtaStatusBar(engine: engine, telemetry: engine.telemetry, showsBars: showsBars)
    }
}

/// The analyser window's status line.  It is the only view observing the
/// telemetry, so the status changing twice a second redraws this line alone.
private struct RtaStatusBar: View {
    @ObservedObject var engine: RtaEngine
    @ObservedObject var telemetry: RtaTelemetry
    @ObservedObject private var settings = AppSettings.shared
    let showsBars: Bool

    var body: some View {
        let s = telemetry.status
        // The shaded bars low in the scale have a remedy in Settings, so name
        // it rather than leave the user to conclude the analyser is broken.
        let lowBandHint: Double? = showsBars && s.isRunning
            && settings.rtaFftOrder < Int(engine.caps.fftOrderMax)
            ? engine.lowestMeasurableCentreHz : nil
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
                Text("shaded bands below \(rtaShortHz(lowest)) Hz need a larger transform size in Settings")
                    .foregroundColor(.orange)
            } else if engine.caps.dynamicRangeDB > 0 {
                Text("\(engine.caps.dynamicRangeDB)/\(engine.caps.bassDynamicRangeDB) dB range")
                    .help("FFT / bass usable dynamic range. Bass bands use overlapping filters calibrated for tones.")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
