import SwiftUI

// MARK: - Subharmonic Synthesizer Window Controller

class SubharmonicSynthWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    /// Held so the window can clear solo on close.  Solo removes the program
    /// signal from the masked outputs, so it must never outlive the panel that
    /// switched it on - the firmware keeps it across a preset load.
    private weak var vm: DSPViewModel?

    func show(vm: DSPViewModel) {
        self.vm = vm
        if window == nil {
            let view = SubharmonicSynthView(vm: vm, controller: self).onboardingHint("subharm")

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Subharmonic Synthesizer"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 740, height: 612)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
        clearSolo()
    }

    /// Puts the program signal back on the masked outputs.  Only sends when the
    /// app believes solo is on, so closing the window is otherwise silent.
    private func clearSolo() {
        guard let vm, vm.subharmSolo else { return }
        vm.setSubharmSolo(false)
    }
}

extension SubharmonicSynthWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
        clearSolo()
    }
}

// MARK: - Starting Points (spec §6)

private struct SubharmStartingPoint {
    let name: String
    let detail: String
    let low: Float
    let high: Float
    let boost: Float
}

/// The spec's own table.  None of them uses the 56-80 Hz band, which is why
/// applying one sets it back to its floor rather than leaving it where it was:
/// a starting point that only half applies is worse than none.
private let subharmStartingPoints: [SubharmStartingPoint] = [
    SubharmStartingPoint(name: "Subwoofer feed",   detail: "Subtle added weight",    low: -6, high: -6,  boost: 0),
    SubharmStartingPoint(name: "Club / large PA",  detail: "Lower two bands, full", low: 0,  high: 0,   boost: 3),
    SubharmStartingPoint(name: "Thin recordings",  detail: "Add a missing bottom",   low: 0,  high: -6,  boost: 3),
    SubharmStartingPoint(name: "Cinema LFE",       detail: "Lowest octave only",     low: 3,  high: -12, boost: 0),
]

// MARK: - Subharmonic Synthesizer View

