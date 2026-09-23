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
                    set: { vm.setLimiterEnabled(output: output, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)
                .help("A test signal from the Signal Generator is limited like any other signal. Switch this output's limiter off for an unaltered full-scale measurement.")
            }

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
                set: { vm.setLimiterThreshold(output: output, $0) }
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
                set: { vm.setLimiterRelease(output: output, $0) }
            )

            linkSection(group: s.linkGroup)

            Divider()

            HStack {
                Button("Copy to all outputs") { vm.copyLimiterToAllOutputs(from: output) }
                    .controlSize(.small)
                    .help("Give every output this output's threshold, release and on/off state. Link groups are left as they are.")
                Spacer()
                Menu {
                    Button("Link all stereo pairs") { vm.setLimiterLinkGroups(stereoPairGroups) }
                    Button("Unlink all outputs") { vm.setLimiterLinkGroups([]) }
                    Divider()
                    Button("Switch every limiter off") { vm.setLimiterEnabledOnAll(false) }
                } label: {
                    Text("All outputs")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .disabled(!vm.isDeviceConnected)
        }
        .padding(16)
        .frame(width: 320)
        // Re-created per output, so a slider's local state never carries over
        // when the page switches with the popover open.
        .id(output)
        .onboardingHint("limiter")
        .onAppear { limiter.watchers += 1 }
        .onDisappear { limiter.watchers -= 1 }
    }

    private func linkSection(group: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link group")
                .font(.system(size: 12, weight: .medium))

            Picker("", selection: Binding(
                get: { group },
                set: { vm.setLimiterLinkGroup(output: output, $0) }
            )) {
                Text("Off").tag(0)
                ForEach(1...LIMITER_LINK_GROUP_MAX, id: \.self) { g in
                    Text("\(g)").tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!vm.isDeviceConnected)

            Text(linkSummary(group: group))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Outputs in the same group all apply the deepest gain reduction any of them needs, so a stereo image cannot shift and a pair of woofers stays matched. Linking does not share settings: each output keeps its own threshold and release, and only outputs whose limiter is on take part.")
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
