import SwiftUI

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
    case overview
    case channel(Channel)
    case output(Int)  // Matrix output index 0-8
}
// MARK: - Main Layout

struct ContentView: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var matrixMixerController: MatrixMixerWindowController
    @EnvironmentObject var loudnessController: LoudnessWindowController
    @EnvironmentObject var crossfeedController: CrossfeedWindowController
    @EnvironmentObject var statsController: StatsWindowController
    @EnvironmentObject var graphWindowController: GraphWindowController
    @EnvironmentObject var levellerController: VolumeLevellerWindowController
    @State private var selection: SidebarSelection = .overview
    @State private var renamingChannel: Int? = nil  // channelNames index
    @State private var renameText = ""
    @State private var localMasterVolume: Float = 0
    @State private var isDraggingMasterVolume = false
    @State private var showPresetRename = false
    @State private var presetRenameSlot = 0
    @State private var presetRenameText = ""
    @State private var presetSwitchInFlight = false
    @State private var settingsWindowOpen = false
    @Environment(\.openSettings) private var openSettingsAction

    // Piecewise-linear master volume slider mapping:
    //   0 to -10 dB:   0.1 dB steps → 100 units (40% of throw)
    //   -10 to -40 dB: 0.5 dB steps →  60 units (24% of throw)
    //   -40 to -128 dB: 1.0 dB steps → 88 units (36% of throw)
    // Slider pos 1.0 = 0 dB, pos 0.0 = -128 dB (mute)
    private static let mvTotalUnits: Float = 248 // 100 + 60 + 88
    private static let mvBreak1: Float = 1.0 - 100 / mvTotalUnits  // pos where db = -10
    private static let mvBreak2: Float = mvBreak1 - 60 / mvTotalUnits // pos where db = -40

    private static func masterVolSliderToDB(_ pos: Float) -> Float {
        if pos <= 0 { return -128 }
        if pos >= 1 { return 0 }
        if pos > mvBreak1 {
            // Region 1: 0 to -10 dB, 0.1 dB per unit
            return -(1.0 - pos) * mvTotalUnits * 0.1
        } else if pos > mvBreak2 {
            // Region 2: -10 to -40 dB, 0.5 dB per unit
            return -10 - (mvBreak1 - pos) * mvTotalUnits * 0.5
        } else {
            // Region 3: -40 to -128 dB, 1.0 dB per unit
            return -40 - (mvBreak2 - pos) * mvTotalUnits * 1.0
        }
    }

    private static func masterVolDBToSlider(_ db: Float) -> Float {
        if db <= -128 { return 0 }
        if db >= 0 { return 1 }
        if db > -10 {
            return 1.0 - (-db / 0.1) / mvTotalUnits
        } else if db > -40 {
            return mvBreak1 - ((-db - 10) / 0.5) / mvTotalUnits
        } else {
            return mvBreak2 - ((-db - 40) / 1.0) / mvTotalUnits
        }
    }

    private static func masterVolDisplayValue(_ db: Float) -> Float {
        if db <= -128 { return -128 }
        let rounded: Float
        if db > -10 {
            rounded = (db * 10).rounded() / 10
        } else if db > -40 {
            rounded = (db * 2).rounded() / 2
        } else {
            rounded = db.rounded()
        }
        return rounded == -0.0 ? 0.0 : rounded
    }

    private func commitRename() {
        guard let idx = renamingChannel else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                vm.setChannelName(channel: idx, name: trimmed)
            }
        }
        renamingChannel = nil
    }

    private func startRename(_ channelIdx: Int) {
        if renamingChannel != nil { commitRename() }
        renameText = vm.channelNames[channelIdx]
        renamingChannel = channelIdx
    }

    private func presetLabel(_ slot: Int) -> String {
        let display = slot + 1
        return "\(display): \(presetDropdownLabel(slot))"
    }

    private func presetDropdownLabel(_ slot: Int) -> String {
        guard vm.isPresetOccupied(slot) else { return "Empty" }
        let trimmed = vm.presetNames[slot].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Preset \(slot + 1)" : trimmed
    }

    private func saveActivePreset(vm: DSPViewModel) {
        let slot = vm.activePresetSlot
        DispatchQueue.global(qos: .userInitiated).async {
            if vm.presetNames[slot].isEmpty {
                vm.setPresetName(slot: slot, name: "Preset \(slot + 1)")
            }
            let status = vm.savePreset(slot: slot)
            if status != PRESET_OK {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Save Failed"
                    alert.informativeText = "Failed to save preset (error \(status))."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func showPresetClearConfirmation(vm: DSPViewModel, slot: Int) {
        let alert = NSAlert()
        alert.messageText = "Clear Preset?"
        alert.informativeText = "Clear \"\(presetLabel(slot))\" and restore factory defaults? This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let status = vm.deletePreset(slot: slot)
            if status == PRESET_OK {
                vm.setPresetName(slot: slot, name: "")
                vm.fetchPresetDirectory()
                // If we cleared the active slot, reload it to apply factory defaults
                if vm.activePresetSlot == slot {
                    _ = vm.loadPreset(slot: slot)
                }
            }
            DispatchQueue.main.async {
                if status != PRESET_OK {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Clear Failed"
                    errAlert.informativeText = "Failed to clear preset (error \(status))."
                    errAlert.alertStyle = .warning
                    errAlert.addButton(withTitle: "OK")
                    errAlert.runModal()
                }
            }
        }
    }

    private func showPresetClearAllConfirmation(vm: DSPViewModel) {
        let alert = NSAlert()
        alert.messageText = "Clear All Presets?"
        alert.informativeText = "This will erase all preset data and names, restoring every slot to factory defaults. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for slot in 0..<10 where vm.isPresetOccupied(slot) {
                vm.deletePreset(slot: slot)
                vm.setPresetName(slot: slot, name: "")
            }
            vm.fetchPresetDirectory()
            for slot in 0..<10 {
                vm.fetchPresetName(slot: slot)
            }
            // Reload active slot to apply factory defaults
            _ = vm.loadPreset(slot: vm.activePresetSlot)
        }
    }

    var body: some View {
        HSplitView {
            // SIDEBAR
            List {
                Section(header: Text("INPUTS")) {
                    ForEach(Channel.allCases.filter { !$0.isOutput }, id: \.self) { ch in
                        // When Link L/R is on, both master rows show as
                        // selected if either master is currently selected.
                        // The right-pane still tracks the actually-clicked
                        // channel (via `selection`) — only the visual
                        // highlight is shared.
                        let rowSelected: Bool = {
                            if selection == .channel(ch) { return true }
                            if vm.preampLinked && (ch == .masterLeft || ch == .masterRight) {
                                return selection == .channel(.masterLeft) || selection == .channel(.masterRight)
                            }
                            return false
                        }()
                        ChannelRow(channel: ch, isSelected: rowSelected,
                                  name: vm.channelNames[ch.rawValue], meters: vm.meters,
                                  isRenaming: renamingChannel == ch.rawValue,
                                  renameText: $renameText,
                                  onCommitRename: { commitRename() })
                            .onOptionClick { startRename(ch.rawValue) }
                            .onTapGesture {
                                if renamingChannel != nil { commitRename() }
                                if selection == .channel(ch) {
                                    selection = .overview
                                    vm.updateSelection(to: nil)
                                } else {
                                    selection = .channel(ch)
                                    vm.updateSelection(to: ch)
                                }
                            }
                            .contextMenu {
                                Button("Rename") { startRename(ch.rawValue) }
                                Divider()
                                Button("Copy Parameters") {
                                    vm.copyChannelParams(eqChannel: ch.rawValue, name: vm.channelNames[ch.rawValue])
                                }
                                Button("Paste Parameters") {
                                    vm.pasteChannelParams(eqChannel: ch.rawValue)
                                }
                                .disabled(vm.channelClipboard == nil)
                            }
                    }
                }

                Section(header: Text("OUTPUTS")) {
                    ForEach(MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes).filter { vm.outputEnabled[$0.index] }, id: \.index) { out in
                        OutputRow(output: out, isSelected: selection == .output(out.index),
                                  name: vm.channelNames[out.index + 2],
                                  isMuted: vm.isOutputInactive(out.index),
                                  meters: vm.meters,
                                  isRenaming: renamingChannel == out.index + 2,
                                  renameText: $renameText,
                                  onCommitRename: { commitRename() })
                            .onOptionClick { startRename(out.index + 2) }
                            .onTapGesture {
                                if renamingChannel != nil { commitRename() }
                                if selection == .output(out.index) {
                                    selection = .overview
                                    vm.updateSelection(to: nil)
                                } else {
                                    selection = .output(out.index)
                                    vm.updateSelectionToOutput(out.index)
                                }
                            }
                            .contextMenu {
                                Button("Rename") { startRename(out.index + 2) }
                                Divider()
                                Button("Copy Parameters") {
                                    vm.copyChannelParams(eqChannel: out.index + 2, name: vm.channelNames[out.index + 2])
                                }
                                Button("Paste Parameters") {
                                    vm.pasteChannelParams(eqChannel: out.index + 2)
                                }
                                .disabled(vm.channelClipboard == nil)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
                .ignoresSafeArea(.all, edges: [.top, .bottom])
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // Quick Access Icons
                    HStack(spacing: 0) {
                        SidebarIconButton(
                            icon: "slider.vertical.3",
                            isActive: matrixMixerController.isVisible,
                            tooltip: "Matrix Mixer",
                            action: { matrixMixerController.toggle() }
                        )

                        SidebarIconButton(
                            icon: "headphones",
                            isActive: vm.crossfeedEnabled,
                            tooltip: "Headphone Crossfeed",
                            action: { vm.setCrossfeed(!vm.crossfeedEnabled) }
                        )
                        .onRightClick { crossfeedController.show(vm: vm) }

                        SidebarIconButton(
                            icon: "speaker.zzz",
                            isActive: vm.loudnessEnabled,
                            tooltip: "Loudness Compensation",
                            action: { vm.setLoudness(!vm.loudnessEnabled) }
                        )
                        .onRightClick { loudnessController.show(vm: vm) }

                        SidebarIconButton(
                            icon: "waveform.path.ecg",
                            isActive: vm.levellerEnabled,
                            tooltip: "Volume Leveller",
                            action: { vm.setLeveller(!vm.levellerEnabled) }
                        )
                        .onRightClick { levellerController.show(vm: vm) }

                        SidebarIconButton(
                            icon: "info.circle",
                            isActive: statsController.isVisible,
                            tooltip: "Stats for Nerbs",
                            action: { statsController.toggle(usb: vm.usb) }
                        )

                        SidebarIconButton(
                            icon: "gearshape",
                            isActive: settingsWindowOpen,
                            tooltip: "Settings",
                            action: {
                                if settingsWindowOpen, let w = NSApp.windows.first(where: {
                                    $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
                                }) {
                                    w.close()
                                } else {
                                    openSettingsAction()
                                    settingsWindowOpen = true
                                }
                            }
                        )

                        SidebarIconButton(
                            icon: "xmark",
                            isActive: vm.bypass,
                            tooltip: "Bypass Master EQ",
                            action: { vm.setBypass(!vm.bypass) }
                        )
                    }
                    .padding(.vertical, 8)

                    VStack(spacing: 0) {
                    Divider()

                    // Global Controls
                    VStack(alignment: .leading, spacing: 12) {
                        // Preset Picker
                        HStack {
                            Text("Preset").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            BorderlessPopUpButton(
                                items: Array(0..<10),
                                titleForItem: { slot in
                                    // Append "*" to the currently-selected slot's title when
                                    // unsaved changes are pending.  The popup face shows the
                                    // selected item's title verbatim, so the asterisk also
                                    // appears inside the picker box — exactly the dirty marker
                                    // we want.  Only the active slot ever gets the marker, so
                                    // when the user opens the menu they see at most one "*".
                                    let base = presetDropdownLabel(slot)
                                    return (slot == vm.activePresetSlot && vm.hasUnsavedChanges)
                                        ? "\(base)*"
                                        : base
                                },
                                selection: Binding(
                                    get: { vm.activePresetSlot },
                                    set: { slot in
                                        let previousSlot = vm.activePresetSlot
                                        print("[PRESET] set closure: slot=\(slot) previous=\(previousSlot) inFlight=\(presetSwitchInFlight) connected=\(vm.isDeviceConnected) unsaved=\(vm.hasUnsavedChanges)")
                                        guard slot != previousSlot else {
                                            print("[PRESET] SKIP: same slot")
                                            return
                                        }
                                        guard !presetSwitchInFlight else {
                                            print("[PRESET] SKIP: switch in flight")
                                            return
                                        }

                                        let showLoadFailed: (UInt8) -> Void = { status in
                                            vm.fetchPresetActive()
                                            let alert = NSAlert()
                                            alert.messageText = "Load Failed"
                                            alert.informativeText = status == PRESET_ERR_CRC
                                                ? "Preset data is corrupted."
                                                : "Failed to load preset (error \(status))."
                                            alert.alertStyle = .warning
                                            alert.addButton(withTitle: "OK")
                                            alert.runModal()
                                        }

                                        presetSwitchInFlight = true
                                        print("[PRESET] inFlight = true")
                                        if vm.isDeviceConnected && vm.hasUnsavedChanges {
                                            let diff = vm.computeDiff()
                                            let action = PresetAlerts.showUnsavedChangesAlert(diff: diff)
                                            switch action {
                                            case .save:
                                                DispatchQueue.global(qos: .userInitiated).async {
                                                    if vm.presetNames[previousSlot].isEmpty {
                                                        vm.setPresetName(slot: previousSlot, name: "Preset \(previousSlot + 1)")
                                                    }
                                                    let saveStatus = vm.savePreset(slot: previousSlot)
                                                    guard saveStatus == PRESET_OK else {
                                                        DispatchQueue.main.async {
                                                            vm.activePresetSlot = previousSlot
                                                            let alert = NSAlert()
                                                            alert.messageText = "Save Failed"
                                                            alert.informativeText = "Failed to save preset (error \(saveStatus)). Preset switch aborted."
                                                            alert.alertStyle = .warning
                                                            alert.addButton(withTitle: "OK")
                                                            alert.runModal()
                                                            presetSwitchInFlight = false
                                                        }
                                                        return
                                                    }
                                                    let loadStatus = vm.loadPreset(slot: slot)
                                                    DispatchQueue.main.async {
                                                        if loadStatus != PRESET_OK {
                                                            showLoadFailed(loadStatus)
                                                        }
                                                        presetSwitchInFlight = false
                                                    }
                                                }
                                            case .discard:
                                                DispatchQueue.global(qos: .userInitiated).async {
                                                    let status = vm.loadPreset(slot: slot)
                                                    DispatchQueue.main.async {
                                                        if status != PRESET_OK {
                                                            showLoadFailed(status)
                                                        }
                                                        presetSwitchInFlight = false
                                                    }
                                                }
                                            case .cancel:
                                                presetSwitchInFlight = false
                                                return
                                            }
                                        } else {
                                            print("[PRESET] no unsaved changes, loading slot \(slot)")
                                            vm.activePresetSlot = slot
                                            DispatchQueue.global(qos: .userInitiated).async {
                                                let status = vm.loadPreset(slot: slot)
                                                print("[PRESET] loadPreset returned status=\(status)")
                                                DispatchQueue.main.async {
                                                    if status != PRESET_OK {
                                                        print("[PRESET] load FAILED status=\(status)")
                                                        showLoadFailed(status)
                                                    } else {
                                                        print("[PRESET] load OK, activeSlot=\(vm.activePresetSlot)")
                                                    }
                                                    presetSwitchInFlight = false
                                                    print("[PRESET] inFlight = false")
                                                }
                                            }
                                        }
                                    }
                                )
                            )
                            .frame(minWidth: 80)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 4)
                                    .allowsHitTesting(false)
                            }
                            .fixedSize()
                            .opacity(vm.isDeviceConnected ? 1.0 : 0.4)
                            .allowsHitTesting(vm.isDeviceConnected && !presetSwitchInFlight)
                        }
                        .contextMenu {
                            Button("Save") { saveActivePreset(vm: vm) }
                            Button("Rename…") {
                                presetRenameSlot = vm.activePresetSlot
                                presetRenameText = vm.presetNames[vm.activePresetSlot]
                                showPresetRename = true
                            }
                            if vm.isPresetOccupied(vm.activePresetSlot) {
                                Divider()
                                Button("Clear \"\(presetLabel(vm.activePresetSlot))\"…", role: .destructive) {
                                    showPresetClearConfirmation(vm: vm, slot: vm.activePresetSlot)
                                }
                            }
                            if vm.presetOccupied != 0 {
                                Divider()
                                Button("Clear All Slots…", role: .destructive) {
                                    showPresetClearAllConfirmation(vm: vm)
                                }
                            }
                        }

                        // Input Source Picker (hidden if firmware doesn't support it)
                        if vm.inputSourceSupported {
                            HStack {
                                Text("Source").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                BorderlessPopUpButton(
                                    items: [0, 1],
                                    titleForItem: { $0 == 0 ? "USB" : "S/PDIF" },
                                    selection: Binding(
                                        get: { vm.inputSource },
                                        set: { source in
                                            guard source != vm.inputSource else { return }
                                            vm.setInputSource(source)
                                        }
                                    )
                                )
                                .frame(minWidth: 80)
                                .overlay(alignment: .trailing) {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.secondary)
                                        .padding(.trailing, 4)
                                        .allowsHitTesting(false)
                                }
                                .fixedSize()
                                .opacity(vm.isDeviceConnected ? 1.0 : 0.4)
                                .allowsHitTesting(vm.isDeviceConnected)
                            }
                        }

                        VStack(spacing: 4) {
                            HStack {
                                Text("Master Volume").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                ValueField(label: "dB", value: Self.masterVolDisplayValue(localMasterVolume), width: 60,
                                           displayOverride: localMasterVolume <= -128 ? "-∞" : nil) {
                                    localMasterVolume = max(-128, min(0, $0))
                                    vm.setMasterVolume(localMasterVolume)
                                }
                            }
                            Slider(value: Binding(
                                get: { Self.masterVolDBToSlider(localMasterVolume) },
                                set: { localMasterVolume = Self.masterVolSliderToDB($0) }
                            ), in: 0...1) { editing in
                                isDraggingMasterVolume = editing
                                if !editing { vm.setMasterVolume(localMasterVolume) }
                            }
                            .controlSize(.small)
                            .onChange(of: localMasterVolume) { val in
                                if isDraggingMasterVolume { vm.sendMasterVolumeToDevice(val) }
                            }
                            .onAppear { localMasterVolume = vm.masterVolumeDB }
                            .onChange(of: vm.masterVolumeDB) { val in
                                if !isDraggingMasterVolume { localMasterVolume = val }
                            }
                            .onRightClick { localMasterVolume = 0; vm.setMasterVolume(0) }
                        }

                    }
                    .padding()
                    // ADDED GESTURE HERE FOR SIDEBAR CONTROLS
                    .onTapGesture {
                        if renamingChannel != nil { commitRename() }
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }

                    Divider()

                    // System Status — CPU load only (meters are inline in sidebar rows)
                    CpuSection(meters: vm.meters)
                    .padding()
                    }
                    .background(.ultraThinMaterial)
                }
            }
            .frame(minWidth: 220, maxWidth: 260)
            // ADDED GESTURE FOR THE REST OF THE SIDEBAR
            .onTapGesture {
                if renamingChannel != nil { commitRename() }
                NSApp.keyWindow?.makeFirstResponder(nil)
            }

            // MAIN CONTENT
            VStack(alignment: .leading, spacing: 20) {
                // Graph + connection status
                VStack(alignment: .leading, spacing: 0) {
                    // Header: connection status (always visible)
                    HStack {
                        if graphWindowController.isVisible {
                            Button(action: { graphWindowController.hide() }) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Close pop-out window")
                            .transition(.opacity)
                        } else {
                            Text("Filter Response").font(.headline)
                                .transition(.opacity)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            Circle()
                                .fill(vm.isDeviceConnected ? .green : .red)
                                .frame(width: 6, height: 6)

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
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, graphWindowController.isVisible ? 0 : 16)

                    if !graphWindowController.isVisible {
                        BodePlotView(vm: vm)
                            .frame(height: CGFloat(settings.graphHeight))
                            .padding(.horizontal)
                            .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
                        GraphResizeHandle()
                        GraphLegend(vm: vm).padding(.horizontal).padding(.top, -16)
                            .transition(.opacity)
                    }
                }

                // Right Panel Content (Dynamic)
                VStack {
                    switch selection {
                    case .channel(let channel):
                        let masterCh = channel == .masterLeft ? 0 : 1
                        VStack(spacing: 16) {
                            InputChannelHeader(
                                channel: masterCh,
                                vm: vm,
                                onClearMasterPEQ: { vm.clearAllMaster() }
                            )
                            .padding(.horizontal)

                            FilterListView(
                                bands: vm.channelData[channel.rawValue] ?? [],
                                channelId: channel.rawValue,
                                onUpdate: { band, params in
                                    vm.setFilter(ch: channel.rawValue, band: band, p: params)
                                    // Link L/R mirrors PEQ edits across master channels.
                                    // Only fan out for master L/R (channels 0/1); other
                                    // channels never enter this branch since this case
                                    // only handles .masterLeft/.masterRight.
                                    if vm.preampLinked {
                                        vm.setFilter(ch: 1 - masterCh, band: band, p: params)
                                    }
                                },
                                onClear: nil  // moved to InputChannelHeader's "Clear Master PEQ"
                            )
                        }

                    case .output(let idx):
                        let eqChannel = idx + 2
                        VStack(spacing: 16) {
                            ChannelSettingsView(
                                vm: vm,
                                outputIndex: idx,
                                gainDB: Binding(
                                    get: { vm.outputGainDB[idx] },
                                    set: { vm.setOutputGain(output: idx, db: $0) }
                                ),
                                delayMS: Binding(
                                    get: { vm.outputDelayMS[idx] },
                                    set: { vm.setOutputDelay(output: idx, ms: $0) }
                                ),
                                isMuted: Binding(
                                    get: { vm.outputMuted[idx] },
                                    set: { vm.setOutputMute(output: idx, muted: $0) }
                                ),
                                maxDelay: vm.platformName == "RP2040" ? 42 : 85,
                                onGainDrag: { vm.sendOutputGainToDevice(output: idx, db: $0) },
                                onDelayDrag: { vm.sendOutputDelayToDevice(output: idx, ms: $0) }
                            )
                            .padding(.horizontal)

                            FilterListView(
                                bands: vm.channelData[eqChannel] ?? [],
                                channelId: eqChannel,
                                onUpdate: { band, params in
                                    vm.setFilter(ch: eqChannel, band: band, p: params)
                                },
                                onClear: nil
                            )
                        }

                    case .overview:
                        ScrollView {
                            DashboardOverview(vm: vm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
            .onTapGesture {
                if renamingChannel != nil { commitRename() }
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .navigationTitle("DSPi Console")
        .frame(maxHeight:900)
        .onChange(of: vm.outputEnabled) { _ in
            // If the selected output was disabled, fall back to overview
            if case .output(let idx) = selection, !vm.outputEnabled[idx] {
                selection = .overview
                vm.updateSelection(to: nil)
            }
        }
        .sheet(isPresented: $showPresetRename) {
            VStack(spacing: 16) {
                Text("Rename Preset").font(.headline)
                TextField("Name", text: $presetRenameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                HStack {
                    Button("Cancel") { showPresetRename = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        let name = presetRenameText.trimmingCharacters(in: .whitespaces)
                        DispatchQueue.global(qos: .userInitiated).async {
                            vm.setPresetName(slot: presetRenameSlot, name: name)
                        }
                        showPresetRename = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.isMovableByWindowBackground = true
                    window.setContentSize(NSSize(width: 950, height: 813))
                    window.styleMask.remove(.resizable)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow,
               window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                settingsWindowOpen = false
            }
        }
    }

}

// MARK: - Preview Support

extension DSPViewModel {
    /// Creates a preview-safe view model with mock data (no USB connection)
    static var preview: DSPViewModel {
        let vm = DSPViewModel(usb: USBDevice())
        vm.isDeviceConnected = true
        vm.preampDB = [-3.0, -3.0]
        vm.meters.status = SystemStatus(peaks: [0.6, 0.55, 0.4, 0.35, 0.25], cpu0: 42, cpu1: 38)

        // Add some sample filter data for Master L
        vm.channelData[Channel.masterLeft.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        // Add some sample filter data for Master R
        vm.channelData[Channel.masterRight.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        return vm
    }
}

#Preview("Dashboard") {
    ContentView(vm: .preview)
        .environmentObject(MatrixMixerWindowController())
        .environmentObject(LoudnessWindowController())
        .environmentObject(CrossfeedWindowController())
        .environmentObject(StatsWindowController())
        .environmentObject(GraphWindowController())
        .frame(height: 790)
}

#Preview("Channel Selected") {
    ContentView(vm: .preview)
        .environmentObject(MatrixMixerWindowController())
        .environmentObject(LoudnessWindowController())
        .environmentObject(CrossfeedWindowController())
        .environmentObject(StatsWindowController())
        .environmentObject(GraphWindowController())
        .frame(width: 1000, height: 780)
}