struct SubharmonicSynthView: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var controller: SubharmonicSynthWindowController

    /// The sub meter is a decaying peak the firmware updates per packet; 10 Hz
    /// is enough to watch a band level land without loading the control pipe.
    private let meterTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Output channels exposed in the mask grid (5 on RP2040, 9 on RP2350).
    private var outputCount: Int { vm.numOutputChannels }

    /// The whole feature ships in wire format V29; hide the interactive body on
    /// older firmware and show an upgrade note instead.
    private var supported: Bool { vm.firmwareSupportsSubharm }

    /// The third band, selectivity, the ceiling, the pair link and solo arrived
    /// at V30.  On V29 firmware those commands STALL, so the sections are hidden
    /// rather than shown dead.
    private var extended: Bool { vm.firmwareSupportsSubharmExtended }

    /// Mask with every valid output bit set.
    private var allOutputsMask: UInt16 {
        outputCount >= 16 ? 0xFFFF : UInt16((1 << outputCount) - 1)
    }

    /// The PDM sub alone - the recommended starting mask, since a synthesized
    /// fundamental is only worth making on an output that can reproduce it.
    private var subOnlyMask: UInt16 {
        UInt16(1) << vm.pdmOutputIndex
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
                // Two columns of the sections the other tool windows stack.
                // The graph sits over the band levels that move it, at a
                // column's width; the right column runs the rest of the
                // signal path top to bottom.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        bandGraph
                        Divider()
                        bandsColumn
                    }
                    .column()

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        if extended {
                            selectivitySection
                            Divider()
                            ceilingSection
                            Divider()
                        }
                        boostSection
                        Divider()
                        outputSection
                    }
                    .column()
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 16)
            } else {
                unsupportedNote
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // The bulk fetch carries every field except the headroom, which the
            // firmware derives on demand, and solo, which is runtime-only and
            // deliberately absent from the wire.  Read both once so the window
            // opens with live figures rather than stale defaults.
            guard supported else { return }
            vm.fetchSubharmRuntimeState()
        }
        .onReceive(meterTimer) { _ in
            // Only while the panel is up and something can actually be metered.
            guard controller.isVisible, extended, vm.isDeviceConnected, vm.subharmEnabled else { return }
            DispatchQueue.global(qos: .utility).async { vm.fetchSubharmMeter() }
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
            Image(systemName: "waveform.path.badge.minus")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Subharmonic Synthesizer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Octave divider - adds a real fundamental below the bass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if extended { soloButton }

            Toggle("", isOn: Binding(
                get: { vm.subharmEnabled },
                set: { vm.setSubharm($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected || !supported)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Monitoring solo.  It latches rather than being press-and-hold, because
    /// the point of it is to dial the band levels in while listening to the sub
    /// alone; closing the window clears it, and the firmware never writes it to
    /// a preset, so it cannot escape this panel.
    private var soloButton: some View {
        Button(action: { vm.setSubharmSolo(!vm.subharmSolo) }) {
            Text("SOLO")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .foregroundColor(vm.subharmSolo ? .white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(vm.subharmSolo ? Color.orange : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(!vm.isDeviceConnected || !vm.subharmEnabled)
        .opacity(vm.subharmEnabled ? 1 : 0.4)
        .help(vm.subharmSolo
              ? "The selected outputs are carrying the synthesized sub only - the program signal is muted on them. Closing this window switches it off."
              : "Mute the program signal on the selected outputs so the synthesized sub can be heard or measured on its own. Never saved to a preset.")
        .animation(.easeInOut(duration: 0.12), value: vm.subharmSolo)
    }

    private var unsupportedNote: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Requires firmware with wire format V29 or newer.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Update the DSPi firmware to use the Subharmonic Synthesizer.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Band Graph

    private var bandGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("BANDS")
                Spacer()
                startingPointsMenu
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                SubharmBandView(
                    lowDB: vm.subharmLowDB,
                    highDB: vm.subharmHighDB,
                    topDB: extended ? vm.subharmTopDB : SUBHARM_LEVEL_MIN,
                    boostDB: vm.subharmBoostDB,
                    ceilingDB: extended ? vm.subharmCeilingDB : SUBHARM_CEILING_MAX,
                    isEnabled: vm.subharmEnabled
                )
                .padding(8)
            }
            .frame(height: 188)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )

            headroomReadout
                .padding(.top, 4)
        }
    }

    /// The worst-case gain of the current setting, sitting under the graph as
    /// its caption: it is a property of what the graph is showing, and the number moves
    /// whenever a band level, the boost or the ceiling does.  Shown as a
    /// requirement rather than a suggestion - the effect is amplitude-linear,
    /// so lowering the preamp by this much is exact.
    private var headroomReadout: some View {
        HStack(spacing: 6) {
            sectionLabel("HEADROOM COST")

            Spacer()

            Text(vm.subharmHeadroomDB > 0
                 ? String(format: "%+.1f dB", vm.subharmHeadroomDB)
                 : "none")
                .font(.system(size: 11))
                .foregroundColor(vm.subharmHeadroomDB > 0 ? .orange : .secondary)
        }
        .help(vm.subharmHeadroomDB > 0
              ? "This setting can add up to \(String(format: "%.1f", vm.subharmHeadroomDB)) dB. Lower the preamp on the inputs feeding the selected outputs by that much, or a loud passage will clip."
              : "This setting cannot push the signal past full scale.")
    }

    private var startingPointsMenu: some View {
        Menu {
            ForEach(0..<subharmStartingPoints.count, id: \.self) { i in
                let p = subharmStartingPoints[i]
                Button("\(p.name) - \(p.detail)") {
                    vm.setSubharmLow(p.low)
                    vm.setSubharmHigh(p.high)
                    vm.setSubharmBoost(p.boost)
                    if extended { vm.setSubharmTop(SUBHARM_LEVEL_MIN) }
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

    // MARK: - Bands

    private var bandsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("LEVELS")

            bandRow(
                title: "24 - 36 Hz",
                source: "48 - 72 Hz",
                value: vm.subharmLowDB,
                help: "Level of the sub synthesized from program content between 48 and 72 Hz. At 0 dB it comes out 1.4 dB below the bass that produced it, which is the divider's own gain.",
                set: { vm.setSubharmLow($0) }
            )

            Divider()

            bandRow(
                title: "36 - 56 Hz",
                source: "72 - 112 Hz",
                value: vm.subharmHighDB,
                help: "Level of the sub synthesized from program content between 72 and 112 Hz. This band has its own divider, so a bass note here and a kick in the band below are tracked independently.",
                set: { vm.setSubharmHigh($0) }
            )

            if extended {
                Divider()

                bandRow(
                    title: "56 - 80 Hz",
                    source: "112 - 160 Hz",
                    value: vm.subharmTopDB,
                    help: "Level of the sub synthesized from program content between 112 and 160 Hz. It ships off: this band reaches up into the range where a divided sub starts to compete with the program's own fundamentals. Turn it up for a subwoofer that cannot reach the lowest octave.",
                    set: { vm.setSubharmTop($0) }
                )
            }
        }
    }

    /// One band-level row.  The floor is a real setting rather than the bottom
    /// of a range - it switches the band off and skips its divider - so the
    /// field reads "Off" there instead of "-30.0".  The explanation is a
    /// tooltip here: inline, it would set the height of the whole row.
    private func bandRow(
        title: String,
        source: String,
        value: Float,
        help: String,
        set: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The title is the sub the band adds; the caption names the
                // program range it is synthesized from, an octave above.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text("Derived from \(source)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                ValueField(
                    label: "dB",
                    value: value,
                    width: 60,
                    scrollStep: 0.5,
                    maxDecimals: 1,
                    displayOverride: value <= SUBHARM_LEVEL_MIN ? "Off" : nil
                ) { set(min(max($0, SUBHARM_LEVEL_MIN), SUBHARM_LEVEL_MAX)) }
            }

            CustomSlider(
                value: Binding(get: { value }, set: { set($0) }),
                range: SUBHARM_LEVEL_MIN...SUBHARM_LEVEL_MAX
            )
            .disabled(!vm.isDeviceConnected)

            HStack {
                Text("Off")
                Spacer()
                Text(String(format: "%+.0f dB", SUBHARM_LEVEL_MAX))
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
        .help(help)
    }

    // MARK: - Selectivity (V30)

    private var selectivityActive: Bool { vm.subharmSelectMode != SUBHARM_SELECT_ALL }

    private var selectivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SELECTIVITY")

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: Binding(
                    get: { vm.subharmSelectMode },
                    set: { vm.setSubharmSelectMode($0) }
                )) {
                    Text("All material").tag(SUBHARM_SELECT_ALL)
                    Text("Percussive").tag(SUBHARM_SELECT_PERCUSSIVE)
                    Text("Sustained").tag(SUBHARM_SELECT_SUSTAINED)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)

                Text(selectivitySummary)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(selectivityHelp)

            // Depth and hold are ignored by the firmware in "all material" mode,
            // so they are hidden there rather than shown doing nothing.
            if selectivityActive {
                paramRow(
                    title: "Depth",
                    unit: "%",
                    value: vm.subharmSelectDepthPct,
                    range: SUBHARM_DEPTH_MIN...SUBHARM_DEPTH_MAX,
                    scrollStep: 5,
                    maxDecimals: 0,
                    help: "How far the material this mode does not favour is gated down. At 0% the selectivity is inaudible whatever the mode is set to; 100% is full gating.",
                    set: { vm.setSubharmSelectDepth($0) }
                )

                paramRow(
                    title: "Hold",
                    unit: "ms",
                    value: vm.subharmSelectHoldMs,
                    range: SUBHARM_HOLD_MIN_MS...SUBHARM_HOLD_MAX_MS,
                    scrollStep: 10,
                    maxDecimals: 0,
                    help: vm.subharmSelectMode == SUBHARM_SELECT_PERCUSSIVE
                        ? "The length of the sub burst after each attack."
                        : "How long a band must ring before its sub opens. Every note's first hold period has no sub, so staccato bass lines get little.",
                    set: { vm.setSubharmSelectHold($0) }
                )
            }
        }
    }

    /// One line under the picker; the full explanation is its tooltip.
    private var selectivitySummary: String {
        switch vm.subharmSelectMode {
        case SUBHARM_SELECT_PERCUSSIVE: return "A short sub burst after each attack - extends kicks, not the bass line."
        case SUBHARM_SELECT_SUSTAINED:  return "The sub opens once a band has been ringing - extends bass notes, not kicks."
        default:                        return "Every band signal is treated alike."
        }
    }

    private var selectivityHelp: String {
        switch vm.subharmSelectMode {
        case SUBHARM_SELECT_PERCUSSIVE:
            return "A short sub burst after each attack, so a kick can be extended without extending the bass line under it. The most robust of the three: a held note gets nothing between kicks."
        case SUBHARM_SELECT_SUSTAINED:
            return "The sub opens only after a band has been ringing, so bass notes are extended and kicks are not. A kick landing in the same band ducks the held note's sub, which pumps on a four-on-the-floor line - shorten the hold or lower the depth to soften it."
        default:
            return "Every band signal is treated alike. Choose percussive or sustained to weight the synthesized sub toward one kind of bass material; the gate decides per band from time behaviour, so it cannot separate two sources sounding at once in the same band."
        }
    }

    // MARK: - Sub Ceiling (V30)

    private var ceilingOff: Bool { vm.subharmCeilingDB >= SUBHARM_CEILING_MAX }

    private var ceilingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SUB CEILING")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "dB",
                        value: vm.subharmCeilingDB,
                        width: 60,
                        scrollStep: 1,
                        maxDecimals: 0,
                        displayOverride: ceilingOff ? "Off" : nil
                    ) { vm.setSubharmCeiling(min(max($0, SUBHARM_CEILING_MIN), SUBHARM_CEILING_MAX)) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.subharmCeilingDB },
                        set: { vm.setSubharmCeiling($0) }
                    ),
                    range: SUBHARM_CEILING_MIN...SUBHARM_CEILING_MAX
                )
                .disabled(!vm.isDeviceConnected)

                HStack {
                    Text("-40 dBFS")
                    Spacer()
                    Text("Off")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .help("A soft limit on the synthesized sub just before it is mixed back in, capping how far it can push a driver without touching the program signal. It is an absolute level, so a ceiling at full scale limits nothing and means the stage is off. With it on, the headroom cost is only the ceiling's worth. A loud onset overshoots it by a few dB for the first few milliseconds while the limiter's 3 ms attack catches up.")
    }

    // MARK: - LF Boost

    private var boostSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("LF BOOST")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("70 Hz bell")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "dB",
                        value: vm.subharmBoostDB,
                        width: 60,
                        scrollStep: 0.5,
                        maxDecimals: 1
                    ) { vm.setSubharmBoost(min(max($0, SUBHARM_BOOST_MIN), SUBHARM_BOOST_MAX)) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.subharmBoostDB },
                        set: { vm.setSubharmBoost($0) }
                    ),
                    range: SUBHARM_BOOST_MIN...SUBHARM_BOOST_MAX
                )
                .disabled(!vm.isDeviceConnected)

                HStack {
                    Text("Off")
                    Spacer()
                    Text(String(format: "%+.0f dB", SUBHARM_BOOST_MAX))
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .help("A gentle bell at 70 Hz, Q 0.9, applied to the whole output after the subs are summed. It fills the gap between the synthesized sub and the program's own mid-bass. Meant to stay gentle, as on the dbx.")
    }

    // MARK: - Output Channels

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("OUTPUTS")
                Spacer()
                Menu {
                    Button("Sub only (recommended)") {
                        vm.setSubharmMask(subOnlyMask)
                    }
                    Button("All outputs") {
                        vm.setSubharmMask(allOutputsMask)
                    }
                    Button("None") {
                        vm.setSubharmMask(0x0000)
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
                        on: vm.subharmOutputMask & (UInt16(1) << out) != 0
                    ) {
                        vm.setSubharmOutputChannel(out, enabled: vm.subharmOutputMask & (UInt16(1) << out) == 0)
                    }
                }
            }
            .help("Select the outputs that can actually play 24 to 80 Hz. Subharm runs before the crossover, so a satellite with a highpass loses the sub again - mask it off and save the CPU instead.")

            if extended {
                linkPairsRow
                    .padding(.top, 4)
            }
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

            if extended {
                // A masked-off output is never metered by the firmware, so its
                // rail stays empty rather than showing a stale reading.  The
                // bar is the synthesized sub on its own, not the output.
                HorizontalMeterBar(
                    level: on ? subMeterLevel(out) : Float(0),
                    color: .accentColor
                )
                .frame(height: 3)
                .opacity(on ? 1 : 0.25)
            }
        }
        .help(outputName(out))
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    private func subMeterLevel(_ out: Int) -> Float {
        out < vm.subharmSubMeter.count ? vm.subharmSubMeter[out] : 0
    }

    private var linkPairsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link output pairs")
                    .font(.system(size: 12, weight: .medium))
                Text("One sub per pair, from its mono sum.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.subharmLinkPairs },
                set: { vm.setSubharmLinkPairs($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!vm.isDeviceConnected)
        }
        .help("Synthesize one sub per output pair from its mono sum and feed it to both channels, as the dbx does. Bass is near-mono in most material, and two independent dividers can land on opposite polarities, which cancels a centred note's sub between the speakers.")
    }

    // MARK: - Parameter Row

    /// The labelled ValueField + CustomSlider row the other tool windows use.
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
                ) { set(min(max($0, range.lowerBound), range.upperBound)) }
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

