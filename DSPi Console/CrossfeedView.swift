import SwiftUI

// MARK: - Crossfeed Window Controller

class CrossfeedWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = CrossfeedView(vm: vm, crossfeed: vm.crossfeed).onboardingHint("crossfeed")

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 470),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Crossfeed"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 740, height: 460)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension CrossfeedWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Crossfeed Presets

private struct CrossfeedPreset {
    let name: String
    let description: String
    let freq: Float
    let feed: Float
}

private let crossfeedPresets: [CrossfeedPreset] = [
    CrossfeedPreset(name: "Default", description: "700 Hz / 4.5 dB - Balanced, most popular", freq: 700, feed: 4.5),
    CrossfeedPreset(name: "Chu Moy", description: "700 Hz / 6.0 dB - Stronger spatial effect", freq: 700, feed: 6.0),
    CrossfeedPreset(name: "Jan Meier", description: "650 Hz / 9.5 dB - Natural speaker-like", freq: 650, feed: 9.5),
    CrossfeedPreset(name: "Custom", description: "User-defined parameters", freq: 700, feed: 4.5),
]

// MARK: - Crossfeed View

struct CrossfeedView: View {
    @ObservedObject var vm: DSPViewModel
    /// Observed separately from `vm` so a slider drag invalidates this
    /// window and nothing else; see ToolParameters.swift.
    @ObservedObject var crossfeed: CrossfeedParameters
    /// What the curve follows during a drag; see `GraphLive`.
    @State private var graphLive = GraphLive<CrossfeedGraphKey>()

    private var isCustom: Bool { crossfeed.preset == 3 }

    /// Number of stereo output pairs (S/PDIF instances): 2 on RP2040, 4 on RP2350.
    /// Pair p covers output slots 2p / 2p+1; the mono PDM sub is never crossfed.
    private var pairCount: Int { vm.numOutputSlots }

    /// The per-pair mask (cmds 0xFC/0xFD) shipped in wire format V20; hide the
    /// selector on older firmware, which crossfeeds a fixed set of outputs.
    private var showPairMask: Bool { vm.firmwareSupportsCrossfeedMask }

    /// Mask with every valid pair bit set, for the "All pairs" preset.
    private var allPairsMask: UInt8 { pairCount >= 8 ? 0xFF : UInt8((1 << pairCount) - 1) }

