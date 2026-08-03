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
    @ObservedObject var vm: DSPViewModel
    var body: some View {
        HStack {
            CpuMeter(core: 0, load: vm.meters.status.cpu0)
            Spacer()
            CpuMeter(core: 1, load: vm.meters.status.cpu1)
        }
    }
}

// Connection state dot + device picker.  Extracted from ContentView's
// graph header so it can also live in the sidebar status row.  Right-click
// the picker to force a USB reconnect.
struct ConnectionStatusIndicator: View {
    @ObservedObject var vm: DSPViewModel
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.isDeviceConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .help(vm.isDeviceConnected
                      ? "Connected"
                      : (vm.connectionError ?? "Not connected. Right-click the device name to retry."))

            if vm.availableDevices.isEmpty {
                Text("No Devices").font(.caption).foregroundColor(.red)
            } else {
                BorderlessPopUpButton(
                    items: vm.availableDevices,
                    titleForItem: { $0.displayName },
                    selection: Binding(
                        get: {
                            if let selected = vm.selectedDevice,
                               vm.availableDevices.contains(selected) {
                                return selected
                            }
                            return vm.availableDevices.first ?? DSPiDevice(serial: "", locationID: 0)
                        },
                        set: { vm.switchToDevice($0) }
                    ),
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    enabled: vm.availableDevices.count > 1,
                    showsHoverBorder: false,
                    onRightClick: { vm.usb.reconnect() }
                )
                .overlay(alignment: .trailing) {
                    if vm.availableDevices.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                            .offset(y: 1)
                            .padding(.trailing, 4)
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize()
                .allowsHitTesting(vm.availableDevices.count > 1)
            }
        }
    }
}

// Compact dB readout / editor sized to match CpuMeter.  Plain TextField
// rather than ValueField so the font matches the surrounding caption2
// status row.  Commits on Return / blur, falls back to the live value
// when the entered text isn't a number.  "−∞" is shown at -128 dB (mute);
// to leave mute, the user types a number.
// MARK: - Sidebar Volume Mode + Master Volume Taper
//
// Mode for the sidebar volume slider.  `auto` preserves the input-source-
// driven host/user split; `master` drives masterVolumeDB directly.
// Persisted as a String via @AppStorage in AppSettings so a user's choice
// survives relaunches.
enum SidebarVolumeMode: String { case auto, master }

// Piecewise-linear master volume taper used by MasterModeSection (the
// sidebar slider in master mode).  Encodes the firmware's per-region
// step sizes:
//   0 to -10 dB:   0.1 dB steps over 100 units (~40% of throw)
//  -10 to -40 dB:  0.5 dB steps over  60 units (~24% of throw)
//  -40 to -128 dB: 1.0 dB steps over  88 units (~36% of throw)
// Slider position 1.0 = 0 dB; 0.0 = -128 dB (mute, displayed as "−∞").
enum MasterVolumeTaper {
    static let totalUnits: Float = 248
    static let break1: Float = 1.0 - 100 / totalUnits   // pos at -10 dB
    static let break2: Float = break1 - 60 / totalUnits // pos at -40 dB

    static func sliderToDB(_ pos: Float) -> Float {
        if pos <= 0 { return -128 }
        if pos >= 1 { return 0 }
        if pos > break1 {
            return -(1.0 - pos) * totalUnits * 0.1
        } else if pos > break2 {
            return -10 - (break1 - pos) * totalUnits * 0.5
        } else {
            return -40 - (break2 - pos) * totalUnits * 1.0
        }
    }

    static func dbToSlider(_ db: Float) -> Float {
        if db <= -128 { return 0 }
        if db >= 0 { return 1 }
        if db > -10 {
            return 1.0 - (-db / 0.1) / totalUnits
        } else if db > -40 {
            return break1 - ((-db - 10) / 0.5) / totalUnits
        } else {
            return break2 - ((-db - 40) / 1.0) / totalUnits
        }
    }

    /// Snap a dB value to the closest step the firmware actually applies
    /// in each region (0.1 / 0.5 / 1.0 dB).  Used by the readout so the
    /// number on screen matches what the device acts on.
    static func displayValue(_ db: Float) -> Float {
        if db <= -128 { return -128 }
        let rounded: Float
        if db > -10 { rounded = (db * 10).rounded() / 10 }
        else if db > -40 { rounded = (db * 2).rounded() / 2 }
        else { rounded = db.rounded() }
        return rounded == -0.0 ? 0.0 : rounded
    }

