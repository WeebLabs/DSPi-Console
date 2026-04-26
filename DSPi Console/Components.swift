import SwiftUI

// MARK: - Right Click Handler

/// Invisible overlay that intercepts right-clicks while passing left-clicks through
struct RightClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.action = action
    }

    class RightClickNSView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        self.overlay(RightClickHandler(action: action))
    }
    func onOptionClick(perform action: @escaping () -> Void) -> some View {
        self.overlay(OptionClickHandler(action: action))
    }
}

// MARK: - Option Click Handler

/// Invisible overlay that intercepts option-clicks while passing other clicks through
struct OptionClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> OptionClickNSView {
        let view = OptionClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: OptionClickNSView, context: Context) {
        nsView.action = action
    }

    class OptionClickNSView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .leftMouseDown,
               event.modifierFlags.contains(.option) {
                return self
            }
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            action?()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

// MARK: - Meter Components

struct HorizontalMeterBar: View {
    var level: Float        // 0.0 to 1.0
    var color: Color
    var isMuted: Bool = false
    var isClipping: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clipZoneWidth: CGFloat = 3
            let meterWidth = w - clipZoneWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: CGFloat(max(0, min(1, level))) * meterWidth)
                    .animation(.linear(duration: 0.06), value: level)

                if isClipping {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: clipZoneWidth)
                        .offset(x: meterWidth)
                }
            }
        }
        .frame(height: 6)
        .opacity(isMuted ? 0.4 : 1.0)
    }
}

struct CpuMeter: View {
    var core: Int
    var load: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("C\(core):").font(.caption2).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 2).fill(load > 90 ? Color.red : Color.blue)
                    .frame(width: CGFloat(load) * 0.4) // Max 40px width
            }
            .frame(width: 40, height: 6)
            Text("\(load)%").font(.caption2).monospacedDigit()
        }
    }
}

struct CpuSection: View {
    @ObservedObject var meters: DSPMeterModel
    var body: some View {
        HStack {
            CpuMeter(core: 0, load: meters.status.cpu0)
            Spacer()
            CpuMeter(core: 1, load: meters.status.cpu1)
        }
    }
}

struct MuteableLabel: View {
    let text: String
    let isMuted: Bool
    var width: CGFloat = 8
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .opacity(isMuted ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .help(isMuted ? "Click to unmute" : "Click to mute")
    }
}

// MARK: - Sidebar Rows

struct ChannelRow: View {
    let channel: Channel
    let isSelected: Bool
    let name: String
    @ObservedObject var meters: DSPMeterModel
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            } else {
                Rectangle().fill(Color.clear).frame(width: 3).padding(.vertical, 4)
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { onCommitRename() }
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(name)
                    .font(.body)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            }

            HorizontalMeterBar(
                level: meters.status.peaks[channel.rawValue],
                color: channel.color,
                isClipping: (meters.status.clipLatched & (1 << UInt16(channel.rawValue))) != 0
            )
            .padding(.horizontal, 4)

            Text(channel.descriptor)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(channel.color)
                .frame(minWidth: 28)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(channel.color.opacity(0.15)))
                .overlay(Capsule().stroke(channel.color.opacity(0.4), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.05) : Color.clear)
        .onChange(of: isRenaming) { renaming in
            if renaming {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused && isRenaming { onCommitRename() }
        }
    }
}

struct OutputRow: View {
    let output: MatrixOutput
    let isSelected: Bool
    let name: String
    let isMuted: Bool
    @ObservedObject var meters: DSPMeterModel
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    @FocusState private var isFocused: Bool

    private var chIdx: Int { output.index + 2 }

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            } else {
                Rectangle().fill(Color.clear).frame(width: 3).padding(.vertical, 4)
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { onCommitRename() }
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(name)
                    .font(.body)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            }

            HorizontalMeterBar(
                level: meters.status.peaks[chIdx],
                color: output.color,
                isMuted: isMuted,
                isClipping: (meters.status.clipLatched & (1 << UInt16(chIdx))) != 0
            )
            .padding(.horizontal, 4)

            Text(output.descriptor)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(output.color)
                .frame(minWidth: 28)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(output.color.opacity(0.15)))
                .overlay(Capsule().stroke(output.color.opacity(0.4), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.05) : Color.clear)
        .onChange(of: isRenaming) { renaming in
            if renaming {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused && isRenaming { onCommitRename() }
        }
    }
}

