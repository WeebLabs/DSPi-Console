import SwiftUI

// MARK: - Output Channel Definitions

struct MatrixOutput {
    let index: Int
    let name: String
    let descriptor: String
    let color: Color

    static let all: [MatrixOutput] = [
        MatrixOutput(index: 0, name: "SPDIF 1 L", descriptor: "OUT1", color: Color(red: 0.27, green: 0.76, blue: 0.64)),
        MatrixOutput(index: 1, name: "SPDIF 1 R", descriptor: "OUT2", color: Color(red: 0.35, green: 0.82, blue: 0.50)),
        MatrixOutput(index: 2, name: "SPDIF 2 L", descriptor: "OUT3", color: Color(red: 0.94, green: 0.77, blue: 0.35)),
        MatrixOutput(index: 3, name: "SPDIF 2 R", descriptor: "OUT4", color: Color(red: 0.95, green: 0.65, blue: 0.30)),
        MatrixOutput(index: 4, name: "SPDIF 3 L", descriptor: "OUT5", color: Color(red: 0.35, green: 0.55, blue: 0.95)),
        MatrixOutput(index: 5, name: "SPDIF 3 R", descriptor: "OUT6", color: Color(red: 0.55, green: 0.70, blue: 0.95)),
        MatrixOutput(index: 6, name: "SPDIF 4 L", descriptor: "OUT7", color: Color(red: 0.85, green: 0.45, blue: 0.55)),
        MatrixOutput(index: 7, name: "SPDIF 4 R", descriptor: "OUT8", color: Color(red: 0.95, green: 0.60, blue: 0.65)),
        MatrixOutput(index: 8, name: "PDM",            descriptor: "OUT9", color: Color(red: 0.73, green: 0.53, blue: 0.95)),
    ]
}

struct MatrixInput {
    let index: Int
    let name: String
    let color: Color

    static let all: [MatrixInput] = [
        MatrixInput(index: 0, name: "Input L", color: Color(red: 0.29, green: 0.56, blue: 0.89)),
        MatrixInput(index: 1, name: "Input R", color: Color(red: 0.96, green: 0.45, blue: 0.45)),
    ]
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

    private let columnWidth: CGFloat = 72
    private let labelWidth: CGFloat = 75