    /// Pretty-print: "−∞" at -128 (mute), otherwise "%.1f dB" with trailing
    /// ".0" stripped (e.g. "0", "-12", "-7.5").
    static func format(_ db: Float) -> String {
        if db <= -128 { return "−∞" }
        let v = displayValue(db)
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

// MARK: - Volume Mode Selector
//
// Compact popup label used as the section heading on the sidebar volume
// slider.  Renders as e.g. "User Volume ▾" (the input-source-driven host/
// user path) or "Master Volume ▾" (master attenuator); clicking opens a
// menu with those two choices.  The `inputSource` parameter is retained
// for callers but no longer reflected in the menu — the user-facing label
// reads "User Volume" regardless of whether the underlying path is the
// CoreAudio host slider (USB) or REQ_SET_USER_VOLUME (SPDIF/I2S).
struct VolumeModeSelector: View {
    @Binding var modeRaw: String
    /// Retained for API compatibility with callers; not used in the menu.
    let inputSource: Int

    private var mode: SidebarVolumeMode {
        SidebarVolumeMode(rawValue: modeRaw) ?? .auto
    }

    private var headingText: String {
        switch mode {
        case .auto:   return "User Volume"
        case .master: return "Master Volume"
        }
    }

    var body: some View {
        Menu {
            Button {
                modeRaw = SidebarVolumeMode.auto.rawValue
            } label: {
                if mode == .auto {
                    Label("User Volume", systemImage: "checkmark")
                } else {
                    Text("User Volume")
                }
            }
            Button {
                modeRaw = SidebarVolumeMode.master.rawValue
            } label: {
                if mode == .master {
                    Label("Master Volume", systemImage: "checkmark")
                } else {
                    Text("Master Volume")
                }
            }
        } label: {
            // The chevron is part of the text string rather than a
            // sibling Image — `.menuStyle(.borderlessButton)` on macOS
            // injects its own indicator and shuffles HStack siblings,
            // so the only reliable way to place a chevron on the right
            // is to bake it into the title.  `.menuIndicator(.hidden)`
            // suppresses the system one.  Concatenated Texts keep the
            // label at caption2 (matching "Source" and other sidebar
            // labels) while bumping the chevron larger.
            (Text(headingText).font(.caption2)
             + Text(" ▾").font(.system(size: 11, weight: .bold)))
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        // `.button` menu style + `.plain` button style strips the
        // ~8pt horizontal padding that `.borderlessButton` adds, so
        // the label sits flush left with sibling sidebar labels like
        // "Source".
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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

/// Sidebar descriptor badge that doubles as the graph curve's visibility toggle:
/// coloured when the curve is drawn, greyed out when it is hidden.  The tap
/// target is padded well beyond the capsule so the pill can be hit without
/// tripping the row's channel-selection gesture.
struct ChannelVisibilityPill: View {
    let descriptor: String
    let color: Color
    let isVisible: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.1)) { onToggle() }
        }) {
            Text(descriptor)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isVisible ? color : .secondary)
                .frame(minWidth: 32)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(isVisible ? color.opacity(0.15)
                                                     : Color.gray.opacity(0.12)))
                .overlay(Capsule().stroke(isVisible ? color.opacity(0.4)
                                                    : Color.gray.opacity(0.35),
                                          lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isVisible ? "Hide \(descriptor) on the graph"
                        : "Show \(descriptor) on the graph")
    }
}

struct ChannelRow: View {
    let channelIndex: Int   // unified input EQ channel index (0..chOut1-1)
    let color: Color
    let descriptor: String
    let isSelected: Bool
    let name: String
    @ObservedObject var meters: DSPMeterModel
    let isRenaming: Bool
    @Binding var renameText: String
    /// Row height, tightened by the sidebar when input channels are crowded.
    var rowHeight: CGFloat = 28
    let onCommitRename: () -> Void
    /// Graph-curve visibility for this channel, toggled by the descriptor pill.
    let isCurveVisible: Bool
    let onToggleCurve: () -> Void
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
                level: channelIndex < meters.status.peaks.count ? meters.status.peaks[channelIndex] : 0,
                color: color,
                isClipping: (meters.status.clipLatched & (UInt32(1) << UInt32(channelIndex))) != 0
            )
            .padding(.leading, 4)

            ChannelVisibilityPill(descriptor: descriptor,
                                  color: color,
                                  isVisible: isCurveVisible,
                                  onToggle: onToggleCurve)
        }
        .frame(height: rowHeight)
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
    /// Row height, tightened by the sidebar when input channels are crowded.
    var rowHeight: CGFloat = 28
    let onCommitRename: () -> Void
    /// Unified EQ/channel index for this output (output index + chOut1).
    let chIdx: Int
    /// Graph-curve visibility for this channel, toggled by the descriptor pill.
    let isCurveVisible: Bool
    let onToggleCurve: () -> Void
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
                level: chIdx < meters.status.peaks.count ? meters.status.peaks[chIdx] : 0,
                color: output.color,
                isMuted: isMuted,
                isClipping: (meters.status.clipLatched & (UInt32(1) << UInt32(chIdx))) != 0
            )
            .padding(.leading, 4)

            ChannelVisibilityPill(descriptor: output.descriptor,
                                  color: output.color,
                                  isVisible: isCurveVisible,
                                  onToggle: onToggleCurve)
        }
        .frame(height: rowHeight)
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
///   1. Input routing preview — up to two USB input rows with
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

