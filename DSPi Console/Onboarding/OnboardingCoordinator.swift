import Foundation
import Combine

/// Which kind of user this is, which decides how onboarding is *presented*.
/// The selection mechanism underneath is the same for all of them.
enum OnboardingCohort: Equatable {
    /// No prior state of any kind: gets the full sequence, framed as setup.
    case newUser
    /// Has seen earlier steps; only what is new since is offered, quietly.
    case updater
    /// Was already using the app before onboarding existed.  Everything
    /// shipped so far is marked seen and the tour is offered once, opt in,
    /// rather than dropping a working user into a beginner's wizard.
    case existingUser
    /// Nothing to show.
    case upToDate
    /// Asked never to be shown this again.
    case declined
}

/// Decides what onboarding to show, and remembers what has been shown.
///
/// The whole point of this type is that "what does this user see" is a pure
/// function of persisted ids, the catalogue, and the connected hardware, so it
/// can be tested without a window on screen.  Nothing here draws anything.
final class OnboardingCoordinator: ObservableObject {

    // MARK: Persistence

    enum Key {
        static let completed = "onboarding.completedStepIDs"
        static let lastSeenVersion = "onboarding.lastSeenVersion"
        static let declined = "onboarding.tourDeclined"
        static let firstLaunch = "onboarding.firstLaunchDate"

        static let all = [completed, lastSeenVersion, declined, firstLaunch]
    }

    /// Keys that only exist if someone has actually used the app before.
    ///
    /// Used once, to tell a genuinely new install from an existing user
    /// meeting onboarding for the first time.  A user who ran the app and
    /// changed absolutely nothing reads as new, which is harmless: they are
    /// new in every way that matters here.
    private static let priorUseKeys = [
        "graphMinFreq", "graphMaxFreq", "graphHeight", "showPhase",
        "sidebarVolumeMode", "settingsSelectedTab", "showDebugInfo",
        "autoEQFavorites", "outputNames",
    ]

    private let defaults: UserDefaults
    private let debug: OnboardingDebug

    @Published private(set) var cohort: OnboardingCohort = .upToDate
    @Published private(set) var pending: [OnboardingStep] = []

    init(defaults: UserDefaults = .standard, debug: OnboardingDebug = .fromDefaults()) {
        self.defaults = defaults
        self.debug = debug
    }

    // MARK: State

    private(set) var completedIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.completed) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.completed) }
    }

    private var declined: Bool {
        get { defaults.bool(forKey: Key.declined) }
        set { defaults.set(newValue, forKey: Key.declined) }
    }

    /// True when nothing has ever written our own state.
    private var isFirstOnboardingLaunch: Bool {
        Key.all.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    private var hasPriorAppUse: Bool {
        Self.priorUseKeys.contains { defaults.object(forKey: $0) != nil }
    }

    // MARK: Evaluation

    /// Works out what this user should be shown.  Call once the device state
    /// is known, since applicability depends on the attached hardware.
    func evaluate(vm: DSPViewModel) {
        debug.applyCohortOverride(to: defaults, catalogue: OnboardingCatalogue.all)

        if isFirstOnboardingLaunch {
            defaults.set(Date(), forKey: Key.firstLaunch)
            // Someone already using the app should not be dragged through a
            // beginner's wizard on upgrade day.  Mark everything shipped so
            // far as seen, then offer the tour once rather than running it.
            if hasPriorAppUse {
                completedIDs = Set(OnboardingCatalogue.all.map(\.id))
                defaults.set(FirmwareVersion.expected?.description, forKey: Key.lastSeenVersion)
                cohort = .existingUser
                pending = []
                return
            }
        }

        guard !declined else {
            cohort = .declined
            pending = []
            return
        }

        let seen = completedIDs
        pending = OnboardingCatalogue.all.filter { !seen.contains($0.id) && $0.applies(vm) }

        if pending.isEmpty {
            cohort = .upToDate
        } else if seen.isEmpty {
            cohort = .newUser
        } else {
            cohort = .updater
        }
    }

    /// Steps of one phase that are still pending, in catalogue order.
    func pending(_ phase: OnboardingPhase) -> [OnboardingStep] {
        pending.filter { $0.phase == phase }
    }

    /// The card to show the first time `key`'s window opens, if any.
    func justInTimeStep(for key: String) -> OnboardingStep? {
        pending.first { $0.phase == .justInTime(key) }
    }

    // MARK: The wizard

    /// Set when the user asks for the wizard from the Help menu, so it opens
    /// even for someone who has already finished setup.
    @Published var setupRequested = false

    /// Whether the wizard should replace the console inside the main window.
    ///
    /// Only for a genuinely new user with nothing plugged in.  That is the one
    /// case where the ordinary interface is a wall of disabled controls and
    /// showing it teaches nothing.  A returning user with an unplugged device
    /// gets the empty state instead, and a new user who already has a working
    /// device gets the real interface, because there is nothing to block them
    /// from.
    func shouldTakeOverMainWindow(deviceConnected: Bool) -> Bool {
        if setupRequested { return true }
        if debug.forceWizard { return true }
        guard cohort == .newUser, !deviceConnected else { return false }
        return !pending(.setup).isEmpty
    }

    /// Opens the wizard on demand.
    func requestSetup() { setupRequested = true }

    /// Leaves the wizard, whether it was completed or skipped.  Both record
    /// the setup steps as seen: a skip that reappears next launch is not a
    /// skip, and a user who reached the end does not want it again either.
    func finishSetup() {
        setupRequested = false
        skip(.setup)
    }

    // MARK: Recording

    func markSeen(_ step: OnboardingStep) { markSeen([step.id]) }

    func markSeen(_ ids: [String]) {
        completedIDs = completedIDs.union(ids)
        defaults.set(FirmwareVersion.expected?.description, forKey: Key.lastSeenVersion)
        pending.removeAll { ids.contains($0.id) }
        if pending.isEmpty { cohort = .upToDate }
    }

    /// Skipping is as final as completing.  A step the user dismissed must not
    /// come back on the next launch, or the skip button is a lie.
    func skip(_ phase: OnboardingPhase) {
        markSeen(pending(phase).map(\.id))
    }

    /// "Never show me this again."  Leaves the completed set alone so a later
    /// reset restores the ordinary behaviour.
    func declineEverything() {
        declined = true
        cohort = .declined
        pending = []
    }

    // MARK: Developer

    /// Forgets everything, as though the app had never been run.  Backs the
    /// developer panel and the launch-argument override.
    func resetAll() {
        Key.all.forEach { defaults.removeObject(forKey: $0) }
        cohort = .upToDate
        pending = []
    }

    /// Makes the basics tour offerable again without disturbing setup or the
    /// just-in-time cards.
    func replayBasics() {
        let ids = OnboardingCatalogue.basics.map(\.id)
        completedIDs = completedIDs.subtracting(ids)
        declined = false
    }

    /// Clears only the first-open cards, for testing a feature's hint without
    /// re-running the wizard.
    func replayJustInTime() {
        let ids = OnboardingCatalogue.justInTime.map(\.id)
        completedIDs = completedIDs.subtracting(ids)
    }
}
