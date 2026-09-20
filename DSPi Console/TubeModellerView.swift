import SwiftUI

// MARK: - Tube Modeller Window Controller

class TubeModellerWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = TubeModellerView(vm: vm, tube: vm.tube, controller: self).onboardingHint("tube")

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 664),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Tube Modeller"
            let hosting = NSHostingView(rootView: view)
            // The controller sets the window's min and max content size itself
            // in `fit`. Left to its defaults the hosting view derives them too,
            // and that is a full ideal-size measurement of the whole tree on
            // every display cycle - 30 % of the main thread during a slider
            // drag, for a number nobody reads.
            hosting.sizingOptions = []
            window?.contentView = hosting
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 740, height: 400)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    /// Sizes the window to its content's height, keeping the top edge where it
    /// was.  Basic and Advanced are different heights, so the window follows
    /// whichever is showing; only its width stays free to resize.
    func fit(contentHeight: CGFloat) {
        guard let window, contentHeight > 0 else { return }
        let height = ceil(contentHeight)
        window.contentMinSize = NSSize(width: 740, height: height)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.height - height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: current.width, height: height)))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// Height of the window's content, reported so the controller can fit to it.
private struct TubeContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    var damping: Float = TUBE_DEFAULT_XFMR_DAMPING
    var resHz: Float = TUBE_DEFAULT_XFMR_RES_HZ
}

/// The spec's suggestions (§6).  Each sets every non-character control, mix and
/// trim included, so applying one lands on the same sound whatever came before;
/// the type sets the character knobs.
private let tubeStartingPoints: [TubeStartingPoint] = [
    TubeStartingPoint(name: "Clean default", detail: "12AX7, level-neutral, output stage off",
                      tubeType: 1, driveDB: TUBE_DEFAULT_DRIVE_DB, rectifier: 1, xfmr: false),
    TubeStartingPoint(name: "Warm hi-fi", detail: "12AU7 line stage, tightly damped",
                      tubeType: 5, driveDB: -3, rectifier: 1, xfmr: true, damping: 10),
    TubeStartingPoint(name: "Single-ended sweetness", detail: "300B, loose damping",
                      tubeType: 16, driveDB: 3, rectifier: 1, xfmr: true, damping: 2),
    TubeStartingPoint(name: "Guitar-amp style", detail: "12AX7 pushed, 5U4, loose damping",
                      tubeType: 1, driveDB: 15, rectifier: 2, xfmr: true, damping: 2, resHz: 100),
    TubeStartingPoint(name: "Push-pull power", detail: "EL34 with the output stage on",
                      tubeType: 12, driveDB: 0, rectifier: 1, xfmr: true, damping: 6),
]

// MARK: - Tube Modeller View

struct TubeModellerView: View {
    @ObservedObject var vm: DSPViewModel
    /// Observed separately from `vm` so a slider drag invalidates this window
    /// and nothing else; see ToolParameters.swift.
    @ObservedObject var tube: TubeParameters
    @ObservedObject var controller: TubeModellerWindowController

    /// Basic shows the tube and the two controls most people need; Advanced
    /// shows every parameter.  Remembered across launches.
    @AppStorage("tubeModellerAdvanced") private var advanced = false

