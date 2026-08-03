import SwiftUI

// MARK: - Output Channel Definitions

struct MatrixOutput {
    let index: Int
    let name: String
    let descriptor: String
    let color: Color

    static let pdmColor = ChannelPalette.pdm

    /// All outputs for RP2350 (9 outputs: 4 SPDIF pairs + PDM at index 8)
    static let all: [MatrixOutput] = [
        MatrixOutput(index: 0, name: "SPDIF 1 L", descriptor: "OUT1", color: ChannelPalette.output(0)),
        MatrixOutput(index: 1, name: "SPDIF 1 R", descriptor: "OUT2", color: ChannelPalette.output(1)),
        MatrixOutput(index: 2, name: "SPDIF 2 L", descriptor: "OUT3", color: ChannelPalette.output(2)),
        MatrixOutput(index: 3, name: "SPDIF 2 R", descriptor: "OUT4", color: ChannelPalette.output(3)),
        MatrixOutput(index: 4, name: "SPDIF 3 L", descriptor: "OUT5", color: ChannelPalette.output(4)),
        MatrixOutput(index: 5, name: "SPDIF 3 R", descriptor: "OUT6", color: ChannelPalette.output(5)),
        MatrixOutput(index: 6, name: "SPDIF 4 L", descriptor: "OUT7", color: ChannelPalette.output(6)),
        MatrixOutput(index: 7, name: "SPDIF 4 R", descriptor: "OUT8", color: ChannelPalette.output(7)),
        MatrixOutput(index: 8, name: "PDM",        descriptor: "OUT9", color: pdmColor),
    ]

    /// RP2040 outputs: 2 SPDIF pairs (indices 0-3) + PDM at index 4
    static let rp2040: [MatrixOutput] = [
        all[0], all[1], all[2], all[3],
        MatrixOutput(index: 4, name: "PDM", descriptor: "OUT5", color: pdmColor),
    ]

    static func visible(for platform: String) -> [MatrixOutput] {
        platform == "RP2040" ? rp2040 : all
    }

    static func visible(for platform: String, slotTypes: [UInt8]) -> [MatrixOutput] {
        func slotName(_ slot: Int) -> String {
            slot < slotTypes.count && slotTypes[slot] == 1 ? "I2S" : "SPDIF"
        }
        if platform == "RP2040" {
            return [
                MatrixOutput(index: 0, name: "\(slotName(0)) 1 L", descriptor: "OUT1", color: all[0].color),
                MatrixOutput(index: 1, name: "\(slotName(0)) 1 R", descriptor: "OUT2", color: all[1].color),
                MatrixOutput(index: 2, name: "\(slotName(1)) 2 L", descriptor: "OUT3", color: all[2].color),
                MatrixOutput(index: 3, name: "\(slotName(1)) 2 R", descriptor: "OUT4", color: all[3].color),
                MatrixOutput(index: 4, name: "PDM", descriptor: "OUT5", color: pdmColor),
            ]
        } else {
            return [
                MatrixOutput(index: 0, name: "\(slotName(0)) 1 L", descriptor: "OUT1", color: all[0].color),
                MatrixOutput(index: 1, name: "\(slotName(0)) 1 R", descriptor: "OUT2", color: all[1].color),
                MatrixOutput(index: 2, name: "\(slotName(1)) 2 L", descriptor: "OUT3", color: all[2].color),
                MatrixOutput(index: 3, name: "\(slotName(1)) 2 R", descriptor: "OUT4", color: all[3].color),
                MatrixOutput(index: 4, name: "\(slotName(2)) 3 L", descriptor: "OUT5", color: all[4].color),
                MatrixOutput(index: 5, name: "\(slotName(2)) 3 R", descriptor: "OUT6", color: all[5].color),
                MatrixOutput(index: 6, name: "\(slotName(3)) 4 L", descriptor: "OUT7", color: all[6].color),
                MatrixOutput(index: 7, name: "\(slotName(3)) 4 R", descriptor: "OUT8", color: all[7].color),
                MatrixOutput(index: 8, name: "PDM", descriptor: "OUT9", color: pdmColor),
            ]
        }
    }
}

