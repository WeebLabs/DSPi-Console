import SwiftUI

/// Chooses what the main window shows: the wizard, or the console.
///
/// The choice lives here rather than inside `ContentView` so the console
/// itself stays unaware of onboarding, and so the wizard is a peer of the
/// interface rather than something layered over it.
struct MainWindowRoot: View {
    @ObservedObject var vm: DSPViewModel
    @EnvironmentObject private var onboarding: OnboardingCoordinator

    var body: some View {
        if onboarding.shouldTakeOverMainWindow() {
            GettingStartedView(vm: vm)
        } else {
            ContentView(vm: vm)
        }
    }
}

/// Shown in place of the disabled console when no device is attached.
///
/// The old behaviour was a full window of dead controls, which tells a user
/// nothing about why nothing works.  This says what is wrong, offers the two
/// things that could fix it, and is where a returning user with an unplugged
/// device lands rather than being sent back through the wizard.
struct NoDeviceView: View {
    @ObservedObject var vm: DSPViewModel
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var firmwareUpdate: FirmwareUpdateWindowController

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("No DSPi connected")
                    .font(.system(size: 17, weight: .semibold))
                Text("Check the USB cable, or set up a new board.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button("Set Up a Board...") { firmwareUpdate.show(vm: vm) }
                Button("Getting Started...") { onboarding.requestSetup() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