// MARK: - Channel Settings

/// Header row for the output channel page.  Layout from left to right:
///   1. Input routing preview — one row per USB input (Master L / Master R) with
///      a connected indicator, the input's name, the per-crosspoint gain, and a
///      phase-invert toggle.  Clicking the indicator/name connects/disconnects
///      that input from the current output; gain & invert are clickable to edit.
///   2. Output GAIN slider.
///   3. Output DELAY slider.
///   4. Output MUTE toggle.
///
/// All four panels share the same rounded container and divider visual style.
struct ChannelSettingsView: View {
    @ObservedObject var vm: DSPViewModel
    let outputIndex: Int
    @Binding var gainDB: Float
    @Binding var delayMS: Float
    @Binding var isMuted: Bool
    var maxDelay: Float = 85
    var onGainDrag: ((Float) -> Void)? = nil
    var onDelayDrag: ((Float) -> Void)? = nil

    @State private var localGain: Float = 0
    @State private var localDelay: Float = 0
    @State private var isDraggingGain = false
    @State private var isDraggingDelay = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // INPUT ROUTING PREVIEW
            InputRoutingPanel(vm: vm, outputIndex: outputIndex)
                .padding(.vertical, 8)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .fixedSize(horizontal: true, vertical: false)

            Divider()

            // GAIN — label + value on top row, slider full width below
            VStack(spacing: 4) {
                HStack {
                    Text("GAIN")
                        .font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                    Spacer()
                    ValueField(label: "dB", value: localGain, width: 60) {
                        localGain = $0
                        gainDB = $0
                    }
                }

                Slider(value: $localGain, in: -60...10) { editing in
                    isDraggingGain = editing
                    if !editing { gainDB = localGain }
                }
                .controlSize(.small)
                .frame(height: 24)
                .onChange(of: localGain) { val in
                    if isDraggingGain { onGainDrag?(val) }
                }
                .onAppear { localGain = gainDB }
                .onChange(of: gainDB) { val in if !isDraggingGain { localGain = val } }
                .onRightClick { localGain = 0; gainDB = 0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)

            Divider()

            // DELAY — same layout as GAIN
            VStack(spacing: 4) {
                HStack {
                    Text("DELAY")
                        .font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                    Spacer()
                    ValueField(label: "ms", value: localDelay, width: 60) {
                        localDelay = $0
                        delayMS = $0
                    }
                }

                Slider(value: $localDelay, in: 0...maxDelay) { editing in
                    isDraggingDelay = editing
                    if !editing { delayMS = localDelay }
                }
                .controlSize(.small)
                .frame(height: 24)
                .onChange(of: localDelay) { val in
                    if isDraggingDelay { onDelayDrag?(val) }
                }
                .onAppear { localDelay = delayMS }
                .onChange(of: delayMS) { val in if !isDraggingDelay { localDelay = val } }
                .onRightClick { localDelay = 0; delayMS = 0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)

            Divider()

            // MUTE — fills full height and centers its icon, otherwise the
            // top-aligned HStack would pin it to the top of the row.
            Toggle(isOn: $isMuted) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title2)
                    .foregroundColor(isMuted ? .red : .secondary)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .frame(width: 60)
            .frame(maxHeight: .infinity)
            .background(isMuted ? Color.red.opacity(0.1) : Color.clear)
        }
        .frame(height: 68)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Input Routing Panel

/// Shows the matrix routing for a single output column: one row per USB input
/// channel with a connect indicator, name, per-crosspoint gain, and invert
/// toggle.  The whole panel is a thin wrapper over `vm.matrixRouting/Gain/Invert`
/// for the selected output index.
private struct InputRoutingPanel: View {
    @ObservedObject var vm: DSPViewModel
    let outputIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<min(vm.matrixRouting.count, vm.channelNames.count), id: \.self) { input in
                InputRoutingRow(vm: vm, input: input, output: outputIndex)
            }
        }
    }
}

