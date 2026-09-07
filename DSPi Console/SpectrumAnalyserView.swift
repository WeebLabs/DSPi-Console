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
private let rtaLabelledCentres: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

private func rtaShortHz(_ hz: Double) -> String {
    hz >= 1000 ? "\(Int((hz / 1000).rounded()))k" : "\(Int(hz.rounded()))"
}

// MARK: - Subscription

/// Watches the analyser for as long as the view is on screen.
///
/// The device has one FFT engine, so a view cannot simply ask for a picture -
/// it registers what it wants and the engine reconciles every request into a
/// single configuration.  Dropping the last subscription stops the analyser on
/// the device, which is what keeps it free when nobody is looking at it.
private struct RtaWatch: ViewModifier {
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    let request: RtaRequest
    @State private var token: UUID? = nil

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The device forgets these at every power cycle, so push them
                // whenever a view starts watching rather than only on edit.
                engine.setOptions(settings.rtaOptions)
                if token == nil { token = engine.subscribe(request) }
            }
            .onDisappear {
                if let t = token { engine.release(t); token = nil }
            }
            .onChange(of: request) { newValue in
                if let t = token { engine.update(t, to: newValue) }
            }
    }
}

extension View {
    /// Subscribe to the analyser while this view is visible.
    func rtaWatching(_ engine: RtaEngine, _ request: RtaRequest) -> some View {
        modifier(RtaWatch(engine: engine, request: request))
    }
}

// MARK: - Third-octave bars

/// One channel's third-octave picture.
///
/// Bands are equally spaced on a logarithmic frequency axis by construction, so
/// they are drawn as equal-width bars; the axis labels come from the device's
/// own band-centre table rather than a table of our own, so the picture and the
/// labels can never disagree about where a band sits.
struct RtaBandsView: View {
    @ObservedObject var engine: RtaEngine
    let frame: RtaBandFrame?
    let color: Color
    let scale: RtaScale
    var showPeakHold: Bool = true
    /// Axis labels and the dB grid: on in the full-size views, off in the
    /// thumbnails, where they would be unreadable anyway.
    var showLabels: Bool = false

    private var bandCount: Int {
        let n = Int(frame?.nBands ?? 0)
        return n > 0 ? min(n, RTA_MAX_BANDS) : max(engine.bandCentresHz.count, 31)
    }

    /// Bands below this read the floor because no FFT bin lands inside them at
    /// the current transform size.  They are drawn as an empty slot rather than
    /// as silence, which is a different thing and would be a lie.
    private var firstResolved: Int { engine.snapshot.status.firstResolvedBand }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let labelHeight: CGFloat = showLabels ? 12 : 0
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - labelHeight))
            guard plot.height > 2, bandCount > 0 else { return }

            if showLabels { drawGrid(ctx, plot) }

            let slot = plot.width / CGFloat(bandCount)
            let gap = min(2.0, max(0.5, slot * 0.18))
            let barWidth = max(1, slot - gap)

            for i in 0..<bandCount {
                let x = plot.minX + CGFloat(i) * slot + gap / 2
                guard i >= firstResolved else {
                    // Unresolved: a hairline on the baseline, so the slot is
                    // visibly present but plainly carries no reading.
                    let dot = CGRect(x: x, y: plot.maxY - 1, width: barWidth, height: 1)
                    ctx.fill(Path(dot), with: .color(.secondary.opacity(0.25)))
                    continue
                }
                guard let frame, i < frame.avg.count else { continue }

                let level = scale.norm(engine.levelDB(frame.avg[i]))
                if level > 0.001 {
                    let h = plot.height * CGFloat(level)
                    let bar = CGRect(x: x, y: plot.maxY - h, width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: min(1.5, barWidth / 3)),
                             with: .linearGradient(
                                Gradient(colors: [color.opacity(0.95), color.opacity(0.45)]),
                                startPoint: CGPoint(x: 0, y: bar.minY),
                                endPoint: CGPoint(x: 0, y: plot.maxY)))
                }

                if showPeakHold, i < frame.peak.count {
                    let peak = scale.norm(engine.levelDB(frame.peak[i]))
                    if peak > 0.001 {
                        let y = plot.maxY - plot.height * CGFloat(peak)
                        let cap = CGRect(x: x, y: max(plot.minY, y - 1), width: barWidth, height: 1.5)
                        ctx.fill(Path(cap), with: .color(color.opacity(0.9)))
                    }
                }
            }

            if showLabels { drawFrequencyLabels(ctx, plot, slot: slot, labelY: size.height - labelHeight + 1) }
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
                                     slot: CGFloat, labelY: CGFloat) {
        let centres = engine.bandCentresHz
        guard !centres.isEmpty else { return }
        for (i, hz) in centres.enumerated() where i < bandCount {
            // The table carries nominal centres rounded to whole hertz, so 31.5
            // arrives as 31 or 32; match on proportion rather than equality.
            guard rtaLabelledCentres.contains(where: { abs(hz - $0) < $0 * 0.03 }) else { continue }
            let x = plot.minX + (CGFloat(i) + 0.5) * slot
            ctx.draw(Text(rtaShortHz(hz)).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: x, y: labelY), anchor: .top)
        }
    }
}

