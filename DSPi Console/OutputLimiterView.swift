import SwiftUI

// The output limiter lives on each output channel page, as an icon under the
// mute button in `ChannelSettingsView`.  A click toggles it and a right-click
// opens its settings popover; the page gains no height, so the filter list
// keeps every row it had.

// MARK: - Icon

/// The limiter's icon, after the speed-limiter symbol on car dashboards: a
/// gauge with a needle, and an arrowhead pointing in at the dial from outside.
/// Drawn rather than bundled so it stays sharp at any size and takes its
/// colour from the state.  Stroke the lines and fill the hub; see
/// `LimiterIcon`.
struct LimiterGlyph: Shape {
    enum Part { case lines, hub }
    var part: Part = .lines

    /// Degrees clockwise from straight up.
    private let needleDeg: CGFloat = -40
    private let arrowDeg: CGFloat = -45

    func path(in r: CGRect) -> Path {
        var p = Path()
        let s = min(r.width, r.height)
        // The dial sits low and right so the arrow has the top-left corner.
        let rad = s * 0.33
        let c = CGPoint(x: r.midX + s * 0.07, y: r.midY + s * 0.1)
        func pt(_ deg: CGFloat, _ rr: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + rr * sin(a), y: c.y - rr * cos(a))
        }

        // A small solid hub, so most of the needle's length stays visible.
        let hub = rad * 0.17
        if part == .hub {
            p.addEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
            return p
        }

        // Dial: a 270-degree arc, open at the bottom.
        let steps = 60
        for i in 0...steps {
            let d = -135 + 270 * CGFloat(i) / CGFloat(steps)
            if i == 0 { p.move(to: pt(d, rad)) } else { p.addLine(to: pt(d, rad)) }
        }

        // Needle, from under the hub.
        p.move(to: c)
        p.addLine(to: pt(needleDeg, rad * 0.72))

        // The arrow, as a head alone pointing in along the radius, its tip
        // stopping short of the dial so the two never merge into one mark.
        let tip = pt(arrowDeg, rad * 1.3), back = pt(arrowDeg, rad * 1.95)
        let dx = back.x - tip.x, dy = back.y - tip.y
        let len = sqrt(dx * dx + dy * dy)
        let ux = dx / len, uy = dy / len
        let head = rad * 0.34
        p.move(to: CGPoint(x: tip.x + head * (ux - uy), y: tip.y + head * (uy + ux)))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x + head * (ux + uy), y: tip.y + head * (uy - ux)))
        return p
    }
}

/// `LimiterGlyph` drawn: the lines stroked, the hub filled.  The two are
/// combined as a mask and filled once, because a translucent colour such as
/// `.secondary` drawn twice would show a lighter spot where they overlap.
struct LimiterIcon: View {
    let color: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        color.mask(
            ZStack {
                LimiterGlyph()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                LimiterGlyph(part: .hub)
            }
        )
    }
}

// MARK: - Channel Strip Cell

/// The limiter's icon under the mute button.  Grey when off, accent when on,
/// orange while it is reducing gain.  A click toggles it and a right-click
/// opens the settings popover, as the sidebar module icons do.  Hosted in its own `LiveGraphHost` by the
/// strip, so a meter reading re-lays out this icon and nothing else.
struct OutputLimiterCell: View {
    @ObservedObject var limiter: LimiterParameters
    @ObservedObject var meter: LimiterMeter
    let output: Int
    let isConnected: Bool
    let onToggle: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let s = output < limiter.outputs.count ? limiter.outputs[output] : LimiterOutputSettings()
        let gr = s.enabled && output < meter.reductionDB.count ? meter.reductionDB[output] : 0
        let limiting = gr >= 0.05

