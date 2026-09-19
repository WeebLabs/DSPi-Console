import SwiftUI

// MARK: - Tube Modeller Window Controller

class TubeModellerWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = TubeModellerView(vm: vm, controller: self).onboardingHint("tube")

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 664),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Tube Modeller"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 740, height: 660)
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

extension TubeModellerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Starting Points (spec §6)

private struct TubeStartingPoint {
    let name: String
    let detail: String
    let tubeType: Int
    let driveDB: Float
    let rectifier: Int
    let xfmr: Bool
    var xfmrLfHz: Float = 80
    var xfmrSatPct: Float = 30
    var xfmrHfHz: Float = TUBE_XFMR_HF_MAX
}

/// The spec's suggestions.  Each sets every non-character control, mix and trim
/// included, so applying one lands on the same sound whatever came before; the
/// type sets the character knobs.
private let tubeStartingPoints: [TubeStartingPoint] = [
    TubeStartingPoint(name: "Warm hi-fi", detail: "12AU7 line stage, transformer off",
                      tubeType: 5, driveDB: 4, rectifier: 1, xfmr: false),
    TubeStartingPoint(name: "Single-ended sweetness", detail: "300B with transformer",
                      tubeType: 16, driveDB: 6, rectifier: 1, xfmr: true),
    TubeStartingPoint(name: "Guitar-amp style", detail: "12AX7 pushed, 5U4, dark transformer",
                      tubeType: 1, driveDB: 15, rectifier: 2, xfmr: true, xfmrHfHz: 6000),
    TubeStartingPoint(name: "Push-pull power", detail: "EL34 with transformer",
                      tubeType: 12, driveDB: 6, rectifier: 1, xfmr: true),
]

// MARK: - Tube Modeller View

