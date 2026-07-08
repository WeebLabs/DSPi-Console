import SwiftUI

// MARK: - Volume Leveller Window Controller

class VolumeLevellerWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = VolumeLevellerView(vm: vm)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Volume Leveller"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
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

extension VolumeLevellerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Volume Leveller View

struct VolumeLevellerView: View {
    @ObservedObject var vm: DSPViewModel

    /// Number of input channels to expose in the mask grid (live layout, 2-8).
    private var channelCount: Int { min(max(vm.effectiveInputChannels, 2), 8) }

    /// Channel masks are only meaningful with more than two active inputs on a
    /// multichannel-capable device; the section is hidden for stereo.
    private var showMasks: Bool {
        vm.numInputChannels > BASE_MATRIX_INPUTS && channelCount > 2
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Parameters
                    parameterSection
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }
            }
        }
        .frame(width: 380, height: 540)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Volume Leveller")
                    .font(.system(size: 14, weight: .semibold))
                Text("Upward Dynamic Range Compression")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.levellerEnabled },
                set: { vm.setLeveller($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Parameter Section

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showMasks {
                channelSection
                Divider()
            }

            Text("PARAMETERS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // Amount
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Amount")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "%",
                        value: vm.levellerAmount,
                        width: 60
                    ) { vm.setLevellerAmount(min(100, max(0, $0))) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.levellerAmount },
                        set: { vm.setLevellerAmount($0) }
                    ),
                    range: 0...100
                )
                .disabled(!vm.isDeviceConnected)

                Text("Compression strength. Higher values reduce dynamic range more aggressively.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Speed
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed")
                    .font(.system(size: 12, weight: .medium))

                Picker("", selection: Binding(
                    get: { vm.levellerSpeed },
                    set: { vm.setLevellerSpeed($0) }
                )) {
                    Text("Slow").tag(0)
                    Text("Medium").tag(1)
                    Text("Fast").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!vm.isDeviceConnected)

                Text(speedDescription)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Max Gain
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Gain")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "dB",
                        value: vm.levellerMaxGainDB,
                        width: 60
                    ) { vm.setLevellerMaxGain(min(35, max(0, $0))) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.levellerMaxGainDB },
                        set: { vm.setLevellerMaxGain($0) }
                    ),
                    range: 0...35
                )
                .disabled(!vm.isDeviceConnected)

                Text("Maximum boost for quiet passages. Higher values risk amplifying noise.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Gate Threshold
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gate Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "dB",
                        value: vm.levellerGateDB,
                        width: 60
                    ) { vm.setLevellerGate(min(0, max(-96, $0))) }
                }

                CustomSlider(
                    value: Binding(
                        get: { vm.levellerGateDB },
                        set: { vm.setLevellerGate($0) }
                    ),
                    range: -96...0
                )
                .disabled(!vm.isDeviceConnected)

                Text("Silence gate. Signals below this level are not boosted, preventing noise amplification.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Lookahead
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lookahead")
                        .font(.system(size: 12, weight: .medium))
                    Text("Adds 5ms latency. Improves transient handling.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { vm.levellerLookahead },
                    set: { vm.setLevellerLookahead($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!vm.isDeviceConnected)
            }
        }
    }

    // MARK: - Channels

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHANNELS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("All channels (Night mode)") {
                        vm.setLevellerMasks(detector: 0xFF, apply: 0xFF)
                    }
                    Button("Center only (Dialog boost)") {
                        vm.setLevellerMasks(detector: 0x04, apply: 0x04)
                    }
                    Button("Front L / R only") {
                        vm.setLevellerMasks(detector: 0x03, apply: 0x03)
                    }
                } label: {
                    Text("Presets")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!vm.isDeviceConnected)
            }

            maskRow(
                label: "Detector",
                hint: "sets the shared gain",
                isOn: { vm.levellerDetectorMask & (1 << $0) != 0 },
                toggle: { vm.setLevellerDetectorChannel($0, enabled: $1) }
            )

            maskRow(
                label: "Apply",
                hint: "receives the gain",
                isOn: { vm.levellerApplyMask & (1 << $0) != 0 },
                toggle: { vm.setLevellerApplyChannel($0, enabled: $1) }
            )
        }
    }

    private func maskRow(label: String, hint: String,
                         isOn: @escaping (Int) -> Bool,
                         toggle: @escaping (Int, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(0..<channelCount, id: \.self) { ch in
                    channelChip(ch: ch, on: isOn(ch)) { toggle(ch, !isOn(ch)) }
                }
            }
        }
    }

    private func channelChip(ch: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(ch + 1)")
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
        .help(ch < vm.channelNames.count ? vm.channelNames[ch] : "Ch \(ch + 1)")
        .disabled(!vm.isDeviceConnected)
        .animation(.easeInOut(duration: 0.12), value: on)
    }

    private var speedDescription: String {
        switch vm.levellerSpeed {
        case 0: return "Slow \u{2014} Gentle response for music and wide dynamic range content."
        case 2: return "Fast \u{2014} Tight response for speech, dialogue, and podcasts."
        default: return "Medium \u{2014} Balanced response for general purpose use."
        }
    }
}
