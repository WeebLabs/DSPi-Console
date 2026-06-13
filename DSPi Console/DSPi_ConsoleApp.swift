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
    @AppStorage("showPhase") var showPhase: Bool = false
    @AppStorage("phaseUnwrapped") var phaseUnwrapped: Bool = false

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

/// One selectable page in the Settings sidebar. Carries its own title, SF
/// Symbol, and tint so the sidebar row and the detail navigation title stay in
/// sync from a single source of truth.
private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general, graphing, advanced
    case globalParams, outputAssignment, i2sConfig, spdifInput

    var id: Self { self }

    var title: String {
        switch self {
        case .general:          return "About"
        case .graphing:         return "Graphing"
        case .advanced:         return "Advanced"
        case .globalParams:     return "Global Parameters"
        case .outputAssignment: return "Outputs"
        case .i2sConfig:        return "I2S Configuration"
        case .spdifInput:       return "Inputs"
        }
    }

    var icon: String {
        switch self {
        case .general:          return "gear"
        case .graphing:         return "waveform.path.ecg"
        case .advanced:         return "gearshape.2"
        case .globalParams:     return "externaldrive"
        case .outputAssignment: return "cable.connector"
        case .i2sConfig:        return "waveform.path"
        case .spdifInput:       return "arrow.down.to.line"
        }
    }

    /// Icon-badge tint. A single cohesive cool palette (slate → teal → cyan →
    /// blue → indigo) — distinct shades per page, but no warm colors, so the
    /// sidebar reads as one harmonious theme.
    var tint: Color {
        switch self {
        case .general:          return Color(red: 0.46, green: 0.53, blue: 0.62)  // slate
        case .advanced:         return Color(red: 0.38, green: 0.47, blue: 0.60)  // steel blue-gray
        case .graphing:         return Color(red: 0.20, green: 0.62, blue: 0.74)  // cyan
        case .globalParams:     return Color(red: 0.21, green: 0.49, blue: 0.82)  // blue
        case .outputAssignment: return Color(red: 0.34, green: 0.37, blue: 0.80)  // indigo
        case .i2sConfig:        return Color(red: 0.16, green: 0.41, blue: 0.74)  // ocean blue
        case .spdifInput:       return Color(red: 0.15, green: 0.49, blue: 0.62)  // deep teal
        }
    }

    /// Some hardware pages only apply to certain platforms/firmware. A page
    /// that isn't applicable is hidden from the sidebar entirely.
    func isAvailable(_ vm: DSPViewModel) -> Bool {
        switch self {
        case .i2sConfig:    return vm.platformName != "STM32H723"
        case .spdifInput:   return vm.inputSourceSupported
        default:            return true
        }
    }

    /// Non-collapsible sidebar groups, in display order.
    static let groups: [(title: String, items: [SettingsCategory])] = [
        ("Application", [.general, .advanced]),
        ("Display",     [.graphing]),
        ("System",      [.spdifInput, .outputAssignment, .i2sConfig, .globalParams]),
    ]
}

/// A rounded, tinted icon badge with a white SF Symbol — the System-Settings
/// sidebar glyph.
private struct SettingsBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 15, height: 15)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.35), radius: 1, y: 0.5)
    }
}

/// Reaches the hosting `NSWindow` to compact its title bar and drop the title
/// text. SwiftUI's `.windowToolbarStyle` scene modifier is ignored by the
/// `Settings` scene, so we set `toolbarStyle` on the window directly.
///
/// Configuration happens in `viewDidMoveToWindow` — i.e. synchronously, before
/// the window's first paint — rather than an async dispatch from
/// `updateNSView`, which would run after the window is already on screen in its
/// default `.expanded` style and produce a visible "tall title bar" flash.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguratorView)?.applyConfig()
    }

    private final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfig()
        }

        func applyConfig() {
            guard let window = window else { return }
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden   // no "DSPi Console Settings" text
            // Fully transparent title bar (paired with a hidden toolbar
            // background in SwiftUI). A scroll-driven material overlay supplies
            // the blur once content scrolls under the bar, so at rest the bar is
            // transparent - the macOS Settings behavior.
            window.titlebarAppearsTransparent = true
        }
    }
}

/// Cross-page navigation signal for Settings — lets one page deep-link to a
/// specific control on another (e.g. the persistence notice jumping to the
/// Output Configuration option on the Global Parameters page).
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    /// Set to the `.id` of the control to scroll to once its page appears.
    @Published var scrollTarget: String?
    private init() {}
}

