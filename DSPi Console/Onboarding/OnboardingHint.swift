import SwiftUI

// MARK: - First-open hint

/// The card a specialist window shows the first time it is opened.
///
/// Deliberately not part of the tour.  A dozen specialist subsystems explained
/// up front teach nothing, because the user has nowhere to put the
/// information; the same sentence read on first open arrives when it means
/// something.  It also solves the version problem for free: a feature added
/// later ships with its own hint and reaches new users and updaters alike,
/// exactly once, with no version logic of its own.
struct OnboardingHintCard: View {
    let step: OnboardingStep
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(step.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // A hint that cannot be dismissed is an advert.  One click, and
            // it never returns.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Got it")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque, because it floats over live content rather than sitting in
        // its own row: a translucent card over a busy window is unreadable.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Material.regular)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

/// Puts the first-open hint for `key` above a window's content.
///
/// Reads the shared coordinator rather than the environment, because tool
/// windows are hosted in `NSHostingView` and never see the scene's
/// environment objects.
private struct OnboardingHintModifier: ViewModifier {
    let key: String
    /// A plain reference, not an observed one.  `body` never reads the
    /// coordinator - only `onAppear` and `dismiss` do - so observing it would
    /// buy nothing and cost a re-render of all seventeen windows and settings
    /// pages carrying this modifier on every publish, including each step of
    /// the tour.
    private let onboarding = OnboardingCoordinator.shared

    /// Resolved once, when the window appears.  Reading it live would make
    /// the card vanish the instant it was marked seen, taking its own
    /// dismissal animation with it.
    @State private var step: OnboardingStep?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            // An overlay rather than a row above the content, because these
            // windows size themselves to their content once, when they are
            // built.  A card that took up layout space would push the bottom
            // of a fixed-size window out of sight; an overlay changes nothing
            // and gives the space back when it is dismissed.
            .overlay(alignment: .top) {
                if visible, let step {
                    OnboardingHintCard(step: step) { dismiss() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear {
                guard step == nil, let pending = onboarding.justInTimeStep(for: key) else { return }
                step = pending
                withAnimation(.easeOut(duration: 0.25)) { visible = true }
            }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) { visible = false }
        onboarding.markJustInTimeSeen(key)
    }
}

extension View {
    /// Shows this feature's first-open card, once, above the window content.
    func onboardingHint(_ key: String) -> some View {
        modifier(OnboardingHintModifier(key: key))
    }
}

// MARK: - Tour offer

/// The one-line offer of the basics tour.
///
/// A banner rather than an automatic run, for everyone.  A new user has just
/// finished setup and may want to look around first; an existing user was
/// promised the tour would be offered rather than imposed.  Either way it
/// takes one click to start and one to dismiss, and the Help menu keeps it
/// reachable afterwards.
struct BasicsTourOffer: View {
    @ObservedObject var onboarding: OnboardingCoordinator
    /// Needed only to start the tour, which re-checks each step against the
    /// attached hardware before showing it.
    let vm: DSPViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                Text("A short tour of the main window: channels, filters, volume and saving.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button("Show Me") { onboarding.startBasicsTour(vm: vm) }
            Button("Later") { onboarding.dismissBasicsOffer() }
            // Distinct from "Later": this one is the promise that we stop
            // asking for good, not just for this launch.
            Button("Never") { onboarding.declineEverything() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// An updater is told what is new in the version they just installed; a
    /// first-time user is simply offered a look around, because "new in 1.1.7"
    /// means nothing to someone who has never run anything else.
    ///
    /// Only the updater cohort counts pending steps.  An existing user was
    /// seeded as having seen everything precisely so no wizard would run, which
    /// leaves them nothing pending - counting it would offer them "0 things to
    /// show you" and then run all seven.
    private var headline: String {
        guard onboarding.cohort == .updater, let version = FirmwareVersion.expected else {
            return "Would you like a quick tour?"
        }
        let count = onboarding.pending(.basics).count
        return "\(count) thing\(count == 1 ? "" : "s") to show you in \(version)"
    }
}
