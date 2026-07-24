import SwiftUI

// MARK: - Test Signals Window Controller

class TestSignalsWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = TestSignalsView(vm: vm)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 428, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Test Signals"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 428, height: 480)
            window?.contentMaxSize = NSSize(width: 428, height: 980)
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

extension TestSignalsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Type Catalogue (labels, glyphs, fallback descriptors)

/// Host-side per-type presentation info.  Parameter ranges/defaults come from
/// the device caps (SiggenTypeDesc, spec §3.4) when available; `fallback`
/// mirrors the spec §2 table so the UI renders sensibly before the first
/// caps fetch.  Labels are friendlier than the 8-char wire names.
private struct SiggenTypeInfo {
    let id: UInt8
    let tileLabel: String        // short, under the glyph
    let displayName: String      // status line / transport
    let blurb: String            // one-line description
    let paramLabels: [String?]   // p1..p4 field labels
    let fallback: SiggenTypeDesc
}

private func pd(_ semantic: UInt8, _ min: Float, _ max: Float, _ def: Float) -> SiggenParamDesc {
    SiggenParamDesc(semantic: semantic, min: min, max: max, def: def)
}
private let pdUnused = SiggenParamDesc()

private func fallbackDesc(_ id: UInt8, _ timing: UInt8, _ params: [SiggenParamDesc]) -> SiggenTypeDesc {
    SiggenTypeDesc(id: id, name: "", timingModel: timing,
                   params: params + Array(repeating: pdUnused, count: 4 - params.count))
}