struct SettingsView: View {
    @ObservedObject private var vm = AppState.shared.viewModel
    @ObservedObject private var saveCoordinator = SettingsSaveCoordinator.shared
    /// Persisted so the window reopens on the page you left it on.
    @AppStorage("settingsSelectedTab") private var selection: SettingsCategory = .general

    // Visited-page history powering the toolbar's back/forward buttons, à la
    // macOS System Settings. `selection` remains the source of truth for what's
    // shown; this just records the trail through it.
    @State private var history: [SettingsCategory] = []
    @State private var historyIndex = 0
    /// Set while back/forward is driving `selection` so the resulting change
    /// isn't recorded as a brand-new history entry (which would defeat forward).
    @State private var navigatingViaHistory = false

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsCategory.groups, id: \.title) { group in
                    let items = group.items.filter { $0.isAvailable(vm) }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { category in
                                HStack(spacing: 6) {
                                    SettingsBadge(systemImage: category.icon, tint: category.tint)
                                    Text(category.title)
                                }
                                .tag(category)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
            // Must be on the sidebar content (not the split view) to take effect.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailContent
                // Shared save bar - appears on whatever page you're on while
                // there are pending changes (global draft and/or live
                // output-config edits not yet flashed).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if saveCoordinator.hasPendingChanges {
                        SettingsSaveBar()
                            .transition(.move(edge: .bottom))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: saveCoordinator.hasPendingChanges)
                // Size the detail COLUMN (not just its content). NavigationSplitView's
                // detail column has a large default minimum width; `.frame` only
                // shrinks the content inside it, leaving the column — and thus the
                // window — wide. This is what actually narrows the window.
                .navigationSplitViewColumnWidth(450)
                // Empty title suppresses the window's default "DSPi Console Settings"
                // text. The page name is shown by our custom toolbar item below.
                .navigationTitle("")
                // Back/forward + current page name, integrated into the title bar
                // like macOS System Settings.
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: goBack) {
                            Image(systemName: "chevron.backward")
                        }
                        .disabled(!canGoBack)
                        .help("Back")

                        Button(action: goForward) {
                            Image(systemName: "chevron.forward")
                        }
                        .disabled(!canGoForward)
                        .help("Forward")

                        Text(selection.title)
                            .font(.headline)
                    }
                }
                // Hide the toolbar's own material so the title-bar area shows the
                // detail content background - fully integrated, like macOS Settings.
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: 480, idealHeight: 580)
        // The `Settings` scene ignores `.windowToolbarStyle`, so set the
        // NSWindow's toolbar style directly: `.expanded` (the default) stacks
        // the title bar above the toolbar, doubling its height; `.unifiedCompact`
        // collapses them into one short row.
        .background(SettingsWindowConfigurator())
        .onAppear {
            ensureSelectionAvailable()
            if history.isEmpty {
                history = [selection]
                historyIndex = 0
            }
        }
        // Keep the selection valid as devices come and go — a page that the
        // current hardware doesn't support disappears from the sidebar, so
        // fall back to General rather than leaving a blank detail pane.
        .onChange(of: vm.isDeviceConnected) { _ in ensureSelectionAvailable() }
        .onChange(of: selection) { newValue in
            if navigatingViaHistory {
                navigatingViaHistory = false
                return
            }
            // A fresh navigation: drop any forward entries, then append.
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)...)
            }
            history.append(newValue)
            historyIndex = history.count - 1
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigatingViaHistory = true
        selection = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigatingViaHistory = true
        selection = history[historyIndex]
    }

    private func ensureSelectionAvailable() {
        if !selection.isAvailable(vm) { selection = .general }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .general:          GeneralSettingsTab()
        case .graphing:         GraphingSettingsTab()
        case .advanced:         AdvancedSettingsTab()
        case .globalParams:     GlobalSettingsTab()
        case .outputAssignment: HardwareSettingsTab(section: .outputs)
        case .i2sConfig:        HardwareSettingsTab(section: .i2s)
        case .spdifInput:       HardwareSettingsTab(section: .spdif)
        }
    }
}