    var body: some View {
        VStack(spacing: 12) {
            // Routing matrix
            routingSection

            // Per-output controls
            outputSection
        }
        .padding()
        .fixedSize()
        .alert(item: $pendingConflict) { conflict in
            if conflict.isPDM {
                Alert(
                    title: Text("Warning"),
                    message: Text("Channels 3-8 will be disabled. Are you sure?"),
                    primaryButton: .default(Text("Enable PDM")) {
                        DispatchQueue.global(qos: .userInitiated).async {
                            vm.switchToPDM()
                        }
                    },
                    secondaryButton: .cancel()
                )
            } else {
                Alert(
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
        if outputIndex == 8 {
            // PDM conflicts with any enabled output in 2-7
            return (2...7).contains(where: { vm.outputEnabled[$0] })
        } else if (2...7).contains(outputIndex) {
            // EQ worker output conflicts with enabled PDM
            return vm.outputEnabled[8]
        }
        return false
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
            pendingConflict = PendingConflict(output: output, isPDM: output == 8)
        } else {
            vm.setOutputEnable(output: output, enabled: true)
        }
    }

    // MARK: - Routing Matrix

    private var routingSection: some View {
        VStack(spacing: 0) {
            // Column headers (output names)
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 44)

                ForEach(MatrixOutput.all, id: \.index) { out in
                    VStack(spacing: 2) {
                        Text(out.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary.opacity(0.9))
                        Text(out.descriptor)
                            .font(.system(size: 8))
                            .foregroundColor(out.color.opacity(0.7))
                    }
                    .frame(width: columnWidth, height: 44)
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))

            Divider()

            // Input rows
            ForEach(MatrixInput.all, id: \.index) { input in
                HStack(spacing: 0) {
                    // Row header
                    Text(input.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(input.color)
                        .frame(width: labelWidth, alignment: .center)

                    Divider()

                    // Crosspoint cells
                    ForEach(MatrixOutput.all, id: \.index) { out in
                        MatrixPoint(
                            isConnected: matrixRoutingBinding(row: input.index, col: out.index),
                            gain: matrixGainBinding(row: input.index, col: out.index),
                            isInverted: matrixInvertBinding(row: input.index, col: out.index),
                            inputColor: input.color,
                            outputColor: out.color
                        )
                        .frame(width: columnWidth)
                    }
                }
                .frame(height: 78)

                if input.index == 0 {
                    Divider().padding(.leading, labelWidth)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Output Controls

    private var outputSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Row labels
                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(height: 36) // header spacer
                    outputRowLabel("ENABLE")
                    outputRowLabel("GAIN")
                    outputRowLabel("DELAY")
                    outputRowLabel("MUTE")
                }
                .frame(width: labelWidth)

                // Output columns
                ForEach(MatrixOutput.all, id: \.index) { out in
                    let idx = out.index
                    let enabled = vm.outputEnabled[idx]

                    VStack(spacing: 0) {
                        // Header: output name + descriptor
                        VStack(spacing: 1) {
                            Text(out.name)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(enabled ? out.color : out.color.opacity(0.4))
                            Text(out.descriptor)
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .frame(height: 36)

                        // Enable
                        Button(action: {
                            requestOutputEnable(output: idx)
                        }) {
                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(
                                    enabled ? .blue :
                                    (wouldConflict(idx) ? .orange.opacity(0.4) : .secondary.opacity(0.3))
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(height: 28)
                        .help(
                            enabled ? "Disable output (saves CPU)" :
                            (wouldConflict(idx) ? "Conflict: shared Core 1 resource" : "Enable output")
                        )

                        // Gain
                        CompactGainField(gain: Binding(
                            get: { vm.outputGainDB[idx] },
                            set: { vm.setOutputGain(output: idx, db: $0) }
                        ))
                        .frame(height: 28)
                        .opacity(enabled ? 1.0 : 0.3)

                        // Delay
                        CompactDelayField(delay: Binding(
                            get: { vm.outputDelayMS[idx] },
                            set: { vm.setOutputDelay(output: idx, ms: $0) }
                        ))
                        .frame(height: 28)
                        .opacity(enabled ? 1.0 : 0.3)

                        // Mute
                        Button(action: {
                            vm.setOutputMute(output: idx, muted: !vm.outputMuted[idx])
                        }) {
                            Image(systemName: vm.outputMuted[idx] ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .foregroundColor(vm.outputMuted[idx] ? .red : .secondary.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .frame(height: 28)
                        .opacity(enabled ? 1.0 : 0.3)
                        .help(vm.outputMuted[idx] ? "Unmute" : "Mute")
                    }
                    .frame(width: columnWidth)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
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

    // MARK: - Helpers

    private func outputRowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .frame(height: 28)
            .padding(.trailing, 8)
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
            .foregroundColor(isFocused ? .accentColor : .primary.opacity(0.85))
            .multilineTextAlignment(.center)
            .frame(width: 50)
            .focused($isFocused)
            .onSubmit { commitValue(); isFocused = false }
            .onChange(of: isFocused) { focused in
                if focused {
                    text = gain == 0 ? "0" : String(format: "%+.0f", gain)
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

    private func updateDisplay() {
        text = gain == 0 ? "0 dB" : String(format: "%+.0f dB", gain)
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
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isFocused ? .accentColor : .primary.opacity(0.85))
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
                        delay = max(0, min(170, delay + delta * 5))
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
            delay = max(0, min(170, value))
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
    @State private var isHovering = false
    @State private var isHoveringInvert = false

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
                            .fill(Color.accentColor)
                            .frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .stroke(
                                Color.secondary.opacity(isHovering ? 0.3 : 0.12),
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