struct TubeModellerView: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var controller: TubeModellerWindowController

    /// The saturation meter is a 300 ms decaying peak; the spec suggests 10 to
    /// 20 Hz, and 10 is enough to watch a drive setting land.
    private let meterTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Output channels exposed in the mask grid (5 on RP2040, 9 on RP2350).
    private var outputCount: Int { vm.numOutputChannels }

    /// The whole feature ships in wire format V31; hide the interactive body on
    /// older firmware and show an upgrade note instead.
    private var supported: Bool { vm.firmwareSupportsTube }

    private var allOutputsMask: UInt16 {
        outputCount >= 16 ? 0xFFFF : UInt16((1 << outputCount) - 1)
    }

    /// Everything but the PDM sub.  Harmonic colour on a sub feed is mostly
    /// wasted: the crossover after tube removes what the stage adds above it.
    private var excludeSubMask: UInt16 {
        allOutputsMask & ~(UInt16(1) << vm.pdmOutputIndex)
    }

    private func outputName(_ out: Int) -> String {
        let idx = vm.chOut1 + out
        return idx < vm.channelNames.count ? vm.channelNames[idx] : "Out \(out + 1)"
    }

    private var selectedRow: TubeTypeRow? {
        let t = vm.tubeType
        return t > 0 && t < TUBE_TYPE_ROWS.count ? TUBE_TYPE_ROWS[t] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if supported {
                // Two columns of the sections the other tool windows stack.
                // The left column is the stage itself: its curve, the tube and
                // how hard it is driven, and where it applies.  The right column
                // holds what the tube type presets and the transformer after it.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        transferGraph
                        Divider()
                        stageSection
                        Divider()
                        outputSection
                    }
                    .toolColumn()

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        characterSection
                        Divider()
                        transformerSection
                    }
                    .toolColumn()
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 16)
            } else {
                unsupportedNote
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(meterTimer) { _ in
            // Only while the panel is up and there is something to meter.
            guard controller.isVisible, supported, vm.isDeviceConnected, vm.tubeEnabled else { return }
            DispatchQueue.global(qos: .utility).async { vm.fetchTubeMeter() }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "flame")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tube Modeller")
                    .font(.system(size: 14, weight: .semibold))
                Text("Valve-style harmonic colour, supply sag and transformer saturation")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.tubeEnabled },
                set: { vm.setTube($0) }
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
            Text("Requires firmware with wire format V31 or newer.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Update the DSPi firmware to use the Tube Modeller.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transfer Graph

    private var shaper: TubeShaper {
        TubeShaper(driveDB: vm.tubeDriveDB, biasPct: vm.tubeBiasPct, asymDB: vm.tubeAsymDB,
                   hardnessPct: vm.tubeHardnessPct, mixPct: vm.tubeMixPct, trimDB: vm.tubeTrimDB)
    }

    private var transferGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("TRANSFER CURVE")
                Spacer()
                startingPointsMenu
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                TubeTransferView(shaper: shaper, isEnabled: vm.tubeEnabled)
                    .padding(8)
            }
            .frame(height: 188)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )

            harmonicsReadout
                .padding(.top, 4)
        }
    }

    /// The second and third harmonic a full-scale sine comes out with, as the
    /// graph's caption.  They are the two numbers the character controls trade
    /// against each other: bias and asymmetry raise the even one, drive and
    /// hardness the odd one.
    private var harmonicsReadout: some View {
        let h = shaper.harmonics()
        return HStack(spacing: 16) {
            sectionLabel("AT FULL SCALE")
            Spacer()
            harmonicValue("2nd", h.second)
            harmonicValue("3rd", h.third)
        }
        .help("Level of the second and third harmonic relative to the fundamental, for a full-scale sine through the static curve after mix and trim. Sag lowers the drive on sustained loud passages and the transformer adds its own low-frequency colour, so the running figures sit somewhat lower.")
    }

    private func harmonicValue(_ label: String, _ db: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(db <= -100 ? "none" : String(format: "%.0f dB", db))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(db > -100 ? .primary : .secondary)
                .frame(width: 42, alignment: .leading)
        }
    }

    private var startingPointsMenu: some View {
        Menu {
            ForEach(0..<tubeStartingPoints.count, id: \.self) { i in
                let p = tubeStartingPoints[i]
                Button("\(p.name) - \(p.detail)") {
                    vm.setTubeType(p.tubeType)
                    vm.setTubeDrive(p.driveDB)
                    vm.setTubeRectifier(p.rectifier)
                    vm.setTubeXfmrLf(p.xfmrLfHz)
                    vm.setTubeXfmrSat(p.xfmrSatPct)
                    vm.setTubeXfmrHf(p.xfmrHfHz)
                    vm.setTubeXfmr(p.xfmr)
                    vm.setTubeMix(TUBE_MIX_MAX)
                    vm.setTubeTrim(0)
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

    // MARK: - Stage

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("STAGE")

            tubeTypeRow

            paramRow(
                title: "Drive",
                unit: "dB",
                value: vm.tubeDriveDB,
                range: TUBE_DRIVE_MIN...TUBE_DRIVE_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                help: "Gain ahead of the shaper. At 0 dB a full-scale signal just reaches the knee, so this alone sets how hard the stage is driven. Harmonics and sag both rise with it.",
                set: { vm.setTubeDrive($0) }
            )

            paramRow(
                title: "Mix",
                unit: "%",
                value: vm.tubeMixPct,
                range: TUBE_MIX_MIN...TUBE_MIX_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                help: "Blend of the processed signal with the untouched input. The dry path is sample-aligned with the wet one, so blending never combs.",
                set: { vm.setTubeMix($0) }
            )

            paramRow(
                title: "Output Trim",
                unit: "dB",
                value: vm.tubeTrimDB,
                range: TUBE_TRIM_MIN...TUBE_TRIM_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                help: "Level of the processed signal only. A hard-driven, strongly asymmetric setting can push the wet path above full scale; watch the output clip indicators and bring it back here.",
                set: { vm.setTubeTrim($0) }
            )
        }
    }

    /// The tube picker, grouped by the three kinds of stage the rows model.
    /// Custom is selectable too: it keeps the current knobs and stops any row
    /// from being applied.
    private var tubeTypeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tube")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { vm.tubeType },
                    set: { vm.setTubeType($0) }
                )) {
                    Text("Custom").tag(TUBE_TYPE_CUSTOM)
                    Section("Preamp triodes") {
                        ForEach(1...8, id: \.self) { tubeTypeItem($0) }
                    }
                    Section("Preamp pentodes") {
                        ForEach(9...10, id: \.self) { tubeTypeItem($0) }
                    }
                    Section("Power stages") {
                        ForEach(11...16, id: \.self) { tubeTypeItem($0) }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!vm.isDeviceConnected)
            }

            Text(tubeTypeCaption)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Loads the bias, asymmetry, knee hardness and sag of a real tube. Drive, mix, the rectifier and the transformer are left alone. Editing any of the four character controls switches this to Custom.")
    }

    private func tubeTypeItem(_ t: Int) -> some View {
        Text(tubeTypeName(t)).tag(t)
    }

    private var tubeTypeCaption: String {
        guard let row = selectedRow else {
            return "Character controls as set, no tube row applied."
        }
        if row.pushPull && !vm.tubeXfmrEnabled {
            return "\(row.style). Meant for use with the transformer on."
        }
        return "\(row.style)."
    }

    // MARK: - Output Channels

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("OUTPUTS")
                Spacer()
                Menu {
                    Button("All outputs") {
                        vm.setTubeMask(allOutputsMask)
                    }
                    Button("Exclude sub") {
                        vm.setTubeMask(excludeSubMask)
                    }
                    Button("None") {
                        vm.setTubeMask(0x0000)
                    }
                } label: {
                    Text("Presets")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!vm.isDeviceConnected)
            }

            HStack(spacing: 6) {
                ForEach(0..<outputCount, id: \.self) { out in
                    outputChip(
                        out: out,
                        on: vm.tubeOutputMask & (UInt16(1) << out) != 0
                    ) {
                        vm.setTubeOutputChannel(out, enabled: vm.tubeOutputMask & (UInt16(1) << out) == 0)
                    }
                }
            }
            .help("Tube runs before the crossover and the per-output EQ, where a real preamp sits: a sub output saturates the full-band program and then low-passes the result. The bar under each output shows how hard its stage is being driven; full means fully clipped.")
        }
    }

    private func outputChip(out: Int, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
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

            // A masked-off output's state is reset by the firmware, so its rail
            // stays empty rather than showing a stale reading.
            HorizontalMeterBar(
                level: on && vm.tubeEnabled ? saturationLevel(out) : Float(0),
                color: .orange
            )
            .frame(height: 3)
            .opacity(on ? 1 : 0.25)
        }
        .help(outputName(out))
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    private func saturationLevel(_ out: Int) -> Float {
        out < vm.tubeSaturationMeter.count ? vm.tubeSaturationMeter[out] : 0
    }

    // MARK: - Character

    private var characterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("CHARACTER")
                Spacer()
                Text(selectedRow.map { "from \($0.name)" } ?? "custom")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            paramRow(
                title: "Bias",
                unit: "%",
                value: vm.tubeBiasPct,
                range: TUBE_BIAS_MIN...TUBE_BIAS_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                help: "Shifts the operating point along the curve. Positive values give the classic warm second harmonic that grows with level; negative values give the same amount with the even products inverted, which only matters when mixed with the dry signal.",
                set: { vm.setTubeBias($0) }
            )

            paramRow(
                title: "Asymmetry",
                unit: "dB",
                value: vm.tubeAsymDB,
                range: TUBE_ASYM_MIN...TUBE_ASYM_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                help: "How much later the negative half reaches its knee than the positive half. Adds even-order content at heavy drive. Zero is symmetric, as in a push-pull stage.",
                set: { vm.setTubeAsym($0) }
            )

            paramRow(
                title: "Knee Hardness",
                unit: "%",
                value: vm.tubeHardnessPct,
                range: TUBE_HARDNESS_MIN...TUBE_HARDNESS_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                help: "Blends from a soft cubic knee (0%) to a harder quintic one (100%). Clean material stays at the same level at every setting; only how abruptly the stage runs out changes.",
                set: { vm.setTubeHardness($0) }
            )

            paramRow(
                title: "Sag",
                unit: "%",
                value: vm.tubeSagPct,
                range: TUBE_SAG_MIN...TUBE_SAG_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                help: "Supply-sag compression: sustained heavy drive pulls the gain down slowly, then recovers. The rectifier below scales the depth and sets the timing.",
                set: { vm.setTubeSag($0) }
            )
            .opacity(vm.tubeRectifier == TUBE_RECT_SOLID_STATE ? 0.5 : 1)

            rectifierRow
        }
    }

    private var rectifierRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rectifier")
                .font(.system(size: 12, weight: .medium))

            Picker("", selection: Binding(
                get: { vm.tubeRectifier },
                set: { vm.setTubeRectifier($0) }
            )) {
                Text("Solid state").tag(0)
                Text("GZ34").tag(1)
                Text("5U4").tag(2)
                Text("5Y3").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!vm.isDeviceConnected)

            Text(rectifierSummary)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("The power-supply rectifier sets how deep and how slow the sag is. Solid state switches sag off entirely; the valve rectifiers get progressively softer and slower from GZ34 to 5Y3.")
    }

    private var rectifierSummary: String {
        let r = vm.tubeRectifier
        guard r > TUBE_RECT_SOLID_STATE, r < TUBE_RECTIFIER_ROWS.count else {
            return "No sag: the supply holds up however hard the stage is driven."
        }
        let row = TUBE_RECTIFIER_ROWS[r]
        return String(format: "Sag depth x%.1f, %.0f ms attack, %.0f ms release.",
                      row.depthScale, row.attackMs, row.releaseMs)
    }

    // MARK: - Transformer

    private var xfmrHfOff: Bool { vm.tubeXfmrHfHz >= TUBE_XFMR_HF_MAX }

    private var transformerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("OUTPUT TRANSFORMER")
                    Text("Low-band core saturation and a high-frequency rolloff.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.tubeXfmrEnabled },
                    set: { vm.setTubeXfmr($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!vm.isDeviceConnected)
            }
            .help("Core saturation scales with voltage over frequency, so only the band below the split saturates, at 6 dB per octave. The firmware skips the whole stage while it is off.")

            // The firmware skips these stages entirely while the transformer is
            // off, so they are hidden rather than shown doing nothing.
            if vm.tubeXfmrEnabled {
                paramRow(
                    title: "Low Split",
                    unit: "Hz",
                    value: vm.tubeXfmrLfHz,
                    range: TUBE_XFMR_LF_MIN...TUBE_XFMR_LF_MAX,
                    scrollStep: 1,
                    maxDecimals: 0,
                    help: "Corner of the one-pole split feeding the saturator. Content below it saturates; everything above passes clean.",
                    set: { vm.setTubeXfmrLf($0) }
                )

                paramRow(
                    title: "Saturation",
                    unit: "%",
                    value: vm.tubeXfmrSatPct,
                    range: TUBE_XFMR_SAT_MIN...TUBE_XFMR_SAT_MAX,
                    scrollStep: 1,
                    maxDecimals: 0,
                    help: "Moves the low-band knee from 0 dBFS (0%) down to -18 dBFS (100%). Even at 0% the low band is gently shaped near full scale; switch the transformer off for a linear low end.",
                    set: { vm.setTubeXfmrSat($0) }
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("HF Rolloff")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        ValueField(
                            label: "Hz",
                            value: vm.tubeXfmrHfHz,
                            width: 60,
                            scrollStep: 100,
                            maxDecimals: 0,
                            displayOverride: xfmrHfOff ? "Off" : nil
                        ) { vm.setTubeXfmrHf($0) }
                    }

                    CustomSlider(
                        value: Binding(
                            get: { vm.tubeXfmrHfHz },
                            set: { vm.setTubeXfmrHf($0) }
                        ),
                        range: TUBE_XFMR_HF_MIN...TUBE_XFMR_HF_MAX
                    )
                    .disabled(!vm.isDeviceConnected)

                    HStack {
                        Text("2 kHz")
                        Spacer()
                        Text("Off")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }
                .help("A one-pole rolloff after the saturator, for the darker top end of a real output transformer. The top of the range bypasses it; around 6 kHz suits a guitar-amp sound.")
            }
        }
    }

    // MARK: - Parameter Row

    /// The labelled ValueField + CustomSlider row the other tool windows use.
    /// The setters clamp, so the field can commit any typed value.
    private func paramRow(
        title: String,
        unit: String,
        value: Float,
        range: ClosedRange<Float>,
        scrollStep: Float,
        maxDecimals: Int,
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
                ) { set($0) }
            }

            CustomSlider(
                value: Binding(get: { value }, set: { set($0) }),
                range: range
            )
            .disabled(!vm.isDeviceConnected)
        }
        .help(help)
    }
}