struct GeneralSettingsTab: View {
    /// App version string, read from the bundle (CFBundleShortVersionString,
    /// driven by MARKETING_VERSION) so it stays in sync with the build settings
    /// and the standard macOS About window.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// A support/social link with a brand-colored icon in a fixed-width slot
    /// (so all the labels line up) and normal light-gray label text.
    @ViewBuilder
    private func supportLink(_ title: String, _ url: String, icon: String, color: Color) -> some View {
        Link(destination: URL(string: url)!) {
            Label {
                Text(title)
                    // Explicit gray, not `.secondary` (which inherits the link's
                    // blue tint and renders faint blue).
                    .foregroundStyle(Color(white: 0.72))
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24, alignment: .center)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
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
                .padding(.vertical, 8)
            }

            Section {
                Text("DSPi Firmware and Console are free, open-source software that I develop in my spare time. Contributions of any kind - code, feedback, funding, or otherwise - are always immensely appreciated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                supportLink("YouTube", "https://youtube.com/weeblabs",
                            icon: "play.rectangle.fill", color: .red)
                supportLink("GitHub", "https://github.com/weeblabs",
                            icon: "chevron.left.forwardslash.chevron.right", color: Color(white: 0.72))
                supportLink("Discord", "https://discord.gg/RCyqxAQ5xS",
                            icon: "bubble.left.and.bubble.right.fill", color: Color(red: 0.345, green: 0.396, blue: 0.949))
                supportLink("Patreon", "https://patreon.com/weeblabs",
                            icon: "heart.fill", color: .orange)
                supportLink("Ko-fi", "https://ko-fi.com/weeblabs",
                            icon: "cup.and.saucer.fill", color: Color(red: 0.443, green: 0.620, blue: 0.737))
            } header: {
                Label("Links & Support", systemImage: "heart.text.square")
            }
        }
        .formStyle(.grouped)
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

/// Snapshot of the device-global output configuration (pins, output types, I2S
/// clocks, S/PDIF RX). These edits apply live to RAM; this captures a baseline
/// so we can detect/revert changes that haven't been flashed yet.
struct OutputConfigSnapshot: Equatable {
    var outputPins: [UInt8]
    var outputSlotTypes: [UInt8]
    var i2sBckPin: UInt8
    var mckEnabled: Bool
    var mckPin: UInt8
    var mckMultiplier: Int
    var spdifRxPin: UInt8
}

/// App-lifetime owner of pending (unsaved) Settings changes, so the save bar
/// survives navigation between pages and the Settings window being closed and
/// reopened. Two independent categories of pending change:
///
///  - Global parameters: staged in `globalDraft` and not applied until saved
///    (the firmware setters apply + persist on Save).
///  - Output config (independent mode only): pin/type/clock/RX edits apply
///    LIVE to RAM as they're made; "dirty" means they haven't been flashed yet.
///    Save calls `saveOutputConfig()`; Revert re-applies the captured baseline.
///
/// One Save / one Revert acts on whatever is pending. Dirtiness is gated on
/// actual user edits, so fresh device data (on connect) never looks unsaved.
final class SettingsSaveCoordinator: ObservableObject {
    static let shared = SettingsSaveCoordinator()
    private var vm: DSPViewModel { AppState.shared.viewModel }

    // Category B - Global Parameters
    @Published var globalDraft: GlobalSettingsDraft
    /// True once the user has edited the global draft since the last clean point.
    @Published var globalUserEdited = false

    // Category A - Output config (live edits, flash on save)
    @Published var outputConfigDirty = false
    private var outputBaseline: OutputConfigSnapshot

    private init() {
        let vm = AppState.shared.viewModel
        globalDraft = GlobalSettingsDraft.from(vm)
        outputBaseline = SettingsSaveCoordinator.snapshot(vm)
    }

    private static func snapshot(_ vm: DSPViewModel) -> OutputConfigSnapshot {
        OutputConfigSnapshot(
            outputPins: vm.outputPins,
            outputSlotTypes: vm.outputSlotTypes,
            i2sBckPin: vm.i2sBckPin,
            mckEnabled: vm.mckEnabled,
            mckPin: vm.mckPin,
            mckMultiplier: vm.mckMultiplier,
            spdifRxPin: vm.spdifRxPin
        )
    }

    // MARK: Dirty state

    var globalDirty: Bool { globalUserEdited && globalDraft != GlobalSettingsDraft.from(vm) }
    var outputDirty: Bool {
        outputConfigDirty && vm.presetOutputConfigMode == OUTPUT_CONFIG_MODE_INDEPENDENT
    }
    var hasPendingChanges: Bool { globalDirty || outputDirty }