struct MatrixInput {
    let index: Int
    let name: String
    let color: Color

    /// Distinct row colors for up to 8 matrix inputs.  Defined once in
    /// `ChannelPalette`; indices 0/1 keep the stereo blue/red so the 2-input
    /// view is unchanged.
    static let palette: [Color] = ChannelPalette.inputs

    /// 7.1 USB input order used in 8-channel mode (spec §5).
    static let surroundShortNames = ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"]
    static let surroundFullNames  = ["Front Left", "Front Right", "Center", "LFE",
                                     "Back Left", "Back Right", "Side Left", "Side Right"]

    /// Stereo (2-input) labels.
    static let stereo: [MatrixInput] = [
        MatrixInput(index: 0, name: "Input L", color: palette[0]),
        MatrixInput(index: 1, name: "Input R", color: palette[1]),
    ]

    /// Backward-compatible alias for the stereo input pair.
    static let all: [MatrixInput] = stereo

    static func color(for input: Int) -> Color {
        palette.indices.contains(input) ? palette[input] : .accentColor
    }

    /// Short row label for the given input index and total input count.
    static func shortName(for input: Int, count: Int) -> String {
        if count <= 2 { return input == 0 ? "Input L" : "Input R" }
        return surroundShortNames.indices.contains(input) ? surroundShortNames[input] : "In \(input + 1)"
    }

    static func fullName(for input: Int, count: Int) -> String {
        if count <= 2 { return input == 0 ? "USB Left" : "USB Right" }
        return surroundFullNames.indices.contains(input) ? surroundFullNames[input] : "Input \(input + 1)"
    }

    /// The inputs to render for a given count (2 = stereo, 8 = 7.1 surround).
    static func inputs(count: Int) -> [MatrixInput] {
        (0..<max(count, 1)).map { i in
            MatrixInput(index: i, name: shortName(for: i, count: count), color: color(for: i))
        }
    }
}

// MARK: - Matrix Mixer View

struct PendingConflict: Identifiable {
    let id = UUID()
    let output: Int
    let isPDM: Bool  // true = user wants to enable PDM, false = user wants to enable an EQ worker output
}

struct MatrixMixerView: View {
    @ObservedObject var vm: DSPViewModel
    @State private var pendingConflict: PendingConflict?
    @State private var renamingOutput: Int? = nil
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private let columnWidth: CGFloat = 72
    private let labelWidth: CGFloat = 80

