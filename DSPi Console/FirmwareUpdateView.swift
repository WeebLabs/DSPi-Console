import SwiftUI

// MARK: - Window Controller

class FirmwareUpdateWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Firmware Update"
            window?.isReleasedWhenClosed = false
            window?.delegate = self
        }
        // Fresh content on every open.  The view owns the installer, so a
        // reused hosting view would resurrect the last run's terminal state
        // and its already-spent confirmation; each open must start at
        // detection.
        window?.contentView = NSHostingView(rootView: FirmwareUpdateView(
            vm: vm,
            onClose: { [weak self] in self?.hide() }))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
        tearDownContent()
    }

    /// Releases the hosting view, and with it the installer and its locator.
    /// `orderOut` alone left the locator's one-second poll and workspace
    /// observers running for the life of the app, because a hidden-not-closed
    /// window never fires the view's `onDisappear`.  Deferred a turn of the
    /// run loop so the view is never torn down from inside its own button
    /// action, and skipped if the window was reopened in the meantime.
    private func tearDownContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible else { return }
            self.window?.contentView = NSView()
        }
    }
}

extension FirmwareUpdateWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
        tearDownContent()
    }
}

// MARK: - Update View

/// Installs the bundled firmware onto the connected device, or onto a board
/// the user has already put into BOOTSEL.
///
/// Replaces the old "reboot into the bootloader and drag a file yourself"
/// alert.  The user confirms once, here; everything after that is the
/// installer's state machine, including the reboot into BOOTSEL that used to
/// be the whole feature.
struct FirmwareUpdateView: View {
    @ObservedObject var vm: DSPViewModel
    @StateObject private var installer: FirmwareInstaller

    /// Closes this view's own window.  A closure from the controller rather
    /// than `NSApp.keyWindow?.close()`, which closed whichever window
    /// happened to be key - not necessarily this one.
    let onClose: () -> Void

    /// Set when the user commits to the update.  The installer never flashes
    /// on its own, so a board reaching `.ready` only starts a write once this
    /// is true.
    @State private var confirmed = false
    @State private var rebootRequested = false

    /// Chip of the board most recently seen by detection, remembered so the
    /// writing card can still name it: the `.writing` state carries only a
    /// fraction, and by then the board is no longer in `.ready`.
    @State private var lastSeenChip: BootloaderBoard.Chip?

    /// `installer` is injectable so the Getting Started wizard (and tests) can
    /// drive the same view with their own instance; by default the view owns a
    /// system-backed one.
    init(vm: DSPViewModel, installer: FirmwareInstaller? = nil, onClose: @escaping () -> Void = {}) {
        self.vm = vm
        self.onClose = onClose
        _installer = StateObject(wrappedValue: installer ?? FirmwareInstaller(
            locator: SystemBootloaderLocator(),
            verifier: ViewModelFirmwareVerifier(vm: vm)))
    }

    private var bundledVersion: String { FirmwareVersion.expected?.description ?? "unknown" }

    private var deviceVersion: String? {
        guard let v = vm.firmwareVersion else { return nil }
        return FirmwareVersion(v.major, v.minor, v.patch).description
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 14) {
                versionSummary

                StepStrip(current: currentStep, dimmed: isFailed)

                statusCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showBootselHint {
                    bootselHint
                }
            }
            .padding(16)

            Divider()

            buttonRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 460, height: 470)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: installer.state) { _, state in
            switch state {
            case .ready(let board): lastSeenChip = board.chip
            case .waitingForVolume(let chip): lastSeenChip = chip
            default: break
            }
        }
        .onAppear { installer.beginWatching() }
        .onDisappear { installer.stopWatching() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Firmware Update")
                    .font(.system(size: 14, weight: .semibold))
                Text("Install firmware \(bundledVersion) onto a DSPi board")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Version summary

    /// The two versions in play, as a labelled table rather than prose.  The
    /// fixed label column keeps the values aligned however long the labels get.
    private var versionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow(label: "This Console", value: bundledVersion)
            summaryRow(label: "Connected device",
                       value: deviceVersion ?? "None",
                       secondary: deviceVersion == nil)
            if vm.firmwareMatch == .deviceNewer {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                    Text("The device is newer than this Console, so this would be a downgrade.")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.orange)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func summaryRow(label: String, value: String, secondary: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(secondary ? .secondary : .primary)
        }
    }

    // MARK: Step strip

    private var currentStep: UpdateStep {
        switch installer.state {
        case .idle, .waitingForBoard, .waitingForVolume, .ready: return .prepare
        case .writing: return .write
        case .waitingForDevice: return .verify
        case .verified: return .done
        case .failed: return .prepare   // dimmed; the card carries the story
        }
    }

    private var isFailed: Bool {
        if case .failed = installer.state { return true }
        return false
    }

    // MARK: Status card

    @ViewBuilder
    private var statusCard: some View {
        switch installer.state {
        case .idle, .waitingForBoard:
            if confirmed {
                stateCard(
                    icon: "magnifyingglass",
                    tint: .accentColor,
                    spinning: true,
                    title: "Looking for the board",
                    body: "Waiting for it to appear in bootloader mode. If nothing happens after a few seconds, unplug the board, hold BOOTSEL, and plug it back in.")
            } else if vm.isDeviceConnected {
                stateCard(
                    icon: "checkmark.circle",
                    tint: .accentColor,
                    title: "Ready when you are",
                    body: "Click Update Firmware to begin. The device will restart into bootloader mode, and audio will stop until the update finishes. Nothing is written without this click.")
            } else {
                stateCard(
                    icon: "cable.connector",
                    tint: .secondary,
                    title: "Connect a board",
                    body: "No device is connected. Hold the BOOTSEL button while plugging a board in, and it will appear here.")
            }

        case .waitingForVolume(let chip):
            stateCard(
                icon: "externaldrive",
                tint: .accentColor,
                spinning: true,
                title: "\(chip.displayName) found",
                body: "The board is in bootloader mode. Waiting for its \(chip.volumeName) drive to mount - this usually takes a second or two.")

        case .ready(let board):
            if confirmed {
                stateCard(
                    icon: "externaldrive.badge.checkmark",
                    tint: .accentColor,
                    spinning: true,
                    title: "Preparing to write",
                    body: "Opening the \(board.chip.displayName)'s \(board.chip.volumeName) drive.")
            } else {
                stateCard(
                    icon: "externaldrive.badge.checkmark",
                    tint: .green,
                    title: "\(board.chip.displayName) ready",
                    body: "The board is in bootloader mode and ready to receive firmware \(bundledVersion). Click \(primaryTitle) to begin.")
            }

        case .writing(let fraction):
            writingCard(fraction: fraction)

        case .waitingForDevice:
            stateCard(
                icon: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                spinning: true,
                title: "Firmware written",
                body: "The board is restarting with its new firmware. This can take up to half a minute; leave it plugged in.")

        case .verified(let version):
            stateCard(
                icon: "checkmark.seal.fill",
                tint: .green,
                iconSize: 36,
                title: "Update complete",
                body: "The device is back and confirmed running firmware \(version).")

        case .failed(let error):
            failureCard(error)
        }
    }

    /// One centred state: an icon or spinner, a short title, and one or two
    /// sentences of explanation.  A spinner always means the app or the
    /// hardware is doing the work; a still icon means the next move is the
    /// user's, and the body says exactly what that move is.
    private func stateCard(icon: String,
                           tint: Color,
                           spinning: Bool = false,
                           iconSize: CGFloat = 28,
                           title: String,
                           body: String) -> some View {
        VStack(spacing: 10) {
            if spinning {
                ProgressView()
                    .controlSize(.regular)
                    .frame(height: iconSize)
            } else {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundColor(tint)
                    .frame(height: iconSize)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(body)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    /// The write in progress: who is being written, what is being written, how
    /// far along it is, and a line saying the alarming-looking ending - the
    /// drive vanishing - is the normal one.
    private func writingCard(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Writing firmware")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ProgressView(value: fraction)

            VStack(alignment: .leading, spacing: 4) {
                summaryRow(label: "Board", value: writingBoardName)
                summaryRow(label: "Firmware", value: bundledVersion)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            Label("Near the end the board restarts itself and its drive disappears. That is normal - do not unplug it.",
                  systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    /// Name of the chip being written.  A write is only ever started from
    /// `.ready`, so the chip remembered on the way there is always the one
    /// under the pen; the fallback can only show if that assumption breaks.
    private var writingBoardName: String {
        lastSeenChip?.displayName ?? "Raspberry Pi Pico"
    }

    /// A failure, dressed to match its severity.  Detection-side stumbles - no
    /// board yet, a drive that has not mounted - are ordinary and read that
    /// way; a failure after bytes have moved gets the warning triangle.
    private func failureCard(_ error: FirmwareInstallError) -> some View {
        let mundane: Bool
        switch error {
        case .noBoardFound, .volumeNotMounted, .multipleBoards:
            mundane = true
        default:
            mundane = false
        }
        return stateCard(
            icon: mundane ? "questionmark.circle" : "exclamationmark.triangle.fill",
            tint: .orange,
            title: mundane ? "Not quite ready" : "The update did not complete",
            body: error.message)
    }

    // MARK: BOOTSEL hint

    /// Shown whenever the user may need to put a board into BOOTSEL by hand:
    /// before anything is connected, while a committed update hunts for the
    /// board, and after a no-board failure.
    private var showBootselHint: Bool {
        switch installer.state {
        case .idle, .waitingForBoard:
            return confirmed || !vm.isDeviceConnected
        case .failed(.noBoardFound):
            return true
        default:
            return false
        }
    }

    private var bootselHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "button.programmable")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("BOOTSEL is the small button on the Pico board. Hold it down while plugging in the USB cable and the board starts in bootloader mode, ready to receive firmware.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Buttons

    private var primaryTitle: String {
        vm.firmwareMatch == .deviceNewer ? "Downgrade" : "Update Firmware"
    }

    private var buttonRow: some View {
        HStack {
            if case .verified = installer.state {
                // A second board is a second decision: this returns to
                // detection with nothing armed, it does not re-run the
                // update.
                Button("Update Another Board") { resetRun() }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { onClose() }
                // A UF2 write does not target the preset sectors, but a
                // wire-format change between versions can leave them
                // unreadable, and the device is about to become
                // unreachable either way.  Offered rather than forced:
                // a blank board has nothing worth saving.
                if vm.isDeviceConnected, !confirmed {
                    Button("Export Configuration...") {
                        FileMenuActions.exportConfiguration()
                    }
                }
                Spacer()
                primaryButton
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch installer.state {
        case .failed:
            Button("Try Again") { resetRun() }
                .keyboardShortcut(.defaultAction)

        case .writing, .waitingForDevice:
            EmptyView()

        default:
            Button(primaryTitle) {
                start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(confirmed)
        }
    }

    /// Commits to the update.  The installer writes as soon as a board is
    /// ready, whether that is now or after the reboot below, so the order the
    /// user and the hardware arrive in stops mattering.
    private func start() {
        confirmed = true
        installer.installWhenReady()
        guard vm.isDeviceConnected, !rebootRequested else { return }
        rebootRequested = true
        // The device drops off the bus answering this, so there is no reply to
        // wait for.
        _ = vm.usb.getControlRequest(request: REQ_ENTER_BOOTLOADER, value: 0, index: 2, length: 1)
    }

    /// Starts the whole flow over: the view's flags and the installer's
    /// freeze and commitment together, because clearing only one side leaves
    /// the other believing a run is still in progress.  Backs both
    /// Try Again and Update Another Board.
    private func resetRun() {
        confirmed = false
        rebootRequested = false
        installer.reset()
    }
}

// MARK: - Step Strip

/// The four stops of an update.  Small enough to read in a glance, so the user
/// always knows how far along the process is and how much is left.
private enum UpdateStep: Int, CaseIterable {
    case prepare, write, verify, done

    var label: String {
        switch self {
        case .prepare: return "Prepare"
        case .write: return "Write"
        case .verify: return "Verify"
        case .done: return "Done"
        }
    }
}

private struct StepStrip: View {
    let current: UpdateStep
    /// A failure keeps the strip on screen but takes the emphasis off it; the
    /// status card is telling the real story.
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UpdateStep.allCases, id: \.rawValue) { step in
                if step != .prepare {
                    Rectangle()
                        .fill(connectorColor(into: step))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                }
                stepDot(step)
            }
        }
        .padding(.horizontal, 8)
        .opacity(dimmed ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    private func stepDot(_ step: UpdateStep) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(fillColor(step))
                    .frame(width: 14, height: 14)
                if step.rawValue < current.rawValue || (step == .done && current == .done) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            Text(step.label)
                .font(.system(size: 9, weight: step == current ? .bold : .regular))
                .foregroundColor(step == current ? .primary : .secondary)
        }
        // Fixed width so the labels sit centred under their dots and the
        // connectors between dots stay equal, whatever the labels say.
        .frame(width: 52)
    }

    private func fillColor(_ step: UpdateStep) -> Color {
        if step.rawValue < current.rawValue { return .accentColor }
        if step == current { return current == .done ? .green : .accentColor }
        return Color.secondary.opacity(0.25)
    }

    private func connectorColor(into step: UpdateStep) -> Color {
        step.rawValue <= current.rawValue ? Color.accentColor.opacity(0.6)
                                          : Color.secondary.opacity(0.2)
    }
}

// MARK: - Mismatch Banner

/// Shown across the top of the main window only when the connected device's
/// firmware differs from what this Console expects.
///
/// A mismatch is a genuinely broken state rather than a nag: feature gating
/// reads the device's version, so the wrong firmware means controls that do
/// nothing or are missing entirely.  It stays hidden whenever the versions
/// agree, or whenever we know too little to be sure.
struct FirmwareMismatchBanner: View {
    @ObservedObject var vm: DSPViewModel
    let onUpdate: () -> Void

    var body: some View {
        if let match = vm.firmwareMatch, match != .match {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(match == .deviceNewer ? "Details..." : "Update...", action: onUpdate)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    private var message: String {
        let expected = FirmwareVersion.expected?.description ?? "unknown"
        let device = vm.firmwareVersion.map { FirmwareVersion($0.major, $0.minor, $0.patch).description } ?? "unknown"
        switch vm.firmwareMatch {
        case .deviceNewer:
            return "This device runs firmware \(device), which is newer than DSPi Console \(expected). Some of its features may not be shown."
        default:
            return "This device runs firmware \(device); DSPi Console expects \(expected)."
        }
    }
}