/// A single input → output crosspoint row.  Designed to match the screenshot:
/// `[●] Name   0.00 dB   INV` with active state in the input's color and
/// disconnected state desaturated.
private struct InputRoutingRow: View {
    @ObservedObject var vm: DSPViewModel
    let input: Int
    let output: Int

    @State private var localGain: Float = 0
    @State private var isHoveringRow = false

    private static let inputColors: [Color] = [
        Color(red: 0.29, green: 0.56, blue: 0.89),  // L — blue
        Color(red: 0.96, green: 0.45, blue: 0.45),  // R — red
    ]

    private var connected: Bool { vm.matrixRouting[input][output] }
    private var inverted: Bool { vm.matrixInvert[input][output] }
    private var liveGain: Float { vm.matrixGain[input][output] }
    private var inputColor: Color {
        Self.inputColors.indices.contains(input) ? Self.inputColors[input] : .accentColor
    }
    private var name: String {
        vm.channelNames.indices.contains(input) ? vm.channelNames[input] : "Input \(input + 1)"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Connect indicator + tappable name
            Button(action: toggleConnect) {
                HStack(spacing: 6) {
                    Image(systemName: connected ? "circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundColor(connected ? inputColor : .secondary.opacity(0.55))
                    Text(name)
                        .font(.system(size: 11, weight: connected ? .semibold : .regular))
                        .foregroundColor(connected ? inputColor : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(connected ? "Disconnect from \(outputName())" : "Connect to \(outputName())")

            // Crosspoint gain — clickable / scrollable.  Greyed when disconnected
            // but still editable so the user can pre-set a value before connecting.
            ValueField(label: "dB", value: localGain, width: 44, scrollStep: 0.5, maxDecimals: 2) { v in
                localGain = v
                vm.setMatrixRoute(input: input, output: output,
                                  enabled: connected, gain: v, invert: inverted)
            }
            .opacity(connected ? 1.0 : 0.55)
            .onAppear { localGain = liveGain }
            .onChange(of: liveGain) { val in localGain = val }
            .onRightClick {
                localGain = 0
                vm.setMatrixRoute(input: input, output: output,
                                  enabled: connected, gain: 0, invert: inverted)
            }

            // Phase invert.  Same orange-on / muted-off treatment as the matrix mixer.
            Button(action: toggleInvert) {
                Text("INV")
                    .font(.system(size: 9, weight: inverted ? .bold : .medium))
                    .foregroundColor(
                        inverted ? .orange : .secondary.opacity(connected ? 0.45 : 0.3)
                    )
            }
            .buttonStyle(.plain)
            .help(inverted ? "Phase inverted" : "Normal phase")
            .disabled(!connected)
        }
        // No fixed height — the ValueField needs body-sized vertical space to
        // receive clicks reliably, and clamping the row chops its hit area.
        .contentShape(Rectangle())
        .onHover { isHoveringRow = $0 }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHoveringRow ? Color.primary.opacity(0.04) : Color.clear)
        )
    }

    private func outputName() -> String {
        let eqCh = output + 2  // matches the channelNames indexing for outputs
        if vm.channelNames.indices.contains(eqCh) {
            let trimmed = vm.channelNames[eqCh].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Out \(output + 1)" : trimmed
        }
        return "Out \(output + 1)"
    }

    private func toggleConnect() {
        vm.setMatrixRoute(input: input, output: output,
                          enabled: !connected, gain: liveGain, invert: inverted)
    }

    private func toggleInvert() {
        vm.setMatrixRoute(input: input, output: output,
                          enabled: connected, gain: liveGain, invert: !inverted)
    }
}

// MARK: - Per-Channel Preamp Control

// MARK: - Input Channel Header
//
// Top-of-page header for input (master L/R) channel pages.  Combines:
//   • Link L/R button — toggles `vm.preampLinked`, which (a) synchronizes the
//     preamp dB values across both channels and (b) mirrors subsequent PEQ
//     filter edits between L and R (mirroring is wired at the call site that
//     dispatches filter updates).
//   • Preamp slider with inline label and dB value field.
//   • Clear Master PEQ button — resets all bands on both master channels.
struct InputChannelHeader: View {
    let channel: Int  // 0 = L, 1 = R
    @ObservedObject var vm: DSPViewModel
    let onClearMasterPEQ: () -> Void