private extension View {
    /// One column of the control row: equal share of the width, content pinned
    /// to the top so section labels line up across columns.
    func column() -> some View {
        self
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Band Visualization

/// What the divider makes, on a real dB scale: the three program bands it
/// listens to, the three subs it synthesizes an octave below them, the LF boost
/// bell over the dry path, and the ceiling the sub is held under.
///
/// The bell curve is the analog prototype the firmware's Cytomic bell
/// implements, so it is a true magnitude rather than a sketch.  The sub blocks
/// are steady-state levels - band level plus the divider's own 0.849 gain, times
/// the bell at that frequency - which makes the axis read as dBFS for a
/// full-scale band, and the ceiling line sit where it actually bites.  What no
/// still picture can show is the divider's defining property, that the sub's
/// envelope follows the note that made it.
private struct SubharmBandView: View {
    let lowDB: Float
    let highDB: Float
    let topDB: Float
    let boostDB: Float
    let ceilingDB: Float
    let isEnabled: Bool

    private let minFreq: CGFloat = 16.0
    private let maxFreq: CGFloat = 250.0
    private let dbMin: CGFloat = -42.0
    /// Top of scale.  The loudest thing the graph can draw is a band at
    /// SUBHARM_LEVEL_MAX plus the divider's 0.849 gain and the bell at its own
    /// maximum, about +16.6 dB, so 18 keeps the hottest setting on-scale instead
    /// of flattening the blocks against the ceiling of the plot.
    private let dbMax: CGFloat = 18.0
    /// Room under the plot for the frequency labels.
    private let axisStrip: CGFloat = 13.0
    /// Room above the plot for the source-band brackets and the three octave
    /// arrows, so neither can ever land on the curve or the blocks.
    private let annotationStrip: CGFloat = 38.0

    private func xPos(_ freq: CGFloat, w: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(min(max(freq, minFreq), maxFreq))
        return (logVal - logMin) / (logMax - logMin) * w
    }

    /// Maps dB into the curve area only - below the annotation strip, above the
    /// frequency labels.
    private func yPos(_ db: CGFloat, h: CGFloat) -> CGFloat {
        let top = annotationStrip
        let bottom = h - axisStrip
        let clamped = min(max(db, dbMin), dbMax)
        return bottom - (clamped - dbMin) / (dbMax - dbMin) * (bottom - top)
    }

    private func baseline(_ h: CGFloat) -> CGFloat { h - axisStrip }

    /// Magnitude of the 70 Hz LF boost bell in dB.  Standard analog peaking
    /// prototype: with A = 10^(boost/40) the peak gain is A^2, which is exactly
    /// what the firmware's `k (A^2 - 1) v1` mix produces.
    private func bellDB(_ freq: CGFloat) -> CGFloat {
        guard boostDB > 0 else { return 0 }
        let a = pow(10.0, CGFloat(boostDB) / 40.0)
        let q = CGFloat(SUBHARM_BOOST_Q)
        let w = freq / CGFloat(SUBHARM_BOOST_HZ)
        let base = (1 - w * w) * (1 - w * w)
        let num = base + pow(a * w / q, 2)
        let den = base + pow(w / (a * q), 2)
        return 10 * log10(num / den)
    }

    /// Steady-state level of a synthesized sub at `freq`: the band level, the
    /// divider's natural 0.849 gain, and whatever the bell does there.
    private func subDB(_ bandDB: Float, at freq: CGFloat) -> CGFloat {
        CGFloat(bandDB) + 20 * log10(CGFloat(SUBHARM_DIVIDER_GAIN)) + bellDB(freq)
    }

    private func isOff(_ bandDB: Float) -> Bool { bandDB <= SUBHARM_LEVEL_MIN }

    private var ceilingOn: Bool { ceilingDB < SUBHARM_CEILING_MAX }

    private var allBandsOff: Bool { isOff(lowDB) && isOff(highDB) && isOff(topDB) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                grid(w: w, h: h)

                if isEnabled {
                    // The program bands the dividers listen to, drawn behind the
                    // subs so the overlaps read as a stack.
                    sourceBand(from: 48, to: 72, w: w, h: h, dimmed: isOff(lowDB))
                    sourceBand(from: 72, to: 112, w: w, h: h, dimmed: isOff(highDB))
                    sourceBand(from: 112, to: 160, w: w, h: h, dimmed: isOff(topDB))

                    // The LF boost over the dry path.  Only drawn when it does
                    // something: at 0 dB the stage is skipped and the curve
                    // would be the 0 dB gridline redrawn.
                    if boostDB > 0 {
                        bellCurve(w: w, h: h)
                        bellLabel(w: w, h: h)
                    }

                    if !isOff(lowDB) {
                        subBlock(from: 24, to: 36, level: lowDB, color: .accentColor, w: w, h: h)
                        octaveArrow(from: 60, to: 30, y: 15, w: w)
                    }
                    if !isOff(highDB) {
                        subBlock(from: 36, to: 56, level: highDB, color: .orange, w: w, h: h)
                        octaveArrow(from: 92, to: 46, y: 23, w: w)
                    }
                    if !isOff(topDB) {
                        subBlock(from: 56, to: 80, level: topDB, color: .purple, w: w, h: h)
                        octaveArrow(from: 136, to: 68, y: 31, w: w)
                    }

                    // Where the limiter starts holding the sub down.  The axis is
                    // dBFS for a full-scale band, so this is the real threshold,
                    // not a decoration.
                    if ceilingOn && !allBandsOff {
                        ceilingLine(w: w, h: h)
                    }

                    if allBandsOff {
                        Text("All bands off")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                            .position(x: w / 2, y: (annotationStrip + baseline(h)) / 2)
                    }
                } else {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .position(x: w / 2, y: (annotationStrip + baseline(h)) / 2)
                }

                freqLabels(w: w, h: h)
            }
            .clipped()
        }
    }

