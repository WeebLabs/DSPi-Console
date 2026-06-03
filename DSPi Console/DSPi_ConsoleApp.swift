//
//  DSPi_ConsoleApp.swift
//  DSPi Console
//
//  Created by Troy Dunn-Higgins on 07/01/2026.
//

import SwiftUI

// MARK: - App State (Shared USB Device and View Model)
class AppState: ObservableObject {
    static let shared = AppState()
    let usb = USBDevice()
    lazy var viewModel: DSPViewModel = DSPViewModel(usb: usb)

    /// Always-on listener for the device's bulk notification endpoint.
    /// Lifecycle is driven by DSPViewModel based on device connection state.
    /// The display window observes this same instance.
    lazy var interruptMonitor: InterruptMonitor = InterruptMonitor(usb: usb)

    private init() {}
}

// MARK: - App Settings
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Appearance
    @AppStorage("showGraphGlow") var showGraphGlow: Bool = true

    // Graphing
    @AppStorage("graphLineWidth") var graphLineWidth: Double = 2.0
    @AppStorage("graphAnimationSpeed") var graphAnimationSpeed: Double = 0.2

    // Scale & Labels
    @AppStorage("showFrequencyLabels") var showFrequencyLabels: Bool = true
    @AppStorage("showDBLabels") var showDBLabels: Bool = true
    @AppStorage("showFrequencyGrid") var showFrequencyGrid: Bool = true
    @AppStorage("showDBGrid") var showDBGrid: Bool = true
    @AppStorage("graphDBRange") var graphDBRange: Double = 50.0
    @AppStorage("graphDBCenter") var graphDBCenter: Double = 0.0
    @AppStorage("graphHeight") var graphHeight: Double = 250.0
    @AppStorage("graphMinFreq") var graphMinFreq: Double = 15.0
    @AppStorage("graphMaxFreq") var graphMaxFreq: Double = 20000.0

    // Pop-out Graph
    @AppStorage("popoutGraphFollowsSelection") var popoutGraphFollowsSelection: Bool = true

    // Advanced
    @AppStorage("showDebugInfo") var showDebugInfo: Bool = false

    // Sidebar volume slider mode — "auto" (host on USB / user on SPDIF/I2S)
    // or "master" (drives master volume directly with a red track tint).
    // String-backed because @AppStorage doesn't support raw enums.
    @AppStorage("sidebarVolumeMode") var sidebarVolumeMode: String = "auto"

    private init() {}
}