    @State private var localPreamp: Float = 0
    @State private var isDragging = false

    private var linked: Bool { vm.preampLinked }

    var body: some View {
        // Three sections separated by Dividers, mirroring the output channel
        // card's section-with-divider pattern.  Each section adds its own
        // 12-pt horizontal / 8-pt vertical padding so dividers extend the
        // full card height.
        HStack(spacing: 0) {
            // LINK L/R section
            Button(action: toggleLink) {
                HStack(spacing: 6) {
                    Image(systemName: linked ? "link" : "link.badge.plus")
                        .font(.caption).fontWeight(.medium)
                    Text("Link L/R")
                        .font(.caption).fontWeight(.medium)
                }
                .foregroundColor(linked ? .accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(linked ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            linked ? Color.accentColor.opacity(0.45) : Color.gray.opacity(0.3),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .help(linked ? "Unlink L/R (preamp & PEQ stay independent)" : "Link L/R (preamp & PEQ edits mirrored)")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // PREAMP section — label, slider, value.  Inner HStack uses 6-pt
            // spacing to tighten the slider→value gap.  Spacers on either
            // side of the content keep the preamp visually centered within
            // this section's full available width.
            HStack(spacing: 12) {
                Spacer()

                Text("Preamp")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                    .fixedSize()

                HStack(spacing: 6) {
                    Slider(value: $localPreamp, in: -60...10) { editing in
                        isDragging = editing
                        if !editing { vm.setPreampChannel(channel: channel, db: localPreamp) }
                    }
                    .controlSize(.small)
                    .frame(height: 24)
                    .onChange(of: localPreamp) { val in
                        if isDragging {
                            vm.sendPreampChannelToDevice(channel: channel, db: val)
                            if vm.preampLinked {
                                // Update the other channel's @Published value so its
                                // sidebar peak meter / cards reflect the mirrored value
                                // immediately during drag.
                                let rounded = (val * 10).rounded() / 10
                                vm.preampDB[1 - channel] = rounded == -0.0 ? 0.0 : rounded
                            }
                        }
                    }
                    .onAppear { localPreamp = vm.preampDB[channel] }
                    .onChange(of: vm.preampDB) { newArr in
                        if !isDragging { localPreamp = newArr[channel] }
                    }
                    .onRightClick {
                        localPreamp = 0
                        vm.setPreampChannel(channel: channel, db: 0)
                    }

                    // Value field is sized to comfortably fit "-60.0" (the slider's
                    // most negative value) plus the "dB" label without slack.
                    ValueField(label: "dB", value: localPreamp, width: 44) { v in
                        localPreamp = v
                        vm.setPreampChannel(channel: channel, db: v)
                    }
                }
                .frame(maxWidth: 320)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)

            Divider()

            // CLEAR MASTER PEQ section
            Button(action: onClearMasterPEQ) {
                Text("Clear Master PEQ")
                    .font(.caption).fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Reset all PEQ bands on both master channels")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 56)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    private func toggleLink() {
        vm.preampLinked.toggle()
        if vm.preampLinked {
            // Sync the other channel to this channel's value on link-on, matching
            // the prior PreampControlView behavior.  PEQ filters are not bulk-synced
            // here — only forward edits are mirrored, per the design note.
            vm.setPreampChannel(channel: 1 - channel, db: vm.preampDB[channel])
        }
        // Re-evaluate which master curves are shown on the graph so toggling
        // link while a master is selected updates immediately.
        vm.refreshLinkedVisibility()
    }
}

// MARK: - Per-Channel Preamp Control (legacy)

struct PreampControlView: View {
    let channel: Int  // 0 = L, 1 = R
    @ObservedObject var vm: DSPViewModel

    @State private var localPreamp: Float = 0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Label("Preamp", systemImage: "dial.low.fill")
                            .font(.caption).fontWeight(.bold).foregroundColor(.secondary)

                        Button(action: {
                            vm.preampLinked.toggle()
                            if vm.preampLinked {
                                // Sync other channel to this channel's value
                                vm.setPreampChannel(channel: 1 - channel, db: vm.preampDB[channel])
                            }
                        }) {
                            Image(systemName: vm.preampLinked ? "link" : "link.badge.plus")
                                .font(.caption2)
                                .foregroundColor(vm.preampLinked ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(vm.preampLinked ? "Unlink L/R preamp" : "Link L/R preamp")
                    }
                    ValueField(label: "dB", value: localPreamp, width: 60) {
                        localPreamp = $0
                        vm.setPreampChannel(channel: channel, db: $0)
                    }
                }
                .frame(width: 100, alignment: .leading)

                Slider(value: $localPreamp, in: -60...10) { editing in
                    isDragging = editing
                    if !editing {
                        vm.setPreampChannel(channel: channel, db: localPreamp)
                    }
                }
                .onChange(of: localPreamp) { val in
                    if isDragging {
                        vm.sendPreampChannelToDevice(channel: channel, db: val)
                        if vm.preampLinked {
                            // Update other channel's @Published value so its view updates
                            let rounded = (val * 10).rounded() / 10
                            vm.preampDB[1 - channel] = rounded == -0.0 ? 0.0 : rounded
                        }
                    }
                }
                .onAppear { localPreamp = vm.preampDB[channel] }
                .onChange(of: vm.preampDB) { newArr in
                    if !isDragging { localPreamp = newArr[channel] }
                }
                .onRightClick {
                    localPreamp = 0
                    vm.setPreampChannel(channel: channel, db: 0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 60)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Filter List

struct FilterListView: View {
    let bands: [FilterParams]
    let channelId: Int
    /// Filter types offered in the per-band type picker.  Defaults to all
    /// types; callers gate this on firmware capability (e.g. notch requires
    /// firmware 1.1.4+).
    var availableTypes: [FilterType] = FilterType.allCases
    let onUpdate: (Int, FilterParams) -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("#").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 24, alignment: .leading)
                Text("TYPE").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 100, alignment: .leading)
                Text("FREQ").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 104, alignment: .center)
                Text("GAIN").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 84, alignment: .center)
                Text("WIDTH").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 74, alignment: .center)
                Spacer()
                if let onClear = onClear {
                    Button("Clear All", role: .destructive, action: onClear)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(0..<bands.count, id: \.self) { index in
                        FilterRowView(
                            index: index,
                            params: bands[index],
                            availableTypes: availableTypes,
                            onChange: { onUpdate(index, $0) }
                        )
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
        .padding(.bottom)
    }
}

// MARK: - NSViewRepresentable Components

private class PaddedPopUpButtonCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.offsetBy(dx: 0, dy: 1), in: controlView)
    }
}

private class PaddedPopUpButton: NSPopUpButton {
    var trailingPadding: CGFloat = 14
    var onRightClick: (() -> Void)?
    override class var cellClass: AnyClass? {
        get { PaddedPopUpButtonCell.self }
        set {}
    }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += trailingPadding
        return size
    }
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick = onRightClick {
            onRightClick()
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

struct BorderlessPopUpButton<T: Hashable>: NSViewRepresentable {
    let items: [T]
    let titleForItem: (T) -> String
    @Binding var selection: T

    var font: NSFont?
    var enabled: Bool = true
    var showsHoverBorder: Bool = true
    var onRightClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PaddedPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = showsHoverBorder
        button.showsBorderOnlyWhileMouseInside = showsHoverBorder
        button.onRightClick = onRightClick
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        if let font = font { button.font = font }
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Update coordinator's reference to current parent (fixes stale binding issue)
        context.coordinator.parent = self

        if let font = font { button.font = font }
        button.isBordered = showsHoverBorder && enabled
        button.showsBorderOnlyWhileMouseInside = showsHoverBorder && enabled
        (button as? PaddedPopUpButton)?.onRightClick = onRightClick

        // Only rebuild menu if items changed (avoids swallowing clicks during polling updates)
        let currentTitles = (0..<(button.menu?.numberOfItems ?? 0)).map { button.menu?.item(at: $0)?.title ?? "" }
        let newTitles = items.map { titleForItem($0) }
        if currentTitles != newTitles {
            button.menu?.removeAllItems()
            for (index, item) in items.enumerated() {
                let menuItem = NSMenuItem(title: titleForItem(item), action: nil, keyEquivalent: "")
                menuItem.tag = index
                button.menu?.addItem(menuItem)
            }
        }

        // Reconcile selection in two passes.
        //
        // (1) Sync NSPopUpButton's internal selection tracking via
        //     selectItem(withTag:).  This updates the button-face display
        //     and AppKit's notion of "the selected item" for key nav /
        //     accessibility.  The indexOfSelectedItem short-circuit avoids
        //     redundant work during rapid @Published-driven re-renders.
        //
        // (2) Explicitly normalize every NSMenuItem.state.  Defends against
        //     the case where AppKit's internal _selectedItem pointer has
        //     desynced from the actual .state fields — which can leave a
        //     stale .on on the previously-clicked item, manifesting as
        //     MULTIPLE CHECKMARKS in the popup.
        //
        //     Reproducible trigger: rapidly clicking through presets,
        //     especially empty ones.  Multiple unoccupied slots share the
        //     title "Empty" (presetDropdownLabel), and AppKit's selectItem
        //     machinery clears state on whatever it THINKS was previously
        //     selected — if that internal pointer references an item that
        //     was displaced by a menu rebuild, or if a native click and a
        //     selectItem call disagree about "previous", stale .on bits
        //     accumulate on prior items.  Explicitly walking the menu and
        //     setting state from the authoritative `selection` binding
        //     guarantees exactly one .on regardless of AppKit bookkeeping.
        if let targetIndex = items.firstIndex(of: selection) {
            if button.indexOfSelectedItem != targetIndex {
                button.selectItem(withTag: targetIndex)
            }
            if let menu = button.menu {
                for i in 0..<menu.numberOfItems {
                    if let menuItem = menu.item(at: i) {
                        let shouldBeOn = (menuItem.tag == targetIndex)
                        let desired: NSControl.StateValue = shouldBeOn ? .on : .off
                        if menuItem.state != desired {
                            menuItem.state = desired
                        }
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: BorderlessPopUpButton

        init(_ parent: BorderlessPopUpButton) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            if index >= 0 && index < parent.items.count {
                parent.selection = parent.items[index]
            }
        }
    }
}

// MARK: - Filter Row

struct FilterRowView: View {
    let index: Int
    var params: FilterParams
    /// Filter types offered in the type picker.  Caller gates this on
    /// firmware capability — e.g. notch requires firmware 1.1.4+.
    var availableTypes: [FilterType] = FilterType.allCases
    var onChange: (FilterParams) -> Void

    var isActive: Bool { params.type != .flat }

    var body: some View {
        HStack(spacing: 12) {
            // Index
            Text("\(index + 1)")
                .font(.system(.body))
                .foregroundColor(isActive ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, alignment: .leading)

            // Type Selector
            BorderlessPopUpButton(
                items: availableTypes,
                titleForItem: { $0.name },
                selection: Binding(
                    get: { params.type },
                    set: { var p = params; p.type = $0; onChange(p) }
                )
            )
            .frame(width: 100, height: 20)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }

            // Controls
            if isActive {
                HStack(spacing: 12) {
                    // Freq
                    ValueField(label: "Hz", value: params.freq, width: 80, scrollStep: 10, minValue: 10) {
                        var p = params; p.freq = $0; onChange(p)
                    }

                    // Gain
                    if params.type == .peaking || params.type == .lowShelf || params.type == .highShelf {
                        ValueField(label: "dB", value: params.gain, width: 60, maxDecimals: 2) {
                            var p = params; p.gain = $0; onChange(p)
                        }
                    } else {
                        Spacer().frame(width: 60 + 24) // Placeholder
                    }

                    // Q
                    ValueField(label: "Q", value: params.q, width: 50, minValue: 0.1, maxDecimals: 3) {
                        var p = params; p.q = $0; onChange(p)
                    }
                }
            } else {
                Text("Filter Disabled")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 104, alignment: .center)
            }

            Spacer()
        }
        .frame(height: 24) // Fixed height to prevent jumping
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                if index % 2 == 0 { Color.white.opacity(0.03) }
            }
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Value Field

struct ValueField: View {
    let label: String
    let value: Float
    let width: CGFloat
    var scrollStep: Float = 0.1
    var minValue: Float? = nil
    var maxDecimals: Int = 1
    var displayOverride: String? = nil
    let onCommit: (Float) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private func format(_ v: Float) -> String {
        let full = String(format: "%.\(maxDecimals)f", v)
        // Trim trailing zeros but keep at least one decimal
        let parts = full.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return full }
        let decimals = String(parts[1])
        let trimmed = decimals.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        if trimmed.isEmpty { return "\(parts[0]).0" }
        return "\(parts[0]).\(trimmed)"
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .trailing) {
                Text(text + " ")
                    .font(.system(.body).monospacedDigit())
                    .opacity(0)
                    .padding(4)

                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body).monospacedDigit())
                    .foregroundColor(isFocused ? .accentColor : .primary)
                    .tint(.accentColor)
                    .multilineTextAlignment(.trailing)
                    .padding(4)
                    .frame(width: width) // Enforce fixed width
                    .focused($isFocused)
                    .onSubmit { if let v = Float(text) { onCommit(v) } else { text = format(value) } }
                    .onChange(of: isFocused) { focused in if !focused { if let v = Float(text) { onCommit(v) } else { text = format(value) } } }
            }
            .fixedSize(horizontal: true, vertical: false)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .leading)
        }
        .overlay(
            ValueFieldScrollHandler(value: value, step: scrollStep, minValue: minValue, onCommit: onCommit)
        )
        .onAppear { text = (!isFocused && displayOverride != nil) ? displayOverride! : format(value) }
        .onChange(of: value) { newValue in
            if !isFocused, let override = displayOverride { text = override } else { text = format(newValue) }
        }
        .onChange(of: displayOverride) { override in
            if !isFocused, let override { text = override } else { text = format(value) }
        }
    }
}

