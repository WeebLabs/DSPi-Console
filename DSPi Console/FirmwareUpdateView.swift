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
            window?.contentView = NSHostingView(rootView: FirmwareUpdateView(vm: vm))
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

extension FirmwareUpdateWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { isVisible = false }
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

    /// Set when the user commits to the update.  The installer never flashes
    /// on its own, so a board reaching `.ready` only starts a write once this
    /// is true.
    @State private var confirmed = false
    @State private var rebootRequested = false

    init(vm: DSPViewModel) {
        self.vm = vm
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
                    Spacer()
                    Button("Done") { NSApp.keyWindow?.close() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { NSApp.keyWindow?.close() }
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
        .onChange(of: installer.state) { state in
            // The user has already confirmed; a board arriving is the go
            // signal.  Without the flag this would flash anything plugged in.
            if case .ready(let board) = state, confirmed {
                installer.install(board)
            }
        }
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
            Button("Try Again") {
                confirmed = false
                rebootRequested = false
                installer.stopWatching()
                installer.beginWatching()
            }
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

    /// Commits to the update.  A connected device has to be sent into BOOTSEL
    /// first; a board already sitting there is picked up by the watcher.
    private func start() {
        confirmed = true
        guard vm.isDeviceConnected, !rebootRequested else { return }
        rebootRequested = true
        // The device drops off the bus answering this, so there is no reply to
        // wait for.
        _ = vm.usb.getControlRequest(request: REQ_ENTER_BOOTLOADER, value: 0, index: 2, length: 1)
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