    private var visibleOutputs: [MatrixOutput] {
        MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes)
    }

    private var is8ch: Bool { vm.supports8chInput }

    private var matrixInputs: [MatrixInput] {
        // In stereo + upmix mode the row count exceeds the plain input count and
        // rows 2-4 carry contextual Upmix C / Ls / Rs labels (spec §3).
        (0..<max(vm.matrixSourceRowCount, 1)).map { i in
            MatrixInput(index: i, name: vm.matrixRowShortName(i), color: MatrixInput.color(for: i))
        }
    }

    private func commitRename() {
        guard let idx = renamingOutput else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                vm.setChannelName(channel: vm.eqChannel(forOutput: idx), name: trimmed)
            }
        }
        renamingOutput = nil
    }

    private func startRename(_ index: Int) {
        if renamingOutput != nil { commitRename() }
        renameText = vm.channelNames[vm.eqChannel(forOutput: index)]
        renamingOutput = index
    }

    var body: some View {
        Group {
            if is8ch {
                // 8 input rows make a tall/wide table; let the (resizable) window
                // scroll it rather than forcing an oversized fixed size.  The
                // stereo + upmixer matrix (up to 5 rows) stays fixed-size so the
                // window can shrink-to-fit when the upmixer is toggled off.
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 0) { unifiedSection }
                        .padding()
                }
            } else {
                VStack(spacing: 0) { unifiedSection }
                    .padding()
                    .fixedSize()
            }
        }
        .onTapGesture {
            if renamingOutput != nil { commitRename() }
        }
        .onChange(of: renameFocused) { focused in
            if !focused && renamingOutput != nil {
                commitRename()
            }
        }
        .onChange(of: renamingOutput) { idx in
            if idx != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    renameFocused = true
                }
            }
        }
        .alert(item: $pendingConflict) { conflict in
            if conflict.isPDM {
                let eqRange = vm.eqWorkerRange
                let first = eqRange.lowerBound + 1  // 1-based for display
                let last = eqRange.upperBound + 1
                return Alert(
                    title: Text("Warning"),
                    message: Text("Outputs \(first)-\(last) will be disabled. Are you sure?"),
                    primaryButton: .default(Text("Enable PDM")) {
                        DispatchQueue.global(qos: .userInitiated).async {
                            vm.switchToPDM()
                        }
                    },
                    secondaryButton: .cancel()
                )
            } else {
                return Alert(
                    title: Text("Warning"),
                    message: Text("The PDM output will be disabled. Are you sure?"),
                    primaryButton: .default(Text("Disable PDM")) {
                        let output = conflict.output
                        DispatchQueue.global(qos: .userInitiated).async {
                            vm.switchFromPDM(enabling: output)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Conflict Helpers

    /// Check if enabling this output would conflict with current state (client-side check).
    private func wouldConflict(_ outputIndex: Int) -> Bool {
        vm.outputEnableWouldConflict(outputIndex)
    }

    /// Handle enable button tap with conflict detection.
    private func requestOutputEnable(output: Int) {
        let currentlyEnabled = vm.outputEnabled[output]
        if currentlyEnabled {
            // Disabling always succeeds
            vm.setOutputEnable(output: output, enabled: false)
            return
        }
        // Enabling: check for conflict
        if wouldConflict(output) {
            pendingConflict = PendingConflict(output: output, isPDM: output == vm.pdmOutputIndex)
        } else {
            vm.setOutputEnable(output: output, enabled: true)
        }
    }

    // MARK: - Unified Matrix Table

    private var unifiedSection: some View {
        VStack(spacing: 0) {
            columnHeaders

            sectionDivider

            // ── ROUTING ──
            routingHeader
            inputRowsSection

            sectionDivider

            // ── OUTPUT CONTROLS ──
            sectionLabel("OUTPUT")
            outputControlsSection

            Spacer().frame(height: 4)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // ── Column headers ──
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 48)

            ForEach(visibleOutputs, id: \.index) { out in
                VStack(spacing: 3) {
                    if renamingOutput == out.index {
                        TextField("", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                    } else {
                        Text(vm.channelNames[vm.eqChannel(forOutput: out.index)])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(out.descriptor)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(out.color.opacity(0.8))
                }
                .frame(width: columnWidth, height: 48)
                .contentShape(Rectangle())
                .contextMenu {
                    if vm.isDeviceConnected && vm.siggenSupported {
                        // Identify plays the ident tone on this output; a
                        // matrix-disabled output would render silent, so gate
                        // on enabled (spec §5.3 intersection rule).
                        Button("Identify") { vm.identifyOutput(out.index) }
                            .disabled(!vm.outputEnabled[out.index])
                        Divider()
                    }
                    Button("Rename") { startRename(out.index) }
                    Divider()
                    Button("Copy Parameters") {
                        vm.copyChannelParams(eqChannel: vm.eqChannel(forOutput: out.index), name: vm.channelNames[vm.eqChannel(forOutput: out.index)])
                    }
                    Button("Paste Parameters") {
                        vm.pasteChannelParams(eqChannel: vm.eqChannel(forOutput: out.index))
                    }
                    .disabled(vm.channelClipboard == nil)
                }
            }
        }
    }

    // ── Routing input rows ──
    private var inputRowsSection: some View {
        ForEach(matrixInputs, id: \.index) { input in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    inputLabel(input)
                    ForEach(visibleOutputs, id: \.index) { out in
                        crosspointCell(input: input, out: out)
                    }
                }
                .frame(height: 78)

                if rowNeedsDivider(after: input.index) {
                    Divider().padding(.leading, labelWidth).opacity(0.4)
                }
            }
        }
    }

    private func crosspointCell(input: MatrixInput, out: MatrixOutput) -> some View {
        let enabled = vm.outputEnabled[out.index]
        let conflictOutline: Color? = (out.index == vm.pdmOutputIndex && wouldConflict(vm.pdmOutputIndex)) ? .orange : nil
        return MatrixPoint(
            isConnected: matrixRoutingBinding(row: input.index, col: out.index),
            gain: matrixGainBinding(row: input.index, col: out.index),
            isInverted: matrixInvertBinding(row: input.index, col: out.index),
            inputColor: input.color,
            outputColor: out.color,
            outlineColor: conflictOutline
        )
        .frame(width: columnWidth)
        .saturation(enabled ? 1.0 : 0.0)
        .opacity(enabled ? 1.0 : 0.3)
    }

    // ── Per-output controls (enable / gain / delay / mute) ──
    private var outputControlsSection: some View {
        VStack(spacing: 0) {
            controlRow("ENABLE") {
                ForEach(visibleOutputs, id: \.index) { out in
                    let idx = out.index
                    Button(action: { requestOutputEnable(output: idx) }) {
                        Image(systemName: "power")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                vm.outputEnabled[idx] ? .blue :
                                (wouldConflict(idx) ? .orange.opacity(0.4) : .secondary.opacity(0.3))
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(width: columnWidth, height: 30)
                    .help(
                        vm.outputEnabled[idx] ? "Disable output (saves CPU)" :
                        (wouldConflict(idx) ? "Conflict: shared Core 1 resource" : "Enable output")
                    )
                }
            }

            subtleDivider

            controlRow("GAIN") {
                ForEach(visibleOutputs, id: \.index) { out in
                    let idx = out.index
                    CompactGainField(gain: Binding(
                        get: { vm.outputGainDB[idx] },
                        set: { vm.setOutputGain(output: idx, db: $0) }
                    ))
                    .frame(width: columnWidth, height: 30)
                    .opacity(vm.outputEnabled[idx] ? 1.0 : 0.3)
                }
            }

            subtleDivider

            controlRow("DELAY") {
                ForEach(visibleOutputs, id: \.index) { out in
                    let idx = out.index
                    CompactDelayField(delay: Binding(
                        get: { vm.outputDelayMS[idx] },
                        set: { vm.setOutputDelay(output: idx, ms: $0) }
                    ), maxDelay: vm.platformName == "RP2040" ? 42 : 85)
                    .frame(width: columnWidth, height: 30)
                    .opacity(vm.outputEnabled[idx] ? 1.0 : 0.3)
                }
            }

            subtleDivider

            controlRow("MUTE") {
                ForEach(visibleOutputs, id: \.index) { out in
                    let idx = out.index
                    Button(action: {
                        vm.setOutputMute(output: idx, muted: !vm.outputMuted[idx])
                    }) {
                        Image(systemName: vm.outputMuted[idx] ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundColor(vm.outputMuted[idx] ? .red : .secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .frame(width: columnWidth, height: 30)
                    .opacity(vm.outputEnabled[idx] ? 1.0 : 0.3)
                    .help(vm.outputMuted[idx] ? "Unmute" : "Mute")
                }
            }
        }
    }

    // MARK: - Routing Header & Input Labels

    /// The "ROUTING" band.  In 8-channel mode it also carries quick-route
    /// buttons (Direct 1:1 / Clear) since out-of-the-box an 8-channel stream is
    /// silent until routes are set (spec §10.D).
    @ViewBuilder private var routingHeader: some View {
        if is8ch {
            HStack(spacing: 8) {
                Text("ROUTING")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.leading, 12)
                Spacer(minLength: 12)
                Button("Direct 1:1") { vm.applyDirectRouting() }
                .help("Route each input to the matching output (FL→OUT1, FR→OUT2, …) and disable the PDM sub")
                Button("Clear") { vm.clearAllRoutes() }
                .help("Disconnect every crosspoint")
                .padding(.trailing, 10)
            }
            .controlSize(.small)
            .frame(height: 26)
            .background(Color.white.opacity(0.015))
        } else {
            sectionLabel("ROUTING")
        }
    }

    /// Left-column label for an input row.  In 8-channel mode it shows the 7.1
    /// role plus a per-input trim (preamp) field so users can correct level /
    /// host channel-mapping differences (spec §14).
    @ViewBuilder private func inputLabel(_ input: MatrixInput) -> some View {
        if is8ch {
            VStack(spacing: 3) {
                Text(input.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(input.color)
                    .help(MatrixInput.fullName(for: input.index, count: vm.numMatrixInputs))
                CompactGainField(gain: matrixInputTrimBinding(input.index))
                    .help("Input trim (preamp) for \(MatrixInput.fullName(for: input.index, count: vm.numMatrixInputs))")
            }
            .frame(width: labelWidth)
        } else {
            Text(input.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(input.color)
                .frame(width: labelWidth, alignment: .center)
                .help(vm.matrixRowFullName(input.index))
        }
    }

    /// Whether to draw a divider beneath the row for `index`.  Stereo keeps a
    /// single L/R separator; 8-channel groups the 7.1 channels into stereo pairs.
    private func rowNeedsDivider(after index: Int) -> Bool {
        if is8ch {
            return index % 2 == 1 && index < vm.numMatrixInputs - 1
        }
        return index == 0
    }

    private func matrixInputTrimBinding(_ input: Int) -> Binding<Float> {
        Binding(
            get: { vm.preampDB.indices.contains(input) ? vm.preampDB[input] : 0 },
            set: { newVal in vm.setPreampChannel(channel: input, db: newVal) }
        )
    }

    // MARK: - Table Helpers

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private var subtleDivider: some View {
        Divider().padding(.leading, labelWidth).opacity(0.3)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.leading, 12)
            Spacer()
        }
        .frame(height: 22)
        .background(Color.white.opacity(0.015))
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
        }
        .frame(height: 30)
    }

    // MARK: - Bindings

    private func matrixRoutingBinding(row: Int, col: Int) -> Binding<Bool> {
        Binding(
            get: { vm.matrixRouting[row][col] },
            set: { newVal in
                vm.setMatrixRoute(
                    input: row, output: col,
                    enabled: newVal,
                    gain: vm.matrixGain[row][col],
                    invert: vm.matrixInvert[row][col])
            }
        )
    }

    private func matrixGainBinding(row: Int, col: Int) -> Binding<Float> {
        Binding(
            get: { vm.matrixGain[row][col] },
            set: { newVal in
                vm.setMatrixRoute(
                    input: row, output: col,
                    enabled: vm.matrixRouting[row][col],
                    gain: newVal,
                    invert: vm.matrixInvert[row][col])
            }
        )
    }

    private func matrixInvertBinding(row: Int, col: Int) -> Binding<Bool> {
        Binding(
            get: { vm.matrixInvert[row][col] },
            set: { newVal in
                vm.setMatrixRoute(
                    input: row, output: col,
                    enabled: vm.matrixRouting[row][col],
                    gain: vm.matrixGain[row][col],
                    invert: newVal)
            }
        )
    }

}

// MARK: - Compact Gain Field with Scroll Support

struct CompactGainField: View {
    @Binding var gain: Float
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isFocused ? .accentColor : .primary.opacity(0.65))
            .multilineTextAlignment(.center)
            .frame(width: 62)
            .focused($isFocused)
            .onSubmit { commitValue(); isFocused = false }
            .onChange(of: isFocused) { focused in
                if focused {
                    text = formatGain(gain)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                } else {
                    commitValue()
                }
            }
            .onAppear { updateDisplay() }
            .onChange(of: gain) { _ in
                if !isFocused { updateDisplay() }
            }
            .background(
                ScrollWheelHandler { delta in
                    if !isFocused {
                        gain = max(-60, min(12, gain + delta))
                    }
                }
            )
    }

    private func formatGain(_ value: Float) -> String {
        if value == 0 { return "0" }
        var s = String(format: "%+.2f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private func updateDisplay() {
        text = formatGain(gain) + " dB"
    }

    private func commitValue() {
        let cleaned = text
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let value = Float(cleaned) {
            gain = max(-60, min(12, value))
        }
        updateDisplay()
    }
}

// MARK: - Compact Delay Field with Scroll Support

struct CompactDelayField: View {
    @Binding var delay: Float
    var maxDelay: Float = 85
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isFocused ? .accentColor : .primary.opacity(0.65))
            .multilineTextAlignment(.center)
            .frame(width: 50)
            .focused($isFocused)
            .onSubmit { commitValue(); isFocused = false }
            .onChange(of: isFocused) { focused in
                if focused {
                    text = String(format: "%.1f", delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                } else {
                    commitValue()
                }
            }
            .onAppear { updateDisplay() }
            .onChange(of: delay) { _ in
                if !isFocused { updateDisplay() }
            }
            .background(
                ScrollWheelHandler { delta in
                    if !isFocused {
                        delay = max(0, min(maxDelay, delay + delta * 5))
                    }
                }
            )
    }

    private func updateDisplay() {
        if delay == 0 {
            text = "0 ms"
        } else if delay < 1 {
            text = String(format: "%.1f ms", delay)
        } else {
            text = String(format: "%.1f ms", delay)
        }
    }

    private func commitValue() {
        let cleaned = text
            .replacingOccurrences(of: "ms", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let value = Float(cleaned) {
            delay = max(0, min(maxDelay, value))
        }
        updateDisplay()
    }
}

// MARK: - Scroll Wheel Handler

struct ScrollWheelHandler: NSViewRepresentable {
    let onScroll: (Float) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? ScrollCaptureView {
            view.onScroll = onScroll
        }
    }

    class ScrollCaptureView: NSView {
        var onScroll: ((Float) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let delta = Float(event.scrollingDeltaY) * 0.1
            onScroll?(delta)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

// MARK: - Routing Point

struct MatrixPoint: View {
    @Binding var isConnected: Bool
    @Binding var gain: Float
    @Binding var isInverted: Bool
    let inputColor: Color
    let outputColor: Color
    var outlineColor: Color? = nil  // Optional override for disconnected circle outline
    @State private var isHovering = false
    @State private var isHoveringInvert = false

    private var disconnectedColor: Color {
        if let c = outlineColor {
            return c.opacity(isHovering ? 0.5 : 0.35)
        }
        return Color.secondary.opacity(isHovering ? 0.3 : 0.12)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Gain (when connected)
            if isConnected {
                CompactGainField(gain: $gain)
                    .padding(.top, 6)
            } else {
                Spacer().frame(height: 16)
            }

            Spacer().frame(height: 4)

            // Connection toggle
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isConnected.toggle()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())

                    if isConnected {
                        Circle()
                            .fill(inputColor)
                            .frame(width: 16, height: 16)
                    } else {
                        Circle()
                            .stroke(
                                disconnectedColor,
                                lineWidth: isHovering ? 2 : 1.5
                            )
                            .frame(width: 18, height: 18)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isConnected ? "Disconnect" : "Connect")

            Spacer().frame(height: 4)

            // Phase invert (when connected)
            if isConnected {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isInverted.toggle()
                    }
                }) {
                    Text("INV")
                        .font(.system(size: 9, weight: isInverted ? .bold : .medium))
                        .foregroundColor(
                            isInverted
                                ? Color.orange
                                : (isHoveringInvert ? .secondary.opacity(0.6) : .secondary.opacity(0.3))
                        )
                }
                .buttonStyle(.plain)
                .help(isInverted ? "Phase inverted" : "Normal phase")
                .padding(.bottom, 6)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHoveringInvert = hovering
                    }
                }
            } else {
                Spacer().frame(height: 16)
            }
        }
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MatrixMixerView(vm: .preview)
}