private let siggenTypeInfos: [SiggenTypeInfo] = [
    SiggenTypeInfo(id: SIGGEN_SINE, tileLabel: "Sine", displayName: "Sine",
                   blurb: "Pure tone, THD approx -139 dB",
                   paramLabels: ["Frequency", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_SINE, SIGGEN_TIMING_CONTINUOUS,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 1000)])),
    SiggenTypeInfo(id: SIGGEN_SQUARE, tileLabel: "Square", displayName: "Square wave",
                   blurb: "Band-limited (polyBLEP) square",
                   paramLabels: ["Frequency", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_SQUARE, SIGGEN_TIMING_CONTINUOUS,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 100)])),
    SiggenTypeInfo(id: SIGGEN_WHITE, tileLabel: "White", displayName: "White noise",
                   blurb: "Uniform white noise",
                   paramLabels: [nil, nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_WHITE, SIGGEN_TIMING_CONTINUOUS, [])),
    SiggenTypeInfo(id: SIGGEN_PINK, tileLabel: "Pink", displayName: "Pink noise",
                   blurb: "-3 dB/oct, level-safe normalized",
                   paramLabels: [nil, nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_PINK, SIGGEN_TIMING_CONTINUOUS, [])),
    SiggenTypeInfo(id: SIGGEN_SWEEP_LOG, tileLabel: "Log Swp", displayName: "Log sweep",
                   blurb: "Exponential sweep for room measurement",
                   paramLabels: ["Start", "End", nil, nil],
                   fallback: fallbackDesc(SIGGEN_SWEEP_LOG, SIGGEN_TIMING_SWEEP,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20000)])),
    SiggenTypeInfo(id: SIGGEN_SWEEP_LIN, tileLabel: "Lin Swp", displayName: "Linear sweep",
                   blurb: "Linear frequency sweep",
                   paramLabels: ["Start", "End", nil, nil],
                   fallback: fallbackDesc(SIGGEN_SWEEP_LIN, SIGGEN_TIMING_SWEEP,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20000)])),
    SiggenTypeInfo(id: SIGGEN_SWEEP_STEP, tileLabel: "Step Swp", displayName: "Stepped sweep",
                   blurb: "Discrete tones stepping up the band",
                   paramLabels: ["Start", "End", "Steps/octave", "Dwell"],
                   fallback: fallbackDesc(SIGGEN_SWEEP_STEP, SIGGEN_TIMING_SWEEP,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20000),
                                           pd(SIGGEN_PARAM_COUNT, 1, 24, 3),
                                           pd(SIGGEN_PARAM_MS, 20, 10000, 250)])),
    SiggenTypeInfo(id: SIGGEN_IMPULSE, tileLabel: "Impulse", displayName: "Impulse",
                   blurb: "Single-sample unit impulses",
                   paramLabels: ["Period", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_IMPULSE, SIGGEN_TIMING_PATTERN,
                                          [pd(SIGGEN_PARAM_MS, 10, 60000, 500)])),
    SiggenTypeInfo(id: SIGGEN_CLICKS_ALT, tileLabel: "Clicks", displayName: "Alternating clicks",
                   blurb: "Clicks with alternating polarity",
                   paramLabels: ["Period", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_CLICKS_ALT, SIGGEN_TIMING_PATTERN,
                                          [pd(SIGGEN_PARAM_MS, 10, 60000, 500)])),
    SiggenTypeInfo(id: SIGGEN_POLARITY, tileLabel: "Polarity", displayName: "Polarity pulse",
                   blurb: "Positive half-sine lobe per period",
                   paramLabels: ["Pulse width", "Period", nil, nil],
                   fallback: fallbackDesc(SIGGEN_POLARITY, SIGGEN_TIMING_PATTERN,
                                          [pd(SIGGEN_PARAM_MS, 1, 100, 5),
                                           pd(SIGGEN_PARAM_MS, 10, 60000, 500)])),
    SiggenTypeInfo(id: SIGGEN_TONE_BURST, tileLabel: "Burst", displayName: "Tone burst",
                   blurb: "Sine bursts with raised-cosine edges",
                   paramLabels: ["Frequency", "On cycles", "Off cycles", "Edge cycles"],
                   fallback: fallbackDesc(SIGGEN_TONE_BURST, SIGGEN_TIMING_PATTERN,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 1000),
                                           pd(SIGGEN_PARAM_CYCLES, 1, 1000, 8),
                                           pd(SIGGEN_PARAM_CYCLES, 0, 1000, 8),
                                           pd(SIGGEN_PARAM_CYCLES, 0, 100, 2)])),
    SiggenTypeInfo(id: SIGGEN_TONE_PAIR, tileLabel: "2-Tone", displayName: "Tone pair",
                   blurb: "IMD test pair (SMPTE / CCIF)",
                   paramLabels: ["Tone 1", "Tone 2", "Ratio A1/A2", nil],
                   fallback: fallbackDesc(SIGGEN_TONE_PAIR, SIGGEN_TIMING_CONTINUOUS,
                                          [pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 60),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 7000),
                                           pd(SIGGEN_PARAM_RATIO, 0.1, 10, 4)])),
    SiggenTypeInfo(id: SIGGEN_MULTITONE, tileLabel: "Multi", displayName: "Multitone",
                   blurb: "Log-spaced tones, Schroeder phases",
                   paramLabels: ["Tones", "Low", "High", nil],
                   fallback: fallbackDesc(SIGGEN_MULTITONE, SIGGEN_TIMING_CONTINUOUS,
                                          [pd(SIGGEN_PARAM_COUNT, 2, 16, 10),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20),
                                           pd(SIGGEN_PARAM_FREQ_HZ, 1, 30000, 20000)])),
    SiggenTypeInfo(id: SIGGEN_ISP, tileLabel: "ISP", displayName: "ISP test",
                   blurb: "Inter-sample-peak over patterns",
                   paramLabels: ["Pattern", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_ISP, SIGGEN_TIMING_CONTINUOUS,
                                          [pd(SIGGEN_PARAM_PATTERN, 0, 1, 0)])),
    SiggenTypeInfo(id: SIGGEN_CHANNEL_ID, tileLabel: "Chan ID", displayName: "Channel ID",
                   blurb: "Counted pentatonic blips per channel",
                   paramLabels: ["Blip length", nil, nil, nil],
                   fallback: fallbackDesc(SIGGEN_CHANNEL_ID, SIGGEN_TIMING_PATTERN,
                                          [pd(SIGGEN_PARAM_MS, 30, 1000, 120)])),
]

private func typeInfo(_ id: UInt8) -> SiggenTypeInfo {
    siggenTypeInfos.first { $0.id == id } ?? siggenTypeInfos[0]
}