// MARK: - Shaper Model

/// The firmware's static waveshaper (spec §1), evaluated in Double for the
/// graph.  It is the real curve rather than a sketch: drive, bias, the two knees,
/// the hardness blend, the rest-point offset, mix and trim.  What it leaves out
/// is everything with memory - sag, the DC blocker and the transformer - which
/// is why the graph is labelled a transfer curve and not a frequency response.
struct TubeShaper {
    let m: Double
    let b: Double
    let ratioN: Double
    let c1: Double, c3: Double, c5: Double
    let sP: Double, sN: Double
    let dryW: Double
    let wetW: Double
    let v0: Double

    init(driveDB: Float, biasPct: Float, asymDB: Float, hardnessPct: Float, mixPct: Float, trimDB: Float) {
        m = pow(10, Double(driveDB) / 20)
        b = Double(biasPct) / 200
        ratioN = pow(10, -Double(asymDB) / 20)
        let h = Double(hardnessPct) / 100
        c1 = 1.5 + 0.375 * h
        c3 = -0.5 - 0.75 * h
        c5 = 0.375 * h
        sP = 1 / c1
        sN = pow(10, Double(asymDB) / 20) / c1
        let mix = Double(mixPct) / 100
        dryW = 1 - mix
        wetW = mix * pow(10, Double(trimDB) / 20)
        v0 = TubeShaper.shape(0, m: m, b: b, ratioN: ratioN, c1: c1, c3: c3, c5: c5, sP: sP, sN: sN)
    }

