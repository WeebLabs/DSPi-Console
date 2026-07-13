import SwiftUI

// MARK: - Psychoacoustic Bass Window Controller

class PsychoacousticBassWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = PsychoacousticBassView(vm: vm)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Psychoacoustic Bass"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 380, height: 360)
            window?.contentMaxSize = NSSize(width: 380, height: 900)
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

extension PsychoacousticBassWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Starting Points (spec §6)

private struct PsybassStartingPoint {
    let name: String
    let detail: String
    let cutoff: Float
    let harmonics: Float
    let drive: Float
    let character: Float
    let original: Float
}

private let psybassStartingPoints: [PsybassStartingPoint] = [
    PsybassStartingPoint(name: "Bookshelf speakers",  detail: "Gentle low-end help",       cutoff: 60,  harmonics: 0,  drive: 6,  character: 50, original: 0),
    PsybassStartingPoint(name: "Small Bluetooth",     detail: "Portable speaker",           cutoff: 100, harmonics: 3,  drive: 9,  character: 40, original: -12),
    PsybassStartingPoint(name: "Laptop / tablet",     detail: "Tiny drivers, protect them", cutoff: 180, harmonics: 6,  drive: 12, character: 50, original: -24),
    PsybassStartingPoint(name: "Headphone bass feel", detail: "Extra sub sensation",        cutoff: 45,  harmonics: -3, drive: 6,  character: 30, original: 0),
]

// MARK: - Psychoacoustic Bass View

struct PsychoacousticBassView: View {
    @ObservedObject var vm: DSPViewModel

    /// Output channels exposed in the mask grid (5 on RP2040, 9 on RP2350).
    private var outputCount: Int { vm.numOutputChannels }

    /// The whole feature ships in wire format V23; hide the interactive body on
    /// older firmware and show an upgrade note instead.
    private var supported: Bool { vm.firmwareSupportsPsybass }

    /// Mask with every valid output bit set.
    private var allOutputsMask: UInt16 {
        outputCount >= 16 ? 0xFFFF : UInt16((1 << outputCount) - 1)
    }

    /// All outputs except the PDM sub (harmonics on a real-bass channel are
    /// counterproductive, so this is the recommended default).
    private var excludeSubMask: UInt16 {
        allOutputsMask & ~(UInt16(1) << vm.pdmOutputIndex)
    }