    /// What the transfer graph follows during a drag: the committed parameters
    /// with the dragged one substituted, or nil between drags. Held in `@State`
    /// as a plain reference, deliberately not `@StateObject`, so this view does
    /// not observe it; only the graph pane inside its `LiveGraphHost` does.
    @State private var graphLive = TubeGraphLive()

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
        let t = tube.type
        return t > 0 && t < TUBE_TYPE_ROWS.count ? TUBE_TYPE_ROWS[t] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if supported && !advanced {
                basicBody
            } else if supported {
                // Two columns of the sections the other tool windows stack.
                // The left column is the stage itself: its curve, the tube and
                // how hard it is driven, and where it applies.  The right column
                // holds what the tube type presets and the output stage after it.
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
        .background(GeometryReader { geo in
            Color.clear.preference(key: TubeContentHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(TubeContentHeightKey.self) { controller.fit(contentHeight: $0) }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
    }

    // MARK: - Basic Mode

    /// The tube on show on the left, and on the right the choice of tube, the
    /// two controls that matter most, and where it applies.  Everything else
    /// keeps the value it has, so switching modes never changes the sound.
    private var basicBody: some View {
        HStack(alignment: .top, spacing: 0) {
            tubeShowcase
                .toolColumn()
                .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                tubeShelf
                Divider()
                basicControls
                Divider()
                outputSection
            }
            .toolColumn()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
    }

    private var family: TubeFamily { TubeFamily.of(tube.type) }

    private var tubeShowcase: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            // A warm pool of light behind the glass while the stage is on.
            RoundedRectangle(cornerRadius: 10)
                .fill(RadialGradient(colors: [Color.orange.opacity(0.10), .clear],
                                     center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 190))
                .opacity(vm.tubeEnabled ? 1 : 0)
                .animation(.easeInOut(duration: vm.tubeEnabled ? 0.9 : 0.6), value: vm.tubeEnabled)

            VStack(spacing: 12) {
                Spacer(minLength: 8)
                ZStack {
                    TubeIllustration(family: family, lit: vm.tubeEnabled,
                                     meters: vm.meters, outputStart: vm.chOut1,
                                     outputCount: outputCount, outputMask: tube.outputMask,
                                     active: controller.isVisible && vm.isDeviceConnected)
                        .id(family)
                        .transition(.opacity)
                }
                .frame(width: 168, height: 280)
                .animation(.easeInOut(duration: 0.25), value: family)

                VStack(spacing: 4) {
                    Text(selectedRow?.name ?? "Custom")
                        .font(.system(size: 17, weight: .semibold))
                    Text(showcaseCaption)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var showcaseCaption: String {
        guard let row = selectedRow else {
            return "Character set by hand. Pick a tube to load one, or fine-tune it in Advanced."
        }
        if row.pushPull && !tube.xfmrEnabled {
            return "\(row.style). Meant for use with the output stage, in Advanced."
        }
        return "\(row.style)."
    }

    /// Every tube as a one-click chip, grouped by kind of stage.
    private var tubeShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("TUBE")
            shelfGroup("Preamp triodes", 1...8)
            shelfGroup("Preamp pentodes", 9...10)
            shelfGroup("Power stages", 11...16)
        }
        .help("Loads the character of a real tube: its bias, asymmetry, knee hardness and sag. Drive, mix and everything in Advanced keep their values.")
    }

    private func shelfGroup(_ title: String, _ types: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(types), id: \.self) { tubeChip($0) }
            }
        }
    }