/// Shows the matrix routing for a single output column: up to two USB input rows
/// with a connect indicator, name, per-crosspoint gain, and invert toggle. The
/// full set of inputs remains available in the matrix mixer.
private struct InputRoutingPanel: View {
    @ObservedObject var vm: DSPViewModel
    let outputIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<min(vm.numMatrixInputs, BASE_MATRIX_INPUTS), id: \.self) { input in
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

    private var connected: Bool { vm.matrixRouting[input][output] }
    private var inverted: Bool { vm.matrixInvert[input][output] }
    private var liveGain: Float { vm.matrixGain[input][output] }
    private var inputColor: Color { MatrixInput.color(for: input) }
    private var name: String {
        // In 8-channel mode use the 7.1 role names; stereo keeps the device's
        // USB L/R channel names.
        if vm.numMatrixInputs > BASE_MATRIX_INPUTS {
            return MatrixInput.shortName(for: input, count: vm.numMatrixInputs)
        }
        return vm.channelNames.indices.contains(input) ? vm.channelNames[input] : "Input \(input + 1)"
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
        let eqCh = vm.eqChannel(forOutput: output)  // channelNames index for this output
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

// MARK: - Input Pair Link Alert

/// What the user chose when asked how to reconcile a mismatched pair.
enum InputLinkChoice {
    /// Copy this channel's filters and trim onto its partner, then link.
    case keep(Int)
    case cancel
}

enum InputLinkAlerts {
    /// Ask which channel's settings to keep before linking a pair that doesn't
    /// already match.  `pageChannel` is the input whose page the Link button
    /// was clicked on, and it's offered first so the default keeps the tuning
    /// the user is actually looking at.
    static func showMismatchAlert(pageChannel: Int, partner: Int,
                                  bandsDiffer: Bool, preampDiffers: Bool) -> InputLinkChoice {
        let pageLabel = "IN\(pageChannel + 1)"
        let partnerLabel = "IN\(partner + 1)"
        let differences: String
        switch (bandsDiffer, preampDiffers) {
        case (true, true):  differences = "different filters and input trims"
        case (true, false): differences = "different filters"
        default:            differences = "different input trims"
        }

        let alert = NSAlert()
        alert.messageText = "Inputs \(pageChannel + 1) and \(partner + 1) don't match"
        alert.informativeText = """
            These inputs have \(differences). Linking mirrors future edits across \
            both channels, but it cannot merge settings that already differ.

            Choose which channel's filters and trim to copy onto the other. This \
            overwrites the other channel and cannot be undone.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep \(pageLabel)")
        alert.addButton(withTitle: "Keep \(partnerLabel)")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .keep(pageChannel)
        case .alertSecondButtonReturn: return .keep(partner)
        default:                       return .cancel
        }
    }
}

// MARK: - Input Channel Header
//
// Top-of-page header for input channel pages.  Combines:
//   • Link button - toggles this channel's adjacent pair (1/2, 3/4, 5/6, 7/8)
//     in `vm.linkedInputPairs`, which (a) synchronizes the preamp dB values
//     across both halves and (b) mirrors subsequent PEQ filter edits between
//     them (mirroring is wired at the call site that dispatches filter updates).
//   • Preamp slider with inline label and dB value field.
//   • Clear PEQ button - resets all bands on this channel, and on its partner
//     when the pair is linked.
struct InputChannelHeader: View {
    let channel: Int  // input channel index (0 = L, 1 = R, 2..7 = surround)
    @ObservedObject var vm: DSPViewModel
    let onClearPEQ: () -> Void

    @State private var localPreamp: Float = 0
    @State private var isDragging = false

    /// Adjacent pair this input belongs to, and the channel it pairs with.
    private var pair: Int { channel / 2 }
    private var partner: Int { channel ^ 1 }
    /// A pair can only be linked while both of its channels are live.
    private var pairAvailable: Bool { max(channel, partner) < vm.numMatrixInputs }
    private var linked: Bool { vm.linkedPartner(of: channel) != nil }
    /// "Link 1/2", "Link 3/4", … keyed to the sidebar's IN1..IN8 numbering.
    private var pairLabel: String { "\(min(channel, partner) + 1)/\(max(channel, partner) + 1)" }

    // Fixed label widths keep both pills the same size whatever their state:
    // the link icon swaps glyphs and the clear label gains the pair number.
    // Sized to the widest variants ("Link 3/4" 39.7pt, "Clear 7/8 PEQ" 68.0pt
    // at caption/medium) plus a little slack.
    private let linkIconWidth: CGFloat = 14
    private let linkLabelWidth: CGFloat = 42
    private let clearLabelWidth: CGFloat = 70

    var body: some View {
        // Three sections separated by Dividers, mirroring the output channel
        // card's section-with-divider pattern.  Each section adds its own
        // 12-pt horizontal / 8-pt vertical padding so dividers extend the
        // full card height.
        HStack(spacing: 0) {
            // LINK section (hidden when this input's partner isn't live)
            if pairAvailable {
                Button(action: toggleLink) {
                    HStack(spacing: 6) {
                        Image(systemName: linked ? "link" : "link.badge.plus")
                            .font(.caption).fontWeight(.medium)
                            .frame(width: linkIconWidth)
                        Text("Link \(pairLabel)")
                            .font(.caption).fontWeight(.medium)
                            .fixedSize()
                            .frame(width: linkLabelWidth)
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
                .help(linked ? "Unlink \(pairLabel) (preamp & PEQ stay independent)"
                             : "Link \(pairLabel) (preamp & PEQ edits mirrored)")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

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
                            if let mirror = vm.linkedPartner(of: channel) {
                                // Update the partner's @Published value so its
                                // sidebar peak meter / cards reflect the mirrored value
                                // immediately during drag.
                                let rounded = (val * 10).rounded() / 10
                                vm.preampDB[mirror] = rounded == -0.0 ? 0.0 : rounded
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

            // CLEAR PEQ section
            Button(action: onClearPEQ) {
                Text(linked ? "Clear \(pairLabel) PEQ" : "Clear PEQ")
                    .font(.caption).fontWeight(.medium)
                    .fixedSize()
                    .frame(width: clearLabelWidth)
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
            .help(linked ? "Reset all PEQ bands on both channels of the linked pair"
                         : "Reset all PEQ bands on this input")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 56)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    private func toggleLink() {
        guard pairAvailable else { return }

        if vm.isInputPairLinked(pair) {
            vm.setInputPairLinked(pair, false)
            vm.refreshLinkedVisibility()
            return
        }

        // Linking only mirrors future edits, so a pair that already differs
        // has to be reconciled here - otherwise "linked" would quietly mean
        // "still mismatched on every band nobody happens to touch".  Matching
        // channels link with no prompt at all.
        let mismatch = vm.inputPairMismatch(channel, partner)
        if mismatch.bands || mismatch.preamp {
            let choice = InputLinkAlerts.showMismatchAlert(
                pageChannel: channel, partner: partner,
                bandsDiffer: mismatch.bands, preampDiffers: mismatch.preamp)
            switch choice {
            case .cancel:
                return
            case .keep(let keeper):
                vm.syncInputPair(from: keeper, to: keeper == channel ? partner : channel)
            }
        }

        vm.setInputPairLinked(pair, true)
        // Re-evaluate which curves are shown on the graph so toggling link
        // while this input is selected updates immediately.
        vm.refreshLinkedVisibility()
    }
}

// MARK: - Per-Channel Preamp Control (legacy)

struct PreampControlView: View {
    let channel: Int  // 0 = L, 1 = R
    @ObservedObject var vm: DSPViewModel

    @State private var localPreamp: Float = 0
    @State private var isDragging = false

    private var linked: Bool { vm.linkedPartner(of: channel) != nil }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Label("Preamp", systemImage: "dial.low.fill")
                            .font(.caption).fontWeight(.bold).foregroundColor(.secondary)

                        Button(action: {
                            let nowLinked = !vm.isInputPairLinked(channel / 2)
                            vm.setInputPairLinked(channel / 2, nowLinked)
                            if nowLinked {
                                // Sync other channel to this channel's value
                                vm.setPreampChannel(channel: channel ^ 1, db: vm.preampDB[channel])
                            }
                        }) {
                            Image(systemName: linked ? "link" : "link.badge.plus")
                                .font(.caption2)
                                .foregroundColor(linked ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(linked ? "Unlink L/R preamp" : "Link L/R preamp")
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
                        if let mirror = vm.linkedPartner(of: channel) {
                            // Update other channel's @Published value so its view updates
                            let rounded = (val * 10).rounded() / 10
                            vm.preampDB[mirror] = rounded == -0.0 ? 0.0 : rounded
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

/// Optional tab entry rendered in FilterListView's header row.
/// This keeps the band-list mode selector local to the list without spending
/// another horizontal row.
struct FilterListTab {
    let title: String
    let isSelected: Bool
    let action: () -> Void
}

/// Compact pill button used in FilterListView's header row.  Matches the
/// caption-font / small-padding / outlined-rect treatment shared with the
/// Link L/R button and the matrix INV toggle elsewhere in the UI.
private struct FilterListHeaderButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    var help: String? = nil

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}

/// Split-pill control with two pure actions — "Enable All" and "Bypass
/// All".  No stored toggle state; each half is a one-shot action that
/// applies to every band.  A half is disabled (and dimmed) when its
/// action would be a no-op, giving passive feedback about the list's
/// current uniformity without turning the control itself into a toggle.
private struct BypassAllControls: View {
    let allBypassed: Bool
    let allEnabled: Bool
    let onEnableAll: () -> Void
    let onBypassAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            BypassActionHalf(
                title: "Enable All",
                isDisabled: allEnabled,
                action: onEnableAll
            )
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 16)
            BypassActionHalf(
                title: "Bypass All",
                isDisabled: allBypassed,
                action: onBypassAll
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct BypassActionHalf: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.secondary)
                .opacity(isDisabled ? 0.4 : 1.0)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Rectangle()
                        .fill(hovered && !isDisabled ? Color.gray.opacity(0.22) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovered = $0 }
        .help(isDisabled ? "" : title)
    }
}

struct FilterListTabToggle: View {
    let tabs: [FilterListTab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { i in
                if i > 0 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 1, height: 16)
                }
                let tab = tabs[i]
                Button(action: { if !tab.isSelected { tab.action() } }) {
                    ZStack {
                        // Reserve width to the widest tab title so each
                        // segment is the same width regardless of label.
                        ForEach(tabs.indices, id: \.self) { j in
                            Text(tabs[j].title)
                                .font(.caption).fontWeight(.medium)
                                .opacity(0)
                        }
                        Text(tab.title)
                            .font(.caption).fontWeight(.medium)
                            .foregroundColor(tab.isSelected ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Rectangle()
                            .fill(tab.isSelected ? Color.gray.opacity(0.22) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.isSelected ? "Currently showing \(tab.title) bands" : "Switch to \(tab.title) bands")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

struct FilterListView: View {
    let bands: [FilterParams]
    let channelId: Int
    /// Filter types offered in the per-band type picker.  Defaults to all
    /// types; callers gate this on firmware capability (e.g. notch requires
    /// firmware 1.1.4+).
    var availableTypes: [FilterType] = FilterType.allCases
    /// True when the connected firmware supports per-band bypass (>= 1.1.4).
    var bypassSupported: Bool = false
    /// Optional tabs rendered at the top of the card (above the column header).
    /// Empty by default so existing call sites are unaffected.
    var tabs: [FilterListTab] = []
    /// When true the row layout swaps the GAIN column for an ORDER column and
    /// the TYPE picker collapses to family + LP/HP — used by the XO tab where
    /// gain is meaningless and crossover order is the meaningful axis.
    var isCrossoverMode: Bool = false
    let onUpdate: (Int, FilterParams) -> Void
    /// Toggle bypass on a single band.  Cheaper than re-sending the full
    /// EqParamPacket via onUpdate and avoids racing with in-flight edits.
    var onBypassToggle: ((Int, Bool) -> Void)? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        // ScrollView contains the full list of rows.  Header and footer are
        // attached as safeAreaInset views so they stay pinned at the top
        // and bottom while the row content scrolls UNDERNEATH them — that
        // lets us use `.ultraThinMaterial` for a true translucent vibrancy
        // effect that picks up the row colors moving behind.
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(0..<bands.count, id: \.self) { index in
                    FilterRowView(
                        index: index,
                        params: bands[index],
                        availableTypes: availableTypes,
                        bypassSupported: bypassSupported,
                        isCrossoverMode: isCrossoverMode,
                        onChange: { onUpdate(index, $0) },
                        onBypassToggle: { newVal in
                            onBypassToggle?(index, newVal)
                        }
                    )
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                if bypassSupported {
                    Spacer().frame(width: 18)
                }
                Text("#").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 24, alignment: .leading)
                Text(isCrossoverMode ? "FAMILY" : "TYPE").font(.caption).fontWeight(.bold).foregroundColor(.secondary).padding(.leading, 8).frame(width: isCrossoverMode ? 110 : 140, alignment: .leading).padding(.leading, -15)
                if isCrossoverMode {
                    Text("TYPE").font(.caption).fontWeight(.bold).foregroundColor(.secondary).padding(.leading, 8).frame(width: 84, alignment: .leading).padding(.leading, 23)
                    Text("SLOPE").font(.caption).fontWeight(.bold).foregroundColor(.secondary).padding(.leading, 7).frame(width: 80, alignment: .leading).padding(.leading, 25)
                    Text("FREQ").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 104, alignment: .center).padding(.leading, -3)
                } else {
                    Text("FREQ").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 104, alignment: .center)
                    Text("GAIN").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 84, alignment: .center)
                    Text("WIDTH").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 74, alignment: .center)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    Color.black.opacity(0.01)
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if onClear != nil || !tabs.isEmpty || (bypassSupported && onBypassToggle != nil) {
                HStack(spacing: 0) {
                    if bypassSupported, let onBypassToggle = onBypassToggle {
                        // Off bands (type == .flat) have no audio effect, so
                        // their bypass flag is meaningless — exclude them from
                        // both the disable logic and the click action.  When
                        // every band is Off, `actionable` is empty and
                        // allSatisfy returns true for both predicates, which
                        // greys out both halves of the control.
                        let actionable = bands.filter { $0.type != .flat }
                        BypassAllControls(
                            allBypassed: actionable.allSatisfy { $0.bypass },
                            allEnabled: actionable.allSatisfy { !$0.bypass },
                            onEnableAll: {
                                for i in bands.indices where bands[i].type != .flat {
                                    onBypassToggle(i, false)
                                }
                            },
                            onBypassAll: {
                                let doBypassAll = {
                                    for i in bands.indices where bands[i].type != .flat {
                                        onBypassToggle(i, true)
                                    }
                                }
                                // Bypassing a crossover removes the high/low-pass
                                // protection, sending full-range audio to the
                                // drivers — which can destroy a tweeter.  Require
                                // explicit confirmation on the XO tab.  Re-enabling
                                // is safe, so onEnableAll stays unprompted.
                                if isCrossoverMode {
                                    let alert = NSAlert()
                                    alert.messageText = "Bypass this output's crossovers?"
                                    alert.informativeText = "This sends full-range audio to this output with no crossover protection, which can damage unprotected drivers such as tweeters. Continue only if you are sure."
                                    alert.alertStyle = .critical
                                    alert.addButton(withTitle: "Bypass All")
                                    alert.addButton(withTitle: "Cancel")
                                    if alert.runModal() == .alertFirstButtonReturn {
                                        doBypassAll()
                                    }
                                } else {
                                    doBypassAll()
                                }
                            }
                        )
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if let onClear = onClear {
                            FilterListHeaderButton(
                                title: "Clear All",
                                tint: .secondary,
                                action: {
                                    let alert = NSAlert()
                                    alert.messageText = "Clear All Bands?"
                                    alert.informativeText = "Every band in this list will be reset to its default (flat) state. This cannot be undone."
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: "Clear All")
                                    alert.addButton(withTitle: "Cancel")
                                    if alert.runModal() == .alertFirstButtonReturn {
                                        onClear()
                                    }
                                },
                                help: "Reset all bands"
                            )
                        }
                        if !tabs.isEmpty {
                            FilterListTabToggle(tabs: tabs)
                        }
                    }
                    .fixedSize()
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
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
    /// True when the connected firmware supports per-band bypass (>= 1.1.4).
    /// When false the bypass checkbox is hidden so users don't try to use
    /// a non-functional control.
    var bypassSupported: Bool = false
    /// When true the row renders the XO-tab layout: a shape (family+LP/HP)
    /// picker, a separate order picker, freq, and an empty width column.
    var isCrossoverMode: Bool = false
    var onChange: (FilterParams) -> Void
    /// Toggle just the bypass flag without re-sending freq/Q/gain.  When
    /// nil, the checkbox is rendered but its action no-ops; callers should
    /// always wire this when bypassSupported is true.
    var onBypassToggle: ((Bool) -> Void)? = nil

    /// Presentation state for the Linkwitz Transform parameter popover.  LT has
    /// four parameters (f0, Q0, fp, Qp) that don't fit the shared 3-column row,
    /// so they live in a popover opened from a compact button instead of
    /// widening the table.
    @State private var showLinkwitzPanel = false

    var isActive: Bool { params.type != .flat }
    var isBypassed: Bool { params.bypass }

    var body: some View {
        HStack(spacing: 12) {
            // Bypass checkbox (firmware 1.1.4+).  Filled disc only when the
            // band is both armed (filter type != Off) and not bypassed; an
            // "Off" band renders the same hollow ring as a bypassed one
            // since its audio contribution is the same.
            if bypassSupported {
                BypassCheckbox(
                    isActive: isActive && !isBypassed,
                    isEnabled: isActive,
                    onToggle: { onBypassToggle?(!isBypassed) }
                )
                .frame(width: 18, height: 18)
            }

            // Index
            Text("\(index + 1)")
                .font(.system(.body))
                .foregroundColor(isActive && !isBypassed ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, alignment: .leading)

            if isCrossoverMode {
                crossoverRowContent
            } else {
                peqRowContent
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

    // MARK: PEQ-tab row layout

    @ViewBuilder
    private var peqRowContent: some View {
        // Type Selector - a hierarchical menu.  Top level is the filter shape;
        // shapes with multiple orders (shelves, all-pass) open a submenu of
        // their order variants (e.g. "Low Shelf" ▸ "6 dB" / "12 dB").  The
        // button face shows the full name of the selected type.
        // Type name picker (left-click opens the shape menu).
        typeNameMenu

        // Controls
        if isActive {
            if params.type.isLinkwitzTransform {
                linkwitzControls
                    .opacity(isBypassed ? 0.45 : 1.0)
            } else {
                HStack(spacing: 12) {
                    // Freq
                    ValueField(label: "Hz", value: params.freq, width: 80, scrollStep: 10, minValue: 10) {
                        var p = params; p.freq = $0; onChange(p)
                    }

                    // Gain
                    if params.type.usesGain {
                        ValueField(label: "dB", value: params.gain, width: 60, maxDecimals: 2) {
                            var p = params; p.gain = $0; onChange(p)
                        }
                    } else {
                        Spacer().frame(width: 60 + 24) // Placeholder
                    }

                    // Q (hidden for crossover and first-order PEQ types — firmware
                    // ignores Q on those).
                    if params.type.usesQ {
                        ValueField(label: "Q", value: params.q, width: 50, minValue: 0.1, maxDecimals: 3, stripTrailingZeros: true) {
                            var p = params; p.q = $0; onChange(p)
                        }
                    } else {
                        Spacer().frame(width: 50 + 24)
                    }
                }
                .opacity(isBypassed ? 0.45 : 1.0)
            }
        }
    }

    /// Implied DC boost of the Linkwitz Transform, `40 x log10(f0/fp)` dB.
    /// Positive when fp < f0 (bass extension).  Real low-frequency gain that
    /// consumes driver excursion and amp headroom - surfaced so the user can
    /// apply a matching preamp cut.  See peq_filters.md §3.3.
    private var linkwitzDCBoostDB: Float {
        guard params.gain > 0, params.freq > 0 else { return 0 }
        return 40 * log10(params.freq / params.gain)
    }

    /// The filter-type name picker (a hierarchical Menu).  Extracted so the
    /// Linkwitz Transform row can hang a right-click gesture and popover off it
    /// without duplicating the styling.
    @ViewBuilder
    private var typeNameMenu: some View {
        Menu {
            peqTypeMenuItems
        } label: {
            Text(params.type.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        // `.button` style + `.plain` strips the ~8pt padding `.borderlessButton`
        // adds so the label sits flush-left under the TYPE header; the chevron
        // is an overlay (not an HStack sibling, which borderless menus shuffle).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 140, height: 20, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
        }
        .padding(.leading, -15)
        .opacity(isBypassed || !isActive ? 0.45 : 1.0)
    }

    /// LT row controls: a single config icon in the Freq column that opens the
    /// parameter popover.  No numeric columns, so the table stays clean.
    @ViewBuilder
    private var linkwitzControls: some View {
        HStack(spacing: 12) {
            Button {
                showLinkwitzPanel = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 80 + 24, alignment: .center)
            .help("Edit Linkwitz Transform parameters (f0, Q0, fp, Qp)")
            .popover(isPresented: $showLinkwitzPanel, arrowEdge: .bottom) {
                linkwitzPopover
            }
        }
    }

    /// The Linkwitz Transform parameter panel: driver alignment (f0, Q0) mapped
    /// to a target alignment (fp, Qp), with the implied DC boost called out.
    @ViewBuilder
    private var linkwitzPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Linkwitz Transform")
                    .font(.headline)
                Text("Re-align a sealed woofer's rolloff from the driver's (f0, Q0) to a target (fp, Qp).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Driver").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    linkwitzField(label: "f0", unit: "Hz", value: params.freq, width: 64, scrollStep: 1, minValue: 10, decimals: 1) {
                        var p = params; p.freq = $0; onChange(p)
                    }
                    linkwitzField(label: "Q0", unit: "", value: params.q, width: 56, scrollStep: 0.01, minValue: 0.1, decimals: 3) {
                        var p = params; p.q = $0; onChange(p)
                    }
                }
                GridRow {
                    Text("Target").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    linkwitzField(label: "fp", unit: "Hz", value: params.gain, width: 64, scrollStep: 1, minValue: 10, decimals: 1) {
                        var p = params; p.gain = $0; onChange(p)
                    }
                    linkwitzField(label: "Qp", unit: "", value: params.qp, width: 56, scrollStep: 0.01, minValue: 0.1, decimals: 3) {
                        var p = params; p.qp = $0; onChange(p)
                    }
                }
            }

            Divider()

            let boost = linkwitzDCBoostDB
            HStack(spacing: 6) {
                Text("DC boost")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%+.1f dB", boost))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundColor(boost > 15 ? .orange : .primary)
                if boost > 15 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Text("Real low-frequency gain (40 x log10(f0/fp)). It uses driver excursion and amp headroom - reduce preamp or master volume to match.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    /// A labelled numeric field for the LT popover: caption label, the value
    /// field, then an optional unit - fixed widths so the two rows align.
    @ViewBuilder
    private func linkwitzField(label: String, unit: String, value: Float, width: CGFloat,
                               scrollStep: Float, minValue: Float, decimals: Int,
                               onCommit: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .leading)
            ValueField(label: unit, value: value, width: width, scrollStep: scrollStep,
                       minValue: minValue, maxDecimals: decimals, stripTrailingZeros: true, onCommit: onCommit)
        }
    }

    /// A shape in the PEQ type menu and its order variants (gentler first).
    /// Single-variant shapes render as a plain item; multi-variant shapes
    /// (shelves, all-pass) render as a submenu of their `orderLabel`s.
    private struct PEQMenuGroup { let name: String; let variants: [FilterType] }

    private static let peqMenuGroups: [PEQMenuGroup] = [
        PEQMenuGroup(name: "Off",        variants: [.flat]),
        PEQMenuGroup(name: "Peaking",    variants: [.peaking]),
        PEQMenuGroup(name: "Low Shelf",  variants: [.lowShelf1, .lowShelf]),
        PEQMenuGroup(name: "High Shelf", variants: [.highShelf1, .highShelf]),
        PEQMenuGroup(name: "High Cut",   variants: [.lowPass]),
        PEQMenuGroup(name: "Low Cut",    variants: [.highPass]),
        PEQMenuGroup(name: "Notch",      variants: [.notch]),
        PEQMenuGroup(name: "All Pass",   variants: [.allPass1, .allPass]),
        PEQMenuGroup(name: "Linkwitz Transform", variants: [.linkwitzTransform]),
    ]

    @ViewBuilder
    private var peqTypeMenuItems: some View {
        ForEach(Self.peqMenuGroups, id: \.name) { group in
            // Gate each shape's variants on firmware capability via the
            // caller-supplied `availableTypes`.
            let avail = group.variants.filter { availableTypes.contains($0) }
            if avail.count == 1 {
                peqTypeButton(avail[0], title: group.name)
            } else if avail.count > 1 {
                Menu(group.name) {
                    ForEach(avail, id: \.self) { type in
                        peqTypeButton(type, title: type.orderLabel ?? type.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func peqTypeButton(_ type: FilterType, title: String) -> some View {
        Button {
            var p = params
            let wasLT = p.type.isLinkwitzTransform
            p.type = type
            // The Linkwitz Transform repurposes the gain field as fp (Hz).
            // Seed it on entry so the band starts neutral (fp = f0 => 0 dB DC
            // boost) rather than flat (fp <= 0) or with a leftover dB value;
            // reset it to 0 dB on exit so a stale fp isn't read as gain.
            if type.isLinkwitzTransform && !wasLT {
                if p.gain <= 0 { p.gain = p.freq }
                p.qp = FilterParams.defaultQp
            } else if !type.isLinkwitzTransform && wasLT {
                p.gain = 0
            }
            onChange(p)
        } label: {
            if params.type == type {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: XO-tab row layout

    private var currentFamilyOption: CrossoverFamilyOption {
        CrossoverFamilyOption(from: params.type)
    }

    private var currentLowPass: Bool {
        params.type.crossoverIsLowPass ?? true
    }

    /// Family options offered in the XO TYPE picker — Off plus the unique
    /// crossover families present in `availableTypes`.
    private var availableFamilies: [CrossoverFamilyOption] {
        var seen = Set<CrossoverFamilyOption>()
        var out: [CrossoverFamilyOption] = [.off]
        seen.insert(.off)
        for t in availableTypes {
            let opt = CrossoverFamilyOption(from: t)
            if seen.insert(opt).inserted { out.append(opt) }
        }
        return out
    }

    private var availableOrdersForFamily: [Int] {
        currentFamilyOption.family?.availableOrders ?? []
    }

    @ViewBuilder
    private var crossoverRowContent: some View {
        // TYPE picker — full family name only (LP/HP lives in its own column).
        BorderlessPopUpButton(
            items: availableFamilies,
            titleForItem: { $0.label },
            selection: Binding(
                get: { currentFamilyOption },
                set: { applyFamily($0) }
            )
        )
        .frame(width: 110, height: 20)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
        }
        .padding(.leading, -15)
        .opacity(isBypassed || !isActive ? 0.45 : 1.0)

        if isActive {
            HStack(spacing: 12) {
                // LP/HP picker — splits direction out of TYPE so each axis
                // is independently selectable.
                BorderlessPopUpButton(
                    items: [true, false],
                    titleForItem: { $0 ? "Low Pass" : "High Pass" },
                    selection: Binding(
                        get: { currentLowPass },
                        set: { applyLowPass($0) }
                    )
                )
                .frame(width: 84, height: 20)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                }
                .padding(.leading, 23)

                // Slope picker — order shown as its dB/octave equivalent
                // (order × 6).  Internal data model is still order; only
                // the label changes for user-facing clarity.
                BorderlessPopUpButton(
                    items: availableOrdersForFamily,
                    titleForItem: { "\($0 * 6) dB/oct" },
                    selection: Binding(
                        get: { params.type.crossoverOrder },
                        set: { applyOrder($0) }
                    )
                )
                .frame(width: 80, height: 20)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                }
                .padding(.leading, 25)

                // Freq
                ValueField(label: "Hz", value: params.freq, width: 80, scrollStep: 10, minValue: 10) {
                    var p = params; p.freq = $0; onChange(p)
                }
                .padding(.leading, -3)
            }
            .opacity(isBypassed ? 0.45 : 1.0)
        }
    }

    private func applyFamily(_ option: CrossoverFamilyOption) {
        var p = params
        switch option {
        case .off:
            p.type = .flat
        case .family(let family):
            // Preserve current order if valid for the new family, else
            // snap to the closest available.  Preserve current LP/HP
            // (defaults to LP when transitioning from Off).
            let orders = family.availableOrders
            let currentOrder = params.type.crossoverOrder
            let order = orders.contains(currentOrder)
                ? currentOrder
                : (orders.min(by: { abs($0 - currentOrder) < abs($1 - currentOrder) }) ?? orders.first ?? 2)
            let lp = params.type.crossoverIsLowPass ?? true
            guard let newType = family.filterType(order: order, lowPass: lp) else { return }
            p.type = newType
        }
        onChange(p)
    }

    private func applyLowPass(_ lowPass: Bool) {
        guard let family = currentFamilyOption.family,
              let newType = family.filterType(order: params.type.crossoverOrder, lowPass: lowPass) else { return }
        var p = params
        p.type = newType
        onChange(p)
    }

    private func applyOrder(_ order: Int) {
        guard let family = currentFamilyOption.family,
              let newType = family.filterType(order: order, lowPass: currentLowPass) else { return }
        var p = params
        p.type = newType
        onChange(p)
    }
}

/// User-facing TYPE option on the XO tab — the crossover family name
/// (Linkwitz-Riley, Butterworth, Bessel) plus an "Off" sentinel.  LP/HP
/// and order are selected in separate columns.
fileprivate enum CrossoverFamilyOption: Hashable {
    case off
    case family(CrossoverFamily)

    init(from type: FilterType) {
        if type == .flat {
            self = .off
        } else if let f = type.crossoverFamily {
            self = .family(f)
        } else {
            self = .off
        }
    }

    var family: CrossoverFamily? {
        if case .family(let f) = self { return f }
        return nil
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .family(let f): return f.name
        }
    }
}

// MARK: - Bypass Checkbox

/// Stylish round indicator used for per-band bypass.  Filled accent dot
/// when the band is active; hollow ring with a slash when bypassed.
/// Dimmed when the band is "Off" (filter type = flat) so the control
/// reads as inert until a real filter is selected.
struct BypassCheckbox: View {
    let isActive: Bool
    let isEnabled: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                // Active: solid accent fill with a subtle radial highlight
                // for a glassy look.  Inactive: hollow ring on a near-clear
                // disc so the hit area still covers the interior.
                Circle()
                    .fill(isActive ? Color(white: 0.5) : Color.white.opacity(0.001))
                    .frame(width: 12, height: 12)

                Circle()
                    .strokeBorder(
                        isActive
                            ? Color(white: 0.5)
                            : Color.secondary.opacity(0.55),
                        lineWidth: 1.2
                    )
                    .frame(width: 12, height: 12)
            }
            .frame(width: 18, height: 18)        // larger hit area than the visible 12×12
            .contentShape(Rectangle())
            .scaleEffect(hovered && isEnabled ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: hovered)
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .opacity(isEnabled ? 1.0 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovered = $0 }
        .help(isActive ? "Bypass this band" : "Re-enable this band")
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
    /// When true, an all-zero decimal portion is dropped entirely (e.g.
    /// "1.000" → "1") instead of being collapsed to a single trailing zero.
    /// Useful for Q where "1.0" reads as awkward but mid-precision values
    /// like "0.707" must still show full precision.
    var stripTrailingZeros: Bool = false
    var displayOverride: String? = nil
    let onCommit: (Float) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private func format(_ v: Float) -> String {
        let full = String(format: "%.\(maxDecimals)f", v)
        // Trim trailing zeros from the decimal portion.
        let parts = full.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return full }
        let decimals = String(parts[1])
        let trimmed = decimals.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        if trimmed.isEmpty {
            return stripTrailingZeros ? String(parts[0]) : "\(parts[0]).0"
        }
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
    /// Optional custom glyph rendered with the "Apple Symbols" font instead of
    /// an SF Symbol. Used for glyphs SF Symbols lacks (e.g. the bass clef).
    var glyph: String? = nil
    /// Point size for the custom `glyph` (SF Symbols use a fixed 14).
    var glyphSize: CGFloat = 16
    /// Vertical nudge for the custom `glyph`, to correct fonts with uneven
    /// bearings (positive moves down).
    var glyphYOffset: CGFloat = 0
    let isActive: Bool
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let glyph {
                    Text(glyph)
                        .font(.custom("Apple Symbols", size: glyphSize))
                        .offset(y: glyphYOffset)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                }
            }
            .foregroundColor(isActive ? .white : isHovered ? .white.opacity(0.7) : .secondary.opacity(0.6))
            .animation(.easeInOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
    }
}