    /// Display name for output channel `out` (unified channel index chOut1 + out).
    private func outputName(_ out: Int) -> String {
        let idx = vm.chOut1 + out
        return idx < vm.channelNames.count ? vm.channelNames[idx] : "Out \(out + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if supported {
                ScrollView {
                    VStack(spacing: 20) {
                        spectrumGraph
                            .padding(.top, 16)
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        startingPointsSection
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        outputSection
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        parameterSection
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            } else {
                unsupportedNote
            }
        }
        .frame(minWidth: 380, maxWidth: 380)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Psychoacoustic Bass")
                    .font(.system(size: 14, weight: .semibold))
                Text("Missing-fundamental bass enhancement")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.psybassEnabled },
                set: { vm.setPsybass($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected || !supported)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unsupportedNote: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Requires firmware with wire format V23 or newer.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Update the DSPi firmware to use Psychoacoustic Bass.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Spectrum Graph

    private var spectrumGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SPECTRUM")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                PsybassSpectrumView(
                    cutoff: vm.psybassCutoffHz,
                    harmonicsDB: vm.psybassHarmonicsDB,
                    originalDB: vm.psybassOriginalDB,
                    isEnabled: vm.psybassEnabled
                )
                .padding(8)
            }
            .frame(height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Starting Points

    private var startingPointsSection: some View {
        HStack {
            Text("STARTING POINTS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Spacer()
            Menu {
                ForEach(0..<psybassStartingPoints.count, id: \.self) { i in
                    let p = psybassStartingPoints[i]
                    Button("\(p.name) - \(p.detail)") {
                        vm.setPsybassCutoff(p.cutoff)
                        vm.setPsybassHarmonics(p.harmonics)
                        vm.setPsybassDrive(p.drive)
                        vm.setPsybassCharacter(p.character)
                        vm.setPsybassOriginal(p.original)
                    }
                }
            } label: {
                Text("Apply preset")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!vm.isDeviceConnected)
        }
    }

    // MARK: - Output Channels

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OUTPUTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("All outputs") {
                        vm.setPsybassMask(allOutputsMask)
                    }
                    Button("Exclude sub (recommended)") {
                        vm.setPsybassMask(excludeSubMask)
                    }
                    Button("None") {
                        vm.setPsybassMask(0x0000)
                    }
                } label: {
                    Text("Presets")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!vm.isDeviceConnected)
            }

            Text("Enhance only the small-speaker outputs. Mask off the sub and any full-range outputs - synthesizing harmonics on a channel that can reproduce real bass is counterproductive.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(0..<outputCount, id: \.self) { out in
                    outputChip(
                        out: out,
                        on: vm.psybassOutputMask & (UInt16(1) << out) != 0
                    ) {
                        vm.setPsybassOutputChannel(out, enabled: vm.psybassOutputMask & (UInt16(1) << out) == 0)
                    }
                }
            }
        }
    }

    private func outputChip(out: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(out + 1)")
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
        .help(outputName(out))
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    // MARK: - Parameters

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PARAMETERS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // Cutoff Frequency
            paramRow(
                title: "Cutoff Frequency",
                unit: "Hz",
                value: vm.psybassCutoffHz,
                range: 30...300,
                maxDecimals: 0,
                scrollStep: 1,
                help: "The speaker's low-frequency limit. Content below this feeds the harmonic generator; generated harmonics span roughly this to 4x.",
                set: { vm.setPsybassCutoff($0) }
            )

            Divider()

            // Harmonics Level
            paramRow(
                title: "Harmonics",
                unit: "dB",
                value: vm.psybassHarmonicsDB,
                range: -24...12,
                maxDecimals: 1,
                scrollStep: 0.5,
                help: "Level of the synthesized harmonics. The primary amount-of-effect control. Higher = more perceived bass.",
                set: { vm.setPsybassHarmonics($0) }
            )

            Divider()

            // Drive
            paramRow(
                title: "Drive",
                unit: "dB",
                value: vm.psybassDriveDB,
                range: 0...18,
                maxDecimals: 1,
                scrollStep: 0.5,
                help: "Pre-gain into the odd-harmonic soft clipper. Higher makes the effect audible on quieter passages. Mostly affects aggressive character.",
                set: { vm.setPsybassDrive($0) }
            )

            Divider()

            // Character
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Character")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "%",
                        value: vm.psybassCharacterPct,
                        width: 60,
                        scrollStep: 1,
                        maxDecimals: 0
                    ) { vm.setPsybassCharacter(min(max($0, 0), 100)) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.psybassCharacterPct },
                        set: { vm.setPsybassCharacter($0) }
                    ),
                    range: 0...100
                )
                .disabled(!vm.isDeviceConnected)

                HStack {
                    Text("Warm")
                    Spacer()
                    Text("Aggressive")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Divider()

            // Original Bass
            paramRow(
                title: "Original Bass",
                unit: "dB",
                value: vm.psybassOriginalDB,
                range: -60...0,
                maxDecimals: 1,
                scrollStep: 1,
                help: "Level of the un-reproducible fundamental below the cutoff. Lower attenuates it, freeing driver excursion and headroom. -60 dB is full removal. Speaker protection.",
                set: { vm.setPsybassOriginal($0) }
            )
        }
    }

    /// One labelled ValueField + CustomSlider + caption row.  The commit closure
    /// clamps to the documented range so app state matches the firmware's silent
    /// clamping without a read-back.
    private func paramRow(
        title: String,
        unit: String,
        value: Float,
        range: ClosedRange<Float>,
        maxDecimals: Int,
        scrollStep: Float,
        help: String,
        set: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                ValueField(
                    label: unit,
                    value: value,
                    width: 60,
                    scrollStep: scrollStep,
                    maxDecimals: maxDecimals
                ) { set(min(max($0, range.lowerBound), range.upperBound)) }
            }

            CustomSlider(
                value: Binding(get: { value }, set: { set($0) }),
                range: range
            )
            .disabled(!vm.isDeviceConnected)

            Text(help)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Spectrum Visualization