    private func tubeChip(_ type: Int) -> some View {
        let on = tube.type == type
        let row = TUBE_TYPE_ROWS[type]
        return Button(action: { vm.setTubeType(type) }) {
            Text(row?.shortName ?? tubeTypeName(type))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundColor(on ? .white : .primary.opacity(0.75))
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
        .help(row.map { "\($0.name): \($0.style)" } ?? tubeTypeName(type))
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    /// Drive and mix: how hard the tube works, and how much of it is heard.
    private var basicControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            paramRow(
                title: "Drive",
                unit: "dB",
                value: tube.driveDB,
                range: TUBE_DRIVE_MIN...TUBE_DRIVE_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                ends: ("Clean", "Overdrive"),
                liveIndex: TUBE_PARAM_DRIVE_DB,
                liveShaper: { shaperOverriding(driveDB: $0) },
                help: "How hard the tube is driven. Drive moves the knee, not the level: at the -6 dB default the knee sits 6 dB above full scale and the colour is subtle, and the top of the range is overdrive.",
                set: { vm.setTubeDrive($0) }
            )

            paramRow(
                title: "Mix",
                unit: "%",
                value: tube.mixPct,
                range: TUBE_MIX_MIN...TUBE_MIX_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                ends: ("Dry", "All tube"),
                liveIndex: TUBE_PARAM_MIX_PCT,
                liveShaper: { shaperOverriding(mixPct: $0) },
                help: "Blends the tube with the untouched signal. Below 100% the original transients stay intact under the colour, which is the easiest way to use heavy drive subtly.",
                set: { vm.setTubeMix($0) }
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            TubeIcon(lit: vm.tubeEnabled)
                .frame(width: 27, height: 27)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tube Modeller")
                    .font(.system(size: 14, weight: .semibold))
                Text("Valve-style harmonic colour, supply sag and a tube amplifier's output stage")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if supported {
                Picker("", selection: $advanced) {
                    Text("Basic").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.trailing, 4)
            }

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
        .frame(maxWidth: .infinity)
        .frame(height: 240)
    }

    // MARK: - Transfer Graph

    private var shaper: TubeShaper {
        TubeShaper(driveDB: tube.driveDB, biasPct: tube.biasPct, asymDB: tube.asymDB,
                   hardnessPct: tube.hardnessPct, mixPct: tube.mixPct, trimDB: tube.trimDB)
    }

    private var transferGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("TRANSFER CURVE")
                Spacer()
                startingPointsMenu
            }

            // In its own hosting view, so following a drag re-lays out the
            // graph alone rather than the whole window.
            LiveGraphHost {
                TubeGraphPane(base: shaper, isEnabled: vm.tubeEnabled, live: graphLive)
            }
        }
    }

    /// The committed shaper with one parameter replaced, for the graph to show
    /// while that parameter is being dragged.
    private func shaperOverriding(driveDB: Float? = nil, biasPct: Float? = nil, asymDB: Float? = nil,
                                  hardnessPct: Float? = nil, mixPct: Float? = nil, trimDB: Float? = nil) -> TubeShaper {
        TubeShaper(driveDB: driveDB ?? tube.driveDB, biasPct: biasPct ?? tube.biasPct,
                   asymDB: asymDB ?? tube.asymDB, hardnessPct: hardnessPct ?? tube.hardnessPct,
                   mixPct: mixPct ?? tube.mixPct, trimDB: trimDB ?? tube.trimDB)
    }

    private var startingPointsMenu: some View {
        Menu {
            ForEach(0..<tubeStartingPoints.count, id: \.self) { i in
                let p = tubeStartingPoints[i]
                Button("\(p.name) - \(p.detail)") {
                    vm.setTubeType(p.tubeType)
                    vm.setTubeDrive(p.driveDB)
                    vm.setTubeRectifier(p.rectifier)
                    vm.setTubeXfmrDamping(p.damping)
                    vm.setTubeXfmrRes(p.resHz)
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
                value: tube.driveDB,
                range: TUBE_DRIVE_MIN...TUBE_DRIVE_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                liveIndex: TUBE_PARAM_DRIVE_DB,
                liveShaper: { shaperOverriding(driveDB: $0) },
                help: "Gain ahead of the shaper. At 0 dB a full-scale signal just reaches the knee, so this alone sets how hard the stage is driven. The shaper carries matching makeup gain, so clean material keeps its level at every drive; harmonics and sag rise with it.",
                set: { vm.setTubeDrive($0) }
            )

            paramRow(
                title: "Mix",
                unit: "%",
                value: tube.mixPct,
                range: TUBE_MIX_MIN...TUBE_MIX_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                liveIndex: TUBE_PARAM_MIX_PCT,
                liveShaper: { shaperOverriding(mixPct: $0) },
                help: "Blend of the processed signal with the untouched input. The dry path is sample-aligned with the wet one, so blending never combs.",
                set: { vm.setTubeMix($0) }
            )

            paramRow(
                title: "Output Trim",
                unit: "dB",
                value: tube.trimDB,
                range: TUBE_TRIM_MIN...TUBE_TRIM_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                liveIndex: TUBE_PARAM_TRIM_DB,
                liveShaper: { shaperOverriding(trimDB: $0) },
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
                    get: { tube.type },
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
        .help("Loads the bias, asymmetry, knee hardness and sag of a real tube. Drive, mix, the rectifier and the output stage are left alone. Editing any of the four character controls switches this to Custom.")
    }

    private func tubeTypeItem(_ t: Int) -> some View {
        Text(tubeTypeName(t)).tag(t)
    }

    private var tubeTypeCaption: String {
        guard let row = selectedRow else {
            return "Character controls as set, no tube row applied."
        }
        if row.pushPull && !tube.xfmrEnabled {
            return "\(row.style). Meant for use with the output stage on."
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
                        on: tube.outputMask & (UInt16(1) << out) != 0
                    ) {
                        vm.setTubeOutputChannel(out, enabled: tube.outputMask & (UInt16(1) << out) == 0)
                    }
                }
            }
            .help("Tube runs before the crossover and the per-output EQ, where a real preamp sits: a sub output saturates the full-band program and then low-passes the result.")
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
                value: tube.biasPct,
                range: TUBE_BIAS_MIN...TUBE_BIAS_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                liveIndex: TUBE_PARAM_BIAS_PCT,
                liveShaper: { shaperOverriding(biasPct: $0) },
                help: "Shifts the operating point along the curve. Positive values give the classic warm second harmonic that grows with level; negative values give the same amount with the even products inverted, which only matters when mixed with the dry signal.",
                set: { vm.setTubeBias($0) }
            )

            paramRow(
                title: "Asymmetry",
                unit: "dB",
                value: tube.asymDB,
                range: TUBE_ASYM_MIN...TUBE_ASYM_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                liveIndex: TUBE_PARAM_ASYM_DB,
                liveShaper: { shaperOverriding(asymDB: $0) },
                help: "How much later the negative half reaches its knee than the positive half. Adds even-order content at heavy drive. Zero is symmetric, as in a push-pull stage.",
                set: { vm.setTubeAsym($0) }
            )

            paramRow(
                title: "Knee Hardness",
                unit: "%",
                value: tube.hardnessPct,
                range: TUBE_HARDNESS_MIN...TUBE_HARDNESS_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                liveIndex: TUBE_PARAM_HARDNESS_PCT,
                liveShaper: { shaperOverriding(hardnessPct: $0) },
                help: "Blends from a soft cubic knee (0%) to a harder quintic one (100%). Clean material stays at the same level at every setting; only how abruptly the stage runs out changes.",
                set: { vm.setTubeHardness($0) }
            )

            paramRow(
                title: "Sag",
                unit: "%",
                value: tube.sagPct,
                range: TUBE_SAG_MIN...TUBE_SAG_MAX,
                scrollStep: 1,
                maxDecimals: 0,
                liveIndex: TUBE_PARAM_SAG_PCT,
                help: "Supply-sag compression: sustained heavy drive pulls the gain down slowly, then recovers. The rectifier below scales the depth and sets the timing.",
                set: { vm.setTubeSag($0) }
            )
            .opacity(tube.rectifier == TUBE_RECT_SOLID_STATE ? 0.5 : 1)

            rectifierRow
        }
    }

    private var rectifierRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rectifier")
                .font(.system(size: 12, weight: .medium))

            Picker("", selection: Binding(
                get: { tube.rectifier },
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
        let r = tube.rectifier
        guard r > TUBE_RECT_SOLID_STATE, r < TUBE_RECTIFIER_ROWS.count else {
            return "No sag: the supply holds up however hard the stage is driven."
        }
        let row = TUBE_RECTIFIER_ROWS[r]
        return String(format: "Sag depth x%.1f, %.0f ms attack, %.0f ms release.",
                      row.depthScale, row.attackMs, row.releaseMs)
    }

    // MARK: - Output Stage

    /// What the damping factor does to the response, by the spec's own formula:
    /// a source impedance of Zn/df against a speaker whose impedance rises to
    /// 4x nominal at resonance and 2x at the top lifts the terminal voltage by
    /// these amounts.  Cheap enough to read straight off the current value.
    private var xfmrLift: (bell: Float, top: Float) {
        let df = max(tube.xfmrDamping, TUBE_XFMR_DAMPING_MIN)
        let bump = 4 * (df + 1) / (4 * df + 1)
        let top = 2 * (df + 1) / (2 * df + 1)
        return (20 * log10(bump), 20 * log10(top))
    }

    private var transformerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("OUTPUT STAGE")
                    Text("A valve amplifier's loose grip on the speaker.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { tube.xfmrEnabled },
                    set: { vm.setTubeXfmr($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!vm.isDeviceConnected)
            }
            .help("A tube amplifier's high source impedance lets the speaker's own impedance curve shape the response: a broad bump at the woofer resonance and a small lift at the top. Nothing here is nonlinear, and the firmware skips the whole stage while it is off.")

            // The firmware compiles these stages out of the loop it runs while
            // the stage is off, so they are hidden rather than shown doing
            // nothing.
            if tube.xfmrEnabled {
                let lift = xfmrLift

                paramRow(
                    title: "Damping Factor",
                    unit: "",
                    value: tube.xfmrDamping,
                    range: TUBE_XFMR_DAMPING_MIN...TUBE_XFMR_DAMPING_MAX,
                    scrollStep: 0.5,
                    maxDecimals: 1,
                    ends: ("1 (loose)", "20 (tight)"),
                    liveIndex: TUBE_PARAM_XFMR_DAMPING,
                    help: "The speaker's nominal impedance divided by the amplifier's source impedance. A single-ended triode amplifier without feedback sits around 2 to 3; a push-pull pentode amplifier with feedback around 8 to 15. It sets the size of both the bell and the top lift.",
                    set: { vm.setTubeXfmrDamping($0) }
                )

                Text(String(format: "+%.1f dB at resonance, +%.1f dB at the top.",
                            lift.bell, lift.top))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                paramRow(
                    title: "Speaker Resonance",
                    unit: "Hz",
                    value: tube.xfmrResHz,
                    range: TUBE_XFMR_RES_MIN...TUBE_XFMR_RES_MAX,
                    scrollStep: 1,
                    maxDecimals: 0,
                    ends: ("30 Hz", "150 Hz"),
                    liveIndex: TUBE_PARAM_XFMR_RES_HZ,
                    help: "Where the loudspeaker resonates in its enclosure, which is where the bell sits. Q is fixed at 0.707, so the bump is broad. 85 Hz suits a typical small to medium woofer; larger drivers sit lower.",
                    set: { vm.setTubeXfmrRes($0) }
                )
            }
        }
    }

    // MARK: - Parameter Row

    /// Wraps the shared `ParameterRow`, adding the device-only live send so a
    /// drag never publishes.  `index`, `lo` and `hi` are the firmware's, so the
    /// live path clamps exactly as the committing setter does.
    private func paramRow(
        title: String,
        unit: String,
        value: Float,
        range: ClosedRange<Float>,
        scrollStep: Float,
        maxDecimals: Int,
        ends: (String, String)? = nil,
        displayOverride: String? = nil,
        liveIndex: UInt16,
        liveShaper: ((Float) -> TubeShaper)? = nil,
        help: String,
        set: @escaping (Float) -> Void
    ) -> some View {
        ParameterRow(
            title: title,
            unit: unit,
            value: value,
            range: range,
            scrollStep: scrollStep,
            maxDecimals: maxDecimals,
            ends: ends,
            displayOverride: displayOverride,
            isEnabled: vm.isDeviceConnected,
            help: help,
            live: { v in
                vm.sendTubeParamToDevice(liveIndex, v, range.lowerBound, range.upperBound)
                if let liveShaper { graphLive.shaper = liveShaper(v) }
            },
            set: set
        )
    }
}

