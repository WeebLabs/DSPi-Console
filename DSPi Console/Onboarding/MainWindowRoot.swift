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
                // Offered, never imposed: a user who has just finished setup
                // may want to look around first, and someone who was using the
                // app before onboarding existed was promised the choice.
                //
                // Only with a device attached, because every step describes a
                // channel, a meter or a filter and none of those are on screen
                // otherwise.  The Help menu still runs it on demand.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if onboarding.showsBasicsOffer && vm.isDeviceConnected {
                        BasicsTourOffer(onboarding: onboarding, vm: vm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: onboarding.showsBasicsOffer)
                // Outermost, so the spotlight can cover every part of the
                // window including the banners inset above.
                .basicsTour(onboarding)
        }
    }
}