// MARK: - Waveform Glyphs

/// Miniature hand-drawn waveform icon per signal type.  Each is a stroked
/// path sampled over the tile rect - deliberately playful, no SF Symbols.
private struct SiggenGlyph: Shape {
    let type: UInt8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let midY = rect.midY
        // Map t in 0..1, v in -1..1 into the rect.
        func pt(_ t: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + t * w, y: midY - v * h * 0.42)
        }
        func sampled(_ f: (CGFloat) -> CGFloat, points: Int = 64) {
            p.move(to: pt(0, f(0)))
            for i in 1...points {
                let t = CGFloat(i) / CGFloat(points)
                p.addLine(to: pt(t, f(t)))
            }
        }
        // Deterministic "random" for the noise glyphs.
        func jitter(_ t: CGFloat, _ scale: CGFloat) -> CGFloat {
            sin(t * 91.7 + 1.3) * 0.5 + sin(t * 173.3) * 0.35 + sin(t * 47.9 + 4.1) * 0.15 * scale
        }

        switch type {
        case SIGGEN_SINE:
            sampled { sin($0 * 2 * .pi * 2) }
        case SIGGEN_SQUARE:
            let period: CGFloat = 0.5
            p.move(to: pt(0, 1))
            var t: CGFloat = 0
            var high = true
            while t < 1 {
                let next = min(t + period / 2, 1)
                p.addLine(to: pt(next, high ? 1 : -1))
                if next < 1 { p.addLine(to: pt(next, high ? -1 : 1)) }
                high.toggle()
                t = next
            }
        case SIGGEN_WHITE:
            sampled({ jitter($0, 1) * 1.5 }, points: 40)
        case SIGGEN_PINK:
            sampled({ sin($0 * 2 * .pi * 1.3) * 0.7 + jitter($0, 1) * 0.5 }, points: 40)
        case SIGGEN_SWEEP_LOG:
            sampled { t in sin(2 * .pi * 1.2 * (pow(6, t) - 1)) }
        case SIGGEN_SWEEP_LIN:
            sampled { t in sin(2 * .pi * (1 + 4 * t) * t) }
        case SIGGEN_SWEEP_STEP:
            let steps = 4
            for i in 0..<steps {
                let t0 = CGFloat(i) / CGFloat(steps)
                let t1 = CGFloat(i + 1) / CGFloat(steps)
                let v = CGFloat(i) / CGFloat(steps - 1) * 1.6 - 0.8
                p.move(to: pt(t0, v))
                p.addLine(to: pt(t1 - 0.04, v))
            }
        case SIGGEN_IMPULSE:
            p.move(to: pt(0, 0)); p.addLine(to: pt(0.45, 0))
            p.addLine(to: pt(0.48, 1)); p.addLine(to: pt(0.51, 0))
            p.addLine(to: pt(1, 0))
        case SIGGEN_CLICKS_ALT:
            p.move(to: pt(0, 0)); p.addLine(to: pt(0.28, 0))
            p.addLine(to: pt(0.31, 1)); p.addLine(to: pt(0.34, 0))
            p.addLine(to: pt(0.64, 0))
            p.addLine(to: pt(0.67, -1)); p.addLine(to: pt(0.70, 0))
            p.addLine(to: pt(1, 0))
        case SIGGEN_POLARITY:
            sampled { t in
                (t > 0.3 && t < 0.7) ? sin((t - 0.3) / 0.4 * .pi) : 0
            }
        case SIGGEN_TONE_BURST:
            sampled { t in
                let window: CGFloat = (t > 0.15 && t < 0.55) ? sin((t - 0.15) / 0.4 * .pi) : 0
                return sin(t * 2 * .pi * 6) * window
            }
        case SIGGEN_TONE_PAIR:
            sampled { t in sin(t * 2 * .pi * 1.5) * 0.72 + sin(t * 2 * .pi * 11) * 0.28 }
        case SIGGEN_MULTITONE:
            sampled { t in
                (sin(t * 2 * .pi * 1.5) + sin(t * 2 * .pi * 3.7 + 1) + sin(t * 2 * .pi * 7.3 + 2)) / 2.6
            }
        case SIGGEN_ISP:
            // The +1 +1 -1 -1 sample staircase with the implied over-peak arc.
            p.move(to: pt(0.05, 0.7)); p.addLine(to: pt(0.45, 0.7))
            p.move(to: pt(0.55, -0.7)); p.addLine(to: pt(0.95, -0.7))
            p.move(to: pt(0.05, 0.7))
            p.addQuadCurve(to: pt(0.45, 0.7), control: pt(0.25, 1.15))
        case SIGGEN_CHANNEL_ID:
            for (i, c) in [0.18, 0.5, 0.82].enumerated() {
                let width = 0.11
                let center = CGFloat(c)
                let amp = 0.45 + CGFloat(i) * 0.27
                p.move(to: pt(center - width, 0))
                for s in 1...12 {
                    let t = center - width + CGFloat(s) / 12 * width * 2
                    let ph = (t - (center - width)) / (width * 2)
                    p.addLine(to: pt(t, sin(ph * .pi) * amp * sin(ph * .pi * 6)))
                }
            }
        default:
            sampled { sin($0 * 2 * .pi * 2) }
        }
        return p
    }
}