    // MARK: Graph pieces

    /// Frequency verticals, the 0 dB reference, and three quiet level lines so
    /// the block heights can be read rather than just compared.
    private func grid(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for f in [20.0, 50.0, 100.0, 200.0] as [CGFloat] {
                    let x = xPos(f, w: w)
                    path.move(to: CGPoint(x: x, y: annotationStrip))
                    path.addLine(to: CGPoint(x: x, y: baseline(h)))
                }
                for db in [12.0, -12.0, -24.0, -36.0] as [CGFloat] {
                    let y = yPos(db, h: h)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                path.move(to: CGPoint(x: 0, y: baseline(h)))
                path.addLine(to: CGPoint(x: w, y: baseline(h)))
            }
            .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)

            Path { path in
                let y = yPos(0, h: h)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: w, y: y))
            }
            .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)

            // Level labels hug the left edge, which is always empty: nothing the
            // effect makes reaches below 24 Hz.
            ForEach([12, 0, -12, -24, -36], id: \.self) { db in
                Text(db > 0 ? "+\(db)" : "\(db)")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
                    .position(x: 9, y: yPos(CGFloat(db), h: h) - 5)
            }
        }
    }

    /// A program band: shaded over the curve area, with a bracket and its range
    /// in the annotation strip above.
    private func sourceBand(from lo: CGFloat, to hi: CGFloat, w: CGFloat, h: CGFloat, dimmed: Bool) -> some View {
        let x0 = xPos(lo, w: w)
        let x1 = xPos(hi, w: w)
        let top = annotationStrip
        let bottom = baseline(h)
        let opacity = dimmed ? 0.04 : 0.10
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(opacity))
                .frame(width: max(0, x1 - x0), height: max(0, bottom - top))
                .position(x: (x0 + x1) / 2, y: (top + bottom) / 2)

            // Bracket over the band, so adjacent bands stay distinguishable
            // where their shading meets at 72 and 112 Hz.
            Path { path in
                path.move(to: CGPoint(x: x0 + 1, y: 9))
                path.addLine(to: CGPoint(x: x0 + 1, y: 5))
                path.addLine(to: CGPoint(x: x1 - 1, y: 5))
                path.addLine(to: CGPoint(x: x1 - 1, y: 9))
            }
            .stroke(Color.secondary.opacity(dimmed ? 0.25 : 0.5), lineWidth: 1)

            Text("\(Int(lo))-\(Int(hi))")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(dimmed ? 0.4 : 0.85))
                .padding(.horizontal, 2)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                .position(x: (x0 + x1) / 2, y: 5)
        }
    }

    /// The LF boost bell over the dry path.
    private func bellCurve(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            let steps = 96
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let f = pow(10, log10(minFreq) + t * (log10(maxFreq) - log10(minFreq)))
                let pt = CGPoint(x: t * w, y: yPos(bellDB(f), h: h))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        .stroke(Color.green.opacity(0.8),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    /// Names the bell curve at its 70 Hz peak.  Sits above the curve, inside the
    /// curve area, so it never reaches the annotation strip.
    private func bellLabel(w: CGFloat, h: CGFloat) -> some View {
        Text("LF boost")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.green.opacity(0.9))
            .padding(.horizontal, 2)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            .position(x: xPos(CGFloat(SUBHARM_BOOST_HZ), w: w),
                      y: max(annotationStrip + 5,
                             yPos(bellDB(CGFloat(SUBHARM_BOOST_HZ)), h: h) - 8))
    }

    /// The sub ceiling, drawn across the sub range only: it limits the
    /// synthesized sub, not the program, so a line spanning the whole plot would
    /// claim more than the limiter does.
    private func ceilingLine(w: CGFloat, h: CGFloat) -> some View {
        let y = yPos(CGFloat(ceilingDB), h: h)
        let x1 = xPos(80, w: w)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: x1, y: y))
            }
            .stroke(Color.red.opacity(0.65),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

            Text("ceiling")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.red.opacity(0.8))
                .padding(.horizontal, 2)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                .position(x: x1 + 18, y: y)
        }
    }

    /// One synthesized sub band.  The top follows the bell across the band
    /// rather than sitting flat, so a boost visibly tilts it, and the outline
    /// keeps neighbouring bands apart where they meet at 36 and 56 Hz.
    private func subBlock(from lo: CGFloat, to hi: CGFloat, level: Float,
                          color: Color, w: CGFloat, h: CGFloat) -> some View {
        let x0 = xPos(lo, w: w)
        let x1 = xPos(hi, w: w)
        let bottom = baseline(h)
        let topAt = { (f: CGFloat) in self.yPos(self.subDB(level, at: f), h: h) }
        let shape = Path { path in
            path.move(to: CGPoint(x: x0, y: bottom))
            let steps = 16
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let f = lo * pow(hi / lo, t)
                path.addLine(to: CGPoint(x: x0 + t * (x1 - x0), y: topAt(f)))
            }
            path.addLine(to: CGPoint(x: x1, y: bottom))
            path.closeSubpath()
        }
        let midTop = topAt(sqrt(lo * hi))
        return ZStack {
            shape.fill(color.opacity(0.4))
            shape.stroke(color.opacity(0.9), lineWidth: 1)

            // Inside the block when it is tall enough to hold the text, just
            // above it when a near-floor level leaves no room.
            Text("\(Int(lo))-\(Int(hi))")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(bottom - midTop > 18 ? .white.opacity(0.9) : .primary.opacity(0.7))
                .position(x: (x0 + x1) / 2,
                          y: bottom - midTop > 18 ? midTop + 8 : midTop - 6)
        }
    }

    /// A dashed hop from a program band down to the sub it produces - the one
    /// thing the axes alone do not say, which is that this is an octave.  The
    /// three arrows sit on their own rows because on a log axis every octave is
    /// the same width and their spans overlap.
    private func octaveArrow(from: CGFloat, to: CGFloat, y: CGFloat, w: CGFloat) -> some View {
        let x0 = xPos(from, w: w)
        let x1 = xPos(to, w: w)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: x0, y: y))
                path.addLine(to: CGPoint(x: x1 + 3, y: y))
            }
            .stroke(Color.primary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

            Path { path in
                path.move(to: CGPoint(x: x1 + 4, y: y - 3))
                path.addLine(to: CGPoint(x: x1, y: y))
                path.addLine(to: CGPoint(x: x1 + 4, y: y + 3))
            }
            .stroke(Color.primary.opacity(0.45), lineWidth: 1)

            Text("÷2")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal, 2)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.9))
                .position(x: (x0 + x1) / 2, y: y)
        }
    }

    private func freqLabels(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            ForEach([20, 50, 100, 200], id: \.self) { f in
                Text("\(f)")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: xPos(CGFloat(f), w: w), y: h - 5)
            }
        }
    }
}
