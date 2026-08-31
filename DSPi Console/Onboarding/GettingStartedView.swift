import SwiftUI

/// The Getting Started wizard.
///
/// Replaces the console inside the main window rather than opening over it.
/// A first-time user would otherwise face an interface they cannot read yet,
/// and a modal sheet over it traps people: the menu bar goes quiet and there
/// is no obvious way out.  Taking over the content leaves the menus live,
/// keeps it to one window, and hands the real interface back the moment setup
/// finishes or is skipped.
///
/// The step list is computed from what is actually true, not fixed.  A board
/// already connected and running the right firmware never sees a firmware
/// step; a user with nothing plugged in is shown how to connect a board, and
/// the wizard moves on by itself when one appears.  Nothing on screen is ever
/// something the user cannot act on: firmware installs happen right here, and
/// output configuration is edited right here, so no step hands the user off
/// to another window.
///
/// It stops at the first moment the user can hear their computer through the
/// DSPi.  Everything past that point is discoverable, and a wizard that keeps
/// going past its goal is one people learn to dismiss.
struct GettingStartedView: View {
    @ObservedObject var vm: DSPViewModel
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @StateObject private var installer: FirmwareInstaller

    /// `installer` is injectable so screenshots and tests can drive the board
    /// step through any state without hardware; by default the view owns a
    /// system-backed one, exactly as the Firmware Update window does.
    init(vm: DSPViewModel, installer: FirmwareInstaller? = nil) {
        self.vm = vm
        _installer = StateObject(wrappedValue: installer ?? FirmwareInstaller(
            locator: SystemBootloaderLocator(),
            verifier: ViewModelFirmwareVerifier(vm: vm)))
    }

    #if DEBUG
    /// Test hook: starts the wizard at a given stage (by raw value) so
    /// screenshots and UI tests can reach every screen without replaying the
    /// journey that leads there.
    init(vm: DSPViewModel, installer: FirmwareInstaller? = nil,
         startAtStageForTesting stage: Int, disableReconcileForTesting: Bool = false) {
        self.vm = vm
        _installer = StateObject(wrappedValue: installer ?? FirmwareInstaller(
            locator: SystemBootloaderLocator(),
            verifier: ViewModelFirmwareVerifier(vm: vm)))
        _current = State(initialValue: Stage(rawValue: stage) ?? .welcome)
        self.reconcileDisabledForTesting = disableReconcileForTesting
    }

    /// Screenshot rendering has no real USB, whose connect/disconnect blips
    /// would otherwise pull a forced stage back to where the state machine
    /// thinks it belongs.
    private var reconcileDisabledForTesting = false
    #endif

    // MARK: The stages