// MARK: - Raw FFT bins

/// The most recent frame's raw magnitude bins on a logarithmic frequency axis.
///
/// Where the high-resolution bass stream is running its bins are used below
/// their usable passband, because they resolve the bottom two octaves that the
/// fast transform cannot: at 1024 points and 48 kHz a fast bin is 47 Hz wide,
/// which is wider than the whole 20 Hz third-octave band.
struct RtaBinsView: View {
    @ObservedObject var engine: RtaEngine
    let binFrame: RtaBinFrame?
    let color: Color
    let scale: RtaScale
    var minHz: Double = 20
    var showLabels: Bool = true

    private var maxHz: Double {
        guard let f = binFrame, f.sampleRateHz > 0 else { return 20000 }
        return Double(f.sampleRateHz) / 2
    }

    /// (frequency, dBFS) pairs in ascending frequency, bass stream first.
    private var points: [(hz: Double, db: Double)] {
        guard let f = binFrame else { return [] }
        var out: [(Double, Double)] = []
        // The decimated stream is only trustworthy inside its own passband;
        // above 0.4 x its rate the halfband cascade is already rolling off.
        let lfLimit = f.lfBins.isEmpty ? 0 : Double(f.lfRateHz) * 0.4
        if !f.lfBins.isEmpty {
            for k in 1..<f.lfBins.count {
                let hz = f.lfFrequency(ofBin: k)
                if hz > lfLimit { break }
                out.append((hz, engine.levelDB(f.lfBins[k])))
            }
        }
        for k in 1..<f.bins.count {
            let hz = f.frequency(ofBin: k)
            if hz <= lfLimit { continue }
            out.append((hz, engine.levelDB(f.bins[k])))
        }
        return out.map { (hz: $0.0, db: $0.1) }
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let labelHeight: CGFloat = showLabels ? 12 : 0
            let plot = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - labelHeight))
            guard plot.width > 4, plot.height > 4 else { return }

            drawGrid(ctx, plot, labelY: size.height - labelHeight + 1)

            let pts = points
            guard pts.count > 1, maxHz > minHz else { return }
            let logMin = log10(minHz), logMax = log10(maxHz)
            func x(_ hz: Double) -> CGFloat {
                CGFloat((log10(max(hz, minHz)) - logMin) / (logMax - logMin)) * plot.width
            }

            // One point per pixel column, taking the loudest bin that lands in
            // it: below a few hundred hertz that is one bin per column, above it
            // several, and a maximum is the only summary that keeps a tone from
            // disappearing between columns.
            let columns = Int(plot.width.rounded())
            var peak = [Double](repeating: -Double.infinity, count: max(columns, 1))
            for p in pts where p.hz >= minHz && p.hz <= maxHz {
                let c = min(max(Int(x(p.hz)), 0), peak.count - 1)
                peak[c] = max(peak[c], p.db)
            }

            var path = Path()
            var started = false
            var lastDB = scale.floorDB
            for c in 0..<peak.count {
                let db = peak[c].isFinite ? peak[c] : lastDB
                lastDB = db
                let y = plot.maxY - plot.height * CGFloat(scale.norm(db))
                let pt = CGPoint(x: plot.minX + CGFloat(c), y: y)
                if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
            }
            guard started else { return }

            var fill = path
            fill.addLine(to: CGPoint(x: plot.minX + CGFloat(peak.count - 1), y: plot.maxY))
            fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.45), color.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: plot.minY),
                endPoint: CGPoint(x: 0, y: plot.maxY)))
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
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
        let rate = s.sampleRateHz > 0 ? Double(s.sampleRateHz) : 48000
        let points = Double(1 << Int(options.fftOrder))
        let perChannelMs = points / rate * 1000 * Double(s.liveCount)
        let channels = s.liveCount == 1 ? "1 channel" : "\(s.liveCount) channels"
        return "\(channels), each refreshed every \(Int(perChannelMs.rounded())) ms"
    }
}

// MARK: - Inline strips

/// A labelled thumbnail for one channel, used on the dashboard grid.
struct RtaChannelThumbnail: View {
    @ObservedObject var engine: RtaEngine
    let title: String
    let channel: Int
    let tap: UInt8
    let color: Color
    let scale: RtaScale
    let showPeakHold: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            RtaBandsView(engine: engine,
                         frame: engine.frame(channel: channel, tap: tap),
                         color: color,
                         scale: scale,
                         showPeakHold: showPeakHold)
                .frame(height: 52)
        }
        .padding(6)
        .background(Color.black.opacity(0.18))
        .cornerRadius(6)
    }
}