// MARK: - Value Field Scroll Handler

struct ValueFieldScrollHandler: NSViewRepresentable {
    let value: Float
    let step: Float
    let minValue: Float?
    let onCommit: (Float) -> Void

    func makeNSView(context: Context) -> ValueFieldScrollNSView {
        let view = ValueFieldScrollNSView()
        view.value = value
        view.step = step
        view.minValue = minValue
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ nsView: ValueFieldScrollNSView, context: Context) {
        nsView.value = value
        nsView.step = step
        nsView.minValue = minValue
        nsView.onCommit = onCommit
    }
}

class ValueFieldScrollNSView: NSView {
    var value: Float = 0
    var step: Float = 0.1
    var minValue: Float?
    var onCommit: ((Float) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    /// Be transparent to mouse clicks so the underlying SwiftUI `TextField`
    /// gets focus when the user clicks on the value (enabling click-to-edit).
    /// Only claim the hit target when the current event is a scrollWheel —
    /// matches the `RightClickHandler` pattern used elsewhere in this file.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, event.type == .scrollWheel {
            return self
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.scrollingDeltaY)
        guard abs(delta) > 0.01 else { return }

        let direction: Float = delta > 0 ? 1 : -1
        let newValue = value + direction * step
        onCommit?(minValue.map { max(newValue, $0) } ?? newValue)
    }
}

// MARK: - Sidebar Icon Button

struct SidebarIconButton: View {
    let icon: String
    let isActive: Bool
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isActive ? .white : isHovered ? .white.opacity(0.7) : .secondary.opacity(0.6))
                .animation(.easeInOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
    }
}