    /// Everything the wizard can show, in order.  Which of these actually
    /// appear is `visibleStages`' decision, made live.
    private enum Stage: Int, CaseIterable {
        case welcome, board, outputs, audio, done

        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .board:   return "Board"
            case .outputs: return "Outputs"
            case .audio:   return "Audio"
            case .done:    return "Done"
            }
        }
    }

    @State private var current: Stage = .welcome

    /// Set when the user commits to a firmware install.  The installer never
    /// flashes on its own; this records the one explicit decision.
    @State private var confirmed = false
    /// The reboot-into-BOOTSEL request is sent at most once per commitment.
    @State private var rebootRequested = false
    /// Chip of the board most recently seen by detection, remembered so the
    /// writing card can still name it once the board leaves `.ready`.
    @State private var lastSeenChip: BootloaderBoard.Chip?

    /// Latches once audio has been seen, so a quiet passage does not undo the
    /// confirmation a moment after giving it.
    @State private var sawSignal = false

    /// Inline feedback for output-pin changes.
    @State private var outputStatus: String?
    @State private var outputStatusIsError = false

    /// Whether an install has begun or finished, which pins the board stage on
    /// screen: mid-write the device is off the bus by design, and afterwards
    /// the outcome must stay readable rather than the stage vanishing under
    /// the user because the device reappeared.
    private var installerEngaged: Bool {
        switch installer.state {
        case .writing, .waitingForDevice, .verified, .failed: return true
        default: return confirmed
        }
    }

    /// The board stage earns its place when there is no working device, when
    /// the connected one runs older firmware than this Console ships, or when
    /// an install is in flight.  A downgrade (device newer) is deliberately
    /// not pushed here; that is a power user's decision, made in the Firmware
    /// Update window.
    private var boardStageNeeded: Bool {
        if installerEngaged { return true }
        if !vm.isDeviceConnected { return true }
        return vm.firmwareMatch == .deviceOlder
    }

    /// The steps this user actually faces, right now.
    private var visibleStages: [Stage] {
        var stages: [Stage] = [.welcome]
        if boardStageNeeded { stages.append(.board) }
        if vm.isDeviceConnected {
            stages.append(.outputs)
            stages.append(.audio)
        }
        stages.append(.done)
        return stages
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)

            Divider()

            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { installer.beginWatching() }
        .onDisappear { installer.stopWatching() }
        .onChange(of: vm.isDeviceConnected) { _, _ in reconcile() }
        .onChange(of: installer.state) { _, state in
            switch state {
            case .ready(let board): lastSeenChip = board.chip
            case .waitingForVolume(let chip): lastSeenChip = chip
            default: break
            }
            reconcile()
        }
        .onChange(of: current) { _, stage in
            if stage == .outputs { refreshOutputState() }
        }
        .onReceive(vm.meters.objectWillChange) { _ in
            // Latch, never unlatch: see `sawSignal`.
            if !sawSignal, inputSignalPresent { sawSignal = true }
        }
    }

    /// Keeps `current` pointing at a stage that exists and can be acted on.
    ///
    /// Two moves only.  A device appearing while the user watches the board
    /// stage completes that stage on its own - except when an install has run,
    /// where the outcome stays until the user continues past it.  A device
    /// vanishing from a later stage sends the user back to the board stage,
    /// which is where the problem now lives.
    private func reconcile() {
        #if DEBUG
        if reconcileDisabledForTesting { return }
        #endif
        if (current == .outputs || current == .audio), !vm.isDeviceConnected {
            current = .board
            return
        }
        if current == .board, vm.isDeviceConnected, !installerEngaged,
           vm.firmwareMatch != .deviceOlder {
            current = .outputs
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Getting Started").font(.system(size: 15, weight: .semibold))
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            StepDotStrip(labels: visibleStages.map(\.label),
                         current: currentStageIndex,
                         dotWidth: 60)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var currentStageIndex: Int {
        visibleStages.firstIndex(of: current) ?? 0
    }

    private var headerSubtitle: String {
        "Step \(currentStageIndex + 1) of \(visibleStages.count)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome: welcomeStage
        case .board:   boardStage
        case .outputs: outputsStage
        case .audio:   audioStage
        case .done:    doneStage
        }
    }

    // MARK: Welcome

    private var welcomeStage: some View {
        stepBody(title: "Welcome to DSPi Console",
                 blurb: "DSPi turns a Raspberry Pi Pico into a very flexible audio DSP. Equalisation, crossovers, upmixers, crossfeed, loudness compensation and more can be applied to sound through a plethora of inputs and outputs.\n\nThis setup takes just a minute and will guide you through hearing your computer's audio through DSPi. Everything else can be set up when you need it.") {
            if vm.isDeviceConnected {
                statusRow(.ok, "A DSPi is already connected and running firmware \(deviceVersionText), so this will be short.")
            } else {
                infoRow("bolt.horizontal.circle", "Get your Pico connected and running, installing firmware if needed.")
            }
            infoRow("cable.connector", "Choose the kinds of outputs you'd like to use for now and how they are wired.")
            infoRow("speaker.wave.2", "Send your computer's audio to the DSPi and hear it working.")
        }
    }

    // MARK: Board

    /// Firmware and connection, handled entirely in place.  The installer's
    /// states render right here; there is no second window.  A spinner means
    /// the app or the hardware is working; a still icon means the next move
    /// is the user's, and the card says exactly what that move is.
    private var boardStage: some View {
        stepBody(title: boardStageTitle, blurb: boardStageBlurb) {
            boardStatusCard
                .frame(minHeight: 190)

            if showBootselHint {
                BootselHint()
            }
        }
    }

    private var boardStageTitle: String {
        switch installer.state {
        case .verified: return "Your board is ready"
        case .failed: return "Something needs attention"
        case .writing, .waitingForDevice: return "Installing firmware"
        default:
            if vm.isDeviceConnected, vm.firmwareMatch == .deviceOlder {
                return "Update your board's firmware"
            }
            return "Prepare your Pico"
        }
    }

    private var boardStageBlurb: String {
        switch installer.state {
        case .writing, .waitingForDevice:
            return "Console ships the firmware it expects, so nothing needs a download. Keep the board plugged in until it checks back in."
        case .verified:
            return "The board came back and confirmed it is running exactly what was written."
        case .failed:
            return "This is almost always fixable. Follow the card below, then try again - nothing has been lost."
        default:
            if vm.isDeviceConnected, vm.firmwareMatch == .deviceOlder {
                return "The connected DSPi runs firmware \(deviceVersionText), and this Console expects \(bundledVersion). Updating takes about a minute, or continue and update later from the Tools menu."
            }
            return "In this step, we are going to install the DSPi firmware on your Pico compatible device. Simply follow the directions below."
        }
    }

    @ViewBuilder
    private var boardStatusCard: some View {
        switch installer.state {
        case .idle, .waitingForBoard:
            if confirmed {
                InstallStateCard(
                    icon: "magnifyingglass",
                    tint: .accentColor,
                    spinning: true,
                    title: "Looking for the board",
                    message: "Waiting for it to appear in bootloader mode. If nothing happens after a few seconds, unplug the board, hold BOOTSEL, and plug it back in.")
            } else if vm.isDeviceConnected, vm.firmwareMatch == .deviceOlder {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledValueRow(label: "This Console", value: bundledVersion)
                        LabeledValueRow(label: "Connected device", value: deviceVersionText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Update Firmware") { beginUpdateOfConnectedDevice() }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("The device restarts into bootloader mode and audio stops until the update finishes. Nothing is written without this click.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .setupCard()
            } else {
                InstallStateCard(
                    icon: "cable.connector",
                    tint: .accentColor,
                    spinning: true,
                    title: "Watching for your board",
                    message: "Plug the DSPi in and this step completes by itself. For a new Pico, hold the BOOTSEL button while plugging it in and the firmware installer appears here.")
            }

        case .waitingForVolume(let chip):
            InstallStateCard(
                icon: "externaldrive",
                tint: .accentColor,
                spinning: true,
                title: "\(chip.displayName) found",
                message: "The board is in bootloader mode. Waiting for its \(chip.volumeName) drive to mount - this usually takes a second or two.")

        case .ready(let board):
            if confirmed {
                InstallStateCard(
                    icon: "externaldrive.badge.checkmark",
                    tint: .accentColor,
                    spinning: true,
                    title: "Preparing to write",
                    message: "Opening the \(board.chip.displayName)'s \(board.chip.volumeName) drive.")
            } else {
                VStack(spacing: 12) {
                    InstallStateCard(
                        icon: "externaldrive.badge.checkmark",
                        tint: .green,
                        title: "\(board.chip.displayName) ready",
                        message: "The board is in bootloader mode, ready to receive firmware \(bundledVersion).")
                    Button("Install Firmware \(bundledVersion)") { beginInstall() }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

        case .writing(let fraction):
            InstallWritingCard(fraction: fraction,
                               boardName: lastSeenChip?.displayName,
                               version: bundledVersion)

        case .waitingForDevice:
            InstallStateCard(
                icon: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                spinning: true,
                title: "Firmware written",
                message: "The board is restarting with its new firmware. This can take up to half a minute; leave it plugged in.")

        case .verified(let version):
            InstallStateCard(
                icon: "checkmark.seal.fill",
                tint: .green,
                iconSize: 36,
                title: "Firmware \(version) installed",
                message: "The device is back and confirmed running what was written. Continue to set up your outputs.")

        case .failed(let error):
            VStack(spacing: 12) {
                installFailureCard(error)
                Button("Try Again") { resetInstallRun() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Shown whenever the user may need to put a board into BOOTSEL by hand.
    private var showBootselHint: Bool {
        switch installer.state {
        case .idle, .waitingForBoard:
            return !vm.isDeviceConnected || confirmed
        case .failed(.noBoardFound):
            return true
        default:
            return false
        }
    }

    /// Records the user's decision to install onto a board already in BOOTSEL.
    /// Arming is a decision about this one update; the installer writes as
    /// soon as the board is ready, which it already is.
    private func beginInstall() {
        confirmed = true
        installer.installWhenReady()
    }

    /// Commits to updating the connected, out-of-date device: arms the
    /// installer, then asks the device to restart into bootloader mode.  The
    /// order the user and the hardware arrive in stops mattering; the write
    /// begins when the BOOTSEL drive appears.
    private func beginUpdateOfConnectedDevice() {
        confirmed = true
        installer.installWhenReady()
        guard !rebootRequested else { return }
        rebootRequested = true
        // The device drops off the bus answering this, so there is no reply
        // to wait for.
        _ = vm.usb.getControlRequest(request: REQ_ENTER_BOOTLOADER, value: 0, index: 2, length: 1)
    }

    /// Starts the install flow over after a failure: the view's flags and the
    /// installer's freeze and commitment together, because clearing only one
    /// side leaves the other believing a run is still in progress.
    private func resetInstallRun() {
        confirmed = false
        rebootRequested = false
        installer.reset()
    }

    // MARK: Outputs

    /// One row per physical output the connected device has.  The DSPi cannot
    /// tell what is wired to it, so the user says which outputs are in use and
    /// which GPIO pins carry them - edited right here, applied to the device
    /// live, and committed when the user continues.
    private struct OutputRowModel: Identifiable {
        let id: Int              // index into vm.outputPins
        let title: String
        let typeLabel: String
        let color: Color
        let matrixChannels: [Int]
    }

    private var outputRows: [OutputRowModel] {
        let slots = vm.numOutputSlots
        let matrixOutputs = MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes)
        var rows = (0..<slots).map { slot in
            OutputRowModel(id: slot,
                           title: "OUT \(slot * 2 + 1)/\(slot * 2 + 2)",
                           typeLabel: vm.outputSlotTypes[slot] == 1 ? "I2S" : "S/PDIF",
                           color: matrixOutputs[slot * 2 + 1].color,
                           matrixChannels: [slot * 2, slot * 2 + 1])
        }
        rows.append(OutputRowModel(id: vm.pdmPinIndex,
                                   title: "Sub",
                                   typeLabel: "PDM",
                                   color: MatrixOutput.pdmColor,
                                   matrixChannels: [vm.pdmOutputIndex]))
        return rows
    }

    /// STM32 builds drive fixed peripheral pins; there is nothing to assign.
    private var pinsAssignable: Bool { vm.platformName != "STM32H723" }

    private var outputsStage: some View {
        stepBody(title: "Choose your outputs",
                 blurb: "The DSPi cannot tell what you have wired to it. Switch on the outputs your build uses\(pinsAssignable ? " and check each one's GPIO pin matches your wiring" : ""). Everything applies immediately and can be changed later in Settings.") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(outputRows) { row in
                    outputRow(row)
                }

                if let message = outputStatus {
                    HStack(spacing: 6) {
                        Image(systemName: outputStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(outputStatusIsError ? .orange : .green)
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundColor(outputStatusIsError ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupCard()

            infoRow("lightbulb", "Not sure? The defaults match the standard DSPi wiring, and outputs you switch off can simply stay unwired.")
        }
    }

    /// Fixed-width columns so the switches, names, types and pin pickers line
    /// up across rows whatever their content.
    private func outputRow(_ row: OutputRowModel) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding(row))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

            Circle()
                .fill(row.color)
                .frame(width: 8, height: 8)

            Text(row.title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 74, alignment: .leading)

            Text(row.typeLabel)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)

            Spacer(minLength: 8)

            if pinsAssignable {
                Picker("", selection: pinBinding(row)) {
                    ForEach(pinOptions(for: row), id: \.self) { pin in
                        Text("GPIO \(pin)").tag(pin)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Sized for the longest label ("GPIO 28") so every picker is
                // the same width, right-aligned to the row edge.
                .frame(width: 92, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func enabledBinding(_ row: OutputRowModel) -> Binding<Bool> {
        Binding(
            get: { row.matrixChannels.contains { vm.outputEnabled.indices.contains($0) && vm.outputEnabled[$0] } },
            set: { on in
                for channel in row.matrixChannels {
                    vm.setOutputEnable(output: channel, enabled: on)
                }
            })
    }

    /// The same candidate rule as Settings: any valid pin not owned by another
    /// consumer, with the current selection always kept so the picker renders.
    private func pinOptions(for row: OutputRowModel) -> [UInt8] {
        HardwareSettingsTab.validPins.filter {
            $0 == vm.outputPins[row.id] || vm.pinInUseBy($0, excluding: .output(row.id)) == nil
        }
    }

    private func pinBinding(_ row: OutputRowModel) -> Binding<UInt8> {
        Binding(
            get: { vm.outputPins.indices.contains(row.id) ? vm.outputPins[row.id] : 0 },
            set: { newPin in
                SettingsSaveCoordinator.shared.beginOutputEdit()
                let status = vm.assignOutputPin(output: row.id, pin: newPin)
                switch status {
                case PIN_CONFIG_SUCCESS:
                    outputStatus = "\(row.title) moved to GPIO \(newPin)"
                    outputStatusIsError = false
                case PIN_CONFIG_PIN_IN_USE:
                    if let owner = vm.pinInUseBy(newPin, excluding: .output(row.id)) {
                        outputStatus = "GPIO \(newPin) is already assigned to \(owner)"
                    } else {
                        outputStatus = "GPIO \(newPin) is already in use"
                    }
                    outputStatusIsError = true
                    vm.fetchOutputPin(output: row.id)
                case PIN_CONFIG_INVALID_PIN:
                    outputStatus = "GPIO \(newPin) is not available on this device"
                    outputStatusIsError = true
                    vm.fetchOutputPin(output: row.id)
                default:
                    outputStatus = "The device refused the change"
                    outputStatusIsError = true
                    vm.fetchOutputPin(output: row.id)
                }
            })
    }

    /// Pulls the device's live output state so the rows show the truth, not
    /// whatever the app last cached.
    private func refreshOutputState() {
        guard vm.isDeviceConnected else { return }
        for row in outputRows {
            vm.fetchOutputPin(output: row.id)
            for channel in row.matrixChannels {
                vm.fetchOutputEnable(output: channel)
            }
        }
        for slot in 0..<vm.numOutputSlots {
            vm.fetchOutputSlotType(slot: slot)
        }
    }

    /// Commits pin changes made here to the device's flash, so a first-time
    /// user's configuration survives a power cycle without them having to know
    /// about the save model yet.  Scoped to the output config only: the
    /// wizard must never quietly commit unrelated pending edits.
    private func commitOutputConfigIfDirty() {
        let coordinator = SettingsSaveCoordinator.shared
        guard coordinator.outputDirty, vm.isDeviceConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = vm.saveOutputConfig()
            DispatchQueue.main.async {
                if ok { coordinator.outputConfigDirty = false }
            }
        }
    }

    // MARK: Audio

    private var audioStage: some View {
        stepBody(title: "Send audio to the DSPi",
                 blurb: "macOS needs to be told to play through the DSPi. Open Sound settings, choose the DSPi as the output device, then play something.") {
            Button("Open Sound Settings...") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.large)

            if sawSignal {
                statusRow(.ok, "Signal detected. Your computer's audio is reaching the DSPi.")
            } else {
                statusRow(.waiting, "Listening for audio. Play something and this will confirm itself.")
            }
        }
    }

    // MARK: Done

    private var doneStage: some View {
        stepBody(title: "You are set up",
                 blurb: sawSignal
                    ? "Audio is reaching the DSPi. From here you can shape it however you like."
                    : "Setup is done. If you have not heard anything yet, check that the DSPi is selected as your output device in Sound settings.") {
            infoRow("slider.horizontal.3", "Click an input or output in the sidebar to edit its filters.")
            infoRow("square.and.arrow.down", "Changes live in memory until you commit them to the device.")
            infoRow("questionmark.circle", "Help holds release notes and links, and this wizard can be run again.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            // Always visible, always one click, and it never comes back: a
            // skip that reappears next launch is not a skip.
            Button("Skip Setup") { finish() }

            Spacer()

            if let previous = previousStage, !installInFlight {
                Button("Back") { current = previous }
            }

            if showsContinue {
                Button(current == .done ? "Start Using DSPi Console" : "Continue") { advance() }
                    .keyboardShortcut(continueIsDefault ? .defaultAction : nil)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var previousStage: Stage? {
        let stages = visibleStages
        guard let index = stages.firstIndex(of: current), index > 0 else { return nil }
        return stages[index - 1]
    }

    private var installInFlight: Bool {
        switch installer.state {
        case .writing, .waitingForDevice: return true
        default: return false
        }
    }

    /// The board stage has no Continue while it still has work to do: with no
    /// device it completes on its own, and mid-install there is nothing to
    /// continue to yet.  A disabled button would say "you cannot do this";
    /// showing no button says "nothing is asked of you".
    private var showsContinue: Bool {
        switch current {
        case .board:
            return vm.isDeviceConnected && !installInFlight
        default:
            return true
        }
    }

    /// The install and update buttons own the return key while on screen; the
    /// footer's Continue steps back to an ordinary button so the blue always
    /// marks the action the step is actually about.
    private var continueIsDefault: Bool {
        guard current == .board, !confirmed else { return true }
        if case .ready = installer.state { return false }
        if case .idle = installer.state, vm.firmwareMatch == .deviceOlder { return false }
        if case .waitingForBoard = installer.state, vm.firmwareMatch == .deviceOlder { return false }
        return true
    }

    private func advance() {
        if current == .outputs { commitOutputConfigIfDirty() }
        let stages = visibleStages
        guard let index = stages.firstIndex(of: current), index + 1 < stages.count else {
            finish()
            return
        }
        current = stages[index + 1]
    }

    // MARK: Pieces

    private func stepBody<Content: View>(title: String,
                                         blurb: String,
                                         @ViewBuilder extra: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(blurb)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) { extra() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(.accentColor)
                .frame(width: 20)          // fixed so the text column lines up
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private enum StatusKind { case ok, waiting }

    private func statusRow(_ kind: StatusKind, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch kind {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .waiting:
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(kind == .ok ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: State

    private var bundledVersion: String { FirmwareVersion.expected?.description ?? "unknown" }

    private var deviceVersionText: String {
        guard let v = vm.firmwareVersion else { return "unknown" }
        return FirmwareVersion(v.major, v.minor, v.patch).description
    }

    /// Any input channel showing level.  The threshold is above the noise a
    /// silent input reports, low enough that quiet music still counts.
    private var inputSignalPresent: Bool {
        guard vm.isDeviceConnected else { return false }
        let peaks = vm.meters.status.peaks
        return peaks.prefix(max(vm.numMatrixInputs, 2)).contains { $0 > 0.002 }
    }

    private func finish() {
        onboarding.finishSetup()
    }
}