    /// Display name for one channel of output pair `p` (left = 0, right = 1).
    /// Falls back to a generic label before channel names are fetched.
    private func pairChannelName(_ p: Int, right: Bool) -> String {
        let idx = vm.chOut1 + 2 * p + (right ? 1 : 0)
        return idx < vm.channelNames.count ? vm.channelNames[idx] : "Out \(2 * p + (right ? 1 : 0) + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            // Two columns of the sections the other tool windows stack. The
            // graph sits over the presets that set it; the right column holds
            // the custom parameters, the time delay and where crossfeed applies.
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    crossfeedGraph
                    Divider()
                    presetSection
                }
                .toolColumn()

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    parameterSection
                    Divider()
                    itdSection
                    if showPairMask {
                        Divider()
                        outputPairSection
                    }
                }
                .toolColumn()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Crossfeed")
                    .font(.system(size: 14, weight: .semibold))
                Text("BS2B Bauer Stereophonic-to-Binaural")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.crossfeedEnabled },
                set: { vm.setCrossfeed($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Crossfeed Response Graph

    private var crossfeedGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FREQUENCY RESPONSE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                // In its own hosting view, so following a drag re-lays out the
                // graph alone rather than the whole window.
                LiveGraphHost(flexibleHeight: true) {
                    CrossfeedGraphPane(
                        base: .init(freq: crossfeed.freq, feed: crossfeed.feed),
                        isEnabled: vm.crossfeedEnabled, live: graphLive)
                    .padding(8)
                }
            }
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRESET")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ForEach(0..<crossfeedPresets.count, id: \.self) { i in
                presetRow(index: i, preset: crossfeedPresets[i])
            }
        }
    }

    private func presetRow(index: Int, preset: CrossfeedPreset) -> some View {
        Button(action: {
            vm.setCrossfeedPreset(index)
        }) {
            HStack(spacing: 10) {
                Image(systemName: crossfeed.preset == index ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(crossfeed.preset == index ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(preset.description)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vm.isDeviceConnected)
    }

    // MARK: - Parameter Section

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PARAMETERS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // Cutoff Frequency
            ParameterRow(
                title: "Cutoff Frequency",
                unit: "Hz",
                value: crossfeed.freq,
                range: 500...2000,
                scrollStep: 0.1,
                maxDecimals: 1,
                isEnabled: vm.isDeviceConnected,
                caption: "Simulates head shadow lowpass cutoff. Lower = more bass crossfeed. Typical: 650-700 Hz.",
                live: { v in
                    let c = min(max(v, 500), 2000)
                    vm.sendFloatParamToDevice(REQ_SET_CROSSFEED_FREQ, c)
                    graphLive.set(.freq, c)
                },
                set: { val in
                    vm.setCrossfeedFreq(min(max(val, 500), 2000))
                    if !isCustom { vm.setCrossfeedPreset(3) }
                }
            )

            Divider()

            // Feed Level
            ParameterRow(
                title: "Feed Level",
                unit: "dB",
                value: crossfeed.feed,
                range: 0...15,
                scrollStep: 0.1,
                maxDecimals: 1,
                isEnabled: vm.isDeviceConnected,
                caption: "Crossfeed attenuation below direct signal. Higher = more crossfeed. Typical: 4.5-9.5 dB.",
                live: { v in
                    let c = min(max(v, 0), 15)
                    vm.sendFloatParamToDevice(REQ_SET_CROSSFEED_FEED, c)
                    graphLive.set(.feed, c)
                },
                set: { val in
                    vm.setCrossfeedFeed(min(max(val, 0), 15))
                    if !isCustom { vm.setCrossfeedPreset(3) }
                }
            )
        }
        .opacity(isCustom ? 1.0 : 0.5)
    }

    // MARK: - ITD Section

    private var itdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interaural Time Delay")
                        .font(.system(size: 12, weight: .medium))
                    Text("Simulates ~220 \u{00B5}s path difference via all-pass filter")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { crossfeed.itd },
                    set: { vm.setCrossfeedITD($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!vm.isDeviceConnected)
            }
        }
    }

    // MARK: - Output Pair Selection

    private var outputPairSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OUTPUT PAIRS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("All pairs") {
                        vm.setCrossfeedMask(allPairsMask)
                    }
                    Button("Pair 1 only (Headphones)") {
                        vm.setCrossfeedMask(0x01)
                    }
                    Button("None") {
                        vm.setCrossfeedMask(0x00)
                    }
                } label: {
                    Text("Presets")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!vm.isDeviceConnected)
            }

            Text("Crossfeed only the stereo output pairs feeding headphones. Speaker pairs stay bit-accurate. The mono sub is never crossfed.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(0..<pairCount, id: \.self) { p in
                    pairChip(
                        pair: p,
                        on: crossfeed.outputMask & (UInt8(1) << p) != 0
                    ) {
                        vm.setCrossfeedOutputPair(p, enabled: crossfeed.outputMask & (UInt8(1) << p) == 0)
                    }
                }
            }
        }
    }

    private func pairChip(pair p: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(p + 1)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundColor(on ? .white : .primary.opacity(0.6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(on ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(on ? 0 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("\(pairChannelName(p, right: false)) / \(pairChannelName(p, right: true))")
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }
}

// MARK: - Crossfeed Curve Visualization

enum CrossfeedGraphKey: Hashable { case freq, feed }

/// The response curve, resolving live overrides over the committed values.
/// Lives in a `LiveGraphHost`, so a live update costs the layout of this view alone.
private struct CrossfeedGraphPane: View {
    struct Base: Equatable { var freq, feed: Float }
    let base: Base
    let isEnabled: Bool
    @ObservedObject var live: GraphLive<CrossfeedGraphKey>

    var body: some View {
        CrossfeedCurveView(
            freq: live[.freq, or: base.freq],
            feed: live[.feed, or: base.feed],
            isEnabled: isEnabled
        )
        .onChange(of: base) { _ in live.clear() }
    }
}

private struct CrossfeedCurveView: View {
    let freq: Float
    let feed: Float
    let isEnabled: Bool

    private let minFreq: CGFloat = 20.0
    private let maxFreq: CGFloat = 20000.0
    private let sampleRate: Float = 48000.0

    // Compute complementary crossfeed and direct path frequency responses
    private func computeCurves() -> (crossfeed: [CGPoint], direct: [CGPoint]) {
        let fc = freq
        // Complementary gain: level_ratio = 10^(feed_dB/20), G = 1/(1+level_ratio)
        let levelRatio = powf(10.0, feed / 20.0)
        let G = 1.0 / (1.0 + levelRatio)

        // Lowpass coefficient
        let lpX = expf(-2.0 * .pi * fc / sampleRate)
        let lpA0 = G * (1.0 - lpX)

        var crossfeedPoints: [CGPoint] = []
        var directPoints: [CGPoint] = []

        let numPoints = 100
        for i in 0..<numPoints {
            let t = Float(i) / Float(numPoints - 1)
            let f = 20.0 * powf(1000.0, t) // 20 Hz to 20 kHz

            let omega = 2.0 * .pi * f / sampleRate

            // Lowpass H(z) = a0 / (1 - b1*z^-1)
            let lpRealDen = 1.0 - lpX * cosf(omega)
            let lpImagDen = lpX * sinf(omega)
            let lpDenMag2 = lpRealDen * lpRealDen + lpImagDen * lpImagDen
            let lpReal = (lpA0 * lpRealDen) / lpDenMag2
            let lpImag = (-lpA0 * lpImagDen) / lpDenMag2
            let lpMag = sqrtf(lpReal * lpReal + lpImag * lpImag)
            let lpDB = 20.0 * log10f(max(lpMag, 1e-10))

            // Direct = 1 - Lowpass (complementary)
            let directReal = 1.0 - lpReal
            let directImag = -lpImag
            let directMag = sqrtf(directReal * directReal + directImag * directImag)
            let directDB = 20.0 * log10f(max(directMag, 1e-10))

            crossfeedPoints.append(CGPoint(x: CGFloat(f), y: CGFloat(lpDB)))
            directPoints.append(CGPoint(x: CGFloat(f), y: CGFloat(directDB)))
        }

        return (crossfeedPoints, directPoints)
    }

    private func xPos(_ freq: CGFloat, w: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(freq)
        return CGFloat((logVal - logMin) / (logMax - logMin)) * w
    }

    private func yPos(_ gain: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> CGFloat {
        let range = domainMax - domainMin
        let normalized = (gain - domainMin) / range
        return h - (normalized * h)
    }

    var body: some View {
        let curves = computeCurves()
        let allGains = curves.crossfeed.map { $0.y } + curves.direct.map { $0.y }
        let minGain = allGains.min() ?? -30
        let maxGain = allGains.max() ?? 5

        let dataRange = maxGain - minGain
        let minVisualRange: CGFloat = 10.0
        let visualRange = max(dataRange, minVisualRange)
        let padding = visualRange * 0.2
        let domainMin = minGain - padding
        let domainMax = maxGain + padding

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                drawGrid(w: w, h: h, domainMin: domainMin, domainMax: domainMax)
                drawLabels(w: w, h: h, domainMin: domainMin, domainMax: domainMax)

                if isEnabled {
                    // Crossfeed path (opposite channel)
                    Path { path in
                        for (i, p) in curves.crossfeed.enumerated() {
                            let x = xPos(p.x, w: w)
                            let y = yPos(p.y, h: h, domainMin: domainMin, domainMax: domainMax)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    // Direct path (same channel)
                    Path { path in
                        for (i, p) in curves.direct.enumerated() {
                            let x = xPos(p.x, w: w)
                            let y = yPos(p.y, h: h, domainMin: domainMin, domainMax: domainMax)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    // Legend
                    VStack(alignment: .leading, spacing: 2) {
                        legendItem(color: .accentColor, label: "Direct")
                        legendItem(color: .orange, label: "Crossfeed")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                    .cornerRadius(4)
                    .position(x: w - 40, y: 18)
                } else {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .position(x: w / 2, y: h / 2)
                }
            }
            .clipped()
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 10, height: 2)
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.primary)
        }
    }

    private func drawGrid(w: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> some View {
        Path { path in
            let range = domainMax - domainMin
            let step: CGFloat = range > 40 ? 10 : 5
            let start = ceil(domainMin / step) * step

            var current = start
            while current <= domainMax {
                let y = yPos(current, h: h, domainMin: domainMin, domainMax: domainMax)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: w, y: y))
                current += step
            }

            for f in [100.0, 1000.0, 10000.0] {
                let x = xPos(CGFloat(f), w: w)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: h))
            }
        }
        .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
    }

    private func drawLabels(w: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> some View {
        ZStack {
            ForEach([100, 1000, 10000], id: \.self) { f in
                Text(f == 1000 ? "1k" : (f == 10000 ? "10k" : "\(f)"))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: xPos(CGFloat(f), w: w), y: h - 5)
            }

            let range = domainMax - domainMin
            let step: CGFloat = range > 40 ? 10 : 5
            let start = ceil(domainMin / step) * step
            let steps = stride(from: start, through: domainMax, by: Double(step)).map { CGFloat($0) }

            ForEach(steps, id: \.self) { gain in
                Text("\(Int(gain))")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: 10, y: yPos(gain, h: h, domainMin: domainMin, domainMax: domainMax))
            }
        }
    }
}
