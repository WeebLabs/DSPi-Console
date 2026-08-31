import SwiftUI

// MARK: - Window Controller

class FirmwareUpdateWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
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

    init(vm: DSPViewModel, onClose: @escaping () -> Void = {}) {
        self.vm = vm
        self.onClose = onClose
        _installer = StateObject(wrappedValue: FirmwareInstaller(
            locator: SystemBootloaderLocator(),
            verifier: ViewModelFirmwareVerifier(vm: vm)))
    }

    private var bundledVersion: String { FirmwareVersion.expected?.description ?? "unknown" }

    private var deviceVersion: String? {
        guard let v = vm.firmwareVersion else { return nil }
        return FirmwareVersion(v.major, v.minor, v.patch).description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            statusArea
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

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
        .padding(20)
        .frame(width: 420, height: 300)
        .onAppear { installer.beginWatching() }
        .onDisappear { installer.stopWatching() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Firmware Update").font(.headline)
            if let deviceVersion {
                Text("This device is running firmware \(deviceVersion). This Console ships \(bundledVersion).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Text("This Console ships firmware \(bundledVersion).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            if vm.firmwareMatch == .deviceNewer {
                Text("The device is newer than this Console, so this would be a downgrade.")
                    .font(.callout)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch installer.state {
        case .idle, .waitingForBoard:
            if confirmed {
                waiting("Waiting for the board to appear in bootloader mode. If nothing happens, unplug it, hold BOOTSEL, and plug it back in.")
            } else if vm.isDeviceConnected {
                Text("The device will restart into bootloader mode, and audio will stop until the update finishes.")
                    .foregroundColor(.secondary)
            } else {
                Text("No device is connected. Hold the BOOTSEL button while plugging a board in, and it will appear here.")
                    .foregroundColor(.secondary)
            }

        case .waitingForVolume(let chip):
            waiting("A \(chip.displayName) is in bootloader mode. Waiting for its \(chip.volumeName) drive to appear.")

        case .ready(let board):
            if confirmed {
                waiting("Preparing to write to the \(board.chip.displayName).")
            } else {
                Text("A \(board.chip.displayName) is in bootloader mode and ready to receive firmware \(bundledVersion).")
                    .foregroundColor(.secondary)
            }

        case .writing(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Writing firmware \(bundledVersion)...")
                ProgressView(value: fraction)
            }

        case .waitingForDevice:
            waiting("Firmware written. Waiting for the device to restart.")

        case .verified(let version):
            Label("The device is running firmware \(version).", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)

        case .failed(let error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundColor(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
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
            Button(vm.firmwareMatch == .deviceNewer ? "Downgrade" : "Update Firmware") {
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