/// Schematic (not a precise DSP magnitude) illustration of what psybass does:
/// the original low band below the cutoff, attenuated by `originalDB`, and the
/// synthesized harmonic band from the cutoff to 4x the cutoff at `harmonicsDB`.
private struct PsybassSpectrumView: View {
    let cutoff: Float
    let harmonicsDB: Float
    let originalDB: Float
    let isEnabled: Bool

    private let minFreq: CGFloat = 20.0
    private let maxFreq: CGFloat = 20000.0

    private func xPos(_ freq: CGFloat, w: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(min(max(freq, minFreq), maxFreq))
        return CGFloat((logVal - logMin) / (logMax - logMin)) * w
    }

    /// Original band height fraction: 0 dB = full, -60 dB = gone.
    private var originalFrac: CGFloat {
        CGFloat(min(max((originalDB + 60) / 60, 0), 1))
    }

    /// Harmonics band height fraction: -24 dB = low, +12 dB = full.
    private var harmonicsFrac: CGFloat {
        CGFloat(min(max((harmonicsDB + 24) / 36, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let fcX = xPos(CGFloat(cutoff), w: w)
            let fc4X = xPos(CGFloat(cutoff) * 4, w: w)
            let baseline = h - 14   // leave room for freq labels

            ZStack(alignment: .topLeading) {
                grid(w: w, h: h)

                if isEnabled {
                    // Original low band (20 Hz .. cutoff)
                    let origH = baseline * originalFrac
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(0, fcX), height: max(0, origH))
                        .position(x: fcX / 2, y: baseline - origH / 2)

                    // Synthesized harmonics band (cutoff .. 4x cutoff)
                    let harmH = baseline * harmonicsFrac
                    Rectangle()
                        .fill(Color.orange.opacity(0.55))
                        .frame(width: max(0, fc4X - fcX), height: max(0, harmH))
                        .position(x: (fcX + fc4X) / 2, y: baseline - harmH / 2)

                    // Cutoff marker
                    dashedLine(x: fcX, top: 0, bottom: baseline)
                        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text("fc")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.6))
                        .position(x: fcX, y: 8)

                    // 4x cutoff marker
                    dashedLine(x: fc4X, top: 0, bottom: baseline)
                        .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Text("4fc")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.4))
                        .position(x: fc4X, y: 8)

                    // Legend
                    VStack(alignment: .leading, spacing: 2) {
                        legendItem(color: .accentColor, label: "Original")
                        legendItem(color: .orange, label: "Harmonics")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                    .cornerRadius(4)
                    .position(x: w - 42, y: 20)
                } else {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .position(x: w / 2, y: h / 2)
                }

                freqLabels(w: w, h: h)
            }
            .clipped()
        }
    }

    private func dashedLine(x: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: bottom))
        }
    }

    private func grid(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            for f in [100.0, 1000.0, 10000.0] {
                let x = xPos(CGFloat(f), w: w)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: h - 14))
            }
            path.move(to: CGPoint(x: 0, y: h - 14))
            path.addLine(to: CGPoint(x: w, y: h - 14))
        }
        .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
    }

    private func freqLabels(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            ForEach([100, 1000, 10000], id: \.self) { f in
                Text(f == 1000 ? "1k" : (f == 10000 ? "10k" : "\(f)"))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: xPos(CGFloat(f), w: w), y: h - 5)
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 10, height: 6)
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.primary)
        }
    }
}