        // Sized so it reads as the same size as the speaker icon above it.
        LimiterIcon(color: limiting ? .orange : (s.enabled ? .accentColor : .secondary))
            .frame(width: 19, height: 19)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if isConnected { onToggle() } }
            .onRightClick { if isConnected { onSettings() } }
            .opacity(isConnected ? 1 : 0.5)
            .help(s.enabled
                  ? String(format: "Output limiter on, ceiling %.1f dBFS. Click to switch off, right-click for settings.", s.thresholdDB)
                  : "Output limiter off. Click to switch on, right-click for settings.")
    }
}

// MARK: - Link Group Control

/// The link-group picker, drawn in SwiftUI to match a native segmented
/// control.  It replaces `Picker(.segmented)`, which is an AppKit control with
/// a translucent backdrop: under the popover's opacity fade it flashed black
/// while fading back up, and its own disabled style popped in without fading.
/// Built from plain shapes, it fades with everything else and takes its
/// disabled state from the environment like any SwiftUI control.
/// Colours were sampled from the native control in dark mode.
private struct LinkGroupSegments: View {
    let selection: Int
    let select: (Int) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let groups = Array(0...LIMITER_LINK_GROUP_MAX)
    private let corner: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            ForEach(groups, id: \.self) { g in
                Button { select(g) } label: {
                    Text(g == 0 ? "Off" : "\(g)")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: corner - 1)
                                .fill(Color.white.opacity(g == selection ? 0.29 : 0))
                                .padding(1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(g == 0 ? "Not linked" : "Link group \(g)")
                .accessibilityAddTraits(g == selection ? .isSelected : [])

                // A separator only between two unselected segments, as the
                // native control draws it.
                if g != groups.last {
                    Rectangle()
                        .fill(Color.black.opacity(g == selection || g + 1 == selection ? 0 : 0.15))
                        .frame(width: 0.5)
                        .padding(.vertical, 5)
                }
            }
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: corner).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: - Settings Popover

/// Everything the cell cannot show: threshold, release, link group and the
/// actions that reach across outputs.
struct OutputLimiterSettings: View {
    @ObservedObject var vm: DSPViewModel
    /// Observed separately from `vm`; see ToolParameters.swift.
    @ObservedObject var limiter: LimiterParameters
    let output: Int

    private var outputCount: Int { min(vm.numOutputChannels, limiter.outputs.count) }

    private func outputName(_ out: Int) -> String {
        let idx = vm.chOut1 + out
        return idx < vm.channelNames.count ? vm.channelNames[idx] : "Out \(out + 1)"
    }

    /// Every committed change goes through here.  In independent mode the
    /// limiter is part of the output configuration, so an edit must mark it
    /// unsaved (and capture the revert baseline) before it lands.
    private func edit(_ change: () -> Void) {
        SettingsSaveCoordinator.shared.beginOutputEdit()
        change()
    }