// MARK: - Tube Icon

/// A vacuum tube drawn on a 24-point grid, sized to sit beside the SF Symbols
/// the other tool windows use in their headers.  The glass, base and pins take
/// the foreground colour; the filament glows only while the effect is on, so
/// the header doubles as a status light.
struct TubeIcon: View {
    var lit: Bool

    var body: some View {
        GeometryReader { geo in
            // 1.9 pt at the 27-point header size, scaling with the frame.
            let w = min(geo.size.width, geo.size.height) * 1.9 / 27
            ZStack {
                TubeIconShape(part: .envelope)
                    .stroke(style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                TubeIconShape(part: .base).fill()
                TubeIconShape(part: .pins)
                    .stroke(style: StrokeStyle(lineWidth: w, lineCap: .round))
                TubeIconShape(part: .rods)
                    .stroke(style: StrokeStyle(lineWidth: w * 0.8, lineCap: .round))
                // Both layers stay in place and cross-fade, so the filament
                // warms and cools rather than switching.
                TubeIconShape(part: .filament)
                    .stroke(style: StrokeStyle(lineWidth: w * 0.8, lineCap: .round))
                    .opacity(lit ? 0 : 1)
                TubeIconShape(part: .filament)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: w, lineCap: .round))
                    .shadow(color: .orange.opacity(0.9), radius: geo.size.width / 14)
                    .opacity(lit ? 1 : 0)
            }
        }
        // A heater takes a moment to glow and a little less to go dark.
        .animation(.easeInOut(duration: lit ? 0.9 : 0.6), value: lit)
    }
}