    private static func shape(_ x: Double, m: Double, b: Double, ratioN: Double,
                              c1: Double, c3: Double, c5: Double, sP: Double, sN: Double) -> Double {
        var t = m * x + b
        if t < 0 { t *= ratioN }
        t = min(max(t, -1), 1)
        let t2 = t * t
        let p = t * (c1 + t2 * (c3 + t2 * c5))
        return p * (t >= 0 ? sP : sN)
    }

    /// The shaper's input after drive, bias and the negative-knee ratio, before
    /// the clamp.  |t| >= 1 means that input is fully clipped.
    func knee(_ x: Double) -> Double {
        let t = m * x + b
        return t < 0 ? t * ratioN : t
    }

    /// Wet path only: the stage's output with the rest-point offset removed.
    func wet(_ x: Double) -> Double {
        TubeShaper.shape(x, m: m, b: b, ratioN: ratioN, c1: c1, c3: c3, c5: c5, sP: sP, sN: sN) - v0
    }

    /// What leaves the module for input `x`.
    func output(_ x: Double) -> Double {
        dryW * x + wetW * wet(x)
    }

    /// Second and third harmonic of a full-scale sine, in dB relative to the
    /// fundamental; -120 when a harmonic is absent.  A 256-point DFT at the
    /// three bins is exact for a memoryless curve, which this is.
    func harmonics() -> (second: Double, third: Double) {
        let n = 256
        var re = [0.0, 0.0, 0.0], im = [0.0, 0.0, 0.0]
        for i in 0..<n {
            let phase = 2 * Double.pi * Double(i) / Double(n)
            let y = output(sin(phase))
            for k in 0..<3 {
                re[k] += y * cos(Double(k + 1) * phase)
                im[k] += y * sin(Double(k + 1) * phase)
            }
        }
        let mag = (0..<3).map { hypot(re[$0], im[$0]) }
        func rel(_ a: Double) -> Double {
            guard mag[0] > 1e-12, a > mag[0] * 1e-6 else { return -120 }
            return 20 * log10(a / mag[0])
        }
        return (rel(mag[1]), rel(mag[2]))
    }
}