    var body: some View {
        let s = output < limiter.outputs.count ? limiter.outputs[output] : LimiterOutputSettings()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output Limiter")
                        .font(.system(size: 13, weight: .semibold))
                    Text(outputName(output))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { s.enabled },
                    set: { on in edit { vm.setLimiterEnabled(output: output, on) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)
                .help("A test signal from the Signal Generator is limited like any other signal. Switch this output's limiter off for an unaltered full-scale measurement.")
            }

            // Greyed out and disabled while off, so an output without a
            // limiter never looks as if a ceiling were in force.  Always
            // present rather than shown on demand: a SwiftUI popover snaps to a
            // new size instead of animating it, so a popover that changed
            // height on the switch jumped under the pointer.
            settings(s)
                .disabled(!s.enabled)
                .opacity(s.enabled ? 1 : 0.4)
        }
        .padding(16)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.15), value: s.enabled)
        // On the whole popover, not the settings, which are greyed out and
        // disabled while the limiter is off, dismiss button included.
        .onboardingHint("limiter")
        // Re-created per output, so a slider's local state never carries over
        // when the page switches with the popover open.
        .id(output)
        .onAppear { limiter.watchers += 1 }
        .onDisappear { limiter.watchers -= 1 }
    }

    private func settings(_ s: LimiterOutputSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ParameterRow(
                title: "Threshold",
                subtitle: "The ceiling, in dBFS. No sample leaves this output above it.",
                unit: "dB",
                value: s.thresholdDB,
                range: LIMITER_THRESHOLD_MIN...LIMITER_THRESHOLD_MAX,
                scrollStep: 0.5,
                maxDecimals: 1,
                ends: ("-30 dBFS", "0 dBFS"),
                isEnabled: vm.isDeviceConnected,
                help: "The limiter runs after every gain stage, so this is the absolute level leaving the device. The -1 dBFS default leaves room for the small overshoot a DAC can produce between samples.",
                live: { vm.sendLimiterParamToDevice(output: output, LIMITER_PARAM_THRESHOLD_DB, $0) },
                set: { v in edit { vm.setLimiterThreshold(output: output, v) } }
            )

            ParameterRow(
                title: "Release",
                subtitle: "How fast the gain recovers after a peak",
                unit: "ms",
                value: s.releaseMs,
                range: LIMITER_RELEASE_MIN...LIMITER_RELEASE_MAX,
                scrollStep: 10,
                maxDecimals: 0,
                ends: ("10 ms", "1000 ms"),
                isEnabled: vm.isDeviceConnected,
                help: "The gain recovers 8.7 dB per release time. Short releases keep the level up but can be heard pumping on dense material; long ones are smoother but hold the level down for longer after a peak. Attack is fixed at 16 samples and always completes before the peak arrives.",
                live: { vm.sendLimiterParamToDevice(output: output, LIMITER_PARAM_RELEASE_MS, $0) },
                set: { v in edit { vm.setLimiterRelease(output: output, v) } }
            )

            linkSection(group: s.linkGroup)

            Divider()

            HStack {
                Button("Copy to all outputs") { edit { vm.copyLimiterToAllOutputs(from: output) } }
                    .controlSize(.small)
                    .help("Give every output this output's threshold, release and on/off state. Link groups are left as they are.")
                Spacer()
                Menu {
                    Button("Link all stereo pairs") { edit { vm.setLimiterLinkGroups(stereoPairGroups) } }
                    Button("Unlink all outputs") { edit { vm.setLimiterLinkGroups([]) } }
                    Divider()
                    Button("Switch every limiter off") { edit { vm.setLimiterEnabledOnAll(false) } }
                } label: {
                    Text("All outputs")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .disabled(!vm.isDeviceConnected)
        }
    }

    private func linkSection(group: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link group")
                .font(.system(size: 12, weight: .medium))

            LinkGroupSegments(selection: group) { g in
                edit { vm.setLimiterLinkGroup(output: output, g) }
            }

            Text(linkSummary(group: group))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Outputs in the same group act as one limiter: they share on/off, threshold and release, so changing one changes them all, and each applies the deepest gain reduction any of them needs. A stereo image cannot shift and a pair of woofers stays matched. An output joining a group takes on the group's settings; leaving keeps them.")
    }

    private func linkSummary(group: Int) -> String {
        guard group != 0 else { return "Not linked." }
        let others = (0..<outputCount)
            .filter { $0 != output && limiter.outputs[$0].linkGroup == group }
            .map(outputName)
        guard let last = others.last else { return "No other outputs in group \(group)." }
        let list = others.count == 1 ? last : others.dropLast().joined(separator: ", ") + " and " + last
        return "Linked with \(list)."
    }

    /// Outputs 1+2 in group 1, 3+4 in group 2 and so on, as far as the four
    /// groups go.  The PDM sub is left unlinked: it is the odd output out on
    /// both platforms.
    private var stereoPairGroups: [Int] {
        (0..<outputCount).map { out in
            let pair = out / 2 + 1
            return out < vm.pdmOutputIndex && pair <= LIMITER_LINK_GROUP_MAX ? pair : 0
        }
    }
}