private struct TubeIconShape: Shape {
    enum Part { case envelope, base, pins, rods, filament }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var path = Path()
        switch part {
        case .envelope:
            // Straight-sided glass with a round dome and the exhaust tip.
            path.move(to: p(5.5, 17))
            path.addLine(to: p(5.5, 8.5))
            path.addArc(center: p(12, 8.5), radius: 6.5 * s,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: p(18.5, 17))
            path.move(to: p(12, 2))
            path.addLine(to: p(12, 0.8))
        case .base:
            path.addRoundedRect(in: CGRect(origin: p(4.5, 16.8), size: CGSize(width: 15 * s, height: 3.6 * s)),
                                cornerSize: CGSize(width: 1.2 * s, height: 1.2 * s))
        case .pins:
            for x: CGFloat in [8.5, 12, 15.5] {
                path.move(to: p(x, 20.4))
                path.addLine(to: p(x, 23.2))
            }
        case .rods:
            // The heater's support wires, rising from the base.
            path.move(to: p(10.5, 16.8)); path.addLine(to: p(10.5, 11))
            path.move(to: p(13.5, 16.8)); path.addLine(to: p(13.5, 11))
        case .filament:
            path.move(to: p(10.5, 11))
            path.addQuadCurve(to: p(13.5, 11), control: p(12, 6.5))
        }
        return path
    }
}