// MARK: - Transfer Curve Visualization

/// Output against input over one full-scale swing, with the straight line a
/// clean stage would draw for comparison.  Inputs that drive the stage past
/// either knee are shaded: that is where the curve goes flat and the harmonics
/// come from.  Asymmetry shows as the two shaded regions starting at different
/// distances from the centre, bias as the curve's bend being off-centre.
private struct TubeTransferView: View {
    let shaper: TubeShaper
    let isEnabled: Bool

    /// Output range drawn.  Hot trim and asymmetry can exceed full scale, so
    /// the plot has a little room above 1 before the curve is clipped at the
    /// frame, and a line marks full scale itself.
    private let yMax: Double = 1.4

    private func xPos(_ x: Double, w: CGFloat) -> CGFloat {
        CGFloat((x + 1) / 2) * w
    }

    private func yPos(_ y: Double, h: CGFloat) -> CGFloat {
        let c = min(max(y, -yMax), yMax)
        return CGFloat((yMax - c) / (2 * yMax)) * h
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                grid(w: w, h: h)

                if isEnabled {
                    clipRegions(w: w, h: h)
                    linearReference(w: w, h: h)
                    curve(w: w, h: h)
                } else {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .position(x: w / 2, y: h / 2)
                }

                axisLabels(w: w, h: h)
            }
            .clipped()
        }
    }

    private func grid(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for x in [-1.0, -0.5, 0.5, 1.0] {
                    path.move(to: CGPoint(x: xPos(x, w: w), y: 0))
                    path.addLine(to: CGPoint(x: xPos(x, w: w), y: h))
                }
                for y in [-0.5, 0.5] {
                    path.move(to: CGPoint(x: 0, y: yPos(y, h: h)))
                    path.addLine(to: CGPoint(x: w, y: yPos(y, h: h)))
                }
            }
            .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)

            // Full scale out, so a hot setting visibly crosses it.
            Path { path in
                for y in [-1.0, 1.0] {
                    path.move(to: CGPoint(x: 0, y: yPos(y, h: h)))
                    path.addLine(to: CGPoint(x: w, y: yPos(y, h: h)))
                }
            }
            .stroke(Color.red.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))

            Path { path in
                path.move(to: CGPoint(x: xPos(0, w: w), y: 0))
                path.addLine(to: CGPoint(x: xPos(0, w: w), y: h))
                path.move(to: CGPoint(x: 0, y: yPos(0, h: h)))
                path.addLine(to: CGPoint(x: w, y: yPos(0, h: h)))
            }
            .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
        }
    }

    /// Shades the inputs the stage clips.  Solved from the knee directly rather
    /// than by sampling, so the edge sits exactly where the curve goes flat.
    private func clipRegions(w: CGFloat, h: CGFloat) -> some View {
        // Positive knee: m x + b = 1.  Negative knee: (m x + b) * ratio_n = -1.
        let xPos1 = (1 - shaper.b) / shaper.m
        let xNeg1 = (-1 / shaper.ratioN - shaper.b) / shaper.m
        return ZStack(alignment: .topLeading) {
            if xPos1 < 1 {
                let x0 = xPos(max(xPos1, -1), w: w)
                Rectangle()
                    .fill(Color.orange.opacity(0.10))
                    .frame(width: max(0, w - x0), height: h)
                    .position(x: (x0 + w) / 2, y: h / 2)
            }
            if xNeg1 > -1 {
                let x1 = xPos(min(xNeg1, 1), w: w)
                Rectangle()
                    .fill(Color.orange.opacity(0.10))
                    .frame(width: max(0, x1), height: h)
                    .position(x: x1 / 2, y: h / 2)
            }
        }
    }

    private func linearReference(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: xPos(-1, w: w), y: yPos(-1, h: h)))
            path.addLine(to: CGPoint(x: xPos(1, w: w), y: yPos(1, h: h)))
        }
        .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func curve(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            let steps = 240
            for i in 0...steps {
                let x = -1 + 2 * Double(i) / Double(steps)
                let pt = CGPoint(x: xPos(x, w: w), y: yPos(shaper.output(x), h: h))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private func axisLabels(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text("in")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .position(x: w - 8, y: yPos(0, h: h) + 7)
            Text("out")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .position(x: xPos(0, w: w) + 10, y: 6)
            Text("0 dBFS")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(.red.opacity(0.5))
                .position(x: 18, y: yPos(1, h: h) - 6)
        }
    }
}