// MARK: - Test Signals View

struct TestSignalsView: View {
    @ObservedObject var vm: DSPViewModel

    /// Debounced live re-apply while the generator is running.
    @State private var applyWork: DispatchWorkItem?
    @State private var pulsing = false

    private let statusTimer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    private var draft: SiggenConfig { vm.siggenDraft }
    private var running: Bool { vm.siggenStatus.isRunning }
    private var info: SiggenTypeInfo { typeInfo(draft.signalType) }
    private var desc: SiggenTypeDesc { vm.siggenTypeDesc(for: draft.signalType) ?? info.fallback }
    private var controlsEnabled: Bool { vm.isDeviceConnected && vm.siggenSupported }

    /// Output channel count to render chips for (device caps when known).
    private var outputCount: Int {
        vm.siggenCaps.outputChannels > 0 ? Int(vm.siggenCaps.outputChannels) : vm.numOutputChannels
    }

    private var startBlocker: String? {
        if !vm.isDeviceConnected { return "No device connected" }
        if !vm.siggenSupported { return "Firmware has no signal generator" }
        if draft.channelMask == 0 { return "Select at least one output" }
        if desc.timingModel == SIGGEN_TIMING_SWEEP && draft.durationMS == 0 {
            return "Sweep length must be greater than 0"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if vm.isDeviceConnected && !vm.siggenSupported {
                unsupportedNotice
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        signalSection
                            .padding(.top, 14)
                        Divider().padding(.horizontal, 16)
                        outputsSection
                        Divider().padding(.horizontal, 16)
                        levelSection
                        parametersSection
                        timingSection
                        Divider().padding(.horizontal, 16)
                        optionsSection
                            .padding(.bottom, 14)
                    }
                }
            }

