import SwiftUI

/// The Getting Started wizard.
///
/// Replaces the console inside the main window rather than opening over it.
/// A first-time user with no device would otherwise face a window full of
/// disabled controls, and a modal sheet over that dead interface traps people:
/// the menu bar goes quiet and there is no obvious way out.  Taking over the
/// content leaves the menus live, keeps it to one window, and hands the real
/// interface back the moment setup finishes or is skipped.
///
/// It stops at the first moment the user can hear their computer through the
/// DSPi.  Everything past that point is discoverable, and a wizard that keeps
/// going past its goal is one people learn to dismiss.
struct GettingStartedView: View {
    @ObservedObject var vm: DSPViewModel
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var firmwareUpdate: FirmwareUpdateWindowController

    @State private var stepIndex = 0

    /// Latches once audio has been seen, so a quiet passage does not undo the
    /// confirmation a moment after giving it.
    @State private var sawSignal = false

    private var steps: [OnboardingStep] { OnboardingCatalogue.setup }
    private var step: OnboardingStep { steps[min(stepIndex, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

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
        .onReceive(vm.meters.objectWillChange) { _ in
            // Latch, never unlatch: see `sawSignal`.
            if !sawSignal, inputSignalPresent { sawSignal = true }
        }
    }

    // MARK: Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Getting Started").font(.system(size: 15, weight: .semibold))
                    Text("Step \(stepIndex + 1) of \(steps.count): \(step.title)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Equal-width segments so the bar reads as progress rather than as
            // a set of buttons of varying importance.
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= stepIndex ? Color.accentColor : Color.gray.opacity(0.25))
                        .frame(height: 3)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step.id {
        case "setup.welcome":           welcomeStep
        case "setup.install-firmware":  firmwareStep
        case "setup.describe-hardware": hardwareStep
        case "setup.route-audio":       audioStep
        default:                        finishedStep
        }
    }

    private var welcomeStep: some View {
        stepBody(title: "Welcome to DSPi Console",
                 blurb: "DSPi turns a Raspberry Pi Pico into a USB audio processor: equalisation, crossovers, delay and level control applied to sound on its way out of your computer.\n\nThis takes a few minutes and gets you as far as hearing your computer through the DSPi. Everything else can wait until you want it.") {
            infoRow("bolt.horizontal.circle", "Install firmware on your board, if it needs it.")
            infoRow("cable.connector", "Check which outputs your hardware uses.")
            infoRow("speaker.wave.2", "Send your computer's audio to the DSPi.")
        }
    }

    private var firmwareStep: some View {
        stepBody(title: deviceReady ? "Your board is ready" : "Set up your board",
                 blurb: deviceReady
                    ? "A DSPi is connected and running firmware \(deviceVersionText). There is nothing to install."
                    : "A new Pico needs DSPi firmware before it can do anything. Console ships the firmware it expects, so this does not need a download.\n\nHold the BOOTSEL button while plugging the board in, then install.") {
            if deviceReady {
                statusRow(.ok, "Connected and responding")
            } else {
                Button("Install Firmware...") {
                    firmwareUpdate.show(vm: vm)
                }
                .controlSize(.large)

                statusRow(.waiting, "Waiting for a board. This step completes on its own once one is connected.")
            }
        }
    }

    private var hardwareStep: some View {
        stepBody(title: "Check your outputs",
                 blurb: deviceReady
                    ? "DSPi cannot tell what you have wired to it, so it needs to be told which GPIO pins carry your outputs. The defaults suit most builds, and you can change them at any time."
                    : "This step needs a connected device, since the output configuration lives on the board. You can skip it and set this up later in Settings.") {
            if deviceReady {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<min(vm.numOutputSlots, vm.outputPins.count), id: \.self) { index in
                        summaryRow("S/PDIF \(index + 1)", "GPIO \(vm.outputPins[index])",
                                   enabled: vm.outputEnabled[index * 2])
                    }
                    if vm.outputPins.count > 4 {
                        summaryRow("Subwoofer (PDM)", "GPIO \(vm.outputPins[4])",
                                   enabled: vm.outputEnabled[8])
                    }
                }
                .padding(.vertical, 4)
            }

            Button("Open Output Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .disabled(!deviceReady)
        }
    }

    private var audioStep: some View {
        stepBody(title: "Send audio to the DSPi",
                 blurb: "macOS needs to be told to play through the DSPi. Open Sound settings and choose it as the output device, then play something.") {
            Button("Open Sound Settings...") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.large)

            if sawSignal {
                statusRow(.ok, "Signal detected. Your computer's audio is reaching the DSPi.")
            } else if deviceReady {
                statusRow(.waiting, "Listening for audio. Play something and this will confirm itself.")
            } else {
                statusRow(.idle, "Connect a device to check this.")
            }
        }
    }

    private var finishedStep: some View {
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

            if stepIndex > 0 {
                Button("Back") { stepIndex -= 1 }
            }

            Button(isLastStep ? "Start Using DSPi Console" : "Continue") {
                if isLastStep { finish() } else { stepIndex += 1 }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
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

    private enum StatusKind { case ok, waiting, idle }

    private func statusRow(_ kind: StatusKind, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch kind {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .waiting:
                ProgressView().controlSize(.small)
            case .idle:
                Image(systemName: "circle.dashed").foregroundColor(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(kind == .ok ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Fixed label and value columns so the rows line up whatever the pin
    /// numbers are.
    private func summaryRow(_ label: String, _ value: String, enabled: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            Text(enabled ? "In use" : "Off")
                .font(.system(size: 11))
                .foregroundColor(enabled ? .green : .secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: State

    private var isLastStep: Bool { stepIndex >= steps.count - 1 }

    private var deviceReady: Bool { vm.isDeviceConnected }

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