// MARK: - Settings View
struct SettingsView: View {
    private enum Tabs: Hashable {
        case general, global, appearance, graphing, hardware, advanced
    }

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tabs.general)

            GlobalSettingsTab()
                .tabItem {
                    Label("Global", systemImage: "externaldrive")
                }
                .tag(Tabs.global)

            AppearanceSettingsTab()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(Tabs.appearance)

            GraphingSettingsTab()
                .tabItem {
                    Label("Graphing", systemImage: "waveform.path.ecg")
                }
                .tag(Tabs.graphing)

            HardwareSettingsTab()
                .tabItem {
                    Label("Hardware", systemImage: "cpu")
                }
                .tag(Tabs.hardware)

            AdvancedSettingsTab()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag(Tabs.advanced)
        }
        .frame(width: 450, height: nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel

    /// App version string, read from the bundle (CFBundleShortVersionString,
    /// driven by MARKETING_VERSION) so it stays in sync with the build settings
    /// and the standard macOS About window.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "speaker.wave.3.fill")
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DSPi Console")
                                .font(.headline)
                            Text("USB Audio DSP Controller")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Version \(Self.appVersion)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Made with love by Weeb Labs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Channel Names")
                                .font(.body)
                            Text("Reset all channel names to factory defaults")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Reset") {
                            let defaults = DSPViewModel.defaultChannelNames(for: vm.platformName)
                            DispatchQueue.global(qos: .userInitiated).async {
                                for ch in 0..<vm.numChannels {
                                    vm.setChannelName(channel: ch, name: defaults[ch])
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { vm.lgSoundSyncEnabled },
                    set: { en in
                        vm.lgSoundSyncEnabled = en
                        DispatchQueue.global(qos: .userInitiated).async {
                            vm.setLgSoundSyncEnabled(en)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable LG Sound Sync")
                            .font(.body)
                        Text("Decode the LG TV's TOSLINK volume + mute signaling and apply it as the host volume — TV remote becomes the volume control. Per-preset; saved with the active preset.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!vm.lgSoundSyncSupported)
                .padding(.vertical, 4)

                if !vm.lgSoundSyncSupported {
                    Text("Connected device firmware doesn't support LG Sound Sync. Update to firmware V8 or later.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("LG Sound Sync", systemImage: "tv")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Global Settings Tab
//
// Houses every setting that lives in the device's flash directory
// (board-level configuration that doesn't travel with presets).
// Unlike the rest of the Settings tabs, edits here are staged in a
// local draft and not pushed to the firmware until the user clicks
// Save — that way the firmware's directory sector isn't written on
// every individual picker change.
//
// Settings included:
//   • Startup Preset (mode + default slot)
//   • Master Volume persistence mode
//   • Output Configuration persistence mode (independent / with-preset)
//   • DAC Hardware Mute config (enable / polarity / pin / hold / release)
struct GlobalSettingsDraft: Equatable {
    var presetStartupMode: Int
    var presetDefaultSlot: Int
    var presetMasterVolumeMode: Int
    var presetOutputConfigMode: Int
    var dacHwMuteConfig: DacHwMuteConfig

    static func from(_ vm: DSPViewModel) -> GlobalSettingsDraft {
        GlobalSettingsDraft(
            presetStartupMode:      vm.presetStartupMode,
            presetDefaultSlot:      vm.presetDefaultSlot,
            presetMasterVolumeMode: vm.presetMasterVolumeMode,
            presetOutputConfigMode: vm.presetOutputConfigMode,
            dacHwMuteConfig:        vm.dacHwMuteConfig
        )
    }
}

struct GlobalSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel
    @State private var draft: GlobalSettingsDraft = GlobalSettingsDraft(
        presetStartupMode: 0,
        presetDefaultSlot: 0,
        presetMasterVolumeMode: MASTER_VOLUME_MODE_INDEPENDENT,
        presetOutputConfigMode: OUTPUT_CONFIG_MODE_WITH_PRESET,
        dacHwMuteConfig: DacHwMuteConfig()
    )

    private var hasChanges: Bool {
        draft != GlobalSettingsDraft.from(vm)
    }

    private func slotLabel(_ slot: Int) -> String {
        let display = slot + 1
        let name: String
        if vm.isPresetOccupied(slot) {
            let trimmed = vm.presetNames[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            name = trimmed.isEmpty ? "Preset \(slot + 1)" : trimmed
        } else {
            name = "Empty"
        }
        return "\(display): \(name)"
    }

    var body: some View {
        Form {
            // MARK: Startup Preset
            Section {
                Picker("Mode", selection: $draft.presetStartupMode) {
                    Text("Specified Default").tag(0)
                    Text("Last Used").tag(1)
                }

                if draft.presetStartupMode == 0 {
                    Picker("Default Preset", selection: $draft.presetDefaultSlot) {
                        ForEach(0..<10, id: \.self) { slot in
                            Text(slotLabel(slot)).tag(slot)
                        }
                    }
                }

                Text("Choose which preset loads when the device powers on.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Startup Preset", systemImage: "power")
            }

            // MARK: Master Volume Persistence
            Section {
                Picker("Mode", selection: $draft.presetMasterVolumeMode) {
                    Text("Independent").tag(MASTER_VOLUME_MODE_INDEPENDENT)
                    Text("With Preset").tag(MASTER_VOLUME_MODE_WITH_PRESET)
                }

                if draft.presetMasterVolumeMode == MASTER_VOLUME_MODE_INDEPENDENT {
                    Text("Master volume is stored on the device independently of presets and applied at boot. Loading a preset never changes it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Master volume is part of each preset. Saved with the preset, restored on preset load.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Master Volume", systemImage: "speaker.wave.2")
            }

            // MARK: Output Configuration Persistence
            Section {
                Picker("Mode", selection: $draft.presetOutputConfigMode) {
                    Text("Independent").tag(OUTPUT_CONFIG_MODE_INDEPENDENT)
                    Text("With Preset").tag(OUTPUT_CONFIG_MODE_WITH_PRESET)
                }

                if draft.presetOutputConfigMode == OUTPUT_CONFIG_MODE_INDEPENDENT {
                    Text("Input and output configuration is stored on the device independently and applied at boot. Loading a preset never changes your wiring.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Input and output configuration is part of each preset. Saved with the preset and restored on preset load.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Output Configuration", systemImage: "cable.connector")
            }

            // MARK: DAC Hardware Mute (only when firmware supports it)
            if vm.dacHwMuteSupported {
                Section {
                    Toggle(isOn: Binding(
                        get: { draft.dacHwMuteConfig.enabled },
                        set: { newVal in
                            draft.dacHwMuteConfig.enabled = newVal
                            // Enabling with no pin is nonsensical — auto-
                            // assign the first available GPIO so the user
                            // doesn't see an empty picker the moment they
                            // flip the switch on.
                            if newVal && draft.dacHwMuteConfig.pin == DAC_HW_MUTE_PIN_NONE {
                                if let firstFree = HardwareSettingsTab.validPins.first(where: {
                                    vm.pinInUseBy($0, excluding: .dacMute) == nil
                                }) {
                                    draft.dacHwMuteConfig.pin = firstFree
                                }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable Automatic Mute")
                                .font(.body)
                            Text("Briefly mute an external DAC or amplifier to suppress loud pops during system state changes.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if draft.dacHwMuteConfig.enabled {
                        HStack {
                            Image(systemName: "bolt.horizontal")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Polarity")
                            Spacer()
                            Picker("", selection: $draft.dacHwMuteConfig.activeLow) {
                                Text("Active Low").tag(true)
                                Text("Active High").tag(false)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        HStack {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Mute Pin")
                            Spacer()
                            Picker("", selection: $draft.dacHwMuteConfig.pin) {
                                // No "None" entry — the enable toggle is
                                // the master switch.  Filter pins through
                                // vm.pinInUseBy so claims in the Hardware
                                // tab (output pins, I2S BCK/MCK, S/PDIF RX)
                                // don't appear as free here.
                                ForEach(HardwareSettingsTab.validPins.filter {
                                    vm.pinInUseBy($0, excluding: .dacMute) == nil
                                }, id: \.self) { pin in
                                    Text("GPIO \(pin)").tag(pin)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        // Hold / release timing — same fixed-option pickers
                        // as the per-tab embed used to use, but bound to
                        // the local draft instead of immediately committing.
                        globalMsPicker(label: "Hold Time",
                                       tooltip: "Mute-attack wait before clock-stop",
                                       options: [5, 10, 20, 50, 100],
                                       binding: $draft.dacHwMuteConfig.holdMs)

                        globalMsPicker(label: "Release Time",
                                       tooltip: "Wait after un-mute before audio resumes",
                                       options: [0, 5, 10, 20, 50, 100],
                                       binding: $draft.dacHwMuteConfig.releaseMs)

                        HStack {
                            Image(systemName: "play.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Test")
                                Text("Toggle automatic mute for one second to confirm hardware configuration.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Start") {
                                DispatchQueue.global(qos: .userInitiated).async {
                                    _ = vm.testDacHwMute()
                                }
                            }
                            .disabled(vm.dacHwMuteConfig.pin == DAC_HW_MUTE_PIN_NONE
                                      || !vm.dacHwMuteConfig.enabled
                                      || hasChanges)
                            .help(hasChanges
                                  ? "Save your changes first to test the mute pin."
                                  : "Begins one-second test.")
                        }
                    }
                } header: {
                    Label("External Mute Control", systemImage: "speaker.slash")
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        // Permanent footer bar — the macOS / Primer convention for
        // explicit save flows.  Every dynamic alternative (animated
        // safeAreaInset, conditional Section, VStack with grow,
        // contentMargins, overlay-only) either reflows the Form's
        // ScrollView or fights the Settings scene's window-resize
        // policy, and the user perceives that as a jump.  A fixed
        // footer doesn't move, so nothing jumps.  The bar's STATE
        // signals dirty/clean (status label + button enabled state)
        // rather than its presence.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
        .onAppear { revert() }
        .onChange(of: vm.isDeviceConnected) { connected in
            // Re-sync from device on (re)connect so the draft reflects
            // freshly-fetched firmware values rather than stale state
            // from before the disconnect.
            if connected { revert() }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            // Status indicator — visible only when there's pending state
            // to save.  Uses opacity (not conditional rendering) so the
            // bar's intrinsic width never changes between clean / dirty
            // states.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Once saved, these settings are written directly to flash.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .opacity(hasChanges ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: hasChanges)

            Spacer()

            Button("Revert") { revert() }
                .disabled(!hasChanges)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || !vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)        // Subtle bottom-bar material matching
                                 // macOS toolbar conventions; sits flush
                                 // against the form's bottom edge.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func globalMsPicker(label: String,
                                tooltip: String,
                                options: [UInt16],
                                binding: Binding<UInt16>) -> some View {
        HStack {
            Image(systemName: "timer")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label).help(tooltip)
            Spacer()
            Picker("", selection: binding) {
                ForEach(options, id: \.self) { ms in
                    Text("\(ms) ms").tag(ms)
                }
                if !options.contains(binding.wrappedValue) {
                    Text("\(binding.wrappedValue) ms").tag(binding.wrappedValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Push every draft field whose value differs from the device's
    /// current view-model state.  Each setter publishes optimistically
    /// in addition to sending the USB transfer, so by the time the
    /// background work returns, vm == draft.
    private func save() {
        let snapshot = GlobalSettingsDraft.from(vm)
        let pendingDraft = draft
        DispatchQueue.global(qos: .userInitiated).async {
            if pendingDraft.presetStartupMode != snapshot.presetStartupMode
                || pendingDraft.presetDefaultSlot != snapshot.presetDefaultSlot {
                vm.setPresetStartup(mode: pendingDraft.presetStartupMode,
                                    defaultSlot: pendingDraft.presetDefaultSlot)
            }
            if pendingDraft.presetMasterVolumeMode != snapshot.presetMasterVolumeMode {
                vm.setMasterVolumeMode(pendingDraft.presetMasterVolumeMode)
            }
            if pendingDraft.presetOutputConfigMode != snapshot.presetOutputConfigMode {
                vm.setOutputConfigMode(pendingDraft.presetOutputConfigMode)
            }
            if pendingDraft.dacHwMuteConfig != snapshot.dacHwMuteConfig {
                vm.setDacHwMuteConfig(pendingDraft.dacHwMuteConfig)
            }
        }
    }

    private func revert() {
        draft = GlobalSettingsDraft.from(vm)
    }
}

struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showGraphGlow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Graph Line Glow")
                            .font(.body)
                        Text("Add a neon glow effect to frequency response curves")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 4)
            } header: {
                Label("Graph Appearance", systemImage: "sparkles")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct GraphingSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Line Width: \(settings.graphLineWidth, specifier: "%.1f")pt")
                            .font(.body)
                        Slider(value: $settings.graphLineWidth, in: 1.0...4.0, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Animation Speed: \(settings.graphAnimationSpeed, specifier: "%.2f")s")
                            .font(.body)
                        Slider(value: $settings.graphAnimationSpeed, in: 0.1...0.5, step: 0.05)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Response Curve", systemImage: "waveform.path")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Frequency Grid", isOn: $settings.showFrequencyGrid)
                        .toggleStyle(.switch)
                    Toggle("Show Frequency Labels", isOn: $settings.showFrequencyLabels)
                        .toggleStyle(.switch)
                    Toggle("Show dB Grid", isOn: $settings.showDBGrid)
                        .toggleStyle(.switch)
                    Toggle("Show dB Labels", isOn: $settings.showDBLabels)
                        .toggleStyle(.switch)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vertical Range: \(Int(settings.graphDBRange)) dB")
                            .font(.body)
                        Slider(value: Binding(
                            get: { settings.graphDBRange },
                            set: { settings.graphDBRange = $0.rounded() }
                        ), in: 10...100)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        let top = settings.graphDBCenter + settings.graphDBRange / 2
                        let bottom = settings.graphDBCenter - settings.graphDBRange / 2
                        Text("Center: \(Int(settings.graphDBCenter)) dB → \(String(format: "%+.0f", top)) to \(String(format: "%+.0f", bottom))")
                            .font(.body)
                        Slider(value: Binding(
                            get: { settings.graphDBCenter },
                            set: { settings.graphDBCenter = $0.rounded() }
                        ), in: -40...20)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Min Frequency")
                                .font(.body)
                            Picker("", selection: $settings.graphMinFreq) {
                                Text("10 Hz").tag(10.0)
                                Text("15 Hz").tag(15.0)
                                Text("20 Hz").tag(20.0)
                                Text("50 Hz").tag(50.0)
                                Text("100 Hz").tag(100.0)
                            }
                            .labelsHidden()
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max Frequency")
                                .font(.body)
                            Picker("", selection: $settings.graphMaxFreq) {
                                Text("5 kHz").tag(5000.0)
                                Text("10 kHz").tag(10000.0)
                                Text("20 kHz").tag(20000.0)
                            }
                            .labelsHidden()
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Scale & Grid", systemImage: "ruler")
            }

            Section {
                Toggle("Pop-out graph follows channel selection", isOn: $settings.popoutGraphFollowsSelection)
                    .toggleStyle(.switch)
            } header: {
                Label("Pop-out Window", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AdvancedSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showDebugInfo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Debug Information")
                            .font(.body)
                        Text("Display additional diagnostic data in the UI")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 4)
            } header: {
                Label("Diagnostics", systemImage: "ladybug")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Hardware Settings Tab

struct HardwareSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private struct PinOutput: Identifiable {
        let id: Int       // output index 0-4
        let name: String
        let detail: String
        let icon: String
        let defaultPin: UInt8
        let color: Color
    }

    private static let defaultDataPins: [UInt8] = [6, 7, 8, 9]

    private var mck256UnsupportedAtCurrentRate: Bool {
        vm.sampleRateHz >= 96000
    }

    private var sampleRateLabel: String {
        if vm.sampleRateHz == 0 {
            return "unknown sample rate"
        }
        return String(format: "%.1f kHz", Double(vm.sampleRateHz) / 1000.0)
    }

    private var visiblePinOutputs: [PinOutput] {
        let numSlots = vm.numOutputSlots
        let matrixOutputs = MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes)
        var outputs = (0..<numSlots).map { slot -> PinOutput in
            let isI2S = vm.outputSlotTypes[slot] == 1
            let color = matrixOutputs[slot * 2 + 1].color // R channel color
            return PinOutput(
                id: slot,
                name: "Output \(slot + 1)",
                detail: isI2S ? "I2S" : "S/PDIF",
                icon: isI2S ? "headphones" : "wave.3.right",
                defaultPin: Self.defaultDataPins[slot],
                color: color
            )
        }
        let pdmId = vm.platformName == "RP2040" ? 2 : 4
        outputs.append(PinOutput(id: pdmId, name: "Subwoofer", detail: "PDM", icon: "waveform",
                                 defaultPin: 10, color: MatrixOutput.pdmColor))
        return outputs
    }

    // RP2040 valid GPIO pins (excludes 12=UART, 23-25=system)
    static let validPins: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
        13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
        26, 27, 28
    ]

    /// Whether the connected device's hardware allows slot `slot` to be
    /// I2S given the current state of its dependency parents.  Per
    /// `runtime_output_type_switch_spec.md` §2 (STM32H723 build):
    ///   • Slot 1 = I2S requires Slot 0 = I2S (SAI1_B borrows SAI1_A clocks)
    ///   • Slot 2 = I2S requires Slot 0 = I2S (SAI4_A sync-external to SAI1)
    ///   • Slot 3 = I2S requires Slot 2 = I2S (SAI4_B borrows SAI4_A clocks)
    /// On RP firmware the four slots have no inter-slot constraint, so
    /// the I2S option is always allowed.
    private func i2sAllowedFor(slot: Int) -> Bool {
        guard vm.platformName == "STM32H723" else { return true }
        switch slot {
        case 0:    return true
        case 1, 2: return vm.outputSlotTypes[0] == 1
        case 3:    return vm.outputSlotTypes[2] == 1
        default:   return true
        }
    }

    private var isSTM32: Bool {
        vm.platformName == "STM32H723"
    }

    /// CLK_GPOUTn-capable GPIOs per master_clock_spec.md §2.2.  MCK is
    /// driven directly from one of the chip's hardware clock outputs, so
    /// only pins that map to CLK_GPOUTn are accepted by the firmware:
    ///
    ///   • RP2040 — GPIO 21 only (other GPOUTn pins 23/24/25 are board-reserved)
    ///   • RP2350 — GPIO 13, 15, 21
    ///
    /// On RP2350, GPIO 15 is `clk_gpout1` but is also the I2S LRCLK pin
    /// (BCK + 1) when any output slot is configured for I2S, so it's
    /// hidden from the picker in that case.  Choosing it would always
    /// fail the firmware's `is_pin_in_use()` check.
    private var mckValidPins: [UInt8] {
        if vm.platformName == "RP2040" {
            return [21]
        }
        // RP2350: filter out 15 when an I2S slot is active (LRCLK conflict).
        var pins: [UInt8] = [13, 15, 21]
        if vm.anySlotIsI2S {
            pins.removeAll { $0 == 15 }
        }
        return pins
    }

    /// Thin pass-through to `vm.pinInUseBy` so existing call sites in
    /// this struct keep their concise signature.  `PinConsumer` lives
    /// on the view-model so other tabs can share the same conflict
    /// matrix.
    private func pinInUseBy(_ pin: UInt8, excluding consumer: PinConsumer? = nil) -> String? {
        vm.pinInUseBy(pin, excluding: consumer)
    }


    private func setPinForOutput(_ outputIndex: Int, pin: UInt8) {
        guard vm.isDeviceConnected else {
            statusMessage = "Device not connected"
            statusIsError = true
            return
        }

        var status = vm.setOutputPin(output: outputIndex, pin: pin)

        // PDM requires disable/enable cycle if active
        let isPDM = visiblePinOutputs.first(where: { $0.id == outputIndex })?.name == "PDM"
        if status == PIN_CONFIG_OUTPUT_ACTIVE && isPDM {
            vm.setOutputEnable(output: vm.pdmOutputIndex, enabled: false)
            status = vm.setOutputPin(output: outputIndex, pin: pin)
            vm.setOutputEnable(output: vm.pdmOutputIndex, enabled: true)
        }

        let outputName = visiblePinOutputs.first(where: { $0.id == outputIndex })?.name ?? "Output \(outputIndex)"
        switch status {
        case PIN_CONFIG_SUCCESS:
            statusMessage = "\(outputName) reassigned to GPIO \(pin)"
            statusIsError = false
        case PIN_CONFIG_INVALID_PIN:
            statusMessage = "GPIO \(pin) is not available on this platform"
            statusIsError = true
            vm.fetchOutputPin(output: outputIndex)
        case PIN_CONFIG_PIN_IN_USE:
            if let owner = pinInUseBy(pin, excluding: .output(outputIndex)) {
                statusMessage = "GPIO \(pin) is already assigned to \(owner)"
            } else {
                statusMessage = "GPIO \(pin) is already in use by another output"
            }
            statusIsError = true
            vm.fetchOutputPin(output: outputIndex)
        case PIN_CONFIG_INVALID_OUTPUT:
            statusMessage = "Invalid output index"
            statusIsError = true
        case PIN_CONFIG_OUTPUT_ACTIVE:
            statusMessage = "PDM output must be disabled before changing its pin"
            statusIsError = true
            vm.fetchOutputPin(output: outputIndex)
        default:
            statusMessage = "USB communication error"
            statusIsError = true
        }
    }

    private func resetToDefaults() {
        guard vm.isDeviceConnected else {
            statusMessage = "Device not connected"
            statusIsError = true
            return
        }

        for output in visiblePinOutputs {
            var status = vm.setOutputPin(output: output.id, pin: output.defaultPin)
            // PDM may need disable/enable cycle
            if status == PIN_CONFIG_OUTPUT_ACTIVE && output.name == "PDM" {
                vm.setOutputEnable(output: vm.pdmOutputIndex, enabled: false)
                status = vm.setOutputPin(output: output.id, pin: output.defaultPin)
                vm.setOutputEnable(output: vm.pdmOutputIndex, enabled: true)
            }
            if status != PIN_CONFIG_SUCCESS {
                statusMessage = "Failed to reset \(output.name)"
                statusIsError = true
                return
            }
        }
        statusMessage = "All pins reset to defaults"
        statusIsError = false
    }

    var body: some View {
        Form {
            // MARK: Outputs
            Section {
                ForEach(visiblePinOutputs) { output in
                    HStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(output.color)
                                .frame(width: 6, height: 6)
                            Text(output.id < vm.numOutputSlots ? "OUT \(output.id * 2 + 1)/\(output.id * 2 + 2)" : "Sub")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 60, alignment: .leading)

                        if output.id < vm.numOutputSlots {
                            Picker("", selection: Binding(
                                get: { vm.outputSlotTypes[output.id] },
                                set: { newType in
                                    let slotID = output.id
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let status = vm.setOutputSlotType(slot: slotID, type: newType)
                                        // STM32 firmware silently coerces dependent
                                        // I2S slots down to S/PDIF when their parent
                                        // goes S/PDIF (per
                                        // runtime_output_type_switch_spec.md §2).
                                        // Refetch every slot so the UI reflects any
                                        // cascade.
                                        if status == PIN_CONFIG_SUCCESS && self.isSTM32 {
                                            for s in 0..<vm.numOutputSlots {
                                                vm.fetchOutputSlotType(slot: s)
                                            }
                                        }
                                        DispatchQueue.main.async {
                                            if status != PIN_CONFIG_SUCCESS {
                                                statusMessage = "Failed to change \(output.name) type"
                                                statusIsError = true
                                            } else {
                                                statusMessage = "\(output.name) set to \(newType == 1 ? "I2S" : "S/PDIF")"
                                                statusIsError = false
                                            }
                                        }
                                    }
                                }
                            )) {
                                Text("S/PDIF").tag(UInt8(0))
                                if i2sAllowedFor(slot: output.id) {
                                    Text("I2S").tag(UInt8(1))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80, alignment: .trailing)
                        } else {
                            Picker("", selection: .constant(0)) {
                                Text("PDM").tag(0)
                            }
                            .labelsHidden()
                            .frame(width: 80, alignment: .trailing)
                            .allowsHitTesting(false)
                        }

                        Spacer()

                        // GPIO pin pickers are RP-only — on STM32 the SAI
                        // peripherals drive fixed pins (PE6, PE3, PD11, PA0
                        // for slot data; PE2/5/4 for I2S clocks) so there's
                        // nothing to assign.
                        if !isSTM32 {
                            Picker("", selection: Binding(
                                get: { vm.outputPins[output.id] },
                                set: { setPinForOutput(output.id, pin: $0) }
                            )) {
                                ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .output(output.id)) == nil }, id: \.self) { pin in
                                    Text("GPIO \(pin)").tag(pin)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let message = statusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(statusIsError ? .orange : .green)
                            .font(.caption)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(statusIsError ? .orange : .secondary)
                    }
                }
            } header: {
                HStack {
                    Label(isSTM32 ? "Output Types" : "Output Assignment", systemImage: "cpu")
                    Spacer()
                    if !isSTM32 {
                        Button("Reset Pins") {
                            resetToDefaults()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(vm.isDeviceConnected ? .accentColor : .secondary.opacity(0.5))
                        .disabled(!vm.isDeviceConnected)
                    }
                }
            }

            // MARK: I2S Clock
            // BCK / MCK pin selection and MCK enable / multiplier are
            // GPIO-mux concerns specific to the RP firmware.  STM32's SAI
            // peripheral drives fixed clock pins (PE2 MCLK, PE5 BCK, PE4
            // LRCLK) — there's nothing to assign — so we hide the whole
            // section there.
            if !isSTM32 {
            Section {
                HStack {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BCK Pin")
                            .font(.body)
                        Text("LRCK: GPIO \(vm.i2sBckPin &+ 1) (BCK + 1)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { vm.i2sBckPin },
                        set: { newPin in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let status = vm.setI2SBckPin(newPin)
                                DispatchQueue.main.async {
                                    switch status {
                                    case PIN_CONFIG_SUCCESS:
                                        statusMessage = "BCK pin set to GPIO \(newPin), LRCLK = GPIO \(newPin &+ 1)"
                                        statusIsError = false
                                    case PIN_CONFIG_OUTPUT_ACTIVE:
                                        statusMessage = "All outputs must be S/PDIF before changing BCK pin"
                                        statusIsError = true
                                    case PIN_CONFIG_PIN_IN_USE:
                                        statusMessage = "GPIO \(newPin) or \(newPin &+ 1) is already in use"
                                        statusIsError = true
                                    default:
                                        statusMessage = "Failed to set BCK pin"
                                        statusIsError = true
                                    }
                                }
                            }
                        }
                    )) {
                        ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .i2sBck) == nil }, id: \.self) { pin in
                            Text("GPIO \(pin)").tag(pin)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(vm.anySlotIsI2S)
                }

                //Divider()

                Toggle(isOn: Binding(
                    get: { vm.mckEnabled },
                    set: { newVal in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let status = vm.setMckEnable(newVal)
                            DispatchQueue.main.async {
                                if status == PIN_CONFIG_SUCCESS {
                                    statusMessage = "Master clock \(newVal ? "enabled" : "disabled")"
                                    statusIsError = false
                                } else {
                                    statusMessage = "Failed to \(newVal ? "enable" : "disable") master clock"
                                    statusIsError = true
                                }
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Master Clock (MCK)")
                        Text("Clock reference for external DACs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text("MCK Pin")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { vm.mckPin },
                        set: { newPin in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let status = vm.setMckPin(newPin)
                                DispatchQueue.main.async {
                                    switch status {
                                    case PIN_CONFIG_SUCCESS:
                                        statusMessage = "MCK pin set to GPIO \(newPin)"
                                        statusIsError = false
                                    case PIN_CONFIG_OUTPUT_ACTIVE:
                                        statusMessage = "Disable MCK before changing its pin"
                                        statusIsError = true
                                    case PIN_CONFIG_PIN_IN_USE:
                                        statusMessage = "GPIO \(newPin) is already in use"
                                        statusIsError = true
                                    default:
                                        statusMessage = "Failed to set MCK pin"
                                        statusIsError = true
                                    }
                                }
                            }
                        }
                    )) {
                        ForEach(mckValidPins.filter { pinInUseBy($0, excluding: .mck) == nil }, id: \.self) { pin in
                            Text("GPIO \(pin)").tag(pin)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(vm.mckEnabled)
                }

                HStack {
                    Image(systemName: "multiply")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text("MCK Multiplier")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { vm.mckMultiplier },
                        set: { newVal in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let status = vm.setMckMultiplier(newVal)
                                DispatchQueue.main.async {
                                    if status == PIN_CONFIG_SUCCESS {
                                        statusMessage = "MCK multiplier set to \(newVal)x"
                                        statusIsError = false
                                    } else {
                                        statusMessage = "Failed to set MCK multiplier"
                                        statusIsError = true
                                    }
                                }
                            }
                        }
                    )) {
                        Text("128x").tag(128)
                        Text("256x").tag(256)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(mck256UnsupportedAtCurrentRate)
                }

                if mck256UnsupportedAtCurrentRate {
                    HStack {
                        Spacer()
                        Text("Locked to 128x at \(sampleRateLabel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Label("I2S Configuration", systemImage: "waveform.path")
            }
            }

            // MARK: S/PDIF Input
            if vm.inputSourceSupported {
                Section {
                    HStack {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("RX Pin")
                                .font(.body)
                            Text("GPIO pin for incoming S/PDIF signal")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.spdifRxPin },
                            set: { newPin in
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let status = vm.setSpdifRxPin(newPin)
                                    DispatchQueue.main.async {
                                        switch status {
                                        case PIN_CONFIG_SUCCESS:
                                            statusMessage = "S/PDIF RX pin set to GPIO \(newPin)"
                                            statusIsError = false
                                        case PIN_CONFIG_PIN_IN_USE:
                                            if let owner = pinInUseBy(newPin, excluding: .spdifRx) {
                                                statusMessage = "GPIO \(newPin) is already assigned to \(owner)"
                                            } else {
                                                statusMessage = "GPIO \(newPin) is already in use"
                                            }
                                            statusIsError = true
                                            vm.fetchSpdifRxPin()
                                        case PIN_CONFIG_INVALID_PIN:
                                            statusMessage = "GPIO \(newPin) is not available on this platform"
                                            statusIsError = true
                                            vm.fetchSpdifRxPin()
                                        default:
                                            statusMessage = "Failed to set S/PDIF RX pin"
                                            statusIsError = true
                                            vm.fetchSpdifRxPin()
                                        }
                                    }
                                }
                            }
                        )) {
                            ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .spdifRx) == nil }, id: \.self) { pin in
                                Text("GPIO \(pin)").tag(pin)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } header: {
                    Label("S/PDIF Input", systemImage: "arrow.down.to.line")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if vm.isDeviceConnected {
                for output in visiblePinOutputs {
                    vm.fetchOutputPin(output: output.id)
                }
                for slot in 0..<vm.numOutputSlots {
                    vm.fetchOutputSlotType(slot: slot)
                }
                vm.fetchI2SBckPin()
                vm.fetchMckEnable()
                vm.fetchMckPin()
                vm.fetchMckMultiplier()
                vm.fetchSampleRate()
                if vm.inputSourceSupported {
                    vm.fetchSpdifRxPin()
                }
            }
        }
    }
}

// MARK: - Matrix Mixer Window Controller
class MatrixMixerWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            let mixerView = MatrixMixerView(vm: AppState.shared.viewModel)

            let hostingView = NSHostingView(rootView: mixerView)
            hostingView.setFrameSize(hostingView.fittingSize)

            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Matrix Mixer"
            window?.contentView = hostingView
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

extension MatrixMixerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Stats Window Controller
class StatsWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    private var statsVM: StatsViewModel?
    @Published var isVisible: Bool = false

    func toggle(usb: USBDevice) {
        if isVisible {
            hide()
        } else {
            show(usb: usb)
        }
    }

    func show(usb: USBDevice) {
        if window == nil {
            statsVM = StatsViewModel(usb: usb)
            let statsView = StatsView(vm: statsVM!)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "System Statistics"
            window?.contentView = NSHostingView(rootView: statsView)
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

extension StatsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Graph Pop-Out Window Controller

class GraphWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let graphContent = GraphPopOutView(vm: vm)
                .environmentObject(self)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Filter Response"
            window?.contentView = NSHostingView(rootView: graphContent)
            window?.isReleasedWhenClosed = false
            window?.minSize = NSSize(width: 500, height: 250)
            window?.delegate = self
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        withAnimation(.easeInOut(duration: 0.25)) {
            isVisible = true
        }
    }

    func hide() {
        window?.orderOut(nil)
        withAnimation(.easeInOut(duration: 0.25)) {
            isVisible = false
        }
    }
}

extension GraphWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        withAnimation(.easeInOut(duration: 0.25)) {
            isVisible = false
        }
    }
}

struct GraphPopOutView: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var popoutVisibility: [Int: Bool] = [:]

    private func initVisibility() {
        guard popoutVisibility.isEmpty else { return }
        // Start with all master + enabled outputs visible
        var vis: [Int: Bool] = [0: true, 1: true]
        for i in 0..<9 {
            vis[i + 2] = vm.outputEnabled[i]
        }
        popoutVisibility = vis
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.popoutGraphFollowsSelection {
                BodePlotView(vm: vm, isPopOut: true)
                    .padding()
                GraphLegend(vm: vm)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                BodePlotView(vm: vm, isPopOut: true, visibilityOverride: $popoutVisibility)
                    .padding()
                GraphLegend(vm: vm, visibilityOverride: $popoutVisibility)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { initVisibility() }
    }
}

// MARK: - File Menu Actions
struct FileMenuActions {
    static func importFilters() {
        let panel = NSOpenPanel()
        panel.title = "Import Filters"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)

            if contents.hasPrefix("# DSPi Console") {
                // DSPi Console format - parse and show multi-channel picker
                if let channelFilters = parseDSPiFile(contents) {
                    showMultiChannelPicker(channelFilters: channelFilters)
                } else {
                    showError("Failed to parse DSPi Console filter file")
                }
            } else {
                // REW format - parse and show single-channel picker
                if let filters = parseREWFile(contents) {
                    if filters.isEmpty {
                        showError("No valid filters found in file")
                    } else {
                        showSingleChannelPicker(filters: filters)
                    }
                } else {
                    showError("Failed to parse filter file")
                }
            }
        } catch {
            showError("Failed to read file: \(error.localizedDescription)")
        }
    }

    static func exportFilters() {
        let panel = NSSavePanel()
        panel.title = "Export Filters"
        panel.nameFieldStringValue = "DSPi Filters.txt"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let output = generateExportString()

        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            showSuccess("Filters exported successfully")
        } catch {
            showError("Failed to write file: \(error.localizedDescription)")
        }
    }

    /// Persist the device's current live master volume to its independent
    /// (mode 0) storage, so the value survives a reboot. Action runs on a
    /// background queue because the underlying USB control transfer is
    /// synchronous and we don't want to stall the menu / main thread.
    static func saveMasterVolume() {
        let vm = AppState.shared.viewModel
        guard vm.isDeviceConnected else {
            showError("No device connected.")
            return
        }
        let savedDB = vm.masterVolumeDB
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = vm.saveMasterVolume()
            DispatchQueue.main.async {
                if ok {
                    let display = savedDB <= -128 ? "−∞ dB (mute)" : String(format: "%.1f dB", savedDB)
                    showSuccess("Master volume saved (\(display)). It will be applied on next boot.")
                } else {
                    showError("Failed to save master volume — the device did not acknowledge the request.")
                }
            }
        }
    }

    /// Persist the device's current live output configuration (output pins,
    /// output types, I2S clocks, S/PDIF RX pin) to its independent (directory)
    /// storage so it survives a reboot. Relevant in INDEPENDENT mode, where
    /// per-field edits apply live but only persist after an explicit save.
    /// Runs on a background queue because the underlying USB control transfer
    /// is synchronous.
    static func saveOutputConfig() {
        let vm = AppState.shared.viewModel
        guard vm.isDeviceConnected else {
            showError("No device connected.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = vm.saveOutputConfig()
            DispatchQueue.main.async {
                if ok {
                    showSuccess("Output configuration saved. It will be applied on next boot.")
                } else {
                    showError("Failed to save output configuration — the device did not acknowledge the request.")
                }
            }
        }
    }

    // MARK: - Parsing

    private static func parseREWFile(_ contents: String) -> [FilterParams]? {
        var filters: [FilterParams] = []

        for line in contents.components(separatedBy: .newlines) {
            // Match lines like: "Filter  1: ON  PK       Fc    63.0 Hz  Gain  -5.0 dB  Q  4.00"
            guard line.contains("Filter") && line.contains(":") else { continue }

            let enabled = line.uppercased().contains(" ON ")
            if !enabled { continue }

            // Extract filter type
            var filterType: FilterType = .flat
            let upperLine = line.uppercased()
            if upperLine.contains(" PK ") || upperLine.contains(" PEQ ") {
                filterType = .peaking
            } else if upperLine.contains(" LP ") || upperLine.contains(" LPQ ") {
                filterType = .lowPass
            } else if upperLine.contains(" HP ") || upperLine.contains(" HPQ ") {
                filterType = .highPass
            } else if upperLine.contains(" LS ") || upperLine.contains(" LSC ") {
                filterType = .lowShelf
            } else if upperLine.contains(" HS ") || upperLine.contains(" HSC ") {
                filterType = .highShelf
            } else {
                continue // Unknown filter type, skip
            }

            // Extract frequency (Fc XXX Hz)
            var freq: Float = 1000.0
            if let fcRange = line.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = line[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Float(freqStr) {
                    freq = freqVal
                }
            }

            // Extract gain (Gain XXX dB) - optional
            var gain: Float = 0.0
            if let gainRange = line.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = line[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Float(gainStr) {
                    gain = gainVal
                }
            }

            // Extract Q (Q XXX) - optional
            var q: Float = 0.707
            // Look for " Q " followed by a number (not "EQ" or other Q-containing words)
            let qPattern = try? NSRegularExpression(pattern: "\\sQ\\s+([\\d.]+)", options: .caseInsensitive)
            if let match = qPattern?.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let qRange = Range(match.range(at: 1), in: line),
               let qVal = Float(line[qRange]) {
                q = qVal
            }

            let params = FilterParams(type: filterType, freq: freq, q: q, gain: gain)
            filters.append(params)
        }

        return filters
    }

    struct ParsedChannelData {
        var filters: [FilterParams]
        var enableState: Bool? // nil = no state info (master or legacy format)
    }

    private static func parseDSPiFile(_ contents: String) -> [Int: ParsedChannelData]? {
        var result: [Int: ParsedChannelData] = [:]
        var currentChannel: Int? = nil

        // Regex for new output header content: Output N: Name (Enabled) or Output N: Name (Disabled)
        let outputPattern = try? NSRegularExpression(pattern: "^Output\\s+(\\d+):.+\\((Enabled|Disabled)\\)$")

        for line in contents.components(separatedBy: .newlines) {
            // Check for channel header [...]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let headerContent = String(line.dropFirst().dropLast())

                // New format: [USB L] / [USB R]
                if headerContent == "USB L" {
                    currentChannel = 0
                    result[0] = ParsedChannelData(filters: [], enableState: nil)
                } else if headerContent == "USB R" {
                    currentChannel = 1
                    result[1] = ParsedChannelData(filters: [], enableState: nil)
                }
                // New format: [Output N: Name (Enabled/Disabled)]
                else if let match = outputPattern?.firstMatch(in: headerContent, options: [], range: NSRange(headerContent.startIndex..., in: headerContent)),
                        let idxRange = Range(match.range(at: 1), in: headerContent),
                        let stateRange = Range(match.range(at: 2), in: headerContent),
                        let outputIdx = Int(headerContent[idxRange]),
                        outputIdx >= 0 && outputIdx <= 8 {
                    let eqCh = outputIdx + 2
                    let enabled = headerContent[stateRange] == "Enabled"
                    currentChannel = eqCh
                    result[eqCh] = ParsedChannelData(filters: [], enableState: enabled)
                }
                // Backward compat: old channel names
                else if headerContent == "Out L" {
                    currentChannel = 2
                    result[2] = ParsedChannelData(filters: [], enableState: nil)
                } else if headerContent == "Out R" {
                    currentChannel = 3
                    result[3] = ParsedChannelData(filters: [], enableState: nil)
                } else if headerContent == "Sub" {
                    currentChannel = 4
                    result[4] = ParsedChannelData(filters: [], enableState: nil)
                }
                continue
            }

            // Parse filter line
            guard let channel = currentChannel,
                  line.contains("Filter") && line.contains(":") else { continue }

            // Check if filter is disabled (OFF or just no type)
            if line.uppercased().contains(" OFF") || (!line.uppercased().contains(" ON ")) {
                // Add a flat filter placeholder
                result[channel]?.filters.append(FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
                continue
            }

            // Parse same as REW format
            var filterType: FilterType = .flat
            let upperLine = line.uppercased()
            if upperLine.contains(" PK ") || upperLine.contains(" PEQ ") {
                filterType = .peaking
            } else if upperLine.contains(" LP ") || upperLine.contains(" LPQ ") {
                filterType = .lowPass
            } else if upperLine.contains(" HP ") || upperLine.contains(" HPQ ") {
                filterType = .highPass
            } else if upperLine.contains(" LS ") || upperLine.contains(" LSC ") {
                filterType = .lowShelf
            } else if upperLine.contains(" HS ") || upperLine.contains(" HSC ") {
                filterType = .highShelf
            }

            var freq: Float = 1000.0
            if let fcRange = line.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = line[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Float(freqStr) {
                    freq = freqVal
                }
            }

            var gain: Float = 0.0
            if let gainRange = line.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = line[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Float(gainStr) {
                    gain = gainVal
                }
            }

            var q: Float = 0.707
            let qPattern = try? NSRegularExpression(pattern: "\\sQ\\s+([\\d.]+)", options: .caseInsensitive)
            if let match = qPattern?.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let qRange = Range(match.range(at: 1), in: line),
               let qVal = Float(line[qRange]) {
                q = qVal
            }

            result[channel]?.filters.append(FilterParams(type: filterType, freq: freq, q: q, gain: gain))
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Export

    private static func generateExportString() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var output = "# DSPi Console Filter Settings\n"
        output += "# Exported: \(dateFormatter.string(from: Date()))\n\n"

        let vm = AppState.shared.viewModel

        // Master channels (EQ 0, 1)
        for eqCh in 0...1 {
            let name = vm.channelNames[eqCh]
            output += "[\(name)]\n"
            let filters = vm.channelData[eqCh] ?? []
            for (i, filter) in filters.enumerated() {
                output += formatFilter(index: i + 1, filter: filter)
            }
            output += "\n"
        }

        // Output channels (platform-aware)
        for outputIdx in 0..<vm.numOutputChannels {
            let eqCh = outputIdx + 2
            let name = vm.channelNames[outputIdx + 2]
            let state = vm.outputEnabled[outputIdx] ? "Enabled" : "Disabled"
            output += "[Output \(outputIdx): \(name) (\(state))]\n"
            let filters = vm.channelData[eqCh] ?? []
            for (i, filter) in filters.enumerated() {
                output += formatFilter(index: i + 1, filter: filter)
            }
            output += "\n"
        }

        return output
    }

    private static func formatFilter(index: Int, filter: FilterParams) -> String {
        let typeCode: String
        switch filter.type {
        case .flat: return String(format: "Filter %2d: OFF\n", index)
        case .peaking: typeCode = "PK"
        case .lowPass: typeCode = "LP"
        case .highPass: typeCode = "HP"
        case .lowShelf: typeCode = "LS"
        case .highShelf: typeCode = "HS"
        case .notch: typeCode = "NO"
        case .allPass: typeCode = "AP"
        }

        let paddedType = typeCode.padding(toLength: 8, withPad: " ", startingAt: 0)
        var line = String(format: "Filter %2d: ON  %@Fc %7.1f Hz", index, paddedType, filter.freq)

        // Add gain for types that use it
        if filter.type == .peaking || filter.type == .lowShelf || filter.type == .highShelf {
            line += String(format: "  Gain %+5.1f dB", filter.gain)
        }

        // Add Q for peaking and allpass filters
        if filter.type == .peaking || filter.type == .allPass {
            line += String(format: "  Q %5.2f", filter.q)
        }

        return line + "\n"
    }

    // MARK: - Dialogs

    private static func showSingleChannelPicker(filters: [FilterParams]) {
        let alert = NSAlert()
        alert.messageText = "Import Filters"
        alert.informativeText = "Found \(filters.count) filter(s). Select which channel(s) to apply them to:"
        alert.alertStyle = .informational

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        let vm = AppState.shared.viewModel
        var checkboxes: [NSButton] = []

        // Master channels (checked by default)
        for eqCh in [0, 1] {
            let checkbox = NSButton(checkboxWithTitle: vm.channelNames[eqCh], target: nil, action: nil)
            checkbox.tag = eqCh
            checkbox.state = .on
            checkboxes.append(checkbox)
            accessory.addArrangedSubview(checkbox)
        }

        // Enabled output channels (unchecked by default)
        for outputIdx in 0..<vm.numOutputChannels where vm.outputEnabled[outputIdx] {
            let checkbox = NSButton(checkboxWithTitle: vm.channelNames[outputIdx + 2], target: nil, action: nil)
            checkbox.tag = outputIdx + 2
            checkbox.state = .off
            checkboxes.append(checkbox)
            accessory.addArrangedSubview(checkbox)
        }

        accessory.setFrameSize(NSSize(width: 200, height: CGFloat(checkboxes.count * 24)))
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            var importedCount = 0
            for checkbox in checkboxes where checkbox.state == .on {
                applyFilters(filters, to: checkbox.tag)
                importedCount += 1
            }
            if importedCount > 0 {
                showSuccess("Filters imported to \(importedCount) channel(s)")
            }
        }
    }

    private static func showMultiChannelPicker(channelFilters: [Int: ParsedChannelData]) {
        let alert = NSAlert()
        alert.messageText = "Import Filters"
        alert.informativeText = "This file contains filter settings for multiple channels. Select which channels to import:"
        alert.alertStyle = .informational

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        let vm = AppState.shared.viewModel
        var checkboxes: [NSButton] = []

        // Show channels in order: master 0,1 then outputs
        let maxEqCh = vm.numOutputChannels + 1  // output indices 0..<N map to EQ channels 2..<N+2
        for eqCh in 0...maxEqCh {
            guard channelFilters[eqCh] != nil else { continue }
            let name = vm.channelNames[eqCh]

            let checkbox = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            checkbox.tag = eqCh
            checkbox.state = .on
            checkboxes.append(checkbox)
            accessory.addArrangedSubview(checkbox)
        }

        accessory.setFrameSize(NSSize(width: 200, height: CGFloat(checkboxes.count * 24)))
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            for checkbox in checkboxes where checkbox.state == .on {
                let eqCh = checkbox.tag
                if let data = channelFilters[eqCh] {
                    applyFilters(data.filters, to: eqCh)
                    // Restore enable/disable state for output channels
                    if eqCh >= 2, let enabled = data.enableState {
                        vm.setOutputEnable(output: eqCh - 2, enabled: enabled)
                    }
                }
            }
            showSuccess("Filters imported successfully")
        }
    }

    private static func applyFilters(_ filters: [FilterParams], to channelIndex: Int) {
        let vm = AppState.shared.viewModel
        let bandCount = 10

        for (i, filter) in filters.prefix(bandCount).enumerated() {
            vm.setFilter(ch: channelIndex, band: i, p: filter)
        }

        // Clear remaining bands if imported fewer filters
        for i in filters.count..<bandCount {
            vm.setFilter(ch: channelIndex, band: i, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
        }
    }

    // MARK: - Alerts

    private static func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Tools Menu Actions
struct ToolsMenuActions {
    static func commitParameters() {
        let vm = AppState.shared.viewModel
        guard vm.isDeviceConnected else {
            showError("Not connected to device")
            return
        }

        let slot = vm.activePresetSlot
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Save current parameters to preset slot \(slot + 1)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let result = vm.savePreset(slot: slot)
            switch result {
            case PRESET_OK:
                showSuccess("Preset saved successfully")
            default:
                showError("Failed to save preset (error \(result))")
            }
        }
    }

    static func revertToSaved() {
        let alert = NSAlert()
        alert.messageText = "Revert to Saved"
        alert.informativeText = "Revert to last saved parameters?\n\nCurrent unsaved changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let vm = AppState.shared.viewModel
            guard vm.isDeviceConnected else {
                showError("Not connected to device")
                return
            }
            let result = vm.loadParams()
            switch result {
            case FLASH_OK:
                showSuccess("Parameters reverted successfully")
            case FLASH_ERR_NO_DATA:
                showInfo("No saved parameters found.\n\nThe device is using factory defaults.")
            case FLASH_ERR_CRC:
                showError("Saved data is corrupted")
            default:
                showError("Failed to load parameters")
            }
        }
    }

    static func factoryReset() {
        let alert = NSAlert()
        alert.messageText = "Factory Reset"
        alert.informativeText = "Do you wish to clear all active parameters?\n\nThis will not overwrite your saved parameters unless you run 'Commit Parameters'."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let vm = AppState.shared.viewModel
            guard vm.isDeviceConnected else {
                showError("Not connected to device")
                return
            }
            let result = vm.factoryReset()
            switch result {
            case FLASH_OK:
                showSuccess("Factory reset complete")
            default:
                showError("Failed to reset parameters")
            }
        }
    }

    static func enterFirmwareUpdateMode() {
        let skipConfirmation = NSEvent.modifierFlags.contains(.option)

        if !skipConfirmation {
            let alert = NSAlert()
            alert.messageText = "Firmware Update"
            alert.informativeText = "This will reboot the device into bootloader mode.\n\nAudio output will stop immediately. The device will appear as a USB drive to which you can drag a .uf2 firmware file."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Reboot into Bootloader")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let usb = AppState.shared.usb
        guard usb.isConnected else {
            showError("Not connected to device")
            return
        }
        // Device disconnects after this command — ignore nil response
        _ = usb.getControlRequest(request: REQ_ENTER_BOOTLOADER, value: 0, index: 2, length: 1)
    }

    private static func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Information"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - AutoEQ Menu Actions
struct AutoEQMenuActions {
    static var rebuildWindowController: AutoEQRebuildWindowController?

    static func updateDatabase() {
        let manager = AutoEQManager.shared

        let alert = NSAlert()
        alert.messageText = "Update AutoEQ Database"
        alert.informativeText = "Current database: \(manager.databaseDate ?? "Unknown")\nEntries: \(manager.entries.count)\n\nChoose an update method:"
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Rebuild from GitHub")
        alert.addButton(withTitle: "Import File...")
        if manager.hasUserDatabase {
            alert.addButton(withTitle: "Reset to Built-in")
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Rebuild from GitHub
            showRebuildConfirmation()
        case .alertSecondButtonReturn:
            // Import File
            importDatabase()
        case .alertThirdButtonReturn where manager.hasUserDatabase:
            // Reset to Built-in
            do {
                try manager.resetToBuiltInDatabase()
                showSuccess("Reset to built-in database.\nEntries: \(manager.entries.count)")
            } catch {
                showError("Failed to reset: \(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private static func showRebuildConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Rebuild AutoEQ Database"
        alert.informativeText = "You are about to rebuild the AutoEQ database by downloading all profiles from GitHub.\n\nThis requires an internet connection and may take several minutes.\n\nDo you wish to proceed?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            startRebuild()
        }
    }

    private static func startRebuild() {
        rebuildWindowController = AutoEQRebuildWindowController()
        rebuildWindowController?.show()

        Task {
            do {
                try await AutoEQManager.shared.rebuildDatabase()
                await MainActor.run {
                    // Keep window open briefly to show completion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        rebuildWindowController?.close()
                        rebuildWindowController = nil
                        showSuccess("Database rebuilt successfully!\nEntries: \(AutoEQManager.shared.entries.count)")
                    }
                }
            } catch {
                await MainActor.run {
                    rebuildWindowController?.close()
                    rebuildWindowController = nil
                    showError("Rebuild failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func importDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ Database"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select an autoeq_database.json file."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AutoEQManager.shared.updateDatabaseFromFile(url)
            showSuccess("Database updated successfully.\nEntries: \(AutoEQManager.shared.entries.count)")
        } catch {
            showError("Failed to import database: \(error.localizedDescription)")
        }
    }

    private static func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - AutoEQ Rebuild Progress Window

struct AutoEQRebuildProgressView: View {
    @ObservedObject var manager = AutoEQManager.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Rebuilding AutoEQ Database")
                .font(.headline)

            ProgressView(value: manager.rebuildProgress)
                .progressViewStyle(.linear)
                .frame(width: 280)

            Text(manager.rebuildStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(height: 20)

            if manager.rebuildProgress >= 1.0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
            }
        }
        .padding(30)
        .frame(width: 340)
    }
}

class AutoEQRebuildWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        let progressView = AutoEQRebuildProgressView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window?.title = "Updating Database"
        window?.contentView = NSHostingView(rootView: progressView)
        window?.isReleasedWhenClosed = false
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Quit Interception

class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowObserver: Any?
    private weak var originalWindowDelegate: NSWindowDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Find the main window once it appears and set ourselves as its delegate
        // so we can intercept the close button with windowShouldClose.
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let window = note.object as? NSWindow,
                  window.title == "DSPi Console" else { return }
            self.originalWindowDelegate = window.delegate
            window.delegate = self
            if let obs = self.mainWindowObserver {
                NotificationCenter.default.removeObserver(obs)
                self.mainWindowObserver = nil
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let vm = AppState.shared.viewModel
        guard vm.isDeviceConnected, vm.hasUnsavedChanges else { return .terminateNow }

        let diff = vm.computeDiff()
        let action = PresetAlerts.showUnsavedChangesAlert(diff: diff)
        switch action {
        case .save:
            DispatchQueue.global(qos: .userInitiated).async {
                if vm.presetNames[vm.activePresetSlot].isEmpty {
                    vm.setPresetName(slot: vm.activePresetSlot, name: "Preset \(vm.activePresetSlot + 1)")
                }
                let status = vm.savePreset(slot: vm.activePresetSlot)
                DispatchQueue.main.async {
                    if status == PRESET_OK {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Save Failed"
                        alert.informativeText = "Failed to save preset (error \(status)). Quit anyway?"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Quit")
                        alert.addButton(withTitle: "Cancel")
                        let quit = alert.runModal() == .alertFirstButtonReturn
                        NSApp.reply(toApplicationShouldTerminate: quit)
                    }
                }
            }
            return .terminateLater
        case .discard:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Route window close through app termination so the unsaved changes
        // prompt can prevent the close. NSApp.terminate triggers
        // applicationShouldTerminate, which handles Save/Discard/Cancel.
        // If the user cancels, terminateCancel keeps the window open.
        NSApp.terminate(nil)
        return false
    }

    // Forward all other delegate methods to SwiftUI's original window delegate
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalWindowDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let delegate = originalWindowDelegate, delegate.responds(to: aSelector) {
            return delegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

// MARK: - App
@main
struct DSPi_ConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var statsWindowController = StatsWindowController()
    @StateObject private var loudnessWindowController = LoudnessWindowController()
    @StateObject private var crossfeedWindowController = CrossfeedWindowController()
    @StateObject private var levellerWindowController = VolumeLevellerWindowController()
    @StateObject private var autoEQBrowserController = AutoEQBrowserController()
    @StateObject private var matrixMixerWindowController = MatrixMixerWindowController()
    @StateObject private var graphWindowController = GraphWindowController()
    @StateObject private var interruptMonitorWindowController = InterruptMonitorWindowController()
    @ObservedObject private var vm = AppState.shared.viewModel

    var body: some Scene {
        Window("DSPi Console", id: "main") {
            ContentView(vm: AppState.shared.viewModel)
                .environmentObject(matrixMixerWindowController)
                .environmentObject(loudnessWindowController)
                .environmentObject(crossfeedWindowController)
                .environmentObject(levellerWindowController)
                .environmentObject(statsWindowController)
                .environmentObject(graphWindowController)
                .environmentObject(interruptMonitorWindowController)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Customize the standard "About DSPi Console" window. The panel
            // renders the bundle's name + version (CFBundleShortVersionString =
            // MARKETING_VERSION) automatically; we supply the credits string so
            // it shows our sign-off.
            CommandGroup(replacing: .appInfo) {
                Button("About DSPi Console") {
                    let credits = NSAttributedString(
                        string: "Made with love by Weeb Labs",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: {
                                let style = NSMutableParagraphStyle()
                                style.alignment = .center
                                return style
                            }()
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: credits
                    ])
                }
            }

            // Add to native File menu
            CommandGroup(after: .newItem) {
                Divider()

                Button("Import Filters...") {
                    FileMenuActions.importFilters()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Export Filters...") {
                    FileMenuActions.exportFilters()
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                Button("Save Master Volume") {
                    FileMenuActions.saveMasterVolume()
                }

                Button("Save Output Configuration") {
                    FileMenuActions.saveOutputConfig()
                }
            }

            // AutoEQ Menu
            CommandMenu("AutoEQ") {
                Button("Browse Profiles...") {
                    autoEQBrowserController.show()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Menu("Favorite Profiles") {
                    ForEach(AutoEQManager.shared.favoriteProfiles) { entry in
                        Button("\(entry.manufacturer) \(entry.model)") {
                            AutoEQManager.shared.applyProfile(entry)
                        }
                    }

                    if AutoEQManager.shared.favoriteProfiles.isEmpty {
                        Text("No favorites yet")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Button("Clear Favorites") {
                        AutoEQManager.shared.clearFavorites()
                    }
                    .disabled(AutoEQManager.shared.favoriteProfiles.isEmpty)
                }

                Divider()

                Button("Update Database...") {
                    AutoEQMenuActions.updateDatabase()
                }
            }

            // Tools Menu
            CommandMenu("Tools") {
                Button("Commit Parameters...") {
                    ToolsMenuActions.commitParameters()
                }

                Button("Revert to Saved...") {
                    ToolsMenuActions.revertToSaved()
                }

                Button("Factory Reset...") {
                    ToolsMenuActions.factoryReset()
                }

                // STM32H723 firmware cannot self-reboot into a USB bootloader
                // — there's no UF2 path on that platform, so hide the entry
                // entirely rather than show a non-functional menu item.
                if vm.platformName != "STM32H723" {
                    Divider()

                    Button("Firmware Update...") {
                        ToolsMenuActions.enterFirmwareUpdateMode()
                    }
                }

                Divider()

                Button("Matrix Mixer...") {
                    matrixMixerWindowController.toggle()
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])

                Button("Loudness Compensation...") {
                    loudnessWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])

                Button("Headphone Crossfeed...") {
                    crossfeedWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("X", modifiers: [.command, .shift])

                Button("Volume Leveller...") {
                    levellerWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])

                Button("Stats for nerbs") {
                    // specific method depends on your controller's API (e.g., show, open)
                    statsWindowController.show(usb: AppState.shared.usb)
                }
                .keyboardShortcut("T", modifiers: [.command, .shift])

                Divider()

                Button("Interrupt Monitor...") {
                    interruptMonitorWindowController.show()
                }
                .keyboardShortcut("I", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