/// The dashboard's analyser: every enabled output at once.
///
/// One request covers the whole grid, because the device rotates through the
/// selected set at constant CPU - eight outputs cost exactly what one does, and
/// only the refresh interval of any single channel lengthens.
struct DashboardSpectrumCard: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var engine: RtaEngine
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var analyserController: SpectrumAnalyserWindowController

    private var enabledOutputs: [Int] {
        (0..<vm.numOutputChannels).filter { vm.outputEnabled[$0] }
    }

    private var mask: UInt16 {
        enabledOutputs.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1)) }
    }

    private var scale: RtaScale {
        RtaScale(floorDB: settings.rtaFloorDB, ceilingDB: settings.rtaCeilingDB)
    }

    private func outputColor(_ idx: Int) -> Color {
        idx == vm.pdmOutputIndex ? ChannelPalette.pdm : ChannelPalette.output(idx)
    }

    private func outputName(_ idx: Int) -> String {
        let eqCh = vm.eqChannel(forOutput: idx)
        return eqCh < vm.channelNames.count ? vm.channelNames[eqCh] : "Out \(idx + 1)"
    }

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        if engine.supported, !enabledOutputs.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("SPECTRUM (OUTPUTS)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(engine.refreshDescription)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
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
                .padding(8)
                .frame(height: 32)
                .background(Color.white.opacity(0.01))

                Divider().overlay(Color.gray.opacity(0.1))

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(enabledOutputs, id: \.self) { idx in
                        RtaChannelThumbnail(engine: engine,
                                            title: outputName(idx),
                                            channel: idx,
                                            tap: RTA_TAP_OUTPUT,
                                            color: outputColor(idx),
                                            scale: scale,
                                            showPeakHold: settings.rtaShowPeakHold)
                    }
                }
                .padding(8)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            .rtaWatching(engine, RtaRequest(tap: RTA_TAP_OUTPUT, mask: mask))
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
                             showLabels: true)
                    .frame(height: 96)
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
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    func toggle(vm: DSPViewModel) {
        isVisible ? hide() : show(vm: vm)
    }
}

extension SpectrumAnalyserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Analyser window

/// The full-size analyser: the same engine as the inline strips, with the
/// channel selection, the two products (third-octave bands and raw bins) and
/// every option the device owns exposed in one place.
struct SpectrumAnalyserView: View {
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
        .rtaWatching(engine, request)
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
            Text("No spectrum analyser on this device")
                .font(.headline)
            Text(vm.isDeviceConnected
                 ? "The connected firmware does not carry the analyser. Update the firmware to use it."
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
            .help("Third-octave bands, or the raw FFT bins of the latest frame")

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
                RtaBinsView(engine: engine,
                            binFrame: engine.snapshot.bins,
                            color: channelColor(engine.snapshot.bins.map { Int($0.channel) } ?? binChannel),
                            scale: scale)
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
                                         showLabels: effectiveSelection.count <= 2)
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
                    get: { settings.rtaFftOrder },
                    set: { settings.rtaFftOrder = $0; pushOptions() }
                )) {
                    ForEach(availableOrders, id: \.self) { o in
                        Text("\(1 << o)").tag(o)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
            }
            .help("Points in the transform. More points resolve lower frequencies but take longer to fill, so each channel refreshes less often.")

            labelled("Bass detail") {
                Picker("", selection: Binding(
                    get: { settings.rtaLfMode },
                    set: { settings.rtaLfMode = $0; pushOptions() }
                )) {
                    if engine.caps.supportsLf(RTA_LF_OFF)  { Text("Off").tag(Int(RTA_LF_OFF)) }
                    if engine.caps.supportsLf(RTA_LF_512)  { Text("Fast").tag(Int(RTA_LF_512)) }
                    if engine.caps.supportsLf(RTA_LF_1024) { Text("Full").tag(Int(RTA_LF_1024)) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            .help("A second, decimated transform that resolves the bottom two octaves. Without it the lowest bands read empty, because no FFT bin lands inside them.")

            labelled("Averaging") {
                Picker("", selection: Binding(
                    get: { settings.rtaAvgMs },
                    set: { settings.rtaAvgMs = $0; pushOptions() }
                )) {
                    Text("Off").tag(0)
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
            Spacer()
            if engine.configRejected {
                Label("Device refused this configuration", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            } else if engine.caps.dynamicRangeDB > 0 {
                Text("\(engine.caps.dynamicRangeDB) dB range")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