    // MARK: Global draft editing

    /// Binding for a global-draft field that marks the draft user-edited on write.
    func draftBinding<T>(_ keyPath: WritableKeyPath<GlobalSettingsDraft, T>) -> Binding<T> {
        Binding(
            get: { self.globalDraft[keyPath: keyPath] },
            set: { self.globalDraft[keyPath: keyPath] = $0; self.globalUserEdited = true }
        )
    }

    /// Re-sync the draft to the device's current values (for display) when the
    /// user hasn't edited it - called when the Global page appears / reconnects.
    func refreshGlobalDraftIfClean() {
        if !globalUserEdited { globalDraft = GlobalSettingsDraft.from(vm) }
    }

    // MARK: Output-config editing

    /// Call at the start of any output-config edit. On the first edit since the
    /// last clean point (independent mode only), captures the pre-edit committed
    /// config as the revert baseline.
    func beginOutputEdit() {
        guard vm.presetOutputConfigMode == OUTPUT_CONFIG_MODE_INDEPENDENT else { return }
        if !outputConfigDirty {
            outputBaseline = SettingsSaveCoordinator.snapshot(vm)
            outputConfigDirty = true
        }
    }

    // MARK: Save / Revert

    func save() {
        let doGlobal = globalDirty
        let doOutput = outputDirty
        guard doGlobal || doOutput else { return }
        let pending = globalDraft
        let deviceState = GlobalSettingsDraft.from(vm)
        let vm = self.vm
        DispatchQueue.global(qos: .userInitiated).async {
            if doGlobal {
                if pending.presetStartupMode != deviceState.presetStartupMode
                    || pending.presetDefaultSlot != deviceState.presetDefaultSlot {
                    vm.setPresetStartup(mode: pending.presetStartupMode, defaultSlot: pending.presetDefaultSlot)
                }
                if pending.presetMasterVolumeMode != deviceState.presetMasterVolumeMode {
                    vm.setMasterVolumeMode(pending.presetMasterVolumeMode)
                }
                if pending.presetOutputConfigMode != deviceState.presetOutputConfigMode {
                    vm.setOutputConfigMode(pending.presetOutputConfigMode)
                }
                if pending.dacHwMuteConfig != deviceState.dacHwMuteConfig {
                    vm.setDacHwMuteConfig(pending.dacHwMuteConfig)
                }
            }
            if doOutput {
                _ = vm.saveOutputConfig()
            }
            DispatchQueue.main.async {
                self.globalUserEdited = false
                self.outputConfigDirty = false
                self.globalDraft = GlobalSettingsDraft.from(vm)
            }
        }
    }