            Divider()
            transportBar
        }
        .frame(minWidth: 428, maxWidth: 428)
        .onAppear {
            pulsing = true
            refreshStatus()
        }
        .onReceive(statusTimer) { _ in
            if controlsEnabled && running { refreshStatus() }
        }
        .onChange(of: vm.selectedDevice) { _ in
            // A pending debounced apply belongs to the previously selected
            // device; never deliver it to the new one.
            applyWork?.cancel()
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Test Signals")
                    .font(.system(size: 14, weight: .semibold))
                Text("Onboard measurement signal generator")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stateLabelAndColor: (String, Color) {
        switch vm.siggenStatus.state {
        case SIGGEN_STATE_FADE_IN:  return ("Fading in", .green)
        case SIGGEN_STATE_RUN:      return ("Running", .green)
        case SIGGEN_STATE_GAP:      return ("Gap", .yellow)
        case SIGGEN_STATE_FADE_OUT: return ("Fading out", .orange)
        default:                    return ("Idle", .secondary)
        }
    }

    private var statusPill: some View {
        let (label, color) = stateLabelAndColor
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(running && pulsing ? 1.0 : 0.75)
                .animation(running
                           ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                           : .default,
                           value: pulsing && running)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(running ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .overlay(Capsule().stroke(color.opacity(running ? 0.5 : 0.2), lineWidth: 1))
        )
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("Signal generator not available")
                .font(.system(size: 13, weight: .semibold))
            Text("The connected firmware does not include the onboard test signal generator. Update the DSPi firmware to use this tool.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Signal type grid

    private var signalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIGNAL")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                      spacing: 6) {
                ForEach(siggenTypeInfos, id: \.id) { ti in
                    signalTile(ti)
                }
            }

            Text(info.blurb)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func signalTile(_ ti: SiggenTypeInfo) -> some View {
        let selected = draft.signalType == ti.id
        return Button(action: { selectType(ti.id) }) {
            VStack(spacing: 4) {
                SiggenGlyph(type: ti.id)
                    .stroke(selected ? Color.accentColor : Color.secondary,
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                Text(ti.tileLabel)
                    .font(.system(size: 8, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                          ? Color.accentColor.opacity(0.16)
                          : Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor.opacity(0.7) : Color.gray.opacity(0.2),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .help(ti.blurb)
    }

    // MARK: Outputs

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OUTPUTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("All") {
                    updateDraft { $0.channelMask = allOutputsMask }
                }
                Button("None") {
                    updateDraft { $0.channelMask = 0; $0.invertMask = 0 }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.accentColor)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(0..<outputCount, id: \.self) { o in
                    outputChip(o)
                }
            }

            Text("Click to select, click again to invert polarity (\u{00F8}). Dimmed outputs are disabled in the matrix mixer and stay silent.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    private var allOutputsMask: UInt16 {
        vm.siggenCaps.validChannelMask != 0
            ? vm.siggenCaps.validChannelMask
            : UInt16((1 << outputCount) - 1)
    }

    private func outputName(_ o: Int) -> String {
        let eqCh = vm.eqChannel(forOutput: o)
        return eqCh < vm.channelNames.count ? vm.channelNames[eqCh] : "Out \(o + 1)"
    }

    private func outputChip(_ o: Int) -> some View {
        let bit = UInt16(1) << UInt16(o)
        let selected = draft.channelMask & bit != 0
        let inverted = draft.invertMask & bit != 0
        let matrixEnabled = o < vm.outputEnabled.count ? vm.outputEnabled[o] : true
        let walkActive = running && vm.siggenStatus.activeChannel == UInt8(o)

        return Button(action: { cycleOutput(o) }) {
            HStack(spacing: 4) {
                Text(outputName(o))
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1)
                if inverted {
                    Text("\u{00F8}")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected
                          ? Color.accentColor.opacity(0.18)
                          : Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(walkActive ? Color.green
                            : (selected ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.2)),
                            lineWidth: walkActive ? 1.5 : 1)
            )
            .opacity(matrixEnabled ? 1.0 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .help(matrixEnabled
              ? "Click: on \u{2192} inverted \u{2192} off"
              : "Output disabled in the matrix mixer - selected but silent until enabled")
    }

    private func cycleOutput(_ o: Int) {
        let bit = UInt16(1) << UInt16(o)
        updateDraft { d in
            if d.channelMask & bit == 0 {
                d.channelMask |= bit                        // off -> on
            } else if d.invertMask & bit == 0 {
                d.invertMask |= bit                         // on -> inverted
            } else {
                d.channelMask &= ~bit                       // inverted -> off
                d.invertMask &= ~bit
            }
        }
    }

    // MARK: Level

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LEVEL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                ValueField(label: "dB", value: draft.levelDB, width: 60, scrollStep: 1) { val in
                    updateDraft { $0.levelDB = min(max(val, SIGGEN_LEVEL_MIN_DB), SIGGEN_LEVEL_MAX_DB) }
                }
            }

            CustomSlider(
                value: Binding(
                    get: { draft.levelDB },
                    set: { val in updateDraft { $0.levelDB = min(max(val, -80), 0) } }
                ),
                range: -80...0
            )
            .disabled(!controlsEnabled)

            Text("Peak level in dBFS. Output trim, master volume and mute still apply downstream.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Parameters

    private var usedParamIndices: [Int] {
        (0..<4).filter { desc.params[$0].isUsed }
    }

    @ViewBuilder
    private var parametersSection: some View {
        if !usedParamIndices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PARAMETERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                if draft.signalType == SIGGEN_ISP {
                    ispPatternPicker
                } else {
                    ForEach(usedParamIndices, id: \.self) { i in
                        paramRow(i)
                    }
                }

                if draft.signalType == SIGGEN_TONE_PAIR {
                    tonePairPresets
                }
                if draft.signalType == SIGGEN_MULTITONE && vm.siggenCaps.multitoneMax > 0 {
                    Text("Up to \(vm.siggenCaps.multitoneMax) tones on this device.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func paramValue(_ i: Int) -> Float {
        switch i {
        case 0: return draft.p1
        case 1: return draft.p2
        case 2: return draft.p3
        default: return draft.p4
        }
    }

    private func setParamValue(_ i: Int, _ v: Float) {
        let pdesc = desc.params[i]
        let clamped = min(max(v, pdesc.min), pdesc.max == 0 ? v : pdesc.max)
        updateDraft { d in
            switch i {
            case 0: d.p1 = clamped
            case 1: d.p2 = clamped
            case 2: d.p3 = clamped
            default: d.p4 = clamped
            }
        }
    }

    private func unitLabel(_ semantic: UInt8) -> String {
        switch semantic {
        case SIGGEN_PARAM_FREQ_HZ: return "Hz"
        case SIGGEN_PARAM_MS:      return "ms"
        case SIGGEN_PARAM_CYCLES:  return "cyc"
        case SIGGEN_PARAM_RATIO:   return "\u{00D7}"
        default:                   return ""
        }
    }

    private func paramRow(_ i: Int) -> some View {
        let pdesc = desc.params[i]
        let label = i < info.paramLabels.count ? (info.paramLabels[i] ?? "p\(i + 1)") : "p\(i + 1)"
        let isWhole = pdesc.semantic == SIGGEN_PARAM_COUNT || pdesc.semantic == SIGGEN_PARAM_CYCLES
        return HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            ValueField(
                label: unitLabel(pdesc.semantic),
                value: paramValue(i),
                width: 66,
                scrollStep: isWhole ? 1 : (pdesc.semantic == SIGGEN_PARAM_RATIO ? 0.1 : 1),
                minValue: pdesc.min,
                maxDecimals: isWhole ? 0 : (pdesc.semantic == SIGGEN_PARAM_RATIO ? 2 : 1),
                stripTrailingZeros: true
            ) { setParamValue(i, isWhole ? $0.rounded() : $0) }
            .disabled(!controlsEnabled)
        }
    }

    private var ispPatternPicker: some View {
        Picker("", selection: Binding(
            get: { Int(draft.p1.rounded()) },
            set: { v in updateDraft { $0.p1 = Float(v) } }
        )) {
            Text("fs/4 · +3.01 dBTP").tag(0)
            Text("fs/6 · +1.25 dBTP").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!controlsEnabled)
        .help("Sample-peak-normalized sequences with a known inter-sample true-peak over. Set the level at or below the headroom the over should fit into.")
    }

    private var tonePairPresets: some View {
        HStack(spacing: 8) {
            Text("Presets:")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Button("SMPTE 60/7k") {
                updateDraft { $0.p1 = 60; $0.p2 = 7000; $0.p3 = 4 }
            }
            Button("CCIF 19k/20k") {
                updateDraft { $0.p1 = 19000; $0.p2 = 20000; $0.p3 = 1 }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.accentColor)
        .disabled(!controlsEnabled)
    }

    // MARK: Timing

    private var walkEnabled: Bool {
        draft.flags & SIGGEN_FLAG_WALK != 0 || draft.signalType == SIGGEN_CHANNEL_ID
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIMING")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            switch desc.timingModel {
            case SIGGEN_TIMING_SWEEP:
                timingRow(label: "Sweep length", caption: nil) {
                    secondsField(min: 0.01)
                }
                timingRow(label: "Repeat", caption: "0 = repeat forever") {
                    repeatField
                }
                timingRow(label: "Gap between sweeps", caption: nil) {
                    gapField
                }
            case SIGGEN_TIMING_PATTERN:
                timingRow(label: "Repeat",
                          caption: draft.signalType == SIGGEN_CHANNEL_ID
                              ? "Passes over the selected outputs. 0 = forever"
                              : "Pattern periods. 0 = repeat forever") {
                    repeatField
                }
                timingRow(label: "Extra gap per period", caption: nil) {
                    gapField
                }
            default:
                if walkEnabled {
                    timingRow(label: "Dwell per channel", caption: "0 = 2 s default") {
                        secondsField(min: 0)
                    }
                    timingRow(label: "Passes", caption: "Full passes over the outputs. 0 = forever") {
                        repeatField
                    }
                } else {
                    timingRow(label: "Duration", caption: "0 = play until stopped") {
                        secondsField(min: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func timingRow<Field: View>(label: String, caption: String?,
                                        @ViewBuilder field: () -> Field) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if let caption = caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            field()
                .disabled(!controlsEnabled)
        }
    }

    private func secondsField(min minSeconds: Float) -> some View {
        ValueField(label: "s", value: Float(draft.durationMS) / 1000, width: 66,
                   scrollStep: 0.5, minValue: minSeconds, maxDecimals: 2,
                   stripTrailingZeros: true) { val in
            updateDraft { $0.durationMS = UInt32(max(minSeconds, val) * 1000) }
        }
    }

    private var repeatField: some View {
        ValueField(label: "", value: Float(draft.repeatCount), width: 66,
                   scrollStep: 1, minValue: 0, maxDecimals: 0) { val in
            updateDraft { $0.repeatCount = UInt16(min(max(val.rounded(), 0), 65535)) }
        }
    }

    private var gapField: some View {
        ValueField(label: "ms", value: Float(draft.gapMS), width: 66,
                   scrollStep: 50, minValue: 0, maxDecimals: 0) { val in
            updateDraft { $0.gapMS = UInt16(min(max(val.rounded(), 0), 65535)) }
        }
    }

    // MARK: Options

    private var isNoise: Bool {
        draft.signalType == SIGGEN_WHITE || draft.signalType == SIGGEN_PINK
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPTIONS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            optionRow(title: "Bypass output EQ (RAW)",
                      caption: "Skips crossover and PEQ on the selected outputs. Trim, master volume, mute and delay still apply.",
                      isOn: Binding(
                          get: { draft.flags & SIGGEN_FLAG_RAW != 0 },
                          set: { on in updateDraft { $0.flags = on ? $0.flags | SIGGEN_FLAG_RAW : $0.flags & ~SIGGEN_FLAG_RAW } }
                      ))

            if isNoise {
                optionRow(title: "Decorrelate channels",
                          caption: "Independent noise per output instead of one copied signal.",
                          isOn: Binding(
                              get: { draft.flags & SIGGEN_FLAG_DECORR != 0 },
                              set: { on in updateDraft { $0.flags = on ? $0.flags | SIGGEN_FLAG_DECORR : $0.flags & ~SIGGEN_FLAG_DECORR } }
                          ))
            }

            if draft.signalType == SIGGEN_CHANNEL_ID {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Walk outputs one at a time")
                            .font(.system(size: 12, weight: .medium))
                        Text("Channel ID always walks: each output plays its channel number as counted blips.")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(true))
                        .toggleStyle(.switch)
                        .disabled(true)
                }
            } else {
                optionRow(title: "Walk outputs one at a time",
                          caption: "Plays the selected outputs sequentially instead of together.",
                          isOn: Binding(
                              get: { draft.flags & SIGGEN_FLAG_WALK != 0 },
                              set: { on in updateDraft { $0.flags = on ? $0.flags | SIGGEN_FLAG_WALK : $0.flags & ~SIGGEN_FLAG_WALK } }
                          ))
            }
        }
        .padding(.horizontal, 16)
    }

    private func optionRow(title: String, caption: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .disabled(!controlsEnabled)
        }
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transportTitle)
                    .font(.system(size: 11, weight: .medium))
                Text(transportDetail)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Spacer()

            if running {
                Button(action: { stop(immediate: true) }) {
                    Image(systemName: "stop.fill")
                }
                .help("Stop immediately, no fade")

                Button(action: { stop(immediate: false) }) {
                    Label("Stop", systemImage: "stop.circle")
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(startBlocker != nil)
                .help(startBlocker ?? "Start the generator")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transportTitle: String {
        if running {
            let activeType = typeInfo(vm.siggenStatus.signalType)
            return "\(stateLabelAndColor.0) \u{00B7} \(activeType.displayName)"
        }
        if let blocker = startBlocker, vm.isDeviceConnected, vm.siggenSupported {
            return blocker
        }
        return "Ready \u{00B7} \(info.displayName)"
    }

    private var transportDetail: String {
        let st = vm.siggenStatus
        if running {
            var parts: [String] = [formatElapsed(st.elapsedMS)]
            if st.currentFreq > 0 { parts.append(formatFreq(st.currentFreq)) }
            if st.cyclesDone > 0 { parts.append("cycle \(st.cyclesDone)") }
            if st.activeChannel != 0xFF { parts.append(outputName(Int(st.activeChannel))) }
            parts.append("edits apply live")
            return parts.joined(separator: " \u{00B7} ")
        }
        switch st.stopReason {
        case SIGGEN_STOP_COMPLETED: return "Finished after \(formatElapsed(st.elapsedMS))"
        case SIGGEN_STOP_HOST:      return "Stopped"
        case SIGGEN_STOP_PRESET:    return "Stopped by preset load"
        default:
            return "\(draft.channelMask.nonzeroBitCount) output\(draft.channelMask.nonzeroBitCount == 1 ? "" : "s") \u{00B7} peak \(String(format: "%.1f", draft.levelDB)) dBFS"
        }
    }

    private func formatElapsed(_ ms: UInt32) -> String {
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1f s", s) }
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    private func formatFreq(_ hz: Float) -> String {
        hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    // MARK: Actions

    private func selectType(_ id: UInt8) {
        let td = vm.siggenTypeDesc(for: id) ?? typeInfo(id).fallback
        updateDraft { d in
            d.signalType = id
            d.p1 = td.params[0].def
            d.p2 = td.params[1].def
            d.p3 = td.params[2].def
            d.p4 = td.params[3].def
            switch td.timingModel {
            case SIGGEN_TIMING_SWEEP:
                d.durationMS = 5000
                d.repeatCount = 0
                d.gapMS = 0
            case SIGGEN_TIMING_PATTERN:
                d.durationMS = 0
                d.repeatCount = 0
                d.gapMS = 0
            default:
                d.durationMS = 0
                d.repeatCount = 0
                d.gapMS = 0
            }
        }
    }

    /// Mutate the draft and, when the generator is running, re-apply it after
    /// a short debounce (the firmware restarts with a fade on SET_CONFIG).
    private func updateDraft(_ mutate: (inout SiggenConfig) -> Void) {
        var d = vm.siggenDraft
        mutate(&d)
        guard d != vm.siggenDraft else { return }
        vm.siggenDraft = d
        scheduleLiveApply()
    }

    private func scheduleLiveApply() {
        applyWork?.cancel()
        guard running, controlsEnabled else { return }
        // Capture the device this edit was made for; the onChange cancel only
        // covers a live view, not a work item orphaned by closing the window.
        let device = vm.selectedDevice
        let work = DispatchWorkItem {
            guard vm.selectedDevice == device else { return }
            let cfg = vm.siggenDraft
            guard vm.siggenStatus.isRunning, startBlocker == nil else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                vm.siggenSetConfig(cfg)
                vm.fetchSiggenStatus()
            }
        }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func start() {
        let cfg = vm.siggenDraft
        DispatchQueue.global(qos: .userInitiated).async {
            vm.siggenStart(with: cfg)
        }
    }

    private func stop(immediate: Bool) {
        applyWork?.cancel()
        DispatchQueue.global(qos: .userInitiated).async {
            vm.siggenStop(immediate: immediate)
        }
    }

    private func refreshStatus() {
        guard vm.isDeviceConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            vm.fetchSiggenStatus()
        }
    }
}
