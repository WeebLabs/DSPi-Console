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
    case globalParams, outputAssignment, i2sConfig, spdifInput, controlInterfaces, controlSurfaces

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
        case .controlInterfaces: return "Control Interfaces"
        case .controlSurfaces:  return "Control Surfaces"
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
        case .controlInterfaces: return "cpu"
        case .controlSurfaces:  return "dial.medium"
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
        case .controlInterfaces: return Color(red: 0.30, green: 0.44, blue: 0.66) // dusk blue
        case .controlSurfaces:  return Color(red: 0.27, green: 0.52, blue: 0.70)  // steel cyan
        }
    }

    /// Some hardware pages only apply to certain platforms/firmware. A page
    /// that isn't applicable is hidden from the sidebar entirely.
    func isAvailable(_ vm: DSPViewModel) -> Bool {
        switch self {
        case .i2sConfig:         return vm.platformName != "STM32H723"
        case .spdifInput:        return vm.inputSourceSupported
        case .controlInterfaces: return vm.controlInterfacesSupported
        // Shown while disconnected too (the page carries its own placeholder);
        // hidden only when a connected device lacks the feature.
        case .controlSurfaces:   return vm.controlSurfacesSupported || !vm.isDeviceConnected
        default:                 return true
        }
    }

    /// Non-collapsible sidebar groups, in display order.
    static let groups: [(title: String, items: [SettingsCategory])] = [
        ("Application", [.general, .advanced]),
        ("Display",     [.graphing]),
        ("System",      [.spdifInput, .outputAssignment, .i2sConfig, .controlInterfaces, .controlSurfaces, .globalParams]),
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
        /// Initial window content size. Width matches the two column widths
        /// (sidebar 215 + detail 450); change these together. Height matches the
        /// split view's `idealHeight`.
        private static let initialContentSize = NSSize(width: 665, height: 580)

        private var didSetInitialFrame = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfig()
            applyInitialFrameIfNeeded()
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
            // Now that Settings is a plain `Window` scene (not a `Settings`
            // scene), pin a stable identifier so open/close tracking can find it
            // deterministically, and opt out of state restoration so it doesn't
            // reopen on launch the way the old `Settings` scene never did.
            window.identifier = NSUserInterfaceItemIdentifier("dspiSettings")
            window.isRestorable = false
        }

        /// SwiftUI persists a `Window` scene's frame across launches (keyed to
        /// the scene id). That saved frame overrides the content's ideal width,
        /// so adjusting the column widths otherwise has no effect on the opening
        /// size. Opt out of that persistence and pin the initial size ourselves,
        /// once per window instance. The window stays freely resizable; the size
        /// just isn't remembered across reopens (matching the old Settings scene,
        /// which was always content-sized).
        private func applyInitialFrameIfNeeded() {
            guard !didSetInitialFrame, let window = window else { return }
            didSetInitialFrame = true
            window.setFrameAutosaveName("")   // stop restoring/persisting the frame
            window.setContentSize(Self.initialContentSize)
            window.center()
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
            // A firm minimum so the sidebar never starts narrow enough to
            // truncate the longest labels ("Control Interfaces", "Global
            // Parameters", "I2S Configuration"); `ideal` fixes the initial width.
            .navigationSplitViewColumnWidth(min: 215, ideal: 215)
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
                // shrinks the content inside it, leaving the column - and thus the
                // window - wide. The `min`/`ideal` pin the initial (narrow) width
                // while leaving the column free to grow when the user resizes the
                // now-resizable window, so it fills instead of leaving a gap.
                .navigationSplitViewColumnWidth(min: 450, ideal: 450)
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
        case .controlInterfaces: ControlInterfacesSettingsTab()
        case .controlSurfaces:  ControlSurfacesSettingsTab()
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
    var spdifRxPinsExt: [UInt8]
    var spdifExtEnabled: [Bool]
    var i2sRxPins: [UInt8]
    var i2sInputChannels: Int
    var i2sInputRateHz: UInt32
    var i2sClockMode: UInt8
    var i2sClockPinMode: UInt8
    var i2sBckPinSlave: UInt8
    var adatEnabled: Bool
    var adatPin: UInt8
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
            spdifRxPin: vm.spdifRxPin,
            spdifRxPinsExt: vm.spdifRxPinsExt,
            spdifExtEnabled: vm.spdifExtEnabled,
            i2sRxPins: vm.i2sRxPins,
            i2sInputChannels: vm.i2sInputChannels,
            i2sInputRateHz: vm.i2sInputRateHz,
            i2sClockMode: vm.i2sClockMode,
            i2sClockPinMode: vm.i2sClockPinMode,
            i2sBckPinSlave: vm.i2sBckPinSlave,
            adatEnabled: vm.adatEnabled,
            adatPin: vm.adatPin
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
                if vm.spdifRxPin != base.spdifRxPin { _ = vm.setSpdifRxPin(index: 0, base.spdifRxPin) }
                // Optional S/PDIF 2/3: restore each pin, then the enable state.
                // Apply the pin before re-enabling so an enable validates against
                // the restored pin; disable before repinning frees any conflict.
                if vm.multiSpdifSupported {
                    for i in 0..<min(vm.spdifRxPinsExt.count, base.spdifRxPinsExt.count) {
                        let idx = i + 1
                        // Drop the enable if we're turning it off (so a repin can't clash).
                        if vm.spdifExtEnabled[i] && !base.spdifExtEnabled[i] {
                            _ = vm.setSpdifInputEnable(index: idx, false)
                        }
                        if vm.spdifRxPinsExt[i] != base.spdifRxPinsExt[i] {
                            _ = vm.setSpdifRxPin(index: idx, base.spdifRxPinsExt[i])
                        }
                        if !vm.spdifExtEnabled[i] && base.spdifExtEnabled[i] {
                            _ = vm.setSpdifInputEnable(index: idx, true)
                        }
                    }
                }
                // I2S input: restore the channel count first (lowering frees pairs
                // and never fails), then each pair's data pin.
                if vm.i2sInputChannels != base.i2sInputChannels { _ = vm.setI2SInputChannels(base.i2sInputChannels) }
                for pair in 0..<min(vm.i2sRxPins.count, base.i2sRxPins.count)
                where vm.i2sRxPins[pair] != base.i2sRxPins[pair] {
                    _ = vm.setI2SRxPin(pair: pair, base.i2sRxPins[pair])
                }
                if vm.i2sInputRateHz != base.i2sInputRateHz { vm.setInputRate(base.i2sInputRateHz) }
                if vm.i2sClockMode != base.i2sClockMode { vm.setI2SClockMode(base.i2sClockMode) }
                // Clock-pin mode: restore the slave pair first (a dormant store,
                // accepted any time) so re-entering SPLIT finds it valid.
                if vm.i2sClockPinModeSupported {
                    if vm.i2sBckPinSlave != base.i2sBckPinSlave {
                        _ = vm.setI2SBckPin(base.i2sBckPinSlave, role: I2S_BCK_ROLE_SLAVE)
                    }
                    if vm.i2sClockPinMode != base.i2sClockPinMode {
                        _ = vm.setI2SClockPinMode(base.i2sClockPinMode)
                    }
                }
                // ADAT: restore the data pin first (re-routes under a muted
                // restart if enabled), then the enable state to match baseline.
                if vm.adatSupported {
                    if vm.adatPin != base.adatPin { _ = vm.setAdatPin(base.adatPin) }
                    if vm.adatEnabled != base.adatEnabled { _ = vm.setAdatEnable(base.adatEnabled) }
                }
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
                Label("Hardware Configuration", systemImage: "cable.connector")
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

// MARK: - Control Interfaces Settings Tab
//
// Configures the two external control transports (UART and I2C target) that
// expose the full vendor-command surface to an external microcontroller
// (ESP32/STM32/Arduino/SBC).  See control_interfaces_spec.md.
//
// Model notes:
//   • Both interfaces ship disabled and are configured over USB ONLY - an
//     external controller can read but never reconfigure the transport it is
//     talking on, so this page is the one place these get set up.
//   • A SET writes the full 8-byte config and (on success) persists to flash,
//     applying deferred on the device's main loop.  We stage edits in a local
//     draft and commit them with an explicit Apply, so a single flash write
//     covers a whole enable+pins+baud change rather than one per control.
//   • The firmware validates pins/baud/address at apply time and reports the
//     outcome via REQ_GET_CTRL_IFACE_STATUS; we surface that inline.
struct ControlInterfacesSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel

    // Local, editable drafts seeded from the device's live configs.  "Dirty"
    // (Apply enabled) means the draft differs from what the device holds.
    @State private var uartDraft = UartCtrlConfig()
    @State private var i2cDraft = I2cCtrlConfig()

    @State private var uartStatus: (message: String, isError: Bool)?
    @State private var i2cStatus: (message: String, isError: Bool)?
    @State private var uartApplying = false
    @State private var i2cApplying = false

    private var uartDirty: Bool { uartDraft != vm.uartCtrlConfig }
    private var i2cDirty: Bool { i2cDraft != vm.i2cCtrlConfig }

    var body: some View {
        Form {
            uartSection
            i2cSection

            Section {
                Text("Both control interfaces are configured over USB only - an external controller can read the configuration but can never reconfigure or disable the transport it is talking on, so it cannot lock itself out. Settings persist across reboots and survive a factory reset.\n\nUART TX/RX and I2C SDA/SCL must land on GPIOs that carry the matching peripheral mux function; the device validates this when you apply. Fit external pull-ups (2.2k - 4.7k) on the I2C bus.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } footer: {
                if vm.ctrlIfaceStatus.protoVersion != 0 {
                    Text("External control protocol version \(vm.ctrlIfaceStatus.protoVersion).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            uartDraft = vm.uartCtrlConfig
            i2cDraft = vm.i2cCtrlConfig
            // Refresh live status/config in case another host changed it.
            DispatchQueue.global(qos: .userInitiated).async { vm.fetchControlInterfaces() }
        }
        // Re-seed when the device's live config changes and the user has no
        // pending edits, so an external change doesn't get stranded off-screen.
        .onReceive(vm.$uartCtrlConfig) { newCfg in
            if !uartApplying && uartDraft == vm.uartCtrlConfig { uartDraft = newCfg }
        }
        .onReceive(vm.$i2cCtrlConfig) { newCfg in
            if !i2cApplying && i2cDraft == vm.i2cCtrlConfig { i2cDraft = newCfg }
        }
    }

    // MARK: UART section

    @ViewBuilder
    private var uartSection: some View {
        Section {
            interfaceHeader(
                title: "Enable UART",
                detail: "Asynchronous 3.3V serial link, fixed 8N1 framing.",
                live: vm.ctrlIfaceStatus.uartLive,
                configEnabled: vm.uartCtrlConfig.enabled,
                isOn: $uartDraft.enabled)

            if uartDraft.enabled {
                pinRow(title: "TX Pin",
                       detail: "GPIO transmitting to the controller's RX.",
                       icon: "arrow.up.right",
                       selection: $uartDraft.txPin,
                       candidates: uartTxPins())

                pinRow(title: "RX Pin",
                       detail: "GPIO receiving from the controller's TX.",
                       icon: "arrow.down.left",
                       selection: $uartDraft.rxPin,
                       candidates: uartRxPins())

                settingRow(title: "Baud Rate",
                           detail: "9600 - 1000000. Must match the controller.",
                           icon: "speedometer") {
                    Picker("", selection: $uartDraft.baud) {
                        ForEach(UART_CTRL_BAUD_CHOICES, id: \.self) { b in
                            Text(baudLabel(b)).tag(b)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle(isOn: $uartDraft.notifyEnable) {
                    settingLabel(title: "Push Notifications",
                                 detail: "Stream live parameter/preset/format changes to the controller (type-0x40 frames) instead of polling.",
                                 icon: "dot.radiowaves.left.and.right")
                }
                .toggleStyle(.switch)
            }

            applyRow(applying: uartApplying,
                     dirty: uartDirty,
                     status: uartStatus,
                     apply: applyUart,
                     revert: { uartDraft = vm.uartCtrlConfig; uartStatus = nil })
        } header: {
            Label("UART", systemImage: "cable.connector")
        }
    }

    // MARK: I2C section

    @ViewBuilder
    private var i2cSection: some View {
        Section {
            interfaceHeader(
                title: "Enable I2C Target",
                detail: "Device acts as an I2C slave; the controller is bus master. Poll-only (no async notifications).",
                live: vm.ctrlIfaceStatus.i2cLive,
                configEnabled: vm.i2cCtrlConfig.enabled,
                isOn: $i2cDraft.enabled)

            if i2cDraft.enabled {
                pinRow(title: "SDA Pin",
                       detail: "Serial data line (even GPIO).",
                       icon: "arrow.left.arrow.right",
                       selection: $i2cDraft.sdaPin,
                       candidates: i2cSdaPins())

                pinRow(title: "SCL Pin",
                       detail: "Serial clock line (next odd GPIO, same instance).",
                       icon: "clock",
                       selection: $i2cDraft.sclPin,
                       candidates: i2cSclPins())

                settingRow(title: "Target Address",
                           detail: "7-bit address, 0x08 - 0x77.",
                           icon: "number") {
                    HStack(spacing: 8) {
                        Text(String(format: "0x%02X", i2cDraft.address))
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                        Stepper("", value: Binding(
                            get: { Int(i2cDraft.address) },
                            set: { i2cDraft.address = UInt8(clamping: $0) }
                        ), in: Int(I2C_CTRL_ADDR_MIN)...Int(I2C_CTRL_ADDR_MAX))
                        .labelsHidden()
                    }
                    .fixedSize()
                }
            }

            applyRow(applying: i2cApplying,
                     dirty: i2cDirty,
                     status: i2cStatus,
                     apply: applyI2c,
                     revert: { i2cDraft = vm.i2cCtrlConfig; i2cStatus = nil })
        } header: {
            Label("I2C", systemImage: "cable.connector")
        }
    }

    // MARK: Row helpers

    /// The header row of an interface section: title, description, a live
    /// status pill (Active / Inactive / Disabled), and the enable switch.  The
    /// pill and switch share the title line; the description and any warning sit
    /// below.  "Inactive" flags the spec's boot-collision case - the stored
    /// config is enabled but the pins clash with the current output wiring, so
    /// the peripheral never came up.
    @ViewBuilder
    private func interfaceHeader(title: String, detail: String, live: Bool,
                                 configEnabled: Bool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if configEnabled && !live {
                    Text("Enabled in flash but not running - its pins likely collide with the current output wiring. Reassign the conflicting pin or move this interface, then apply.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            statusPill(live: live, configEnabled: configEnabled)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private func statusPill(live: Bool, configEnabled: Bool) -> some View {
        let (text, color): (String, Color) =
            live ? ("Active", .green)
                 : (configEnabled ? ("Inactive", .orange) : ("Disabled", .secondary))
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    /// A left-aligned icon + title + caption label, matching the other
    /// hardware pages.
    @ViewBuilder
    private func settingLabel(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func settingRow<Control: View>(title: String, detail: String, icon: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack {
            settingLabel(title: title, detail: detail, icon: icon)
            Spacer()
            control()
        }
    }

    @ViewBuilder
    private func pinRow(title: String, detail: String, icon: String,
                        selection: Binding<UInt8>, candidates: [UInt8]) -> some View {
        settingRow(title: title, detail: detail, icon: icon) {
            Picker("", selection: selection) {
                // Keep the current pin visible even if it's not in the free set.
                if !candidates.contains(selection.wrappedValue) {
                    Text("GPIO \(selection.wrappedValue)").tag(selection.wrappedValue)
                }
                ForEach(candidates, id: \.self) { pin in
                    Text("GPIO \(pin)").tag(pin)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// The shared Apply / Revert control row plus inline status feedback.
    @ViewBuilder
    private func applyRow(applying: Bool, dirty: Bool,
                          status: (message: String, isError: Bool)?,
                          apply: @escaping () -> Void, revert: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let status = status, !dirty {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(status.isError ? .orange : .green)
                    .font(.caption)
                Text(status.message)
                    .font(.caption)
                    .foregroundColor(status.isError ? .orange : .secondary)
            } else if dirty {
                Text("Unapplied changes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if applying {
                ProgressView().controlSize(.small)
            }
            Button("Revert", action: revert)
                .buttonStyle(.plain)
                .foregroundColor(dirty ? .accentColor : .secondary.opacity(0.5))
                .disabled(!dirty || applying)
            Button("Apply", action: apply)
                .disabled(!dirty || applying || !vm.isDeviceConnected)
        }
    }

    // MARK: Pin candidate sets
    //
    // Filter the platform's valid GPIOs to those carrying the required
    // peripheral mux function (UART TX = pin % 4 == 0, RX = pin % 4 == 1;
    // I2C SDA even, SCL odd) and not already claimed by another consumer.
    // The device does the authoritative same-instance mux validation on apply.

    private func uartTxPins() -> [UInt8] {
        HardwareSettingsTab.validPins.filter { p in
            p % 4 == 0 && p != uartDraft.rxPin &&
            (p == uartDraft.txPin || vm.pinInUseBy(p, excluding: .uartCtrl) == nil)
        }
    }

    private func uartRxPins() -> [UInt8] {
        HardwareSettingsTab.validPins.filter { p in
            p % 4 == 1 && p != uartDraft.txPin &&
            (p == uartDraft.rxPin || vm.pinInUseBy(p, excluding: .uartCtrl) == nil)
        }
    }

    private func i2cSdaPins() -> [UInt8] {
        HardwareSettingsTab.validPins.filter { p in
            p % 2 == 0 && p != i2cDraft.sclPin &&
            (p == i2cDraft.sdaPin || vm.pinInUseBy(p, excluding: .i2cCtrl) == nil)
        }
    }

    private func i2cSclPins() -> [UInt8] {
        HardwareSettingsTab.validPins.filter { p in
            p % 2 == 1 && p != i2cDraft.sdaPin &&
            (p == i2cDraft.sclPin || vm.pinInUseBy(p, excluding: .i2cCtrl) == nil)
        }
    }

    private func baudLabel(_ b: UInt32) -> String {
        b >= 1000 && b % 1000 == 0 ? "\(b / 1000)k" : "\(b)"
    }

    // MARK: Apply

    private func applyUart() {
        let cfg = uartDraft
        uartApplying = true
        uartStatus = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.setUartCtrlConfig(cfg)
            DispatchQueue.main.async {
                uartApplying = false
                uartDraft = vm.uartCtrlConfig
                uartStatus = statusMessage(status, iface: "UART")
            }
        }
    }

    private func applyI2c() {
        let cfg = i2cDraft
        i2cApplying = true
        i2cStatus = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.setI2cCtrlConfig(cfg)
            DispatchQueue.main.async {
                i2cApplying = false
                i2cDraft = vm.i2cCtrlConfig
                i2cStatus = statusMessage(status, iface: "I2C")
            }
        }
    }

    /// Map a PIN_CONFIG_* apply outcome into inline feedback.
    private func statusMessage(_ status: UInt8, iface: String) -> (String, Bool) {
        switch status {
        case PIN_CONFIG_SUCCESS:        return ("\(iface) configuration applied and saved", false)
        case PIN_CONFIG_INVALID_PIN:    return ("A pin is out of range or lacks the required \(iface) mux function", true)
        case PIN_CONFIG_PIN_IN_USE:     return ("A pin is already claimed by another output or interface", true)
        case PIN_CONFIG_INVALID_PARAM:
            return (iface == "UART"
                    ? "Baud rate is out of range (9600 - 1000000)"
                    : "Address is out of range (0x08 - 0x77)", true)
        default:                        return ("Failed to apply \(iface) configuration", true)
        }
    }
}

// MARK: - Control Surfaces Settings Tab
//
// User-wired physical controls (buttons, switches, pots, encoders, indicator
// LEDs) on spare GPIOs, each bound to one firmware parameter.  The whole picker
// is built from the device-served capability tables (`vm.csCaps` +
// `vm.csNounDescs`), never from hardcoded lists, so a future firmware's new
// component types / parameters appear with no app change (spec §4).  Each of
// the sixteen slots (capability format v2) edits a local draft; Apply sends the
// 24-byte binding and polls the deferred-apply outcome back.  Buttons can carry
// a press gesture (event) and many nouns address a channel/band (target/index).
// See control_surfaces_spec.md.

/// A borderless, left-aligned single-line text field for use inside a grouped
/// Form.  A grouped Form on macOS force-right-aligns any SwiftUI TextField's
/// text and prompt (it styles the field as the row's trailing "value" column;
/// .multilineTextAlignment / .fixedSize have no effect), so this drops to
/// AppKit where NSTextField keeps its natural left alignment.
struct LeftAlignedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize)
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Don't stomp the field (and the cursor) mid-edit; the binding is fed
        // keystroke-by-keystroke from the delegate while editing.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LeftAlignedTextField
        private var clickMonitor: Any?
        init(_ parent: LeftAlignedTextField) { self.parent = parent }

        deinit { removeClickMonitor() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // A grouped SwiftUI Form doesn't move first-responder off an embedded
        // NSTextField when the user clicks static content or another row, so
        // controlTextDidEndEditing (and thus the commit) would never fire on a
        // click "around" the field.  While editing, watch for a mouse-down
        // outside the field and resign first-responder, which ends editing.
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard clickMonitor == nil, let field = notification.object as? NSTextField else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak field] event in
                guard let field = field, let window = field.window, event.window == window else { return event }
                let pointInField = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(pointInField) {
                    // Defer to the next runloop pass so the click still lands on
                    // whatever was clicked; only resign if this field is still the
                    // one being edited (a click onto another field already ended
                    // our editing through the normal path).
                    DispatchQueue.main.async {
                        if field.currentEditor() != nil { window.makeFirstResponder(nil) }
                    }
                }
                return event
            }
        }

        // Fires on Enter and on losing focus - commit in both cases.
        func controlTextDidEndEditing(_ notification: Notification) {
            removeClickMonitor()
            parent.onCommit()
        }

        private func removeClickMonitor() {
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        }
    }
}

struct ControlSurfacesSettingsTab: View {
    @ObservedObject private var vm = AppState.shared.viewModel

    // Local, editable drafts seeded from the device's live bindings.  A slot is
    // "dirty" (Apply enabled) when its draft differs from the live binding.
    @State private var drafts: [CsBinding] = Array(repeating: CsBinding(), count: CS_MAX_BINDINGS)
    @State private var slotMessages: [Int: (message: String, isError: Bool)] = [:]
    @State private var applyingSlot: Int? = nil

    // Cards start collapsed so the list reads as an at-a-glance overview; a
    // newly added control opens for editing.  Collapse state is per-visit.
    @State private var expandedSlots: Set<Int> = []

    // IR remote command sub-slots (device-global; shown under the receiver
    // card).  `irDrafts` mirrors `vm.csIrCommands` for local editing; the learn
    // flow captures a protocol+code into the draft being edited.
    @State private var irDrafts: [IrCommand] = Array(repeating: IrCommand(), count: CS_MAX_IR_COMMANDS)
    @State private var applyingSub: Int? = nil
    @State private var subMessages: [Int: (message: String, isError: Bool)] = [:]
    @State private var learningSub: Int? = nil
    @State private var learnMessage: String? = nil
    // Remote-button cards start collapsed to an at-a-glance list; a newly added
    // one opens for editing (mirrors the component cards' `expandedSlots`).
    @State private var expandedSubs: Set<Int> = []

    // User-given names, shown in the card header so collapsed cards are
    // tellable apart.  Names are device-persistent (spec §3.4), read into
    // `vm.csNames`; this is a local editing buffer committed on submit / close
    // so a keystroke doesn't trigger a blocking device write.  A slot with no
    // buffered edit shows the live device name.
    @State private var nameEdits: [Int: String] = [:]
    // One-time migration of the old app-side names (UserDefaults) onto the
    // device the first time a v3 device that supports device names connects.
    @State private var didMigrateLegacyNames = false
    private static let legacyNamesKey = "controlSurfaceSlotNames"

    // Global Save/Revert (the Apply/Save/Revert preview model; spec §3.5):
    // binding + IR command applies are live-only previews until saved.
    @State private var savingConfig = false

    /// Number of binding slots the device exposes (falls back to the wire max).
    private var slotCount: Int {
        let n = Int(vm.csCaps.maxBindings)
        return n > 0 ? min(n, CS_MAX_BINDINGS) : CS_MAX_BINDINGS
    }

    var body: some View {
        Form {
            if vm.csCaps.types.isEmpty {
                // No capability tables yet: either the device is still being
                // read, or there is no device to read.  The picker UI is built
                // entirely from device-served tables, so without them the page
                // can only explain itself.
                if vm.isDeviceConnected {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading control-surface capabilities from the device...")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    disconnectedSection
                }
            } else {
                if visibleSlots.isEmpty {
                    // The empty state carries its own Add Control button.
                    emptyStateSection
                } else {
                    ForEach(visibleSlots, id: \.self) { slot in
                        slotSection(slot)
                    }
                    addSection
                }
            }

            Section {
                Text("Wire push buttons, toggle switches, potentiometers, rotary encoders, indicator LEDs, and an IR remote receiver to spare GPIOs and bind each to a device function. Buttons and switches wire between the GPIO and GND (internal pull-up); pots use an ADC pin (GPIO 26, 27, or 28) between 3V3 and GND; encoders use two GPIOs with the common wired to GND. LEDs drive active-high by default. An IR receiver module's OUT pin connects to any GPIO, and its remote buttons are learned by pressing them at the device.\n\nThis wiring is a board-level setting: it is stored on the device, survives preset changes, and survives a factory reset. Changes take effect immediately as a live preview; use Save to Device to keep them across a reboot, or Revert to discard them.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } footer: {
                if vm.csCaps.capsVersion != 0 {
                    Text("Control-surface capability version \(vm.csCaps.capsVersion).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Unsaved-changes bar pinned to the bottom of the window, matching the
        // global Settings save bar: it appears while there are live-but-unsaved
        // control changes and just slides away once saved or reverted.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if vm.csDirty {
                csSaveBar.transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.csDirty)
        .onAppear {
            seedDrafts()
            DispatchQueue.global(qos: .userInitiated).async { vm.fetchControlSurfaces() }
        }
        // Re-seed a slot when its live binding changes and the user has no
        // pending edits for it, so an external change never strands a draft.
        .onReceive(vm.$csBindings) { newBindings in
            for slot in 0..<min(drafts.count, newBindings.count) {
                if applyingSlot != slot && drafts[slot] == vm.csBindings[slot] {
                    drafts[slot] = newBindings[slot]
                }
            }
        }
        // Once the device names arrive, migrate any legacy app-side names.
        .onReceive(vm.$csNames) { _ in migrateLegacyNamesIfNeeded() }
        // Re-seed an IR command draft when its live value changes and there is
        // no pending edit for it (mirror of the binding re-seed above).
        .onReceive(vm.$csIrCommands) { newCmds in
            for sub in 0..<min(irDrafts.count, newCmds.count) {
                if applyingSub != sub && learningSub != sub && irDrafts[sub] == vm.csIrCommands[sub] {
                    irDrafts[sub] = newCmds[sub]
                }
            }
        }
    }

    private func seedDrafts() {
        var seeded = Array(repeating: CsBinding(), count: CS_MAX_BINDINGS)
        for slot in 0..<min(CS_MAX_BINDINGS, vm.csBindings.count) {
            seeded[slot] = vm.csBindings[slot]
        }
        drafts = seeded
        var seededIr = Array(repeating: IrCommand(), count: CS_MAX_IR_COMMANDS)
        for sub in 0..<min(CS_MAX_IR_COMMANDS, vm.csIrCommands.count) {
            seededIr[sub] = vm.csIrCommands[sub]
        }
        irDrafts = seededIr
    }

    // MARK: Custom names (device-persistent; spec §3.4)

    /// The name shown for a slot: a pending local edit, else the live device name.
    private func slotName(_ slot: Int) -> String {
        if let edit = nameEdits[slot] { return edit }
        return slot < vm.csNames.count ? vm.csNames[slot] : ""
    }

    /// Editable name for a slot; stages keystrokes locally.  A name edit is
    /// staged like a binding edit (not pushed on Enter): it marks the card
    /// Pending and Apply pushes it live (spec §3.4/§3.5).
    private func nameBinding(_ slot: Int) -> Binding<String> {
        Binding(
            get: { slotName(slot) },
            set: { nameEdits[slot] = $0 })
    }

    /// The staged (unapplied) name for a slot: a local edit that differs from
    /// the live device name, or nil when there is no pending rename.  Editing
    /// stages the name; Apply is what pushes it to the device.
    private func stagedName(_ slot: Int) -> String? {
        guard let edited = nameEdits[slot] else { return nil }
        let live = slot < vm.csNames.count ? vm.csNames[slot] : ""
        return edited == live ? nil : edited
    }

    /// The card's own unapplied edits: a binding edit or a staged rename.
    /// Drives the receiver's Apply/Revert row (its Apply pushes exactly these).
    private func slotSelfDirty(_ slot: Int) -> Bool {
        drafts[slot] != vm.csBindings[slot] || stagedName(slot) != nil
    }

    /// Unapplied edits to any learned remote button.  IR commands are device-
    /// global and edited inside the IR receiver card, so a change to one counts
    /// as pending work on that component.
    private var anyIrCommandDirty: Bool {
        (0..<maxSubs).contains { sub in
            guard sub < irDrafts.count, sub < vm.csIrCommands.count else { return false }
            let d = irDrafts[sub], live = vm.csIrCommands[sub]
            // A learned draft that differs, or a cleared draft over a live one.
            // A freshly-added, not-yet-learned button has nothing to apply, so
            // it doesn't count until a code is learned.
            return d != live && (d.isConfigured || live.isConfigured)
        }
    }

    /// True when the card should read Pending: its own edits, or - for the IR
    /// receiver - an unapplied edit to a remote button nested inside it.
    private func slotDirty(_ slot: Int) -> Bool {
        slotSelfDirty(slot) || (Int(drafts[slot].type) == CS_TYPE_IR && anyIrCommandDirty)
    }

    /// Push any legacy app-side names (old UserDefaults store) onto the device
    /// once, for slots the device hasn't named yet, then retire the local store.
    private func migrateLegacyNamesIfNeeded() {
        guard !didMigrateLegacyNames, vm.controlSurfacesSupported else { return }
        didMigrateLegacyNames = true
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.legacyNamesKey) as? [String: String],
              !stored.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Names are now part of the live preview (spec 3.4), so a bare SET
            // no longer reaches flash.  Only persist the migration if the device
            // was clean to begin with, so we don't silently commit a prior
            // session's unsaved changes.
            let wasClean = !vm.csStatus.dirty
            var wrote = false
            for (key, name) in stored {
                guard let slot = Int(key), slot >= 0, slot < CS_MAX_BINDINGS, !name.isEmpty else { continue }
                let live = slot < vm.csNames.count ? vm.csNames[slot] : ""
                if live.isEmpty { _ = vm.setCsName(slot: slot, name: name); wrote = true }
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyNamesKey)
            // Persist the migrated names so they stick across a reboot, matching
            // the pre-preview behavior where a name SET wrote flash directly.
            if wrote && wasClean { _ = vm.csSave() }
        }
    }

    private func toggleExpanded(_ slot: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if expandedSlots.contains(slot) { expandedSlots.remove(slot) }
            else { expandedSlots.insert(slot) }
        }
    }

    // MARK: Add / remove

    /// Slots that currently hold a control (edited draft or live on the device),
    /// shown as cards.  Empty slots are hidden until "Add a Control" fills one.
    private var visibleSlots: [Int] {
        (0..<slotCount).filter { drafts[$0].isConfigured || vm.csBindings[$0].isConfigured }
    }

    /// The lowest slot with neither a draft nor a live binding, or nil when full.
    private var firstFreeSlot: Int? {
        (0..<slotCount).first { !drafts[$0].isConfigured && !vm.csBindings[$0].isConfigured }
    }

    /// Placeholder while no device is connected.  Everything on this page is
    /// device-served (capability tables) and device-stored (bindings), so
    /// there is nothing to edit offline.
    @ViewBuilder
    private var disconnectedSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                VStack(spacing: 3) {
                    Text("No Device Connected")
                        .font(.headline)
                    Text("Control surfaces are stored on the device. Connect a DSPi to view and configure its wired controls.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 14) {
                // A hint of what can be wired up: one badge per component type.
                HStack(spacing: 10) {
                    ForEach(realTypes, id: \.self) { t in
                        csTypeBadge(t, size: 28)
                    }
                }
                VStack(spacing: 3) {
                    Text("No Controls Configured")
                        .font(.headline)
                    Text("Wire a button, switch, knob, encoder, or LED to a spare GPIO and bind it to a device function.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                addMenu(prominent: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private var addSection: some View {
        Section {
            HStack {
                addMenu(prominent: false)
                Spacer()
                if firstFreeSlot == nil {
                    Text("All \(slotCount) control slots are in use.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: Save / Revert (Apply/Save/Revert preview model; spec §3.5)

    /// Bottom-of-window "unsaved changes" bar, styled like the global Settings
    /// save bar.  Control / name / IR-command applies are live-only previews:
    /// they behave immediately but do not survive a reboot until saved.  Save
    /// persists the whole live config in one flash write; Revert reloads what is
    /// stored.  The bar is shown by `.safeAreaInset` while `vm.csDirty`, so it
    /// simply slides away once the change is saved or reverted.
    @ViewBuilder
    private var csSaveBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Your controls are live now; saving keeps them across a reboot.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if savingConfig { ProgressView().controlSize(.small) }
            Button("Revert") { revertConfig() }
                .disabled(csBusy || !vm.isDeviceConnected)
            Button("Save") { saveConfig() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(csBusy || !vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    /// True while any deferred Control Surfaces operation is in flight.  Because
    /// binding, name, IR-command, save, and revert all report through one shared
    /// status channel (spec §3.2), the UI serializes them: each op disables the
    /// others until it resolves.
    private var csBusy: Bool {
        applyingSlot != nil || applyingSub != nil || savingConfig || learningSub != nil
    }

    private func saveConfig() {
        savingConfig = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = vm.csSave()
            // csDirty flips false on success, sliding the bar away; on failure
            // it stays set so the bar remains for a retry.
            DispatchQueue.main.async { savingConfig = false }
        }
    }

    private func revertConfig() {
        savingConfig = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = vm.csRevert()
            DispatchQueue.main.async {
                savingConfig = false
                // Re-seed drafts from the restored live bindings/names.
                seedDrafts()
                nameEdits.removeAll()
                slotMessages.removeAll()
            }
        }
    }

    /// The "Add Control" menu: picking a component type directly creates its
    /// card, already seeded with sensible defaults.
    @ViewBuilder
    private func addMenu(prominent: Bool) -> some View {
        let menu = Menu {
            ForEach(addableTypes, id: \.self) { t in
                Button { addControl(type: t) } label: {
                    Label(typeName(t), systemImage: typeIcon(t))
                }
            }
        } label: {
            Label("Add Control", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(firstFreeSlot == nil || !vm.isDeviceConnected)

        if prominent {
            menu.buttonStyle(.borderedProminent).controlSize(.regular)
        } else {
            menu.controlSize(.regular)
        }
    }

    /// Create a new binding of `type` in the first free slot so its editor card
    /// appears, and apply it to the device right away as a live preview.  A new
    /// control seeded with sensible defaults is already valid, so it should work
    /// the moment it's added; only later edits are staged and pushed with Apply.
    private func addControl(type: Int) {
        guard let slot = firstFreeSlot else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            drafts[slot] = makeBinding(type: type, slot: slot)
            expandedSlots.insert(slot)   // open the new card for editing
        }
        slotMessages[slot] = nil
        applySlot(slot)
    }

    /// Remove a control.  If it was applied to the device, clear the slot there
    /// too (send CS_TYPE_NONE); an unapplied new draft is just dropped locally.
    private func removeControl(_ slot: Int) {
        slotMessages[slot] = nil
        nameEdits[slot] = nil
        expandedSlots.remove(slot)
        let hadName = slot < vm.csNames.count && !vm.csNames[slot].isEmpty
        guard vm.csBindings[slot].isConfigured else {
            // Never applied to the device - just drop the local draft.  A name
            // set for the slot is device state, so clear it there too.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                drafts[slot] = CsBinding()
            }
            if hadName && vm.isDeviceConnected {
                DispatchQueue.global(qos: .userInitiated).async { _ = vm.setCsName(slot: slot, name: "") }
            }
            return
        }
        applyingSlot = slot
        DispatchQueue.global(qos: .userInitiated).async {
            _ = vm.setCsBinding(slot: slot, binding: CsBinding())
            if hadName { _ = vm.setCsName(slot: slot, name: "") }
            DispatchQueue.main.async {
                applyingSlot = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    drafts[slot] = vm.csBindings[slot]   // now cleared on the device
                }
                slotMessages[slot] = nil
            }
        }
    }

    // MARK: Slot section

    @ViewBuilder
    private func slotSection(_ slot: Int) -> some View {
        let b = drafts[slot]
        let expanded = expandedSlots.contains(slot)
        Section {
            cardHeader(slot)

            if b.isConfigured && expanded {
                if vm.csBindings[slot].isConfigured && !vm.csStatus.isSlotActive(slot) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(inactiveReason(slot))
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                if Int(b.type) == CS_TYPE_IR {
                    // The IR receiver is a container: pin + sense, then its
                    // learned remote-button command table (spec §2.7 / §6.8).
                    pinRows(slot)
                    flagToggle(slot, CS_FLAG_INVERT,
                               title: invertTitle(CS_TYPE_IR),
                               detail: invertDetail(CS_TYPE_IR),
                               icon: "bolt")
                    irCommandsSection(slot)
                } else {
                    nounRow(slot)
                    targetRows(slot)
                    if validActions(type: Int(b.type), noun: Int(b.noun)).count > 1 {
                        actionRow(slot)
                    }
                    if Int(b.type) == CS_TYPE_BUTTON {
                        eventRow(slot)
                    }
                    pinRows(slot)
                    operandRows(slot)
                    flagRows(slot)
                }
            }

            // A collapsed card still surfaces pending edits and apply results so
            // nothing actionable hides behind the fold.  Uses the broad
            // slotDirty so a staged remote-button edit keeps the receiver's one
            // Apply/Revert reachable even while the receiver is collapsed.
            if expanded || slotDirty(slot)
                || applyingSlot == slot || slotMessages[slot] != nil {
                applyRow(slot)
            }
        }
    }

    /// The card's identity row: a disclosure chevron, a tinted component badge
    /// (tap to swap the component type), an editable name over the
    /// plain-language summary, a live status pill, and the remove button.
    /// This row is all a collapsed card shows, so it carries everything needed
    /// to tell controls apart at a glance.
    @ViewBuilder
    private func cardHeader(_ slot: Int) -> some View {
        let b = drafts[slot]
        let type = Int(b.type)
        let expanded = expandedSlots.contains(slot)
        let hasName = !slotName(slot).isEmpty
        HStack(spacing: 12) {
            Button { toggleExpanded(slot) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Collapse" : "Expand")

            Menu {
                ForEach(realTypes, id: \.self) { t in
                    Button { typeBinding(slot).wrappedValue = t } label: {
                        Label(typeName(t), systemImage: typeIcon(t))
                    }
                    .disabled(t == CS_TYPE_IR && !irTypeAvailable(forSlot: slot))
                }
            } label: {
                csTypeBadge(type, size: 32)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change the component type")

            VStack(alignment: .leading, spacing: 2) {
                LeftAlignedTextField(text: nameBinding(slot),
                                     placeholder: typeName(type))
                    .frame(maxWidth: 280, alignment: .leading)
                    .help("Click to rename this control")

                // When a custom name hides the component type, restate it in
                // the summary line.
                Text(hasName ? "\(typeName(type)) - \(verbPhrase(b))" : verbPhrase(b))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusPill(slot)
            Button(role: .destructive) {
                removeControl(slot)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("Remove this control")
            // Removing a device-stored binding needs the device; an unapplied
            // draft can be dropped any time.
            .disabled(applyingSlot == slot
                      || (vm.csBindings[slot].isConfigured && !vm.isDeviceConnected))
        }
        .padding(.vertical, 4)
    }

    /// A rounded, tinted gradient badge for a component type - the card's glyph.
    private func csTypeBadge(_ type: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(typeTint(type).gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: typeIcon(type))
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            )
            .shadow(color: typeTint(type).opacity(0.35), radius: 2, y: 1)
    }

    /// Dot-and-text status capsule reflecting the card's state: Pending (orange)
    /// when it holds edits not yet applied to the device (a binding edit or a
    /// staged rename), otherwise the live device state - Active (green) or
    /// Inactive (orange).  This pill is the single status indicator; the apply
    /// row no longer echoes "Applied".  A control auto-applies on add (draft ==
    /// live) so it reads Active, not stuck Pending; an applied-but-unsaved change
    /// surfaces on the global "unsaved changes" bar, not here.
    @ViewBuilder
    private func statusPill(_ slot: Int) -> some View {
        let (text, color): (String, Color) = {
            if slotDirty(slot) { return ("Pending", .orange) }
            if vm.csStatus.isSlotActive(slot) { return ("Active", .green) }
            return ("Inactive", .orange)
        }()
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Noun / Action rows

    @ViewBuilder
    private func nounRow(_ slot: Int) -> some View {
        let type = Int(drafts[slot].type)
        let current = Int(drafts[slot].noun)
        let groups = nounGroups(forType: type)
        settingRow(title: "Controls",
                   detail: "The device function this control drives.",
                   icon: "slider.horizontal.3") {
            Menu {
                if groups.count <= 1 {
                    // A single category: list its functions directly, no submenu.
                    ForEach(groups.first?.nouns ?? [], id: \.self) { n in
                        nounMenuItem(slot, n, type: type, current: current)
                    }
                } else {
                    ForEach(groups, id: \.name) { group in
                        Menu(group.name) {
                            ForEach(group.nouns, id: \.self) { n in
                                nounMenuItem(slot, n, type: type, current: current)
                            }
                        }
                    }
                }
            } label: {
                Text(nounName(current, forType: type))
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    /// One selectable function inside the Controls menu, check-marked when it's
    /// the slot's current noun.
    @ViewBuilder
    private func nounMenuItem(_ slot: Int, _ noun: Int, type: Int, current: Int) -> some View {
        Button { nounBinding(slot).wrappedValue = noun } label: {
            if noun == current {
                Label(nounName(noun, forType: type), systemImage: "checkmark")
            } else {
                Text(nounName(noun, forType: type))
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ slot: Int) -> some View {
        let type = Int(drafts[slot].type)
        let noun = Int(drafts[slot].noun)
        let (title, detail): (String, String) = {
            if isIndicatorType(type) { return ("Indicates", "How the LED reflects the function.") }
            if type == CS_TYPE_BUTTON { return ("On Press", "What a press does.") }
            return ("Behavior", "How this control drives the function.")
        }()
        settingRow(title: title, detail: detail, icon: "hand.tap") {
            Picker("", selection: actionBinding(slot)) {
                ForEach(validActions(type: type, noun: noun), id: \.self) { a in
                    Text(actionName(a, noun: noun)).tag(a)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Button gesture (event)

    /// Which press gesture a button binding responds to (spec §6.1).  Several
    /// button bindings can share one GPIO, one per gesture, to give a single
    /// button multiple functions.
    @ViewBuilder
    private func eventRow(_ slot: Int) -> some View {
        settingRow(title: "Gesture",
                   detail: "Which press gesture triggers this. Bind several to one button GPIO for multiple functions.",
                   icon: "hand.tap.fill") {
            Picker("", selection: Binding(
                get: { drafts[slot].event },
                set: { var nb = drafts[slot]; nb.event = $0; drafts[slot] = nb })) {
                Text("Press").tag(CS_EVENT_PRESS)
                Text("Long press").tag(CS_EVENT_LONG)
                Text("Double press").tag(CS_EVENT_DOUBLE)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Target (channel / band) rows

    /// Channel (and, for filter nouns, band) address for a targeted noun
    /// (spec §4.4).  Hidden for untargeted nouns.
    @ViewBuilder
    private func targetRows(_ slot: Int) -> some View {
        if let nd = nounDesc(Int(drafts[slot].noun)), nd.isTargeted {
            settingRow(title: "Channel",
                       detail: "Which channel this control affects.",
                       icon: "square.stack.3d.up") {
                Picker("", selection: targetBinding(slot)) {
                    ForEach(Array(0..<Int(nd.targetCount)), id: \.self) { t in
                        Text(targetName(nd, t)).tag(t)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if nd.hasBand {
                let bands = bandOptions(noun: Int(drafts[slot].noun), dspChannel: Int(drafts[slot].target))
                settingRow(title: "Band",
                           detail: "Which filter band this control affects.",
                           icon: "waveform.path.ecg") {
                    Picker("", selection: indexBinding(slot)) {
                        ForEach(bands, id: \.self) { band in
                            Text(bandName(band)).tag(band)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    /// Valid filter bands for a DSP_BAND noun on a given DSP channel: PEQ bands
    /// 0-9 always, plus crossover bands 20-23 for FILTER_FREQ / FILTER_BYPASS on
    /// output channels (spec §4.4).
    private func bandOptions(noun: Int, dspChannel: Int) -> [Int] {
        var bands = Array(0..<10)
        let isOutput = dspChannel >= vm.chOut1
        if isOutput && (noun == CS_NOUN_FILTER_FREQ || noun == CS_NOUN_FILTER_BYPASS) {
            bands += [20, 21, 22, 23]
        }
        return bands
    }

    private func targetBinding(_ slot: Int) -> Binding<Int> {
        Binding(
            get: { Int(drafts[slot].target) },
            set: { newTarget in
                var b = drafts[slot]
                b.target = UInt8(newTarget)
                // Re-clamp the band if the new channel doesn't offer the current one.
                if nounDesc(Int(b.noun))?.hasBand == true {
                    let opts = bandOptions(noun: Int(b.noun), dspChannel: newTarget)
                    if !opts.contains(Int(b.index)) { b.index = UInt8(opts.first ?? 0) }
                }
                drafts[slot] = b
            })
    }

    private func indexBinding(_ slot: Int) -> Binding<Int> {
        Binding(
            get: { Int(drafts[slot].index) },
            set: { var nb = drafts[slot]; nb.index = UInt8($0); drafts[slot] = nb })
    }

    // MARK: Pin rows

    @ViewBuilder
    private func pinRows(_ slot: Int) -> some View {
        let type = Int(drafts[slot].type)
        let twoPin = (typeDesc(type)?.pinCount ?? 1) >= 2
        let adc = (typeDesc(type)?.pinClass ?? 0) == CS_PINCLASS_ADC
        if twoPin {
            csPinRow(slot, title: "GPIO A", detail: "Encoder channel A.",
                     icon: "a.circle", isSecond: false, adc: adc)
            csPinRow(slot, title: "GPIO B", detail: "Encoder channel B.",
                     icon: "b.circle", isSecond: true, adc: adc)
        } else {
            csPinRow(slot, title: "GPIO", detail: pinDetail(type),
                     icon: "cable.connector", isSecond: false, adc: adc)
        }
    }

    @ViewBuilder
    private func csPinRow(_ slot: Int, title: String, detail: String,
                          icon: String, isSecond: Bool, adc: Bool) -> some View {
        let candidates = pinCandidates(slot: slot, type: Int(drafts[slot].type), isSecond: isSecond)
        settingRow(title: title, detail: detail, icon: icon) {
            Picker("", selection: Binding(
                get: { isSecond ? drafts[slot].gpio1 : drafts[slot].gpio0 },
                set: { newPin in
                    var nb = drafts[slot]
                    if isSecond { nb.gpio1 = newPin } else { nb.gpio0 = newPin }
                    drafts[slot] = nb
                })) {
                let current = isSecond ? drafts[slot].gpio1 : drafts[slot].gpio0
                if !candidates.contains(current) {
                    Text(current == CS_GPIO_UNUSED ? "None" : "GPIO \(current)").tag(current)
                }
                ForEach(candidates, id: \.self) { p in Text("GPIO \(p)").tag(p) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Value / step / range operands

    @ViewBuilder
    private func operandRows(_ slot: Int) -> some View {
        let b = drafts[slot]
        let noun = Int(b.noun)
        let action = Int(b.action)
        let kind = nounDesc(noun)?.kind ?? CS_KIND_BOOL

        switch action {
        case CS_ACT_ADJUST:
            if kind == CS_KIND_CONTINUOUS {
                csSpanRows(slot, title: "Limit Range",
                           loDetail: "Level at the fully counter-clockwise position.",
                           hiDetail: "Level at the fully clockwise position.")
            }
        case CS_ACT_STEP, CS_ACT_INC, CS_ACT_DEC:
            if kind == CS_KIND_CONTINUOUS {
                csStepRow(slot)
            } else if kind == CS_KIND_ENUM {
                enumStepRow(slot)
            }
        case CS_ACT_SET, CS_ACT_MOMENTARY:
            let verb = action == CS_ACT_MOMENTARY ? "Hold Value" : "Set To"
            if kind == CS_KIND_CONTINUOUS {
                csValueRow(slot, title: verb, detail: "Level each press applies.")
            } else if kind == CS_KIND_BOOL {
                boolValueRow(slot, title: verb)
            } else if kind == CS_KIND_ENUM {
                enumValueRow(slot, title: verb)
            }
        case CS_ACT_IND_EQUALS:
            if kind == CS_KIND_BOOL {
                boolValueRow(slot, title: "Light When")
            } else if kind == CS_KIND_ENUM {
                enumValueRow(slot, title: "Light When")
            }
        case CS_ACT_IND_ABOVE:
            if kind == CS_KIND_CONTINUOUS {
                csValueRow(slot, title: "Light Above", detail: "Light the LED once the value reaches this.")
            }
        case CS_ACT_IND_LEVEL:
            if kind == CS_KIND_CONTINUOUS {
                csSpanRows(slot, title: "Brightness Range",
                           loDetail: "Value mapped to the LED fully off.",
                           hiDetail: "Value mapped to the LED fully lit.")
            }
        default:
            EmptyView()
        }
    }

    /// Unit for a noun (dB / Hz / Q / percent / none), independent of any slot.
    private func unitFor(noun: Int) -> UInt8 {
        nounDesc(noun)?.unit ?? CS_UNIT_DB
    }

    /// A noun's full natural-unit range [lo, hi], independent of any slot.
    private func rangeFor(noun: Int) -> (lo: Float, hi: Float) {
        let nd = nounDesc(noun)
        let unit = nd?.unit ?? CS_UNIT_DB
        return (csDecodeValue(nd?.minQ8 ?? 0, unit: unit), csDecodeValue(nd?.maxQ8 ?? 0, unit: unit))
    }

    /// Unit for the current draft's noun (dB / Hz / Q / percent / none).
    private func nounUnit(_ slot: Int) -> UInt8 { unitFor(noun: Int(drafts[slot].noun)) }

    /// The noun's full natural-unit range [lo, hi].
    private func nounRange(_ slot: Int) -> (lo: Float, hi: Float) { rangeFor(noun: Int(drafts[slot].noun)) }

    /// Optional custom span (rangeMin/rangeMax) with a full-range toggle, used by
    /// pot ADJUST (custom knob span) and PWM LED IND_LEVEL (brightness mapping).
    @ViewBuilder
    private func csSpanRows(_ slot: Int, title: String, loDetail: String, hiDetail: String) -> some View {
        let nd = nounDesc(Int(drafts[slot].noun))
        let unit = nd?.unit ?? CS_UNIT_DB
        let (lo, hi) = nounRange(slot)
        // A custom span is signalled by either range field being non-zero
        // (both zero = the noun's full range).
        let custom = drafts[slot].rangeMin != 0 || drafts[slot].rangeMax != 0
        Toggle(isOn: Binding(
            get: { custom },
            set: { on in
                var nb = drafts[slot]
                if on {
                    nb.rangeMin = nd?.minQ8 ?? 0
                    nb.rangeMax = nd?.maxQ8 ?? 0
                } else {
                    nb.rangeMin = 0
                    nb.rangeMax = 0
                }
                drafts[slot] = nb
            })) {
            settingLabel(title: title,
                         detail: "Map onto a portion of the \(fmtUnit(lo, unit)) to \(fmtUnit(hi, unit)) range.",
                         icon: "arrow.left.and.right")
        }
        .toggleStyle(.switch)

        if custom {
            settingRow(title: "Minimum", detail: loDetail, icon: "arrow.down.to.line") {
                ValueField(label: csUnitSymbol(unit), value: csDecodeValue(drafts[slot].rangeMin, unit: unit),
                           width: 64, scrollStep: unitScrollStep(unit), maxDecimals: unitDecimals(unit)) { v in
                    var nb = drafts[slot]
                    nb.rangeMin = csEncodeValue(min(hi, max(lo, v)), unit: unit)
                    drafts[slot] = nb
                }
            }
            settingRow(title: "Maximum", detail: hiDetail, icon: "arrow.up.to.line") {
                ValueField(label: csUnitSymbol(unit), value: csDecodeValue(drafts[slot].rangeMax, unit: unit),
                           width: 64, scrollStep: unitScrollStep(unit), maxDecimals: unitDecimals(unit)) { v in
                    var nb = drafts[slot]
                    nb.rangeMax = csEncodeValue(min(hi, max(lo, v)), unit: unit)
                    drafts[slot] = nb
                }
            }
        }
    }

    /// Unit-aware step field.  dB / percent step linearly in their unit; Hz / Q
    /// step multiplicatively, so their step is expressed in octaves.
    @ViewBuilder
    private func csStepRow(_ slot: Int) -> some View {
        let unit = nounUnit(slot)
        let isLog = unit == CS_UNIT_HZ || unit == CS_UNIT_Q
        let logStep: Float = 1.0 / 12.0
        let logMin: Float = 1.0 / 48.0
        let dflt: Float = isLog ? logStep : 1.0
        let cur = drafts[slot].step == 0 ? dflt : csDecodeStep(drafts[slot].step, unit: unit)
        settingRow(title: "Step Size",
                   detail: isLog ? "Ratio per detent/press, in octaves." : "Amount added or removed per detent/press.",
                   icon: "plusminus") {
            ValueField(label: isLog ? "oct" : csUnitSymbol(unit),
                       value: cur, width: 64,
                       scrollStep: isLog ? logStep : unitScrollStep(unit),
                       minValue: isLog ? logMin : 0.1,
                       maxDecimals: isLog ? 3 : unitDecimals(unit)) { v in
                var nb = drafts[slot]
                nb.step = csEncodeStep(max(isLog ? logMin : 0.1, v), unit: unit)
                drafts[slot] = nb
            }
        }
    }

    @ViewBuilder
    private func enumStepRow(_ slot: Int) -> some View {
        let maxStep = max(1, Int(nounDesc(Int(drafts[slot].noun))?.enumCount ?? 2) - 1)
        settingRow(title: "Step Size",
                   detail: "Positions advanced per detent/press.",
                   icon: "plusminus") {
            HStack(spacing: 8) {
                Text("\(currentEnumStep(slot))")
                    .font(.body.monospacedDigit())
                    .frame(width: 20, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { currentEnumStep(slot) },
                    set: { var nb = drafts[slot]; nb.step = Int16($0); drafts[slot] = nb }
                ), in: 1...maxStep)
                .labelsHidden()
            }
            .fixedSize()
        }
    }

    private func currentEnumStep(_ slot: Int) -> Int {
        let s = Int(drafts[slot].step)
        return s <= 0 ? 1 : s
    }

    /// Unit-aware single-value field (SET/MOMENTARY target, IND_ABOVE threshold).
    @ViewBuilder
    private func csValueRow(_ slot: Int, title: String, detail: String) -> some View {
        let unit = nounUnit(slot)
        let (lo, hi) = nounRange(slot)
        settingRow(title: title,
                   detail: "\(detail) (\(fmtUnit(lo, unit)) to \(fmtUnit(hi, unit))).",
                   icon: "target") {
            ValueField(label: csUnitSymbol(unit),
                       value: csDecodeValue(drafts[slot].value, unit: unit),
                       width: 64, scrollStep: unitScrollStep(unit), maxDecimals: unitDecimals(unit)) { v in
                var nb = drafts[slot]
                nb.value = csEncodeValue(min(hi, max(lo, v)), unit: unit)
                drafts[slot] = nb
            }
        }
    }

    @ViewBuilder
    private func boolValueRow(_ slot: Int, title: String) -> some View {
        let noun = Int(drafts[slot].noun)
        settingRow(title: title,
                   detail: title == "Light When" ? "Light the LED when the function is in this state."
                                                  : "The state a press applies.",
                   icon: "switch.2") {
            Picker("", selection: Binding(
                get: { drafts[slot].value != 0 },
                set: { var nb = drafts[slot]; nb.value = $0 ? 1 : 0; drafts[slot] = nb })) {
                Text(boolLabel(noun, on: true)).tag(true)
                Text(boolLabel(noun, on: false)).tag(false)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private func enumValueRow(_ slot: Int, title: String) -> some View {
        let noun = Int(drafts[slot].noun)
        let count = Int(nounDesc(noun)?.enumCount ?? 1)
        settingRow(title: title,
                   detail: title == "Light When" ? "Light the LED for this selection."
                                                  : "The selection a press applies.",
                   icon: "list.number") {
            Picker("", selection: Binding(
                get: { Int(drafts[slot].value) },
                set: { var nb = drafts[slot]; nb.value = Int16($0); drafts[slot] = nb })) {
                ForEach(Array(0..<max(1, count)), id: \.self) { i in
                    Text(enumValueLabel(noun: noun, value: i)).tag(i)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Flag toggles

    @ViewBuilder
    private func flagRows(_ slot: Int) -> some View {
        let b = drafts[slot]
        let type = Int(b.type)
        let action = Int(b.action)
        let kind = nounDesc(Int(b.noun))?.kind ?? CS_KIND_BOOL
        let isEnumStep = kind == CS_KIND_ENUM &&
            (action == CS_ACT_STEP || action == CS_ACT_INC || action == CS_ACT_DEC)

        if type == CS_TYPE_POT || type == CS_TYPE_ENCODER {
            flagToggle(slot, CS_FLAG_REVERSE,
                       title: "Reverse Direction",
                       detail: type == CS_TYPE_POT ? "Clockwise decreases the value."
                                                   : "Clockwise steps down.",
                       icon: "arrow.left.arrow.right")
        }
        // Acceleration: encoders only (fast rotation multiplies the step).
        if type == CS_TYPE_ENCODER {
            flagToggle(slot, CS_FLAG_ACCEL,
                       title: "Acceleration",
                       detail: "Fast spins move in larger steps; slow spins stay fine.",
                       icon: "hare")
        }
        if isEnumStep {
            flagToggle(slot, CS_FLAG_WRAP,
                       title: "Wrap Around",
                       detail: "Step past the last position back to the first.",
                       icon: "arrow.triangle.2.circlepath")
        }
        // Auto-repeat: a button INC/DEC bound to the plain press gesture.
        if type == CS_TYPE_BUTTON && (action == CS_ACT_INC || action == CS_ACT_DEC)
            && b.event == CS_EVENT_PRESS {
            flagToggle(slot, CS_FLAG_REPEAT,
                       title: "Repeat While Held",
                       detail: "After holding ~0.4 s the press repeats automatically.",
                       icon: "repeat")
        }
        flagToggle(slot, CS_FLAG_INVERT,
                   title: invertTitle(type),
                   detail: invertDetail(type),
                   icon: "bolt")
    }

    @ViewBuilder
    private func flagToggle(_ slot: Int, _ mask: UInt8, title: String, detail: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { (drafts[slot].flags & mask) != 0 },
            set: { on in
                var nb = drafts[slot]
                if on { nb.flags |= mask } else { nb.flags &= ~mask }
                drafts[slot] = nb
            })) {
            settingLabel(title: title, detail: detail, icon: icon)
        }
        .toggleStyle(.switch)
    }

    // MARK: Apply row

    @ViewBuilder
    private func applyRow(_ slot: Int) -> some View {
        // This one Apply/Revert acts on the whole component, including - for an
        // IR receiver - every staged remote-button edit nested inside it.
        let dirty = slotDirty(slot)
        let applying = applyingSlot == slot
        let status = slotMessages[slot]
        HStack(spacing: 8) {
            // An expanded IR receiver puts "Add Remote Button" on this same row
            // rather than a line of its own.
            if Int(drafts[slot].type) == CS_TYPE_IR && expandedSlots.contains(slot) {
                addRemoteButton
            }
            // The card header's status pill now conveys applied / Pending state,
            // so this row surfaces only an apply failure.
            if let status = status, status.isError, !dirty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(status.message)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer(minLength: 8)
            if applying { ProgressView().controlSize(.small) }
            Button("Revert") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    drafts[slot] = vm.csBindings[slot]
                    nameEdits[slot] = nil   // drop the staged rename too
                    // Drop staged remote-button edits for an IR receiver as well.
                    if Int(drafts[slot].type) == CS_TYPE_IR {
                        for sub in 0..<min(irDrafts.count, vm.csIrCommands.count) {
                            irDrafts[sub] = vm.csIrCommands[sub]
                        }
                        subMessages.removeAll()
                    }
                }
                slotMessages[slot] = nil
            }
            .buttonStyle(.plain)
            .foregroundColor(dirty ? .accentColor : .secondary.opacity(0.5))
            .disabled(!dirty || applying)
            Button("Apply") { applySlot(slot) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!dirty || applying || savingConfig || !vm.isDeviceConnected)
        }
    }

    private func applySlot(_ slot: Int) {
        let binding = drafts[slot]
        let bindingChanged = binding != vm.csBindings[slot]
        let nameToApply = stagedName(slot)   // nil when the rename is a no-op
        // For an IR receiver, gather the learned remote-button drafts that differ
        // from the device so this one Apply pushes them alongside the receiver.
        let irToApply: [(sub: Int, cmd: IrCommand)] = Int(binding.type) == CS_TYPE_IR
            ? (0..<min(irDrafts.count, vm.csIrCommands.count)).compactMap { sub in
                let d = irDrafts[sub]
                guard d != vm.csIrCommands[sub], d.isConfigured || vm.csIrCommands[sub].isConfigured
                else { return nil }
                return (sub, d)
            }
            : []
        applyingSlot = slot
        slotMessages[slot] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            // Push the binding, the staged name, then each dirty remote button;
            // stop reporting on the first failure.
            var status: UInt8 = PIN_CONFIG_SUCCESS
            if bindingChanged {
                status = vm.setCsBinding(slot: slot, binding: binding)
            }
            if let name = nameToApply, status == PIN_CONFIG_SUCCESS {
                status = vm.setCsName(slot: slot, name: name)
            }
            for item in irToApply where status == PIN_CONFIG_SUCCESS {
                status = vm.setCsIrCommand(sub: item.sub, command: item.cmd)
            }
            DispatchQueue.main.async {
                applyingSlot = nil
                drafts[slot] = vm.csBindings[slot]
                nameEdits[slot] = nil   // staged name is now live (or unchanged)
                for item in irToApply {
                    irDrafts[item.sub] = vm.csIrCommands[item.sub]
                    subMessages[item.sub] = nil
                }
                // Success is shown by the status pill (Active); keep a message
                // only when the apply failed.
                let msg = statusMessage(status)
                slotMessages[slot] = msg.isError ? msg : nil
            }
        }
    }

    // MARK: IR remote command table (spec §2.7 / §3.6)
    //
    // The IR receiver is one container binding; its remote buttons are separate
    // 16-byte IrCommand sub-slots, device-global (8 of them).  Each is a
    // button-shaped command (noun/action/target/value/step) fired by a learned
    // protocol+code instead of a GPIO edge.

    /// IR command sub-slots the device exposes (0 on a pre-v3 device).
    private var maxSubs: Int { min(Int(vm.csCaps.maxIrCommands), CS_MAX_IR_COMMANDS) }

    /// True when a sub-slot holds a started draft or a live command.
    private func subOccupied(_ sub: Int) -> Bool {
        (sub < irDrafts.count && irDrafts[sub] != IrCommand())
            || (sub < vm.csIrCommands.count && vm.csIrCommands[sub].isConfigured)
    }

    private var visibleSubs: [Int] { (0..<maxSubs).filter { subOccupied($0) } }
    private var firstFreeSub: Int? { (0..<maxSubs).first { !subOccupied($0) } }

    /// Nouns an IR remote button can drive (button action repertoire).
    private var irNouns: [Int] { validNouns(forType: CS_TYPE_IR) }

    /// Reset an IR command's value/step to sensible defaults for its action+kind;
    /// leaves the learned protocol/code and target/index intact.
    private func defaultIrOperands(for command: IrCommand) -> IrCommand {
        var c = command
        let nd = nounDesc(Int(c.noun))
        let action = Int(c.action)
        let kind = nd?.kind ?? CS_KIND_BOOL
        c.value = 0; c.step = 0; c.flags = 0
        switch action {
        case CS_ACT_INC, CS_ACT_DEC:
            if kind == CS_KIND_ENUM { c.step = 1 }
        case CS_ACT_SET, CS_ACT_MOMENTARY:
            if kind == CS_KIND_CONTINUOUS { c.value = nd?.maxQ8 ?? 0 }
            else if kind == CS_KIND_BOOL { c.value = 1 }
        default:
            break
        }
        return c
    }

    /// The learned-command table shown under an applied IR receiver card.
    @ViewBuilder
    private func irCommandsSection(_ slot: Int) -> some View {
        let receiverLive = vm.csStatus.isSlotActive(slot)
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 2)
            HStack {
                settingLabel(title: "Remote Buttons",
                             detail: "Learn buttons on any remote and bind each to a function.",
                             icon: "av.remote")
                Spacer()
                Text("\(visibleSubs.count)/\(maxSubs)")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !receiverLive {
                Text("Apply the receiver above before learning remote buttons.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            ForEach(visibleSubs, id: \.self) { sub in
                irCommandCard(sub, receiverLive: receiverLive)
            }
            // "Add Remote Button" shares the receiver's Apply/Revert row (see
            // applyRow) rather than taking a line of its own.
        }
    }

    /// The "Add Remote Button" control, shared onto the IR receiver's Apply row.
    @ViewBuilder
    private var addRemoteButton: some View {
        Button { addIrCommand() } label: {
            Text("Add Remote Button")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(firstFreeSub == nil || !vm.isDeviceConnected)
    }

    @ViewBuilder
    private func irCommandCard(_ sub: Int, receiverLive: Bool) -> some View {
        let c = irDrafts[sub]
        let learning = learningSub == sub
        let expanded = expandedSubs.contains(sub)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { toggleExpandedSub(sub) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Collapse" : "Expand")

                irCodeChip(sub)
                // Collapsed cards need enough to tell buttons apart: the learned
                // code chip plus a plain-language summary of what it does.
                if !expanded && c.isConfigured {
                    Text(irVerbPhrase(c))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if learning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancelLearn() }
                        .buttonStyle(.borderless).controlSize(.small)
                } else {
                    Button {
                        startLearn(sub)
                    } label: {
                        Text(c.isConfigured ? "Re-learn" : "Learn Button")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!receiverLive || !vm.isDeviceConnected || learningSub != nil || savingConfig)
                }
                Button(role: .destructive) { removeIrCommand(sub) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless).foregroundColor(.secondary)
                .disabled(applyingSub == sub || learning)
            }
            if learning, let lm = learnMessage {
                Text(lm).font(.caption2).foregroundColor(.secondary)
            }

            if expanded {
                irNounRow(sub)
                irTargetRows(sub)
                if validActions(type: CS_TYPE_IR, noun: Int(c.noun)).count > 1 { irActionRow(sub) }
                irOperandRows(sub)
                irFlagRows(sub)
                // Learn-flow feedback (e.g. "Learned a NEC code").  Applying is
                // done by the receiver's single Apply, not per button.
                if !learning, let msg = subMessages[sub] {
                    HStack(spacing: 6) {
                        Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(msg.isError ? .orange : .green).font(.caption)
                        Text(msg.message).font(.caption).foregroundColor(msg.isError ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private func toggleExpandedSub(_ sub: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if expandedSubs.contains(sub) { expandedSubs.remove(sub) }
            else { expandedSubs.insert(sub) }
        }
    }

    /// One-line summary of a learned remote button's action, for the collapsed
    /// card (mirrors `verbPhrase` for component bindings).
    private func irVerbPhrase(_ c: IrCommand) -> String {
        let noun = nounName(Int(c.noun), forType: CS_TYPE_IR) + irTargetSuffix(c)
        let isEnum = (nounDesc(Int(c.noun))?.kind ?? CS_KIND_BOOL) == CS_KIND_ENUM
        switch Int(c.action) {
        case CS_ACT_INC:       return isEnum ? "Next \(noun)" : "Raise \(noun)"
        case CS_ACT_DEC:       return isEnum ? "Previous \(noun)" : "Lower \(noun)"
        case CS_ACT_TOGGLE:    return "Toggle \(noun)"
        case CS_ACT_SET:       return "Set \(noun)"
        case CS_ACT_MOMENTARY: return "Hold \(noun)"
        case CS_ACT_TRIGGER:   return noun   // the noun carries the verb
        default:               return noun
        }
    }

    /// " (Output 1)" / " (Band 3)" suffix for a targeted IR command's summary.
    private func irTargetSuffix(_ c: IrCommand) -> String {
        guard let nd = nounDesc(Int(c.noun)), nd.isTargeted else { return "" }
        var s = " (\(targetName(nd, Int(c.target)))"
        if nd.hasBand { s += ", \(bandName(Int(c.index)))" }
        return s + ")"
    }

    /// The learned protocol + code chip (or a "not learned yet" placeholder).
    @ViewBuilder
    private func irCodeChip(_ sub: Int) -> some View {
        let c = irDrafts[sub]
        if c.isConfigured {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                Text("\(csIrProtocolName(c.proto)) \(String(format: "0x%08X", c.code))")
                    .font(.caption.monospaced())
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "circle.dashed").foregroundColor(.secondary).font(.caption)
                Text("Not learned").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: IR command editor rows (button-shaped; write to irDrafts[sub])

    @ViewBuilder
    private func irNounRow(_ sub: Int) -> some View {
        let current = Int(irDrafts[sub].noun)
        let groups = nounGroups(forType: CS_TYPE_IR)
        settingRow(title: "Controls",
                   detail: "The device function this remote button drives.",
                   icon: "slider.horizontal.3") {
            Menu {
                if groups.count <= 1 {
                    ForEach(groups.first?.nouns ?? [], id: \.self) { n in irNounMenuItem(sub, n, current: current) }
                } else {
                    ForEach(groups, id: \.name) { group in
                        Menu(group.name) {
                            ForEach(group.nouns, id: \.self) { n in irNounMenuItem(sub, n, current: current) }
                        }
                    }
                }
            } label: {
                Text(nounName(current, forType: CS_TYPE_IR))
            }
            .menuStyle(.button).fixedSize()
        }
    }

    @ViewBuilder
    private func irNounMenuItem(_ sub: Int, _ noun: Int, current: Int) -> some View {
        Button { setIrNoun(sub, noun) } label: {
            if noun == current {
                Label(nounName(noun, forType: CS_TYPE_IR), systemImage: "checkmark")
            } else {
                Text(nounName(noun, forType: CS_TYPE_IR))
            }
        }
    }

    private func setIrNoun(_ sub: Int, _ noun: Int) {
        guard noun != Int(irDrafts[sub].noun) else { return }
        var c = irDrafts[sub]
        c.noun = UInt8(noun); c.target = 0; c.index = 0
        let acts = validActions(type: CS_TYPE_IR, noun: noun)
        if !acts.contains(Int(c.action)) { c.action = UInt8(defaultAction(type: CS_TYPE_IR, noun: noun)) }
        irDrafts[sub] = defaultIrOperands(for: c)
    }

    @ViewBuilder
    private func irActionRow(_ sub: Int) -> some View {
        let noun = Int(irDrafts[sub].noun)
        settingRow(title: "On Press", detail: "What pressing the remote button does.", icon: "hand.tap") {
            Picker("", selection: Binding(
                get: { Int(irDrafts[sub].action) },
                set: { newAction in
                    guard newAction != Int(irDrafts[sub].action) else { return }
                    var c = irDrafts[sub]; c.action = UInt8(newAction)
                    irDrafts[sub] = defaultIrOperands(for: c)
                })) {
                ForEach(validActions(type: CS_TYPE_IR, noun: noun), id: \.self) { a in
                    Text(actionName(a, noun: noun)).tag(a)
                }
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder
    private func irTargetRows(_ sub: Int) -> some View {
        if let nd = nounDesc(Int(irDrafts[sub].noun)), nd.isTargeted {
            settingRow(title: "Channel", detail: "Which channel this affects.", icon: "square.stack.3d.up") {
                Picker("", selection: Binding(
                    get: { Int(irDrafts[sub].target) },
                    set: { newTarget in
                        var c = irDrafts[sub]; c.target = UInt8(newTarget)
                        if nounDesc(Int(c.noun))?.hasBand == true {
                            let opts = bandOptions(noun: Int(c.noun), dspChannel: newTarget)
                            if !opts.contains(Int(c.index)) { c.index = UInt8(opts.first ?? 0) }
                        }
                        irDrafts[sub] = c
                    })) {
                    ForEach(Array(0..<Int(nd.targetCount)), id: \.self) { t in Text(targetName(nd, t)).tag(t) }
                }
                .labelsHidden().fixedSize()
            }
            if nd.hasBand {
                let bands = bandOptions(noun: Int(irDrafts[sub].noun), dspChannel: Int(irDrafts[sub].target))
                settingRow(title: "Band", detail: "Which filter band this affects.", icon: "waveform.path.ecg") {
                    Picker("", selection: Binding(
                        get: { Int(irDrafts[sub].index) },
                        set: { var c = irDrafts[sub]; c.index = UInt8($0); irDrafts[sub] = c })) {
                        ForEach(bands, id: \.self) { band in Text(bandName(band)).tag(band) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func irOperandRows(_ sub: Int) -> some View {
        let c = irDrafts[sub]
        let noun = Int(c.noun)
        let action = Int(c.action)
        let kind = nounDesc(noun)?.kind ?? CS_KIND_BOOL
        switch action {
        case CS_ACT_INC, CS_ACT_DEC:
            if kind == CS_KIND_CONTINUOUS { irStepRow(sub) }
            else if kind == CS_KIND_ENUM { irEnumStepRow(sub) }
        case CS_ACT_SET, CS_ACT_MOMENTARY:
            let verb = action == CS_ACT_MOMENTARY ? "Hold Value" : "Set To"
            if kind == CS_KIND_CONTINUOUS { irValueRow(sub, title: verb) }
            else if kind == CS_KIND_BOOL { irBoolValueRow(sub, title: verb) }
            else if kind == CS_KIND_ENUM { irEnumValueRow(sub, title: verb) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func irStepRow(_ sub: Int) -> some View {
        let unit = unitFor(noun: Int(irDrafts[sub].noun))
        let isLog = unit == CS_UNIT_HZ || unit == CS_UNIT_Q
        let logStep: Float = 1.0 / 12.0
        let logMin: Float = 1.0 / 48.0
        let dflt: Float = isLog ? logStep : 1.0
        let cur = irDrafts[sub].step == 0 ? dflt : csDecodeStep(irDrafts[sub].step, unit: unit)
        settingRow(title: "Step Size",
                   detail: isLog ? "Ratio per press, in octaves." : "Amount added or removed per press.",
                   icon: "plusminus") {
            ValueField(label: isLog ? "oct" : csUnitSymbol(unit), value: cur, width: 64,
                       scrollStep: isLog ? logStep : unitScrollStep(unit),
                       minValue: isLog ? logMin : 0.1,
                       maxDecimals: isLog ? 3 : unitDecimals(unit)) { v in
                var c = irDrafts[sub]; c.step = csEncodeStep(max(isLog ? logMin : 0.1, v), unit: unit); irDrafts[sub] = c
            }
        }
    }

    @ViewBuilder
    private func irEnumStepRow(_ sub: Int) -> some View {
        let maxStep = max(1, Int(nounDesc(Int(irDrafts[sub].noun))?.enumCount ?? 2) - 1)
        settingRow(title: "Step Size", detail: "Positions advanced per press.", icon: "plusminus") {
            HStack(spacing: 8) {
                Text("\(irEnumStep(sub))")
                    .font(.body.monospacedDigit()).frame(width: 20, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { irEnumStep(sub) },
                    set: { var c = irDrafts[sub]; c.step = Int16($0); irDrafts[sub] = c }), in: 1...maxStep)
                    .labelsHidden()
            }
            .fixedSize()
        }
    }

    private func irEnumStep(_ sub: Int) -> Int { let s = Int(irDrafts[sub].step); return s <= 0 ? 1 : s }

    @ViewBuilder
    private func irValueRow(_ sub: Int, title: String) -> some View {
        let unit = unitFor(noun: Int(irDrafts[sub].noun))
        let (lo, hi) = rangeFor(noun: Int(irDrafts[sub].noun))
        settingRow(title: title,
                   detail: "Level each press applies (\(fmtUnit(lo, unit)) to \(fmtUnit(hi, unit))).",
                   icon: "target") {
            ValueField(label: csUnitSymbol(unit), value: csDecodeValue(irDrafts[sub].value, unit: unit),
                       width: 64, scrollStep: unitScrollStep(unit), maxDecimals: unitDecimals(unit)) { v in
                var c = irDrafts[sub]; c.value = csEncodeValue(min(hi, max(lo, v)), unit: unit); irDrafts[sub] = c
            }
        }
    }

    @ViewBuilder
    private func irBoolValueRow(_ sub: Int, title: String) -> some View {
        let noun = Int(irDrafts[sub].noun)
        settingRow(title: title, detail: "The state a press applies.", icon: "switch.2") {
            Picker("", selection: Binding(
                get: { irDrafts[sub].value != 0 },
                set: { var c = irDrafts[sub]; c.value = $0 ? 1 : 0; irDrafts[sub] = c })) {
                Text(boolLabel(noun, on: true)).tag(true)
                Text(boolLabel(noun, on: false)).tag(false)
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder
    private func irEnumValueRow(_ sub: Int, title: String) -> some View {
        let noun = Int(irDrafts[sub].noun)
        let count = Int(nounDesc(noun)?.enumCount ?? 1)
        settingRow(title: title, detail: "The selection a press applies.", icon: "list.number") {
            Picker("", selection: Binding(
                get: { Int(irDrafts[sub].value) },
                set: { var c = irDrafts[sub]; c.value = Int16($0); irDrafts[sub] = c })) {
                ForEach(Array(0..<max(1, count)), id: \.self) { i in Text(enumValueLabel(noun: noun, value: i)).tag(i) }
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder
    private func irFlagRows(_ sub: Int) -> some View {
        let c = irDrafts[sub]
        let noun = Int(c.noun)
        let action = Int(c.action)
        let kind = nounDesc(noun)?.kind ?? CS_KIND_BOOL
        let isEnumStep = kind == CS_KIND_ENUM && (action == CS_ACT_INC || action == CS_ACT_DEC)
        if isEnumStep {
            irFlagToggle(sub, CS_FLAG_WRAP, title: "Wrap Around",
                         detail: "Step past the last position back to the first.",
                         icon: "arrow.triangle.2.circlepath")
        }
        if action == CS_ACT_INC || action == CS_ACT_DEC {
            irFlagToggle(sub, CS_FLAG_REPEAT, title: "Repeat While Held",
                         detail: "Holding the remote button repeats the step.",
                         icon: "repeat")
        }
    }

    private func irFlagToggle(_ sub: Int, _ mask: UInt8, title: String, detail: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { (irDrafts[sub].flags & mask) != 0 },
            set: { on in var c = irDrafts[sub]; if on { c.flags |= mask } else { c.flags &= ~mask }; irDrafts[sub] = c })) {
            settingLabel(title: title, detail: detail, icon: icon)
        }
        .toggleStyle(.switch)
    }

    // MARK: IR command actions

    private func addIrCommand() {
        guard let sub = firstFreeSub else { return }
        var c = IrCommand()
        let noun = irNouns.first ?? CS_NOUN_USER_VOLUME
        c.noun = UInt8(noun)
        c.action = UInt8(defaultAction(type: CS_TYPE_IR, noun: noun))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            irDrafts[sub] = defaultIrOperands(for: c)
            expandedSubs.insert(sub)   // open the new button for editing
        }
        subMessages[sub] = nil
    }

    private func removeIrCommand(_ sub: Int) {
        subMessages[sub] = nil
        expandedSubs.remove(sub)
        guard vm.csIrCommands[sub].isConfigured else {
            irDrafts[sub] = IrCommand()   // never applied - drop the draft
            return
        }
        applyingSub = sub
        DispatchQueue.global(qos: .userInitiated).async {
            _ = vm.setCsIrCommand(sub: sub, command: IrCommand())
            DispatchQueue.main.async {
                applyingSub = nil
                irDrafts[sub] = vm.csIrCommands[sub]
                subMessages[sub] = nil
            }
        }
    }


    // MARK: IR learn flow (spec §3.6.1)

    private func startLearn(_ sub: Int) {
        learningSub = sub
        learnMessage = "Point the remote at the receiver and press the button to learn."
        subMessages[sub] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            guard vm.csIrLearnArm() else {
                DispatchQueue.main.async {
                    learningSub = nil
                    learnMessage = nil
                    subMessages[sub] = ("No IR receiver is active - apply the receiver first.", true)
                }
                return
            }
            // The learn window is 10 s; poll the result a little past that.
            var result: CsIrLearnResult? = nil
            for _ in 0..<115 {
                Thread.sleep(forTimeInterval: 0.1)
                if let r = vm.csIrLearnRead(), r.state != CS_IR_LEARN_STATE_ARMED {
                    result = r
                    break
                }
            }
            DispatchQueue.main.async { finishLearn(sub, result) }
        }
    }

    private func finishLearn(_ sub: Int, _ result: CsIrLearnResult?) {
        // Ignore a stale completion if the user cancelled or moved on.
        guard learningSub == sub else { learnMessage = nil; return }
        learningSub = nil
        learnMessage = nil
        guard let r = result, r.isDone, r.code != 0 else {
            let timedOut = result?.isTimeout ?? false
            subMessages[sub] = (timedOut ? "No remote button was detected - try again." : "Learn stopped.", timedOut)
            return
        }
        var c = irDrafts[sub]
        c.proto = r.proto
        c.code = r.code
        irDrafts[sub] = c
        subMessages[sub] = ("Learned a \(csIrProtocolName(r.proto)) code. Apply to keep it.", false)
    }

    private func cancelLearn() {
        guard let sub = learningSub else { return }
        learningSub = nil
        learnMessage = nil
        subMessages[sub] = ("Learn cancelled.", false)
        DispatchQueue.global(qos: .userInitiated).async { vm.csIrLearnCancel() }
    }

    // MARK: Shared row helpers (mirror the Control Interfaces page)

    @ViewBuilder
    private func settingLabel(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func settingRow<Control: View>(title: String, detail: String, icon: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack {
            settingLabel(title: title, detail: detail, icon: icon)
            Spacer()
            control()
        }
    }

    // MARK: Caps-driven model helpers

    private func typeDesc(_ type: Int) -> CsTypeDesc? {
        (type >= 0 && type < vm.csCaps.types.count) ? vm.csCaps.types[type] : nil
    }

    private func nounDesc(_ noun: Int) -> CsNounDesc? {
        (noun >= 0 && noun < vm.csNounDescs.count) ? vm.csNounDescs[noun] : nil
    }

    /// Configurable component types (every type but NONE), from the caps table.
    private var realTypes: [Int] {
        let n = Int(vm.csCaps.typeCount)
        guard n > 1 else { return [] }
        return Array(1..<n)
    }

    /// The slot currently holding the IR receiver (draft or live), if any.  Only
    /// one IR component is allowed per device (spec §1.4 / §4.2).
    private var irReceiverSlot: Int? {
        (0..<slotCount).first {
            Int(drafts[$0].type) == CS_TYPE_IR || Int(vm.csBindings[$0].type) == CS_TYPE_IR
        }
    }

    /// True when `slot` may become an IR receiver: no other slot already is one.
    private func irTypeAvailable(forSlot slot: Int) -> Bool {
        guard let existing = irReceiverSlot else { return true }
        return existing == slot
    }

    /// Types offerable when adding a control: hide IR once a receiver exists.
    private var addableTypes: [Int] {
        realTypes.filter { $0 != CS_TYPE_IR || irReceiverSlot == nil }
    }

    /// Nouns a given component type can drive (non-empty action intersection).
    private func validNouns(forType type: Int) -> [Int] {
        guard let td = typeDesc(type) else { return [] }
        return (0..<vm.csNounDescs.count).filter { n in
            (vm.csNounDescs[n].actions & td.actions) != 0
        }
    }

    /// Display grouping for the 35-noun Controls picker.  Ordered categories,
    /// each listing the nouns it contains; the menu filters these to the ones a
    /// given component type can actually drive.  A noun not named here (a future
    /// firmware's addition) still appears, under "Other".
    private static let nounCategories: [(name: String, nouns: [Int])] = [
        ("Volume & Mute", [CS_NOUN_USER_VOLUME, CS_NOUN_MASTER_VOLUME, CS_NOUN_USER_MUTE]),
        ("Sound", [CS_NOUN_LOUDNESS, CS_NOUN_CROSSFEED, CS_NOUN_CROSSFEED_PRESET,
                   CS_NOUN_CROSSFEED_ITD, CS_NOUN_EQ_BYPASS, CS_NOUN_LEVELLER,
                   CS_NOUN_LEVELLER_AMOUNT, CS_NOUN_LEVELLER_SPEED, CS_NOUN_LEVELLER_LOOKAHEAD]),
        ("Input & Presets", [CS_NOUN_PRESET, CS_NOUN_INPUT_SOURCE, CS_NOUN_LG_SYNC]),
        ("Channels", [CS_NOUN_PREAMP, CS_NOUN_OUTPUT_GAIN, CS_NOUN_OUTPUT_MUTE, CS_NOUN_OUTPUT_ENABLE]),
        ("Filters", [CS_NOUN_FILTER_FREQ, CS_NOUN_FILTER_GAIN, CS_NOUN_FILTER_Q,
                     CS_NOUN_FILTER_TYPE, CS_NOUN_FILTER_BYPASS]),
        ("Tools", [CS_NOUN_SIGGEN, CS_NOUN_DAC_MUTE_TEST, CS_NOUN_CLIP]),
        ("Status", [CS_NOUN_CLIP_CH, CS_NOUN_LEVEL, CS_NOUN_SPDIF_LOCK, CS_NOUN_SAMPLE_RATE,
                    CS_NOUN_USB_STREAMING, CS_NOUN_ADAT_ACTIVE, CS_NOUN_LG_PRESENT, CS_NOUN_LG_MUTED]),
    ]

    /// The valid nouns for `type`, bucketed into the display categories above
    /// (empty categories dropped, unknown nouns collected under "Other").
    private func nounGroups(forType type: Int) -> [(name: String, nouns: [Int])] {
        let valid = validNouns(forType: type)
        let validSet = Set(valid)
        var used = Set<Int>()
        var groups: [(name: String, nouns: [Int])] = []
        for cat in Self.nounCategories {
            let ns = cat.nouns.filter { validSet.contains($0) }
            guard !ns.isEmpty else { continue }
            ns.forEach { used.insert($0) }
            groups.append((cat.name, ns))
        }
        let others = valid.filter { !used.contains($0) }
        if !others.isEmpty { groups.append(("Other", others)) }
        return groups
    }

    /// Legal actions for a (type, noun) pair = AND of their two action masks.
    private func validActions(type: Int, noun: Int) -> [Int] {
        guard let td = typeDesc(type), let nd = nounDesc(noun) else { return [] }
        let eff = td.actions & nd.actions
        return (0..<16).filter { (eff & CS_ACT_BIT($0)) != 0 }
    }

    /// A sensible default action for a freshly picked (type, noun).
    private func defaultAction(type: Int, noun: Int) -> Int {
        let avail = validActions(type: type, noun: noun)
        guard !avail.isEmpty else { return 0 }
        let pref: [Int]
        switch type {
        case CS_TYPE_POT:     pref = [CS_ACT_ADJUST]
        case CS_TYPE_ENCODER: pref = [CS_ACT_STEP]
        case CS_TYPE_SWITCH:  pref = [CS_ACT_FOLLOW]
        case CS_TYPE_LED:     pref = [CS_ACT_IND_EQUALS, CS_ACT_IND_ABOVE]
        case CS_TYPE_LED_PWM: pref = [CS_ACT_IND_LEVEL, CS_ACT_IND_ABOVE, CS_ACT_IND_EQUALS]
        // A button and an IR remote command share the same action repertoire.
        case CS_TYPE_BUTTON, CS_TYPE_IR:
                              pref = [CS_ACT_TOGGLE, CS_ACT_TRIGGER, CS_ACT_INC, CS_ACT_SET, CS_ACT_DEC, CS_ACT_MOMENTARY]
        default:              pref = []
        }
        for a in pref where avail.contains(a) { return a }
        return avail.first ?? 0
    }

    /// Build a fresh binding when a slot's component type changes.
    private func makeBinding(type: Int, slot: Int) -> CsBinding {
        if type == CS_TYPE_NONE { return CsBinding() }
        // The IR receiver is a container: it carries only its pin and (optional)
        // INVERT sense; noun/action/operands must all be zero (spec §4.2).  Its
        // remote buttons are separate IrCommand sub-slots, not this binding.
        if type == CS_TYPE_IR {
            var ir = CsBinding()
            ir.type = UInt8(CS_TYPE_IR)
            ir.gpio0 = freePins(slot: slot, adcOnly: false).first ?? (HardwareSettingsTab.validPins.first ?? 0)
            ir.gpio1 = CS_GPIO_UNUSED
            return ir
        }
        var b = CsBinding()
        b.type = UInt8(type)
        let noun = validNouns(forType: type).first ?? CS_NOUN_MASTER_VOLUME
        b.noun = UInt8(noun)
        b.action = UInt8(defaultAction(type: type, noun: noun))
        let adc = (typeDesc(type)?.pinClass ?? 0) == CS_PINCLASS_ADC
        let twoPin = (typeDesc(type)?.pinCount ?? 1) >= 2
        let free = freePins(slot: slot, adcOnly: adc)
        b.gpio0 = free.first ?? (adc ? (CS_ADC_PINS.first ?? 26) : (HardwareSettingsTab.validPins.first ?? 0))
        if twoPin {
            b.gpio1 = free.dropFirst().first ?? (b.gpio0 == 0 ? 1 : 0)
        } else {
            b.gpio1 = CS_GPIO_UNUSED
        }
        return defaultOperands(for: b)
    }

    /// Reset value/step/range to sensible defaults for the binding's action+kind.
    /// Leaves `target`/`index` alone (they persist across action edits; the noun
    /// picker resets them when the addressing changes).
    private func defaultOperands(for binding: CsBinding) -> CsBinding {
        var b = binding
        let nd = nounDesc(Int(b.noun))
        let action = Int(b.action)
        let kind = nd?.kind ?? CS_KIND_BOOL
        let unit = nd?.unit ?? CS_UNIT_DB
        b.value = 0; b.step = 0; b.rangeMin = 0; b.rangeMax = 0
        switch action {
        case CS_ACT_STEP, CS_ACT_INC, CS_ACT_DEC:
            // Continuous: step 0 = the firmware unit default (1 dB / 1 % / 1/12
            // octave).  Enum: one position per detent/press.
            if kind == CS_KIND_ENUM { b.step = 1 }
        case CS_ACT_SET, CS_ACT_MOMENTARY:
            if kind == CS_KIND_CONTINUOUS { b.value = nd?.maxQ8 ?? 0 }
            else if kind == CS_KIND_BOOL { b.value = 1 }
        case CS_ACT_IND_EQUALS:
            if kind == CS_KIND_BOOL { b.value = 1 }
        case CS_ACT_IND_ABOVE:
            // Default the LED threshold to a quarter of the way up the range
            // (e.g. -45 dB on a -60..0 level meter).
            if kind == CS_KIND_CONTINUOUS {
                let lo = csDecodeValue(nd?.minQ8 ?? 0, unit: unit)
                let hi = csDecodeValue(nd?.maxQ8 ?? 0, unit: unit)
                b.value = csEncodeValue(lo + 0.25 * (hi - lo), unit: unit)
            }
        default:
            break   // IND_LEVEL / ADJUST use the full range (0,0)
        }
        return b
    }

    private func freePins(slot: Int, adcOnly: Bool) -> [UInt8] {
        let base = adcOnly ? CS_ADC_PINS : HardwareSettingsTab.validPins
        return base.filter { vm.pinInUseBy($0, excluding: .controlSurface(slot)) == nil }
    }

    /// GPIO options for a pin picker: mux-free pins (ADC-only for pots), the
    /// currently-selected pin always kept visible, and the sibling encoder pin
    /// excluded so the two channels can't collide.  A button may additionally
    /// share a GPIO already held by other button bindings (one binding per
    /// gesture; spec §6.1), so those pins stay selectable for a button.
    private func pinCandidates(slot: Int, type: Int, isSecond: Bool) -> [UInt8] {
        let adc = (typeDesc(type)?.pinClass ?? 0) == CS_PINCLASS_ADC
        let base = adc ? CS_ADC_PINS : HardwareSettingsTab.validPins
        let twoPin = (typeDesc(type)?.pinCount ?? 1) >= 2
        let sibling: UInt8? = twoPin ? (isSecond ? drafts[slot].gpio0 : drafts[slot].gpio1) : nil
        let current = isSecond ? drafts[slot].gpio1 : drafts[slot].gpio0
        let isButton = type == CS_TYPE_BUTTON
        return base.filter { p in
            if p == sibling { return false }
            if p == current { return true }
            if vm.pinInUseBy(p, excluding: .controlSurface(slot)) == nil { return true }
            // A button can share a pin whose only other owners are buttons.
            return isButton && csPinButtonShareable(p, excludingSlot: slot)
        }
    }

    /// True when every live Control Surface binding on `pin` (other than
    /// `excludingSlot`) is a button, so another button may share the GPIO.
    /// Returns false if any non-button binding, or a non-CS peripheral, holds it.
    private func csPinButtonShareable(_ pin: UInt8, excludingSlot: Int) -> Bool {
        var sawButton = false
        for s in 0..<min(vm.csBindings.count, CS_MAX_BINDINGS)
        where s != excludingSlot && vm.csStatus.isSlotActive(s) {
            let bind = vm.csBindings[s]
            guard bind.gpio0 == pin || (bind.gpio1 != CS_GPIO_UNUSED && bind.gpio1 == pin) else { continue }
            if Int(bind.type) != CS_TYPE_BUTTON { return false }
            sawButton = true
        }
        return sawButton
    }

    // MARK: Bindings that re-default on structural changes

    private func typeBinding(_ slot: Int) -> Binding<Int> {
        Binding(
            get: { Int(drafts[slot].type) },
            set: { newType in
                if newType != Int(drafts[slot].type) {
                    drafts[slot] = makeBinding(type: newType, slot: slot)
                }
            })
    }

    private func nounBinding(_ slot: Int) -> Binding<Int> {
        Binding(
            get: { Int(drafts[slot].noun) },
            set: { newNoun in
                guard newNoun != Int(drafts[slot].noun) else { return }
                var b = drafts[slot]
                b.noun = UInt8(newNoun)
                // Reset the channel/band address; the new noun may address
                // differently (or not at all).
                b.target = 0
                b.index = 0
                let acts = validActions(type: Int(b.type), noun: newNoun)
                if !acts.contains(Int(b.action)) {
                    b.action = UInt8(defaultAction(type: Int(b.type), noun: newNoun))
                }
                drafts[slot] = defaultOperands(for: b)
            })
    }

    private func actionBinding(_ slot: Int) -> Binding<Int> {
        Binding(
            get: { Int(drafts[slot].action) },
            set: { newAction in
                guard newAction != Int(drafts[slot].action) else { return }
                var b = drafts[slot]
                b.action = UInt8(newAction)
                drafts[slot] = defaultOperands(for: b)
            })
    }

    // MARK: Display labels

    private func typeName(_ type: Int) -> String {
        switch type {
        case CS_TYPE_NONE:    return "None"
        case CS_TYPE_BUTTON:  return "Push Button"
        case CS_TYPE_SWITCH:  return "Toggle Switch"
        case CS_TYPE_POT:     return "Potentiometer / Fader"
        case CS_TYPE_ENCODER: return "Rotary Encoder"
        case CS_TYPE_LED:     return "Indicator LED"
        case CS_TYPE_LED_PWM: return "Dimmable LED"
        case CS_TYPE_IR:      return "IR Remote"
        default:              return "Type \(type)"
        }
    }

    private func typeIcon(_ type: Int) -> String {
        switch type {
        case CS_TYPE_BUTTON:  return "hand.tap"
        case CS_TYPE_SWITCH:  return "switch.2"
        case CS_TYPE_POT:     return "dial.medium"
        case CS_TYPE_ENCODER: return "dial.high"
        case CS_TYPE_LED:     return "lightbulb.fill"
        case CS_TYPE_LED_PWM: return "sun.max.fill"
        case CS_TYPE_IR:      return "av.remote"
        default:              return "dial.medium"
        }
    }

    /// Badge tint per component type.  Cool hues matching the settings sidebar
    /// palette, with warm hues reserved for the LEDs (they are, after all, lights).
    private func typeTint(_ type: Int) -> Color {
        switch type {
        case CS_TYPE_BUTTON:  return Color(red: 0.20, green: 0.62, blue: 0.74)  // cyan
        case CS_TYPE_SWITCH:  return Color(red: 0.15, green: 0.49, blue: 0.62)  // deep teal
        case CS_TYPE_POT:     return Color(red: 0.21, green: 0.49, blue: 0.82)  // blue
        case CS_TYPE_ENCODER: return Color(red: 0.34, green: 0.37, blue: 0.80)  // indigo
        case CS_TYPE_LED:     return Color(red: 0.93, green: 0.63, blue: 0.18)  // amber
        case CS_TYPE_LED_PWM: return Color(red: 0.90, green: 0.45, blue: 0.20)  // warm orange
        case CS_TYPE_IR:      return Color(red: 0.55, green: 0.35, blue: 0.72)  // violet
        default:              return Color(red: 0.46, green: 0.53, blue: 0.62)  // slate
        }
    }

    /// True when this component only shows state (LED or PWM LED).
    private func isIndicatorType(_ type: Int) -> Bool {
        type == CS_TYPE_LED || type == CS_TYPE_LED_PWM
    }

    private func nounName(_ noun: Int, forType type: Int) -> String {
        // A few nouns read differently as an indicator vs. a control: an LED
        // "Clipping" shows the state, while a button's job is the clearing.
        if !isIndicatorType(type) {
            if noun == CS_NOUN_CLIP { return "Clear Clipping" }
            if noun == CS_NOUN_DAC_MUTE_TEST { return "Test DAC Mute" }
        }
        switch noun {
        case CS_NOUN_USER_VOLUME:        return "Volume"
        case CS_NOUN_MASTER_VOLUME:      return "Master Volume"
        case CS_NOUN_USER_MUTE:          return "Mute"
        case CS_NOUN_LOUDNESS:           return "Loudness"
        case CS_NOUN_CROSSFEED:          return "Crossfeed"
        case CS_NOUN_LEVELLER:           return "Volume Leveller"
        case CS_NOUN_PRESET:             return "Preset"
        case CS_NOUN_INPUT_SOURCE:       return "Input Source"
        case CS_NOUN_CLIP:               return "Clipping"
        case CS_NOUN_EQ_BYPASS:          return "EQ Bypass"
        case CS_NOUN_LG_SYNC:            return "LG Sound Sync"
        case CS_NOUN_CROSSFEED_PRESET:   return "Crossfeed Preset"
        case CS_NOUN_CROSSFEED_ITD:      return "Crossfeed ITD"
        case CS_NOUN_LEVELLER_AMOUNT:    return "Leveller Amount"
        case CS_NOUN_LEVELLER_SPEED:     return "Leveller Speed"
        case CS_NOUN_LEVELLER_LOOKAHEAD: return "Leveller Lookahead"
        case CS_NOUN_PREAMP:             return "Input Preamp"
        case CS_NOUN_OUTPUT_GAIN:        return "Output Gain"
        case CS_NOUN_OUTPUT_MUTE:        return "Output Mute"
        case CS_NOUN_OUTPUT_ENABLE:      return "Output Enable"
        case CS_NOUN_FILTER_FREQ:        return "Filter Frequency"
        case CS_NOUN_FILTER_GAIN:        return "Filter Gain"
        case CS_NOUN_FILTER_Q:           return "Filter Q"
        case CS_NOUN_FILTER_TYPE:        return "Filter Type"
        case CS_NOUN_FILTER_BYPASS:      return "Filter Bypass"
        case CS_NOUN_SIGGEN:             return "Test Signal"
        case CS_NOUN_DAC_MUTE_TEST:      return "DAC Mute Test"
        case CS_NOUN_CLIP_CH:            return "Channel Clipping"
        case CS_NOUN_LEVEL:              return "Channel Level"
        case CS_NOUN_SPDIF_LOCK:         return "S/PDIF Lock"
        case CS_NOUN_SAMPLE_RATE:        return "Sample Rate"
        case CS_NOUN_USB_STREAMING:      return "USB Streaming"
        case CS_NOUN_ADAT_ACTIVE:        return "ADAT Active"
        case CS_NOUN_LG_PRESENT:         return "LG Source Present"
        case CS_NOUN_LG_MUTED:           return "LG Muted"
        default:                         return "Parameter \(noun)"
        }
    }

    private func actionName(_ action: Int, noun: Int) -> String {
        let isEnum = (nounDesc(noun)?.kind ?? CS_KIND_BOOL) == CS_KIND_ENUM
        switch action {
        case CS_ACT_ADJUST:     return "Adjust"
        case CS_ACT_STEP:       return "Step"
        case CS_ACT_INC:        return isEnum ? "Next" : "Increase"
        case CS_ACT_DEC:        return isEnum ? "Previous" : "Decrease"
        case CS_ACT_TOGGLE:     return "Toggle"
        case CS_ACT_SET:        return "Set value"
        case CS_ACT_FOLLOW:     return "Follow position"
        case CS_ACT_TRIGGER:    return "Trigger"
        case CS_ACT_IND_EQUALS: return "Indicate"
        case CS_ACT_MOMENTARY:  return "Hold"
        case CS_ACT_IND_ABOVE:  return "Indicate above"
        case CS_ACT_IND_LEVEL:  return "Show level"
        default:                return "Action \(action)"
        }
    }

    /// One-line plain-language summary of the whole binding.
    private func verbPhrase(_ b: CsBinding) -> String {
        if Int(b.type) == CS_TYPE_IR { return "Receives commands from an IR remote." }
        let noun = nounName(Int(b.noun), forType: Int(b.type)) + targetSuffix(b)
        let isEnum = (nounDesc(Int(b.noun))?.kind ?? CS_KIND_BOOL) == CS_KIND_ENUM
        let press = pressWord(b)
        switch Int(b.action) {
        case CS_ACT_ADJUST:     return "Turn to set \(noun)."
        case CS_ACT_STEP:       return "Turn to step \(noun)."
        case CS_ACT_INC:        return isEnum ? "\(press) to select the next \(noun)." : "\(press) to raise \(noun)."
        case CS_ACT_DEC:        return isEnum ? "\(press) to select the previous \(noun)." : "\(press) to lower \(noun)."
        case CS_ACT_TOGGLE:     return "\(press) to toggle \(noun)."
        case CS_ACT_SET:        return "\(press) to set \(noun)."
        case CS_ACT_MOMENTARY:  return "Hold to engage \(noun); releases when let go."
        case CS_ACT_FOLLOW:     return "\(noun) follows the switch position."
        // The noun name carries the verb for a trigger ("Clear Clipping").
        case CS_ACT_TRIGGER:    return "\(press) to \(noun.lowercased())."
        case CS_ACT_IND_EQUALS: return "Lights to indicate \(noun)."
        case CS_ACT_IND_ABOVE:  return "Lights when \(noun) is above a level."
        case CS_ACT_IND_LEVEL:  return "Brightness follows \(noun)."
        default:                return ""
        }
    }

    /// "Press" / "Long-press" / "Double-press" for a button binding's gesture.
    private func pressWord(_ b: CsBinding) -> String {
        guard Int(b.type) == CS_TYPE_BUTTON else { return "Press" }
        switch b.event {
        case CS_EVENT_LONG:   return "Long-press"
        case CS_EVENT_DOUBLE: return "Double-press"
        default:              return "Press"
        }
    }

    /// " (Output 1)" / " (Band 3)" suffix for a targeted binding's summary.
    private func targetSuffix(_ b: CsBinding) -> String {
        guard let nd = nounDesc(Int(b.noun)), nd.isTargeted else { return "" }
        var s = " (\(targetName(nd, Int(b.target)))"
        if nd.hasBand { s += ", \(bandName(Int(b.index)))" }
        return s + ")"
    }

    private func boolLabel(_ noun: Int, on: Bool) -> String {
        switch noun {
        case CS_NOUN_CLIP, CS_NOUN_CLIP_CH: return on ? "Clipping" : "Not clipping"
        case CS_NOUN_USER_MUTE, CS_NOUN_OUTPUT_MUTE, CS_NOUN_LG_MUTED: return on ? "Muted" : "Unmuted"
        case CS_NOUN_SPDIF_LOCK:  return on ? "Locked" : "Unlocked"
        case CS_NOUN_USB_STREAMING, CS_NOUN_ADAT_ACTIVE, CS_NOUN_SIGGEN: return on ? "Active" : "Idle"
        case CS_NOUN_LG_PRESENT:  return on ? "Present" : "Absent"
        default:                  return on ? "On" : "Off"
        }
    }

    private func enumValueLabel(noun: Int, value: Int) -> String {
        switch noun {
        case CS_NOUN_PRESET:
            let name = (value >= 0 && value < vm.presetNames.count) ? vm.presetNames[value] : ""
            return name.isEmpty ? "Preset \(value + 1)" : "Preset \(value + 1) - \(name)"
        case CS_NOUN_INPUT_SOURCE:
            let names = ["USB", "S/PDIF", "I2S"]
            return (value >= 0 && value < names.count) ? names[value] : "Source \(value)"
        case CS_NOUN_SAMPLE_RATE:
            let names = ["44.1 kHz", "48 kHz", "96 kHz"]
            return (value >= 0 && value < names.count) ? names[value] : "Rate \(value)"
        case CS_NOUN_LEVELLER_SPEED:
            let names = ["Slow", "Medium", "Fast"]
            return (value >= 0 && value < names.count) ? names[value] : "Speed \(value)"
        case CS_NOUN_CROSSFEED_PRESET:
            let names = ["Default", "Chu Moy", "Meier", "Custom"]
            return (value >= 0 && value < names.count) ? names[value] : "Preset \(value)"
        case CS_NOUN_FILTER_TYPE:
            let names = ["Flat", "Peaking", "Low Shelf", "High Shelf", "Low Pass",
                         "High Pass", "Notch", "All Pass", "All Pass (1st)",
                         "Low Shelf (1st)", "High Shelf (1st)"]
            return (value >= 0 && value < names.count) ? names[value] : "Type \(value)"
        default:
            return "\(value)"
        }
    }

    /// Display name for a targeted noun's channel address (`target` byte).
    private func targetName(_ nd: CsNounDesc, _ target: Int) -> String {
        func dsp(_ c: Int) -> String {
            (c >= 0 && c < vm.channelNames.count && !vm.channelNames[c].isEmpty)
                ? vm.channelNames[c] : "Channel \(c + 1)"
        }
        switch nd.targetKind {
        case CS_TARGET_INPUT_CH:
            return dsp(target)
        case CS_TARGET_OUTPUT_CH:
            return dsp(target + vm.chOut1)
        default: // DSP_CH / DSP_BAND
            return dsp(target)
        }
    }

    /// Display name for a filter band index (PEQ 0-9, crossover 20-23).
    private func bandName(_ band: Int) -> String {
        if band >= 20 && band <= 23 { return "Crossover \(band - 19)" }
        return "Band \(band + 1)"
    }

    private func pinDetail(_ type: Int) -> String {
        switch type {
        case CS_TYPE_POT:                    return "ADC pin (GPIO 26, 27, or 28), wiper to the pin."
        case CS_TYPE_LED, CS_TYPE_LED_PWM:   return "Output pin driving the LED."
        case CS_TYPE_IR:                     return "GPIO wired to the receiver module's OUT (VCC to 3V3, GND to GND)."
        default:                             return "Wired between this GPIO and GND."
        }
    }

    private func invertTitle(_ type: Int) -> String {
        switch type {
        case CS_TYPE_LED, CS_TYPE_LED_PWM:   return "Active-Low LED"
        case CS_TYPE_POT, CS_TYPE_ENCODER:   return "Pull-Down Wiring"
        case CS_TYPE_IR:                     return "Idle-Low Receiver"
        default:                             return "Active-High Wiring"
        }
    }

    private func invertDetail(_ type: Int) -> String {
        switch type {
        case CS_TYPE_LED:
            return "Drive the pin low to light the LED (LED wired to 3V3 through a resistor)."
        case CS_TYPE_LED_PWM:
            return "Invert the PWM duty for an LED wired to 3V3 through a resistor."
        case CS_TYPE_POT, CS_TYPE_ENCODER:
            return "Wire the common terminal to 3V3 instead of GND (internal pull-down)."
        case CS_TYPE_IR:
            return "The receiver idles low and pulls high on a mark; default is the usual idle-high, active-low module."
        default:
            return "Component wired to 3V3 with the internal pull-down; default is to GND with pull-up."
        }
    }

    private func fmtDb(_ v: Float) -> String {
        String(format: "%.1f dB", v)
    }

    /// Format a natural-unit value with its unit symbol (Hz integer, Q two
    /// decimals, dB/percent one decimal).
    private func fmtUnit(_ v: Float, _ unit: UInt8) -> String {
        switch unit {
        case CS_UNIT_HZ:      return String(format: "%.0f Hz", v)
        case CS_UNIT_Q:       return String(format: "Q %.2f", v)
        case CS_UNIT_PERCENT: return String(format: "%.0f %%", v)
        case CS_UNIT_DB:      return String(format: "%.1f dB", v)
        default:              return String(format: "%.0f", v)
        }
    }

    /// Scroll-wheel / field increment appropriate to a unit.
    private func unitScrollStep(_ unit: UInt8) -> Float {
        switch unit {
        case CS_UNIT_HZ:      return 10
        case CS_UNIT_Q:       return 0.1
        case CS_UNIT_PERCENT: return 1
        default:              return 0.5   // dB
        }
    }

    /// Field decimal places appropriate to a unit (Hz/percent whole, Q fine).
    private func unitDecimals(_ unit: UInt8) -> Int {
        switch unit {
        case CS_UNIT_HZ, CS_UNIT_PERCENT: return 0
        case CS_UNIT_Q:                   return 2
        default:                          return 1   // dB
        }
    }

    /// Why a stored-but-enabled binding isn't running (from its slot health code).
    private func inactiveReason(_ slot: Int) -> String {
        let code = vm.csStatus.slotHealth(slot)
        let base = statusMessage(code).message
        return "Not running: \(base.lowercased()) Reassign the conflicting pin, then apply."
    }

    /// Map a PIN_CONFIG_* / CS_STATUS_* apply outcome to inline feedback.
    private func statusMessage(_ code: UInt8) -> (message: String, isError: Bool) {
        switch code {
        case PIN_CONFIG_SUCCESS:        return ("Applied", false)
        case PIN_CONFIG_INVALID_PIN:    return ("A pin is out of range, or an encoder's two pins are equal", true)
        case PIN_CONFIG_PIN_IN_USE:     return ("A pin is already claimed by another peripheral or binding", true)
        case CS_STATUS_INVALID_TYPE:    return ("Unsupported component type", true)
        case CS_STATUS_INVALID_NOUN:    return ("Unsupported function", true)
        case CS_STATUS_INVALID_ACTION:  return ("That action isn't allowed for this component and function", true)
        case CS_STATUS_INVALID_VALUE:   return ("A value, step, range, or flag is out of bounds", true)
        case CS_STATUS_PIN_NOT_ADC:     return ("A potentiometer must use an ADC pin (GPIO 26, 27, or 28)", true)
        case CS_STATUS_INVALID_SLOT:    return ("Invalid slot", true)
        case CS_STATUS_PENDING:         return ("Still applying, please retry", true)
        case CS_STATUS_INVALID_TARGET:  return ("The selected channel or band isn't valid for this function", true)
        case CS_STATUS_INVALID_EVENT:   return ("That press gesture isn't allowed here", true)
        case CS_STATUS_PWM_CONFLICT:    return ("This PWM LED pin conflicts with another dimmable LED", true)
        case CS_STATUS_EVENT_IN_USE:    return ("Another button already uses this GPIO and gesture", true)
        case CS_STATUS_BUSY:            return ("The device was busy; please try again", true)
        case CS_STATUS_FLASH_ERROR:     return ("The device could not write to flash", true)
        case CS_STATUS_IR_IN_USE:       return ("Another slot already holds the IR receiver (one per device)", true)
        case CS_STATUS_NO_IR:           return ("Add an IR receiver before learning a remote button", true)
        default:                        return ("Failed to apply the binding", true)
        }
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

    // Valid GPIO pins - mirrors firmware is_valid_gpio_pin(): 0-22 and 26-28.
    // Excludes 23-25 (power/LED).  GPIO 16/17 are general-purpose again since
    // the debug UART was removed, and GPIO 12 (the ADAT default) is likewise
    // free.  RP2350 additionally allows GPIO 29, but this list is shared with
    // RP2040 (max GPIO 28), so 29 is not offered.
    static let validPins: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
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

    /// Apply an I2S input channel-count change (already on the main actor; the
    /// SET itself runs off-thread).  A raise can be rejected if a newly-active
    /// pair's pin clashes, or on a stereo-only part — surface the reason.
    private func setI2SChannelCount(_ count: Int) {
        // Captured before the SET so we know which pairs the raise newly
        // activates (the firmware validates exactly those pins).
        let oldCount = vm.i2sInputChannels
        SettingsSaveCoordinator.shared.beginOutputEdit()
        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.setI2SInputChannels(count)
            DispatchQueue.main.async {
                switch status {
                case PIN_CONFIG_SUCCESS:
                    statusMessage = "I2S input set to \(count) channels (\(count / 2) pair\(count / 2 == 1 ? "" : "s"))"
                    statusIsError = false
                case PIN_CONFIG_PIN_IN_USE where count > oldCount:
                    // The firmware only returns a status byte, so name the
                    // offending pin(s)/owner(s) ourselves: pinInUseBy mirrors the
                    // firmware's per-pair activation check.
                    let conflicts = i2sRaiseConflicts(from: oldCount, to: count)
                    if conflicts.isEmpty {
                        statusMessage = "Can't switch to \(count) channels: a required data pin is already in use. Reassign the new pairs' pins, then try again."
                    } else {
                        statusMessage = "Can't switch to \(count) channels - "
                            + conflicts.joined(separator: "; ")
                            + ". Reassign \(conflicts.count == 1 ? "it" : "them"), then try again."
                    }
                    statusIsError = true
                    vm.fetchI2SInputConfig()
                default:
                    handleI2SInputStatus(status, label: "channel count", gpio: nil)
                }
            }
        }
    }

    /// For a raise from `oldCount` to `newCount` channels, return human-readable
    /// "GPIO N (pair P) is used by <owner>" strings for each newly-activated pair
    /// whose data pin clashes.  Mirrors the firmware's check_i2s_rx_pin so the
    /// message matches what the device rejected.
    private func i2sRaiseConflicts(from oldCount: Int, to newCount: Int) -> [String] {
        let oldPairs = max(1, oldCount / 2)
        let newPairs = newCount / 2
        var out: [String] = []
        for pair in oldPairs..<newPairs where vm.i2sRxPins.indices.contains(pair) {
            let pin = vm.i2sRxPins[pair]
            if let owner = vm.pinInUseBy(pin, excluding: .i2sRx(pair)) {
                out.append("GPIO \(pin) (pair \(pair + 1)) is used by \(owner)")
            }
        }
        return out
    }

    /// Map a PIN_CONFIG_* status from an I2S input SET into the shared status row,
    /// and resync the UI from the device on any rejection (the device kept its
    /// previous state, so a GET realigns our pickers).  Main-actor only.
    private func handleI2SInputStatus(_ status: UInt8, label: String, gpio: UInt8?) {
        switch status {
        case PIN_CONFIG_SUCCESS:
            statusMessage = gpio.map { "\(label) set to GPIO \($0)" } ?? "\(label) updated"
            statusIsError = false
        case PIN_CONFIG_PIN_IN_USE:
            if let g = gpio, let owner = pinInUseBy(g, excluding: nil) {
                statusMessage = "GPIO \(g) is already assigned to \(owner)"
            } else {
                statusMessage = "That pin is already in use"
            }
            statusIsError = true
            vm.fetchI2SInputConfig()
        case PIN_CONFIG_INVALID_PIN:
            statusMessage = gpio.map { "GPIO \($0) isn't available on this device" } ?? "Invalid \(label)"
            statusIsError = true
            vm.fetchI2SInputConfig()
        case PIN_CONFIG_INVALID_OUTPUT:
            statusMessage = "Multichannel I2S isn't supported on this device"
            statusIsError = true
            vm.fetchI2SInputConfig()
        case PIN_CONFIG_OUTPUT_ACTIVE:
            statusMessage = "Can't change the bit clock while an I2S output is active"
            statusIsError = true
            vm.fetchI2SInputConfig()
        default:
            statusMessage = "Failed to set \(label)"
            statusIsError = true
            vm.fetchI2SInputConfig()
        }
    }

    /// Change the I2S clock-pin mode (unified/split) via 0xFE, marking the
    /// output config dirty and mapping the PIN_CONFIG_* status into the status
    /// row.  On rejection we re-GET so the picker snaps back to the live mode.
    private func setI2SClockPinMode(_ mode: UInt8) {
        SettingsSaveCoordinator.shared.beginOutputEdit()
        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.setI2SClockPinMode(mode)
            DispatchQueue.main.async {
                switch status {
                case PIN_CONFIG_SUCCESS:
                    statusMessage = mode == I2S_CLOCK_PIN_MODE_SPLIT
                        ? "Separate clock pins - slave uses GPIO \(vm.i2sBckPinSlave)/\(vm.i2sBckPinSlave &+ 1)"
                        : "Shared clock pins for master and slave"
                    statusIsError = false
                case PIN_CONFIG_PIN_IN_USE:
                    statusMessage = "Slave clock pair GPIO \(vm.i2sBckPinSlave)/\(vm.i2sBckPinSlave &+ 1) conflicts with another function - move it first"
                    statusIsError = true
                    vm.fetchI2SClockPinMode()
                case PIN_CONFIG_OUTPUT_ACTIVE:
                    statusMessage = "Switch I2S output slots to S/PDIF before changing clock pins"
                    statusIsError = true
                    vm.fetchI2SClockPinMode()
                default:
                    statusMessage = "Failed to change clock pins"
                    statusIsError = true
                    vm.fetchI2SClockPinMode()
                }
            }
        }
    }

    /// Move the slave-mode BCK pair via 0xC2 role 1, marking the output config
    /// dirty and mapping the PIN_CONFIG_* status into the status row.
    private func setI2SSlaveBckPin(_ pin: UInt8) {
        SettingsSaveCoordinator.shared.beginOutputEdit()
        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.setI2SBckPin(pin, role: I2S_BCK_ROLE_SLAVE)
            DispatchQueue.main.async {
                switch status {
                case PIN_CONFIG_SUCCESS:
                    statusMessage = "Slave BCK pin set to GPIO \(pin), LRCLK = GPIO \(pin &+ 1)"
                    statusIsError = false
                case PIN_CONFIG_PIN_IN_USE:
                    statusMessage = "GPIO \(pin) or \(pin &+ 1) is already in use"
                    statusIsError = true
                    vm.fetchI2SBckPin(role: I2S_BCK_ROLE_SLAVE)
                case PIN_CONFIG_OUTPUT_ACTIVE:
                    statusMessage = "Can't move the slave clock pins while an I2S output is active"
                    statusIsError = true
                    vm.fetchI2SBckPin(role: I2S_BCK_ROLE_SLAVE)
                case PIN_CONFIG_INVALID_PIN:
                    statusMessage = "GPIO \(pin) isn't available on this device"
                    statusIsError = true
                    vm.fetchI2SBckPin(role: I2S_BCK_ROLE_SLAVE)
                default:
                    statusMessage = "Failed to set slave BCK pin"
                    statusIsError = true
                    vm.fetchI2SBckPin(role: I2S_BCK_ROLE_SLAVE)
                }
            }
        }
    }

    /// GPIO options for the ADAT data pin: the standard valid pins plus the
    /// platform default (GPIO 12, which the shared list omits), de-duplicated
    /// and sorted.  Pins owned by another consumer are filtered out, but the
    /// current selection is always kept so the picker renders it.
    private var adatPinOptions: [UInt8] {
        let current = vm.adatPin
        var seen = Set<UInt8>()
        return ([ADAT_PIN_DEFAULT] + Self.validPins)
            .filter { seen.insert($0).inserted }
            .sorted()
            .filter { $0 == current || pinInUseBy($0, excluding: .adatOut) == nil }
    }

    /// Map an ADAT SET status byte (enable or pin change) onto the inline
    /// status row, re-syncing local state from the device on any rejection.
    /// `label` is the human-readable action ("enabled" / "disabled" / "pin").
    private func handleAdatStatus(_ status: UInt8, label: String, gpio: UInt8?) {
        switch status {
        case PIN_CONFIG_SUCCESS:
            if label == "pin", let g = gpio {
                statusMessage = "ADAT data pin set to GPIO \(g)"
            } else {
                statusMessage = "ADAT output \(label)"
            }
            statusIsError = false
        case PIN_CONFIG_PIN_IN_USE:
            if let g = gpio, let owner = pinInUseBy(g, excluding: .adatOut) {
                statusMessage = "GPIO \(g) is already assigned to \(owner)"
            } else {
                statusMessage = "That pin is already in use"
            }
            statusIsError = true
            vm.fetchAdatStatus()
        case PIN_CONFIG_INVALID_PIN:
            statusMessage = gpio.map { "GPIO \($0) isn't available on this device" } ?? "Invalid ADAT pin"
            statusIsError = true
            vm.fetchAdatStatus()
        case PIN_CONFIG_INVALID_OUTPUT:
            statusMessage = "ADAT output isn't supported on this device"
            statusIsError = true
            vm.fetchAdatStatus()
        default:
            statusMessage = label == "pin" ? "Failed to set ADAT pin" : "Failed to \(label == "enabled" ? "enable" : "disable") ADAT output"
            statusIsError = true
            vm.fetchAdatStatus()
        }
    }

    /// GPIO options for the ADAT input RX pin.  No default pin is free, so the
    /// list is just the standard valid pins minus those owned by another
    /// consumer (the loopback exception lets it keep the ADAT output pin).  The
    /// current selection is always kept so the picker renders it.
    private var adatInputPinOptions: [UInt8] {
        let current = vm.adatInputPin
        return Self.validPins.filter { $0 == current || pinInUseBy($0, excluding: .adatIn) == nil }
    }

    /// Map an ADAT input SET status byte (enable / pin / clock mode) onto the
    /// inline status row, re-syncing local state from the device on any rejection.
    /// `label` is the human-readable action ("enabled" / "disabled" / "pin" /
    /// "clock mode").
    private func handleAdatInputStatus(_ status: UInt8, label: String, gpio: UInt8?) {
        switch status {
        case PIN_CONFIG_SUCCESS:
            switch label {
            case "pin":     statusMessage = gpio.map { "ADAT input pin set to GPIO \($0)" } ?? "ADAT input pin cleared"
            case "enabled": statusMessage = "ADAT input enabled"
            case "disabled": statusMessage = "ADAT input disabled"
            default:        statusMessage = "ADAT input \(label) updated"
            }
            statusIsError = false
        case PIN_CONFIG_PIN_IN_USE:
            if label == "disabled" {
                statusMessage = "Switch to another input source before disabling ADAT input"
            } else if let g = gpio, let owner = pinInUseBy(g, excluding: .adatIn) {
                statusMessage = "GPIO \(g) is already assigned to \(owner)"
            } else {
                statusMessage = "That pin is already in use"
            }
            statusIsError = true
            vm.fetchAdatInputConfig()
        case PIN_CONFIG_INVALID_PIN:
            if label == "enabled" {
                statusMessage = "Assign a valid data pin before enabling ADAT input"
            } else {
                statusMessage = gpio.map { "GPIO \($0) isn't available on this device" } ?? "Invalid ADAT input pin"
            }
            statusIsError = true
            vm.fetchAdatInputConfig()
        case PIN_CONFIG_INVALID_OUTPUT:
            statusMessage = "ADAT input isn't supported on this device"
            statusIsError = true
            vm.fetchAdatInputConfig()
        default:
            statusMessage = "Failed to set ADAT input \(label)"
            statusIsError = true
            vm.fetchAdatInputConfig()
        }
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
                vm.fetchI2SClockPinMode()
                vm.fetchMckEnable()
                vm.fetchMckPin()
                vm.fetchMckMultiplier()
                vm.fetchSampleRate()
                if vm.inputSourceSupported {
                    vm.fetchSpdifInputConfig()
                    vm.fetchI2SInputConfig()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    vm.fetchAdatConfig()
                    vm.fetchAdatInputConfig()
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

                // Clock-pin mode (unified/split) - clock_pins_spec.md.  Shared
                // uses the BCK pair above for both master and slave clocking;
                // Separate routes slave clocking to its own pair (below), so a
                // board can wire both roles at once.  Hidden on firmware that
                // predates the feature.
                if vm.i2sClockPinModeSupported {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Clock Pins")
                                .font(.body)
                            Text("Unified: Master and Slave modes share pins.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Split: Separate pins for Master and Slave modes.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.i2sClockPinMode },
                            set: { setI2SClockPinMode($0) }
                        )) {
                            Text("Unified").tag(I2S_CLOCK_PIN_MODE_UNIFIED)
                            Text("Split").tag(I2S_CLOCK_PIN_MODE_SPLIT)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    // Slave-pair BCK picker.  Editable only in SPLIT; shown as
                    // stored-but-inactive in UNIFIED (spec §7).  Candidates need
                    // both BCK and LRCLK (pin+1) free, and the current selection
                    // is always kept so the picker renders it.
                    HStack {
                        Image(systemName: "waveform.path.badge.plus")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Slave BCK Pin")
                                .font(.body)
                            Text(vm.i2sClockPinMode == I2S_CLOCK_PIN_MODE_SPLIT
                                 ? "LRCK: GPIO \(vm.i2sBckPinSlave &+ 1) (BCK + 1)"
                                 : "Stored but inactive while clock pins are shared.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.i2sBckPinSlave },
                            set: { setI2SSlaveBckPin($0) }
                        )) {
                            ForEach(Self.validPins.filter { p in
                                p == vm.i2sBckPinSlave ||
                                (pinInUseBy(p, excluding: .i2sBckSlave) == nil
                                 && pinInUseBy(p &+ 1, excluding: .i2sBckSlave) == nil)
                            }, id: \.self) { pin in
                                Text("GPIO \(pin)").tag(pin)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(vm.i2sClockPinMode != I2S_CLOCK_PIN_MODE_SPLIT)
                    }
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
                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Master Clock (MCK)")
                            Text(vm.i2sSlaveActive
                                 ? "Forced off in I2S slave mode; a local MCK would be asynchronous to the external clocks. Kept and restored when leaving slave mode."
                                 : "Clock reference for external DACs")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(vm.i2sSlaveActive)

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
                    .disabled(vm.mckEnabled || vm.i2sSlaveActive)
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
                    .disabled(mck256UnsupportedAtCurrentRate || vm.i2sSlaveActive)
                }

                if mck256UnsupportedAtCurrentRate {
                    HStack {
                        Spacer()
                        Text("Locked to 128x at \(sampleRateLabel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // I2S input sample rate — DSPi is the rate authority in I2S
                // input mode, so the source (ADC) follows.  Lives here with the
                // other I2S clocking controls rather than on the input page.
                if vm.i2sInputSupported {
                    HStack {
                        Image(systemName: "metronome")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Input Sample Rate")
                                .font(.body)
                            // In the clock-slave role the external master owns the
                            // rate, so this selector only stores the master-mode
                            // preference; show the auto-detected rate read-only.
                            Text(vm.i2sSlaveActive
                                 ? "Rate used in master mode. In slave mode the external master sets the rate (detected: \(vm.i2sSlaveStatus.detectedRateString))."
                                 : "Rate for I2S input; DSPi drives the clocks, so the source must follow.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.i2sInputRateHz },
                            set: { newRate in
                                SettingsSaveCoordinator.shared.beginOutputEdit()
                                DispatchQueue.global(qos: .userInitiated).async {
                                    vm.setInputRate(newRate)
                                }
                            }
                        )) {
                            ForEach(I2S_INPUT_RATES_HZ, id: \.self) { hz in
                                Text("\(hz % 1000 == 0 ? "\(hz / 1000)" : String(format: "%.1f", Double(hz) / 1000)) kHz").tag(hz)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(vm.i2sSlaveActive)
                    }
                }

                statusRow
            }
            }

            // MARK: Inputs
            if section == .spdif && vm.inputSourceSupported {
                Section {
                    // Number of S/PDIF inputs — 1..3.  Optional inputs 2/3 share
                    // the single receiver; the count selector enables inputs 1..N
                    // and disables the rest.  Only shown on firmware that
                    // advertises the optional inputs (multiSpdifSupported).
                    if vm.multiSpdifSupported {
                        HStack {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Instances")
                                    .font(.body)
                                Text("\(vm.spdifEnabledCount) selectable input\(vm.spdifEnabledCount == 1 ? "" : "s") sharing one receiver")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.spdifEnabledCount },
                                set: { setSpdifInputCount($0) }
                            )) {
                                ForEach(1...max(1, vm.spdifInputCount), id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }

                    // One GPIO pin row per active input (1..N).  Rows appear/hide
                    // as the count selector above changes.
                    let shownCount = vm.multiSpdifSupported ? vm.spdifEnabledCount : 1
                    ForEach(Array(0..<shownCount), id: \.self) { idx in
                        spdifInputRow(index: idx)
                    }

                    // LG Sound Sync decodes the LG TV's TOSLINK (S/PDIF)
                    // signaling, so it lives within the S/PDIF Input section.
                    Toggle(isOn: Binding(
                        get: { vm.lgSoundSyncEnabled },
                        set: { en in
                            vm.lgSoundSyncEnabled = en
                            DispatchQueue.global(qos: .userInitiated).async {
                                vm.setLgSoundSyncEnabled(en)
                            }
                        }
                    )) {
                        HStack {
                            Image(systemName: "av.remote")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("LG Sound Sync")
                                    .font(.body)
                                Text("Decode the LG TV's TOSLINK volume + mute signaling and apply it as the host volume - TV remote becomes the volume control. Per-preset; saved with the active preset.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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

                    statusRow
                } header: {
                    Label("S/PDIF Input", systemImage: "arrow.down.to.line")
                }
            }

            // MARK: I2S Input
            if section == .spdif && vm.i2sInputSupported {
                Section {
                    // Clock mode — MASTER (DSPi drives BCK/LRCLK, app picks the
                    // rate) or SLAVE (an external master drives the clocks and the
                    // rate is auto-detected).  Only meaningful while the input
                    // source is I2S; stored and applied at the next switch into
                    // I2S otherwise.  Hidden on firmware that predates the feature.
                    if vm.i2sClockModeSupported {
                        HStack {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Clock Mode")
                                    .font(.body)
                                Text("Master: DSPi drives BCK/LRCLK. Slave: an external master drives the clocks and the rate is auto-detected.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.i2sClockMode },
                                set: { newMode in
                                    guard newMode != vm.i2sClockMode else { return }
                                    let apply = {
                                        SettingsSaveCoordinator.shared.beginOutputEdit()
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            vm.setI2SClockMode(newMode)
                                        }
                                    }
                                    // Switching the input clock role restarts the I2S
                                    // clocking, which can momentarily glitch a connected
                                    // I2S DAC.  Warn before doing so while any output slot
                                    // is driving an I2S DAC.
                                    if vm.anySlotIsI2S {
                                        let alert = NSAlert()
                                        alert.messageText = "Change I2S clock mode?"
                                        alert.informativeText = "One or more I2S outputs are active. Switching between Master and Slave modes may cause sustained loud noises to be emitted by the connected I2S DAC if wiring has not been adjusted."
                                        alert.alertStyle = .critical
                                        alert.addButton(withTitle: "Change Clock Mode")
                                        alert.addButton(withTitle: "Cancel")
                                        if alert.runModal() == .alertFirstButtonReturn {
                                            apply()
                                        }
                                    } else {
                                        apply()
                                    }
                                }
                            )) {
                                Text("Master").tag(I2S_CLOCK_MODE_MASTER)
                                Text("Slave").tag(I2S_CLOCK_MODE_SLAVE)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }

                        // Live lock indicator, shown while the device is actually
                        // running in the slave role (mode=slave AND source=I2S).
                        // ACQUIRING / RELOCKING / INACTIVE collapse to a single
                        // "waiting for external clock" reading with the raw
                        // measured rate as a diagnostic (spec §7).
                        if vm.i2sSlaveActive {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Lock Status")
                                        .font(.body)
                                    Text(vm.i2sSlaveStatus.isLocked
                                         ? "Locked to external clock at \(vm.i2sSlaveStatus.detectedRateString)."
                                         : "Waiting for external clock (measured \(vm.i2sSlaveStatus.measuredHzString)).")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(vm.i2sSlaveStatus.stateColor)
                                        .frame(width: 6, height: 6)
                                    Text(vm.i2sSlaveStatus.stateString)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    // Channel count — 1..4 stereo pairs.  Multichannel (>2) is
                    // RP2350-only; on a stereo-only part this shows a static "2".
                    HStack {
                        Image(systemName: "rectangle.split.3x1")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Channels")
                                .font(.body)
                            Text("\(vm.i2sActivePairs) stereo pair\(vm.i2sActivePairs == 1 ? "" : "s") of 24-bit audio, sample-aligned")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if vm.i2sMaxInputChannels <= 2 {
                            Text("2")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                        } else {
                            Picker("", selection: Binding(
                                get: { vm.i2sInputChannels },
                                set: { setI2SChannelCount($0) }
                            )) {
                                ForEach(Array(stride(from: 2, through: vm.i2sMaxInputChannels, by: 2)), id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }

                    // One data-pin picker per active stereo pair.  Pair p carries
                    // input channels 2p, 2p+1.
                    ForEach(Array(0..<vm.i2sActivePairs), id: \.self) { pair in
                        HStack {
                            Image(systemName: "cable.connector")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Serial Data \(pair + 1)")
                                    .font(.body)
                                Text("GPIO data pin for input channels \(pair * 2 + 1)-\(pair * 2 + 2)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.i2sRxPins.indices.contains(pair) ? vm.i2sRxPins[pair] : 0 },
                                set: { newPin in
                                    SettingsSaveCoordinator.shared.beginOutputEdit()
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let status = vm.setI2SRxPin(pair: pair, newPin)
                                        DispatchQueue.main.async {
                                            handleI2SInputStatus(status, label: "Serial Data \(pair + 1)", gpio: newPin)
                                        }
                                    }
                                }
                            )) {
                                let current = vm.i2sRxPins.indices.contains(pair) ? vm.i2sRxPins[pair] : UInt8(255)
                                ForEach(Self.validPins.filter { $0 == current || pinInUseBy($0, excluding: .i2sRx(pair)) == nil }, id: \.self) { pin in
                                    Text("GPIO \(pin)").tag(pin)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                } header: {
                    Label("I2S Input", systemImage: "waveform.path")
                } footer: {
                    Text(vm.i2sMaxPairs > 1
                         ? "Wire one ADC serial-data line per stereo pair to the GPIOs above; the shared bit clock and sample rate live in I2S Configuration. DSPi is the clock master and the pairs are sample-aligned. Save a preset to keep this wiring."
                         : "Wire the ADC's serial-data line to the GPIO above. The bit clock and sample rate live in I2S Configuration; DSPi is the clock master, so the source must follow.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: ADAT Input
            if section == .spdif && vm.adatInputSupported {
                Section {
                    // Enable toggle.  There is no free default GPIO, so a data
                    // pin must be assigned first; the firmware rejects an enable
                    // with no pin (INVALID_PIN).  Disabling is refused while ADAT
                    // is the active source - switch away first.
                    Toggle(isOn: Binding(
                        get: { vm.adatInputEnabled },
                        set: { en in
                            SettingsSaveCoordinator.shared.beginOutputEdit()
                            let pin = vm.adatInputPin
                            DispatchQueue.global(qos: .userInitiated).async {
                                let status = vm.setAdatInputEnable(en)
                                DispatchQueue.main.async {
                                    handleAdatInputStatus(status, label: en ? "enabled" : "disabled",
                                                          gpio: pin == ADAT_INPUT_PIN_UNSET ? nil : pin)
                                }
                            }
                        }
                    )) {
                        HStack {
                            Image(systemName: "fibrechannel")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable ADAT Input")
                                    .font(.body)
                                Text("Receive 8 channels of 24-bit audio (44.1/48 kHz) from one TOSLINK optical input into input channels 1-8. Assign a data pin below, then select ADAT as the input source.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    // Can't turn on without a pin; can always turn off.
                    .disabled(!vm.adatInputEnabled && vm.adatInputPin == ADAT_INPUT_PIN_UNSET)
                    .padding(.vertical, 4)

                    // Serial Data (RX) GPIO — no default; may equal the ADAT
                    // output pin for a zero-hardware loopback self-test.  May be
                    // changed while ADAT is live (the firmware re-routes under a
                    // brief muted restart).
                    HStack {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Serial Data")
                                .font(.body)
                            Text("GPIO receiving the ADAT optical input. No default - assign a spare pin (it may match the ADAT output pin for a loopback self-test).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.adatInputPin },
                            set: { newPin in
                                SettingsSaveCoordinator.shared.beginOutputEdit()
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let status = vm.setAdatInputPin(newPin)
                                    DispatchQueue.main.async {
                                        handleAdatInputStatus(status, label: "pin", gpio: newPin)
                                    }
                                }
                            }
                        )) {
                            // Placeholder while unset so the picker has a valid tag.
                            if vm.adatInputPin == ADAT_INPUT_PIN_UNSET {
                                Text("Not set").tag(ADAT_INPUT_PIN_UNSET)
                            }
                            ForEach(adatInputPinOptions, id: \.self) { pin in
                                Text("GPIO \(pin)").tag(pin)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    // Clock mode — MASTER (DSPi owns the rate, the returning
                    // stream is already in its clock domain) or SLAVE (external
                    // gear owns the clock and the rate is auto-detected).  Applied
                    // at the next switch into ADAT when it isn't the live source.
                    HStack {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Clock Mode")
                                .font(.body)
                            Text("Master: DSPi owns the sample rate (set in I2S Configuration) and the source syncs to the ADAT output. Slave: an external master owns the clock and the rate is auto-detected.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.adatInputClockMode },
                            set: { newMode in
                                guard newMode != vm.adatInputClockMode else { return }
                                SettingsSaveCoordinator.shared.beginOutputEdit()
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let status = vm.setAdatInputClockMode(newMode)
                                    DispatchQueue.main.async {
                                        handleAdatInputStatus(status, label: "clock mode", gpio: nil)
                                    }
                                }
                            }
                        )) {
                            Text("Master").tag(ADAT_INPUT_CLOCK_MODE_MASTER)
                            Text("Slave").tag(ADAT_INPUT_CLOCK_MODE_SLAVE)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    // Live lock indicator, shown while ADAT is the active source.
                    // The receiver locks in both clock modes (master decodes the
                    // returning stream), so this appears whenever ADAT is selected.
                    if vm.adatInputActive {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Lock Status")
                                    .font(.body)
                                Text(vm.adatInputStatus.isLocked
                                     ? "Locked and decoding at \(vm.adatInputStatus.detectedRateString)."
                                     : (vm.adatInputSlaveActive
                                        ? "Waiting for external clock (measured \(vm.adatInputStatus.measuredHzString))."
                                        : "Waiting for a valid ADAT signal on the data pin."))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(vm.adatInputStatus.stateColor)
                                    .frame(width: 6, height: 6)
                                Text(vm.adatInputStatus.stateString)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("ADAT Input", systemImage: "fibrechannel")
                } footer: {
                    Text("Pairs with an outboard ADC (for example a Behringer ADA8200) to turn DSPi into an analog-in processor. In master mode, wire DSPi's ADAT output to the box's ADAT input and the box's ADAT output back to the data pin here. The 8 channels arrive as input channels 1-8 with full per-input EQ and metering. Save a preset to keep this wiring.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
            } header: {
                Label("Slots", systemImage: "square.grid.2x2")
            }

            // ADAT bulk output (RP2350 only) — streams all 8 output channels as
            // one optical ADAT lightpipe on a spare GPIO, alongside the
            // SPDIF/I2S slots and PDM.  Enable + data pin are part of the IO
            // block governed by the output-config persistence mode.
            if vm.adatSupported {
                Section {
                    Toggle(isOn: Binding(
                        get: { vm.adatEnabled },
                        set: { en in
                            SettingsSaveCoordinator.shared.beginOutputEdit()
                            let pin = vm.adatPin
                            DispatchQueue.global(qos: .userInitiated).async {
                                let status = vm.setAdatEnable(en)
                                DispatchQueue.main.async {
                                    handleAdatStatus(status, label: en ? "enabled" : "disabled", gpio: pin)
                                }
                            }
                        }
                    )) {
                        HStack {
                            Image(systemName: "fibrechannel")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable ADAT")
                                    .font(.body)
                                Text("Stream all 8 output channels as one optical ADAT lightpipe (44.1/48 kHz, 24-bit). Runs alongside the existing outputs; drive a TOSLINK transmitter from the data pin.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 4)

                    // Data GPIO — may be changed while enabled (the firmware
                    // re-routes under a brief muted restart).
                    HStack {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Serial Data")
                                .font(.body)
                            Text("GPIO driving the ADAT optical output. Default GPIO \(ADAT_PIN_DEFAULT).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.adatPin },
                            set: { newPin in
                                SettingsSaveCoordinator.shared.beginOutputEdit()
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let status = vm.setAdatPin(newPin)
                                    DispatchQueue.main.async {
                                        handleAdatStatus(status, label: "pin", gpio: newPin)
                                    }
                                }
                            }
                        )) {
                            ForEach(adatPinOptions, id: \.self) { pin in
                                Text("GPIO \(pin)").tag(pin)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } header: {
                    Label("Bulk Output", systemImage: "fibrechannel")
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
    /// One GPIO pin row of the S/PDIF Input section: title/description + pin
    /// picker.  Which rows are shown is driven by the count selector above
    /// (mirroring the I2S "Serial Data" per-pair rows).
    @ViewBuilder
    private func spdifInputRow(index: Int) -> some View {
        let multi = vm.multiSpdifSupported
        let title = multi ? "S/PDIF \(index + 1)" : "SPDIF RX"
        HStack {
            Image(systemName: "cable.connector")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                Text(multi
                     ? "GPIO pin for S/PDIF input \(index + 1) (TOSLINK RX module or comparator)."
                     : "GPIO pin for incoming S/PDIF signal from a TOSLINK RX module or comparator.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            spdifPinPicker(index: index)
        }
    }

    /// GPIO pin picker for a S/PDIF input index, with inline status feedback.
    @ViewBuilder
    private func spdifPinPicker(index: Int) -> some View {
        Picker("", selection: Binding(
            get: { vm.spdifPin(index: index) },
            set: { newPin in
                SettingsSaveCoordinator.shared.beginOutputEdit()
                DispatchQueue.global(qos: .userInitiated).async {
                    let status = vm.setSpdifRxPin(index: index, newPin)
                    DispatchQueue.main.async {
                        switch status {
                        case PIN_CONFIG_SUCCESS:
                            statusMessage = "S/PDIF \(index + 1) RX pin set to GPIO \(newPin)"
                            statusIsError = false
                        case PIN_CONFIG_PIN_IN_USE:
                            if let owner = pinInUseBy(newPin, excluding: .spdifRx(index)) {
                                statusMessage = "GPIO \(newPin) is already assigned to \(owner)"
                            } else {
                                statusMessage = "GPIO \(newPin) is already in use"
                            }
                            statusIsError = true
                            vm.fetchSpdifRxPin(index: index)
                        case PIN_CONFIG_INVALID_PIN:
                            statusMessage = "GPIO \(newPin) is not available on this platform"
                            statusIsError = true
                            vm.fetchSpdifRxPin(index: index)
                        default:
                            statusMessage = "Failed to set S/PDIF \(index + 1) RX pin"
                            statusIsError = true
                            vm.fetchSpdifRxPin(index: index)
                        }
                    }
                }
            }
        )) {
            // Always keep the current pin selectable even if another consumer
            // would otherwise filter it out (e.g. a disabled input's stored pin).
            ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .spdifRx(index)) == nil || $0 == vm.spdifPin(index: index) }, id: \.self) { pin in
                Text("GPIO \(pin)").tag(pin)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Set how many S/PDIF inputs are active (1..3): enables inputs 1..target
    /// and disables the rest.  Enables run low→high so a lower input frees its
    /// state first; disables run high→low.  Surfaces the firmware's reason on
    /// the first rejection (pin conflict when enabling, or "switch away first"
    /// when disabling the live source) and re-syncs from the device.
    private func setSpdifInputCount(_ target: Int) {
        guard target != vm.spdifEnabledCount else { return }
        SettingsSaveCoordinator.shared.beginOutputEdit()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String? = nil

            // Enable optional inputs up to the target (ascending).
            if target >= 2 {
                for idx in 1...(target - 1) where !vm.spdifInputEnabled(index: idx) {
                    let s = vm.setSpdifInputEnable(index: idx, true)
                    if s != PIN_CONFIG_SUCCESS {
                        let pin = vm.spdifPin(index: idx)
                        if let owner = pinInUseBy(pin, excluding: .spdifRx(idx)) {
                            failure = "Can't enable S/PDIF \(idx + 1): GPIO \(pin) is assigned to \(owner)"
                        } else {
                            failure = "Can't enable S/PDIF \(idx + 1): GPIO \(pin) is unavailable"
                        }
                        break
                    }
                }
            }

            // Disable inputs above the target (descending).
            if failure == nil {
                for idx in stride(from: SPDIF_RX_NUM_INPUTS - 1, through: 1, by: -1)
                where idx >= target && vm.spdifInputEnabled(index: idx) {
                    let s = vm.setSpdifInputEnable(index: idx, false)
                    if s != PIN_CONFIG_SUCCESS {
                        failure = "Switch the input source away from S/PDIF \(idx + 1) before reducing the input count"
                        break
                    }
                }
            }

            DispatchQueue.main.async {
                if let failure = failure {
                    statusMessage = failure
                    statusIsError = true
                } else {
                    statusMessage = "S/PDIF inputs set to \(target)"
                    statusIsError = false
                }
                // Re-sync the enable mask / pins from the device so a partial or
                // rejected change reflects the true hardware state.
                vm.fetchSpdifInputConfig()
            }
        }
    }

    ///
    /// NOTE: Not currently wired into the Inputs page (which uses the per-input
    /// "SPDIF RX" rows above) — kept here for later use.
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
                                if let owner = pinInUseBy(newPin, excluding: .spdifRx(0)) {
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
                ForEach(Self.validPins.filter { pinInUseBy($0, excluding: .spdifRx(0)) == nil }, id: \.self) { pin in
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

        // Re-evaluate sizing/resizability each time: the 8-channel matrix (8×9)
        // can exceed the screen, so it is resizable and clamped to the visible
        // frame (the view scrolls); the stereo matrix stays fixed-size.  Doing
        // this on every show() keeps it correct across RP2040 ↔ RP2350 swaps.
        if let window = window, let hostingView = window.contentView {
            let eightCh = AppState.shared.viewModel.supports8chInput
            if eightCh {
                window.styleMask.insert(.resizable)
            } else {
                window.styleMask.remove(.resizable)
            }
            let fitting = hostingView.fittingSize
            window.setContentSize(eightCh ? Self.clampToScreen(fitting) : fitting)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    /// Clamp a desired content size to ~90% of the active screen's visible frame
    /// so a tall 8-channel matrix never opens larger than the display.
    private static func clampToScreen(_ size: NSSize) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        return NSSize(width: min(size.width, screen.width * 0.95),
                      height: min(size.height, screen.height * 0.90))
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
        // Start with active inputs + enabled outputs visible
        var vis: [Int: Bool] = [:]
        for ch in 0..<vm.numMatrixInputs { vis[ch] = true }
        for i in 0..<vm.numOutputChannels {
            vis[vm.eqChannel(forOutput: i)] = vm.outputEnabled[i]
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
            } else if upperLine.contains(" LS1 ") {
                filterType = .lowShelf1
            } else if upperLine.contains(" HS1 ") {
                filterType = .highShelf1
            } else if upperLine.contains(" AP1 ") {
                filterType = .allPass1
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
        let vm = AppState.shared.viewModel
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
                    let eqCh = vm.eqChannel(forOutput: outputIdx)
                    let enabled = headerContent[stateRange] == "Enabled"
                    currentChannel = eqCh
                    result[eqCh] = ParsedChannelData(filters: [], enableState: enabled)
                }
                // Backward compat: old channel names (map to V16 output channels)
                else if headerContent == "Out L" {
                    currentChannel = vm.eqChannel(forOutput: 0)
                    result[vm.eqChannel(forOutput: 0)] = ParsedChannelData(filters: [], enableState: nil)
                } else if headerContent == "Out R" {
                    currentChannel = vm.eqChannel(forOutput: 1)
                    result[vm.eqChannel(forOutput: 1)] = ParsedChannelData(filters: [], enableState: nil)
                } else if headerContent == "Sub" {
                    currentChannel = vm.eqChannel(forOutput: vm.pdmOutputIndex)
                    result[vm.eqChannel(forOutput: vm.pdmOutputIndex)] = ParsedChannelData(filters: [], enableState: nil)
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
            } else if upperLine.contains(" LS1 ") {
                filterType = .lowShelf1
            } else if upperLine.contains(" HS1 ") {
                filterType = .highShelf1
            } else if upperLine.contains(" AP1 ") {
                filterType = .allPass1
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
            let eqCh = vm.eqChannel(forOutput: outputIdx)
            let name = vm.channelNames[eqCh]
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
        case .allPass1: typeCode = "AP1"
        case .lowShelf1: typeCode = "LS1"
        case .highShelf1: typeCode = "HS1"
        default:
            // Crossover types live in xoverData, not channelData; this REW-style
            // export only covers PEQ bands.
            typeCode = filter.type.shortLabel
        }

        let paddedType = typeCode.padding(toLength: 8, withPad: " ", startingAt: 0)
        var line = String(format: "Filter %2d: ON  %@Fc %7.1f Hz", index, paddedType, filter.freq)

        // Add gain for types that use it
        if filter.type == .peaking || filter.type == .lowShelf || filter.type == .highShelf
            || filter.type == .lowShelf1 || filter.type == .highShelf1 {
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
            let eqCh = vm.eqChannel(forOutput: outputIdx)
            let checkbox = NSButton(checkboxWithTitle: vm.channelNames[eqCh], target: nil, action: nil)
            checkbox.tag = eqCh
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

        // Show channels in order: inputs then outputs (full unified range).
        for eqCh in 0..<vm.numChannels {
            guard channelFilters[eqCh] != nil else { continue }
            let name = eqCh < vm.channelNames.count ? vm.channelNames[eqCh] : "Ch \(eqCh)"

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
                    if eqCh >= vm.chOut1, let enabled = data.enableState {
                        vm.setOutputEnable(output: eqCh - vm.chOut1, enabled: enabled)
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

/// Restores the standard "Settings..." menu item (Cmd+,) in the app menu. A
/// `Settings` scene provides this automatically; since Settings is now a plain
/// `Window` scene, we supply the item ourselves and open the window by id.
private struct SettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - App
@main
struct DSPi_ConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var statsWindowController = StatsWindowController()
    @StateObject private var loudnessWindowController = LoudnessWindowController()
    @StateObject private var crossfeedWindowController = CrossfeedWindowController()
    @StateObject private var psybassWindowController = PsychoacousticBassWindowController()
    @StateObject private var levellerWindowController = VolumeLevellerWindowController()
    @StateObject private var autoEQBrowserController = AutoEQBrowserController()
    @StateObject private var matrixMixerWindowController = MatrixMixerWindowController()
    @StateObject private var graphWindowController = GraphWindowController()
    @StateObject private var interruptMonitorWindowController = InterruptMonitorWindowController()
    @StateObject private var testSignalsWindowController = TestSignalsWindowController()
    @ObservedObject private var vm = AppState.shared.viewModel

    var body: some Scene {
        Window("DSPi Console", id: "main") {
            ContentView(vm: AppState.shared.viewModel)
                .environmentObject(matrixMixerWindowController)
                .environmentObject(loudnessWindowController)
                .environmentObject(crossfeedWindowController)
                .environmentObject(psybassWindowController)
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
            // Restore the standard "Settings..." item (Cmd+,); the plain
            // `Window` Settings scene no longer provides it automatically.
            SettingsCommand()

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

                Button("Psychoacoustic Bass...") {
                    psybassWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])

                Button("Volume Leveller...") {
                    levellerWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])

                Button("Test Signals...") {
                    testSignalsWindowController.show(vm: AppState.shared.viewModel)
                }
                .keyboardShortcut("G", modifiers: [.command, .shift])

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

        // A plain `Window` scene rather than a `Settings` scene, so the window
        // is user-resizable. Appearance is unchanged: `SettingsWindowConfigurator`
        // styles the NSWindow (compact, transparent title bar) identically, and
        // the standard "Settings..." menu item (Cmd+,) is restored by
        // `SettingsCommand` in `.commands` below.
        Window("Settings", id: "settings") {
            SettingsView()
        }
        // `.contentMinSize` uses the content's size as the *minimum* while
        // letting the user grow the window (unlike `.contentSize`, which pins
        // min == max and blocks resizing). The detail column grows to fill.
        .windowResizability(.contentMinSize)
        // The old `Settings` scene opened centered; preserve that.
        .defaultPosition(.center)
    }
}
