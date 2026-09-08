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
/// The wizard has exactly one objective: a Pico running verified DSPi
/// firmware.  Outputs, wiring and audio routing all belong to the app proper,
/// where they can be revisited; a wizard that keeps going past its goal is
/// one people learn to dismiss.  Nothing on screen is ever something the user
/// cannot act on: the firmware install happens right here, so no step hands
/// the user off to another window.
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
         startAtStageForTesting stage: Int) {
        self.vm = vm
        _installer = StateObject(wrappedValue: installer ?? FirmwareInstaller(
            locator: SystemBootloaderLocator(),
            verifier: ViewModelFirmwareVerifier(vm: vm)))
        _current = State(initialValue: Stage(rawValue: stage) ?? .welcome)
    }
    #endif

    // MARK: The stages

    /// Every step, in order.  The list used to bend around what was plugged
    /// in; with the goal cut back to verified firmware, the journey is the
    /// same for everyone.
    private enum Stage: Int, CaseIterable {
        case welcome, board, done

        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .board:   return "Board"
            case .done:    return "Done"
            }
        }
    }

    @State private var current: Stage = .welcome

    /// Set when the user commits to a firmware install.  The installer never
    /// flashes on its own; this records the one explicit decision.
    @State private var confirmed = false
    /// Whether the connected device has already been told to restart into
    /// bootloader mode, so a second click cannot reboot it twice.
    @State private var rebootRequested = false
    /// Chip of the board most recently seen by detection, remembered so the
    /// writing card can still name it once the board leaves `.ready`.
    @State private var lastSeenChip: BootloaderBoard.Chip?

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
        .onChange(of: installer.state) { _, state in
            switch state {
            case .ready(let board): lastSeenChip = board.chip
            case .waitingForVolume(let chip): lastSeenChip = chip
            default: break
            }
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

            StepDotStrip(labels: Stage.allCases.map(\.label),
                         current: current.rawValue,
                         dotWidth: 60)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        "Step \(current.rawValue + 1) of \(Stage.allCases.count)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome: welcomeStage
        case .board:   boardStage
        case .done:    doneStage
        }
    }

    // MARK: Welcome

    private var welcomeStage: some View {
        stepBody(title: "Welcome to DSPi Console",
                 blurb: "DSPi turns a Raspberry Pi Pico into a remarkably capable audio processor: equalisation, crossovers, upmixing, loudness compensation and more, applied live to whatever you play.\n\nSetup is short and has one job: getting the DSPi firmware onto your Pico. Once it is running, everything else is set up in the app as you need it.") {
            infoRow("bolt.horizontal.circle", "Connect your Pico and install the DSPi firmware, right here.")
            infoRow("checkmark.seal", "The board restarts and the app confirms the install worked.")
            infoRow("slider.horizontal.3", "Outputs, wiring and audio are then yours to shape in the console.")
        }
    }

    // MARK: Board

    /// Firmware and connection, handled entirely in place.  The installer's
    /// states render right here; there is no second window.  A spinner means
    /// the app or the hardware is working; a still icon means the next move
    /// is the user's, and the card says exactly what that move is.
    private var boardStage: some View {
        stepBody(title: boardStageTitle, blurb: boardStageBlurb) {
            // No separate BOOTSEL footnote: the card that needs those
            // instructions carries them itself, and repeating them beneath it
            // made the same sentence appear twice on one screen.
            boardStatusCard
                .frame(minHeight: 190)
        }
    }

    private var boardStageTitle: String {
        switch installer.state {
        case .verified: return "Your device has been prepared"
        case .failed: return "Something needs attention"
        case .writing, .waitingForDevice: return "Installing firmware"
        default:
            switch connectedDeviceMatch {
            case .match: return "Your device is ready"
            case .deviceOlder: return "Update your firmware"
            case .deviceNewer: return "Your firmware is newer"
            case nil: return "Prepare your Pico"
            }
        }
    }

    private var boardStageBlurb: String {
        switch installer.state {
        case .writing, .waitingForDevice:
            return "Console ships the firmware it expects, so nothing needs a download. Keep the Pico plugged in until it checks back in."
        case .verified:
            return "The device has successfully restarted and DSPi Firmware is correctly installed."
        case .failed:
            return "This is almost always fixable. Follow the card below, then try again - nothing has been lost."
        default:
            switch connectedDeviceMatch {
            case .match:
                return "This step installs the DSPi firmware, and your connected device is already running it. There is nothing to do here."
            case .deviceOlder:
                return "Your DSPi is already connected, so no buttons need holding: the app can restart it and install the matching firmware in one step."
            case .deviceNewer:
                return "This Console ships an older firmware than your device is running. Updating the app is usually the better fix, but you can also downgrade the device to match."
            case nil:
                return "In this step, we are going to install the DSPi firmware on your Pico-compatible device. Follow the directions below."
            }
        }
    }

    /// The running, already-connected DSPi the board step should talk about
    /// instead of hunting for a bootloader, if there is one.
    ///
    /// Only while detection is still looking and nothing has been committed:
    /// once a bootloader board is on the bus or an install is underway, the
    /// installer's own states own the screen.
    private var connectedDeviceMatch: FirmwareMatch? {
        guard !confirmed, vm.isDeviceConnected else { return nil }
        switch installer.state {
        case .idle, .waitingForBoard: return vm.firmwareMatch
        default: return nil
        }
    }

    private var deviceVersion: String? {
        guard let v = vm.firmwareVersion else { return nil }
        return FirmwareVersion(v.major, v.minor, v.patch, v.beta).description
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
                    title: "Looking for your Pico",
                    message: "Waiting for it to appear in bootloader mode. If nothing happens after a few seconds, unplug it, hold BOOTSEL, and plug it back in.")
            } else if let match = connectedDeviceMatch {
                connectedDeviceCard(match)
            } else {
                InstallStateCard(
                    icon: "cable.connector",
                    tint: .accentColor,
                    spinning: true,
                    title: "Waiting for your Pico",
                    message: "Hold the BOOTSEL button while connecting your Pico-compatible device to your computer. Once detected, it will appear here.")
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
                InstallStateCard(
                    icon: "externaldrive.badge.checkmark",
                    tint: .green,
                    title: "\(board.chip.displayName) ready",
                    message: "The device is now in bootloader mode and ready to receive firmware.",
                    accessory: AnyView(
                        Button("Install DSPi Firmware") { beginInstall() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    ))
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
                message: "That was the whole job. Continue to finish setup.")

        case .failed(let error):
            VStack(spacing: 12) {
                installFailureCard(error)
                Button("Try Again") { resetInstallRun() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// The card for a DSPi that is already connected and running.  Setup can
    /// finish without a single bootloader button: a current device sails
    /// through, and a mismatched one is updated in place the same way the
    /// Firmware Update window does it.
    @ViewBuilder
    private func connectedDeviceCard(_ match: FirmwareMatch) -> some View {
        switch match {
        case .match:
            InstallStateCard(
                icon: "checkmark.seal.fill",
                tint: .green,
                iconSize: 36,
                title: "Firmware \(bundledVersion) already installed",
                message: "Your DSPi is running the firmware this Console ships, so there is nothing to install. Continue to finish setup.")

        case .deviceOlder:
            InstallStateCard(
                icon: "arrow.up.circle",
                tint: .accentColor,
                title: "Firmware update available",
                message: "Your DSPi is running firmware \(deviceVersion ?? "unknown"); this Console pairs with \(bundledVersion). The device will restart into bootloader mode and come back updated. Audio stops until it finishes.",
                accessory: AnyView(
                    Button("Update DSPi Firmware") { beginConnectedDeviceInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                ))

        case .deviceNewer:
            InstallStateCard(
                icon: "arrow.down.circle",
                tint: .orange,
                title: "This would be a downgrade",
                message: "Your DSPi is running firmware \(deviceVersion ?? "unknown"), which is newer than this Console expects (\(bundledVersion)). A newer Console is the better fix, but you can downgrade the device to match this one.",
                accessory: AnyView(
                    Button("Downgrade Firmware") { beginConnectedDeviceInstall() }
                        .controlSize(.large)
                ))
        }
    }

    /// Records the user's decision to install onto a board already in BOOTSEL.
    /// Arming is a decision about this one update; the installer writes as
    /// soon as the board is ready, which it already is.
    private func beginInstall() {
        confirmed = true
        installer.installWhenReady()
    }

    /// Commits to updating the device that is already connected and running.
    /// Mirrors the Firmware Update window: arm the installer, then ask the
    /// device to restart into bootloader mode.  It drops off the bus while
    /// answering, so there is no reply to wait for.
    private func beginConnectedDeviceInstall() {
        confirmed = true
        installer.installWhenReady()
        guard !rebootRequested else { return }
        rebootRequested = true
        _ = vm.transport.getControlRequest(request: REQ_ENTER_BOOTLOADER, value: 0, index: 2, length: 1)
    }

    /// Starts the install flow over after a failure: the view's flags and the
    /// installer's freeze and commitment together, because clearing only one
    /// side leaves the other believing a run is still in progress.
    private func resetInstallRun() {
        confirmed = false
        rebootRequested = false
        installer.reset()
    }

    // MARK: Done

    /// Reached only through a verified install, so it can assert the firmware
    /// is running and point at what the app offers from here.
    private var doneStage: some View {
        stepBody(title: "You are set up",
                 blurb: "Your Pico is running the DSPi firmware, and the console is ready whenever it is plugged in. A few places worth knowing about:") {
            infoRow("cable.connector", "Choose which outputs your build uses, and the pins that carry them, in Settings under Hardware.")
            infoRow("speaker.wave.2", "Pick the DSPi as the output device in macOS Sound settings to hear your computer through it.")
            infoRow("slider.horizontal.3", "Click an input or output in the sidebar to edit its filters.")
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

            if let previous = Stage(rawValue: current.rawValue - 1), !installInFlight {
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

    private var installInFlight: Bool {
        switch installer.state {
        case .writing, .waitingForDevice: return true
        default: return false
        }
    }

    /// The board stage has no Continue while it still has work to do: mid-
    /// install there is nothing to continue to yet.  A disabled button would
    /// say "you cannot do this"; showing no button says "nothing is asked of
    /// you".
    private var showsContinue: Bool {
        switch current {
        case .board:
            // Either the firmware went on and was confirmed, or the connected
            // device is already running exactly what this Console ships and
            // the step has nothing to install.  A mismatched device gets the
            // update offer instead of a Continue, so the wizard's goal stays
            // firmware this Console can actually drive.
            if case .verified = installer.state { return true }
            return connectedDeviceMatch == .match
        default:
            return true
        }
    }

    /// The install button owns the return key while on screen; the footer's
    /// Continue steps back to an ordinary button so the blue always marks the
    /// action the step is actually about.
    private var continueIsDefault: Bool {
        guard current == .board, !confirmed else { return true }
        if case .ready = installer.state { return false }
        return true
    }

    private func advance() {
        guard let next = Stage(rawValue: current.rawValue + 1) else {
            finish()
            return
        }
        current = next
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

    // MARK: State

    private var bundledVersion: String { FirmwareVersion.expected?.description ?? "unknown" }

    private func finish() {
        onboarding.finishSetup()
    }
}