// MARK: - Shaper Model

/// The firmware's static waveshaper (spec §1), evaluated in Double for the
/// graph.  It is the real curve rather than a sketch: drive, bias, the two knees,
/// the hardness blend, the rest-point offset, mix and trim.  What it leaves out
/// is everything with memory - sag, the DC blocker and the output stage - which
/// is why the graph is labelled a transfer curve and not a frequency response.
struct TubeShaper: Equatable {
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
        // The firmware carries 1/m makeup gain in the half scales, so drive
        // moves the knee rather than the level and clean material keeps unity
        // small-signal gain at every drive and hardness.
        sP = 1 / (c1 * m)
        sN = pow(10, Double(asymDB) / 20) / (c1 * m)
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

/// SwiftUI retains this subtree while its shaper is unchanged, so unrelated
/// settings updates never repeat the harmonic analysis.
private struct TubeHarmonicsReadout: View, Equatable {
    let shaper: TubeShaper

    /// The second and third harmonic a full-scale sine comes out with, as the
    /// graph's caption.  They are the two numbers the character controls trade
    /// against each other: bias and asymmetry raise the even one, drive and
    /// hardness the odd one.
    var body: some View {
        let h = shaper.harmonics()
        return HStack(spacing: 16) {
            Text("AT FULL SCALE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Spacer()
            harmonicValue("2nd", h.second)
            harmonicValue("3rd", h.third)
        }
        .help("Level of the second and third harmonic relative to the fundamental, for a full-scale sine through the static curve after mix and trim. Sag lowers the drive on sustained loud passages and the output stage adds its own low-frequency lift, so the running figures sit somewhat lower.")
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

}

// MARK: - Live Graph

/// The override the transfer graph shows while a parameter is being dragged.
/// Observed only by `TubeGraphPane`, inside its own hosting view.
final class TubeGraphLive: ObservableObject {
    @Published var shaper: TubeShaper?
}

/// The graph and its harmonics readout, resolving the live override over the
/// committed shaper. Lives in a `LiveGraphHost`, so a live update costs the
/// layout of this tree and nothing else.
private struct TubeGraphPane: View {
    let base: TubeShaper
    let isEnabled: Bool
    @ObservedObject var live: TubeGraphLive

    var body: some View {
        let shaper = live.shaper ?? base
        // The commit on release changes `base` to the value the override
        // already shows, so clearing here moves nothing visibly.
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                TubeTransferView(shaper: shaper, isEnabled: isEnabled)
                    .equatable()
                    .padding(8)
            }
            .frame(height: 188)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )

            TubeHarmonicsReadout(shaper: shaper)
                .equatable()
                .padding(.top, 4)
        }
        .onChange(of: base) { _ in live.shaper = nil }
    }
}

// MARK: - Transfer Curve Visualization

/// Output against input over one full-scale swing, with the straight line a
/// clean stage would draw for comparison.  Inputs that drive the stage past
/// either knee are shaded: that is where the curve goes flat and the harmonics
/// come from.  Asymmetry shows as the two shaded regions starting at different
/// distances from the centre, bias as the curve's bend being off-centre.
private struct TubeTransferView: View, Equatable {
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