    func revert() {
        if globalDirty {
            globalUserEdited = false
            globalDraft = GlobalSettingsDraft.from(vm)
        }
        if outputDirty {
            let base = outputBaseline
            let vm = self.vm
            DispatchQueue.global(qos: .userInitiated).async {
                // Best-effort restore of the live config to the baseline.
                for slot in 0..<min(vm.numOutputSlots, base.outputSlotTypes.count)
                where vm.outputSlotTypes[slot] != base.outputSlotTypes[slot] {
                    _ = vm.setOutputSlotType(slot: slot, type: base.outputSlotTypes[slot])
                }
                for i in 0..<min(vm.outputPins.count, base.outputPins.count)
                where vm.outputPins[i] != base.outputPins[i] {
                    _ = vm.setOutputPin(output: i, pin: base.outputPins[i])
                }
                if vm.i2sBckPin != base.i2sBckPin { _ = vm.setI2SBckPin(base.i2sBckPin) }
                if vm.mckEnabled != base.mckEnabled { _ = vm.setMckEnable(base.mckEnabled) }
                if vm.mckPin != base.mckPin { _ = vm.setMckPin(base.mckPin) }
                if vm.mckMultiplier != base.mckMultiplier { _ = vm.setMckMultiplier(base.mckMultiplier) }
                if vm.spdifRxPin != base.spdifRxPin { _ = vm.setSpdifRxPin(base.spdifRxPin) }
                DispatchQueue.main.async { self.outputConfigDirty = false }
            }
        }
    }
}

/// Shared save/revert bar shown at the bottom of any Settings page while there
/// are pending changes (global draft and/or live output-config edits not yet
/// flashed). One Save / one Revert acts on whatever is pending.
private struct SettingsSaveBar: View {
    @ObservedObject var coordinator = SettingsSaveCoordinator.shared
    @ObservedObject var vm = AppState.shared.viewModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Saving writes these settings to the device's flash.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Revert") { coordinator.revert() }
            Button("Save") { coordinator.save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

struct GlobalSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel
    @ObservedObject private var navigator = SettingsNavigator.shared
    @ObservedObject private var coordinator = SettingsSaveCoordinator.shared

    /// Read access to the shared global-params draft. Edits go through
    /// `coordinator.draftBinding(...)` so they're tracked centrally.
    private var draft: GlobalSettingsDraft { coordinator.globalDraft }

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
        ScrollViewReader { proxy in
        Form {
            // MARK: Startup Preset
            Section {
                Picker("Mode", selection: coordinator.draftBinding(\.presetStartupMode)) {
                    Text("Specified Default").tag(0)
                    Text("Last Used").tag(1)
                }

                if draft.presetStartupMode == 0 {
                    Picker("Default Preset", selection: coordinator.draftBinding(\.presetDefaultSlot)) {
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

            // MARK: External Mute Control (DAC Hardware Mute — firmware-gated)
            if vm.dacHwMuteSupported {
                Section {
                    Toggle(isOn: Binding(
                        get: { draft.dacHwMuteConfig.enabled },
                        set: { newVal in
                            coordinator.globalDraft.dacHwMuteConfig.enabled = newVal
                            // Enabling with no pin is nonsensical - auto-assign
                            // the first available GPIO so the user doesn't see an
                            // empty picker the moment they flip the switch on.
                            if newVal && coordinator.globalDraft.dacHwMuteConfig.pin == DAC_HW_MUTE_PIN_NONE {
                                if let firstFree = HardwareSettingsTab.validPins.first(where: {
                                    vm.pinInUseBy($0, excluding: .dacMute) == nil
                                }) {
                                    coordinator.globalDraft.dacHwMuteConfig.pin = firstFree
                                }
                            }
                            coordinator.globalUserEdited = true
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
                            Picker("", selection: coordinator.draftBinding(\.dacHwMuteConfig.activeLow)) {
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
                            Picker("", selection: coordinator.draftBinding(\.dacHwMuteConfig.pin)) {
                                // No "None" entry - the enable toggle is the
                                // master switch.  Filter pins through
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

                        // Hold / release timing, staged in the draft.
                        globalMsPicker(label: "Hold Time",
                                       tooltip: "Mute-attack wait before clock-stop",
                                       options: [5, 10, 20, 50, 100],
                                       binding: coordinator.draftBinding(\.dacHwMuteConfig.holdMs))

                        globalMsPicker(label: "Release Time",
                                       tooltip: "Wait after un-mute before audio resumes",
                                       options: [0, 5, 10, 20, 50, 100],
                                       binding: coordinator.draftBinding(\.dacHwMuteConfig.releaseMs))

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
                                      || coordinator.globalDirty)
                            .help(coordinator.globalDirty
                                  ? "Save your changes first to test the mute pin."
                                  : "Begins one-second test.")
                        }
                    }
                } header: {
                    Label("External Mute Control", systemImage: "speaker.slash")
                }
            }

            // MARK: Master Volume Persistence
            Section {
                Picker("Mode", selection: coordinator.draftBinding(\.presetMasterVolumeMode)) {
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
                Picker("Mode", selection: coordinator.draftBinding(\.presetOutputConfigMode)) {
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
            .id("outputConfig")

        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.refreshGlobalDraftIfClean()
            scrollToOutputConfigIfNeeded(proxy)
        }
        .onChange(of: vm.isDeviceConnected) { connected in
            // On (re)connect, refresh the draft from the device's freshly
            // fetched values - but only when the user hasn't staged edits.
            if connected { coordinator.refreshGlobalDraftIfClean() }
        }
        .onChange(of: navigator.scrollTarget) { _ in
            scrollToOutputConfigIfNeeded(proxy)
        }
        }
        // The save bar is shared across all Settings pages (see SettingsView).
    }

    /// Deep-link handler: when another page sets the scroll target to
    /// "outputConfig", scroll the Output Configuration section into view.
    private func scrollToOutputConfigIfNeeded(_ proxy: ScrollViewProxy) {
        guard navigator.scrollTarget == "outputConfig" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation { proxy.scrollTo("outputConfig", anchor: .top) }
            navigator.scrollTarget = nil
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

}

struct GraphingSettingsTab: View {
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

                Toggle(isOn: $settings.showPhase) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Phase Response")
                            .font(.body)
                        Text("Overlay the selected channel's phase (degrees) as a dotted line")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 4)

                Toggle(isOn: $settings.phaseUnwrapped) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unwrap Phase")
                            .font(.body)
                        Text("Show continuous phase instead of wrapping at \u{00B1}180\u{00B0}")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!settings.showPhase)
                .padding(.vertical, 4)
            } header: {
                Label("Graph Appearance", systemImage: "sparkles")
            }

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
    }
}

struct AdvancedSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var vm = AppState.shared.viewModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Reset all channel names to factory defaults.")
                        .font(.body)
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
                .padding(.vertical, 4)
            } header: {
                Label("Channel Names", systemImage: "textformat")
            }

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
    }
}

// MARK: - Hardware Settings Tab

struct HardwareSettingsTab: View {
    /// Which hardware section this instance renders, so each can live on its
    /// own sidebar page while sharing this struct's helpers and pin-conflict
    /// bookkeeping.
    enum Page { case outputs, i2s, spdif }
    var section: Page = .outputs

    @ObservedObject private var vm = AppState.shared.viewModel
    @State private var statusMessage: String?
    @State private var statusIsError = false

    /// Inline success/error feedback for pin changes, shown on whichever
    /// hardware page is active.
    @ViewBuilder
    private var statusRow: some View {
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
    }

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
        Group {
            if section == .outputs {
                outputsView
            } else {
                formContent
            }
        }
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

    // I2S Configuration / S/PDIF Input still use the standard grouped form.
    @ViewBuilder
    private var formContent: some View {
        Form {

            // MARK: I2S Clock
            // BCK / MCK pin selection and MCK enable / multiplier are
            // GPIO-mux concerns specific to the RP firmware.  STM32's SAI
            // peripheral drives fixed clock pins (PE2 MCLK, PE5 BCK, PE4
            // LRCLK) — there's nothing to assign — so we hide the whole
            // section there.
            if section == .i2s && !isSTM32 {
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
                            SettingsSaveCoordinator.shared.beginOutputEdit()
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
                        // BCK occupies the pin; LRCLK lands on pin+1 - so a
                        // candidate is only valid when BOTH are free (otherwise,
                        // e.g., BCK 15 would put LRCLK on a pin already used by
                        // S/PDIF RX 16).
                        ForEach(Self.validPins.filter { p in
                            pinInUseBy(p, excluding: .i2sBck) == nil
                                && pinInUseBy(p &+ 1, excluding: .i2sBck) == nil
                        }, id: \.self) { pin in
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
                        SettingsSaveCoordinator.shared.beginOutputEdit()
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
                            SettingsSaveCoordinator.shared.beginOutputEdit()
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
                            SettingsSaveCoordinator.shared.beginOutputEdit()
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

                statusRow
            }
            }

            // MARK: Inputs
            if section == .spdif && vm.inputSourceSupported {
                Section {
                    HStack {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SPDIF RX")
                                .font(.body)
                            Text("GPIO pin for incoming S/PDIF signal from a TOSLINK RX module or comparator.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.spdifRxPin },
                            set: { newPin in
                                SettingsSaveCoordinator.shared.beginOutputEdit()
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

                    statusRow
                }

                // LG Sound Sync decodes the LG TV's TOSLINK (S/PDIF) signaling.
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
                            Text("Enable")
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
        }
        .formStyle(.grouped)
    }

    // MARK: - Outputs page (custom full-width cards)

    private var outputsView: some View {
        Form {
            Section {
                ForEach(visiblePinOutputs) { output in
                    outputRow(output)
                }
            }

            // Status feedback + reset, with the persistence notice below it.
            Section {
                if !isSTM32 || statusMessage != nil {
                    HStack(spacing: 8) {
                        statusRow
                        Spacer(minLength: 0)
                        if !isSTM32 {
                            Button("Reset Pins") {
                                resetToDefaults()
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(vm.isDeviceConnected ? .accentColor : .secondary.opacity(0.5))
                            .disabled(!vm.isDeviceConnected)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Shared row layout used by both the Outputs and Inputs pages: a channel
    /// color dot + label (+ optional "Default" capsule) on the left, and the
    /// format + GPIO dropdowns on the right. The values (S/PDIF, GPIO 6, …) are
    /// self-describing, so no "Type"/"Pin" labels are needed.
    @ViewBuilder
    private func assignmentRow<T: View, P: View>(
        color: Color,
        title: String,
        isDefault: Bool,
        @ViewBuilder type: () -> T,
        @ViewBuilder pin: () -> P
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            // Fixed width so the "Default" capsule lines up across rows
            // regardless of label length ("Sub" vs "OUT 1/2").
            Text(title)
                .frame(width: 56, alignment: .leading)
            if isDefault {
                Text("Default")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            Spacer(minLength: 8)

            type()
            pin()
        }
    }

    @ViewBuilder
    private func outputRow(_ output: PinOutput) -> some View {
        let isSlot = output.id < vm.numOutputSlots
        let title = isSlot ? "OUT \(output.id * 2 + 1)/\(output.id * 2 + 2)" : "Sub"

        // "Default" when both type and pin match factory defaults. The Sub has
        // no type choice; STM32 has no assignable pins — those dimensions count
        // as default automatically.
        let typeIsDefault = !isSlot || vm.outputSlotTypes[output.id] == 0
        let pinIsDefault = isSTM32 || vm.outputPins[output.id] == output.defaultPin
        let isDefault = typeIsDefault && pinIsDefault

        assignmentRow(color: output.color, title: title, isDefault: isDefault) {
            typeControl(output)
        } pin: {
            if !isSTM32 {
                pinControl(output)
            }
        }
    }

    /// The single S/PDIF input row — same style as an output row (color dot,
    /// "IN 1/2", S/PDIF-only type, assignable RX GPIO).
    ///
    /// NOTE: Not currently wired into the Inputs page (which uses the simpler
    /// "SPDIF RX" row for now) — kept here for later use.
    @ViewBuilder
    private func inputRow() -> some View {
        assignmentRow(color: Channel.masterRight.color, title: "IN 1/2", isDefault: false) {
            // Type — S/PDIF is the only option (enabled, but it's the sole choice).
            Picker("", selection: .constant(UInt8(0))) {
                Text("S/PDIF").tag(UInt8(0))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } pin: {
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
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func typeControl(_ output: PinOutput) -> some View {
        if output.id < vm.numOutputSlots {
            Picker("", selection: outputTypeBinding(output)) {
                Text("S/PDIF").tag(UInt8(0))
                if i2sAllowedFor(slot: output.id) {
                    Text("I2S").tag(UInt8(1))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } else {
            // Sub is always PDM — same dropdown control as the others, but with
            // PDM as the only option and disabled (grayed out).
            Picker("", selection: .constant(UInt8(0))) {
                Text("PDM").tag(UInt8(0))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(true)
        }
    }

    @ViewBuilder
    private func pinControl(_ output: PinOutput) -> some View {
        Picker("", selection: outputPinBinding(output)) {
            ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .output(output.id)) == nil }, id: \.self) { pin in
                Text("GPIO \(pin)").tag(pin)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        // Fixed width sized for the longest label ("GPIO 28") so every pin
        // selector is the same width, right-aligned to the row edge.
        .frame(width: 92, alignment: .trailing)
    }

    private func outputTypeBinding(_ output: PinOutput) -> Binding<UInt8> {
        Binding(
            get: { vm.outputSlotTypes[output.id] },
            set: { newType in
                SettingsSaveCoordinator.shared.beginOutputEdit()
                let slotID = output.id
                DispatchQueue.global(qos: .userInitiated).async {
                    let status = vm.setOutputSlotType(slot: slotID, type: newType)
                    // STM32 firmware coerces dependent I2S slots down to S/PDIF
                    // when their parent goes S/PDIF; refetch so the UI reflects it.
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
        )
    }

    private func outputPinBinding(_ output: PinOutput) -> Binding<UInt8> {
        Binding(
            get: { vm.outputPins[output.id] },
            set: {
                SettingsSaveCoordinator.shared.beginOutputEdit()
                setPinForOutput(output.id, pin: $0)
            }
        )
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
        // Without this the window keeps whatever (wider) frame macOS restored
        // from a previous launch — content-size hints alone never shrink it.
        // `.contentSize` clamps the window's max size to its fixed content
        // (sidebar + 340pt detail), so it can't sit wider than it needs to.
        .windowResizability(.contentSize)
    }
}
