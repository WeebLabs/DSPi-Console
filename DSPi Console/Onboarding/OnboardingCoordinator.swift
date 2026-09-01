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

        /// Written by a developer reset to demand the genuinely-new-user
        /// path on the next launch.  Deliberately outside `all`, so clearing
        /// state and then asking for a fresh run do not cancel each other.
        static let simulateFresh = "onboarding.simulateFreshInstall"

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

    /// The instance the app runs on.
    ///
    /// Tool windows are AppKit-hosted (`NSHostingView`) and so sit outside the
    /// scene's environment, but their first-open hints have to read and write
    /// the same completed set as everything else.  One shared instance is
    /// simpler than threading the coordinator through a dozen window
    /// controllers.  Tests still construct their own against a scratch
    /// `UserDefaults`.
    static let shared = OnboardingCoordinator()

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

        // Consumed on sight: a simulated fresh install is one launch, not a
        // mode the app gets stuck in.
        let simulatingFresh = defaults.bool(forKey: Key.simulateFresh)
        if simulatingFresh { defaults.removeObject(forKey: Key.simulateFresh) }

        if isFirstOnboardingLaunch {
            defaults.set(Date(), forKey: Key.firstLaunch)
            // Someone already using the app should not be dragged through a
            // beginner's wizard on upgrade day.  Mark everything shipped so
            // far as seen, then offer the tour once rather than running it.
            //
            // Skipped when a fresh install was asked for, because every
            // machine that develops or tests this has years of settings on
            // it: without the exemption the seeding fires the moment the
            // state is cleared, and a first run becomes unreachable on
            // exactly the machines that need to see one.
            if hasPriorAppUse && !simulatingFresh {
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
    /// For any genuinely new user, connected or not.  The wizard's board step
    /// adapts to what is attached: a device already running the expected
    /// firmware sails through, a mismatched one is offered the update in
    /// place, and nothing attached gets the bootloader instructions.
    /// Deliberately not keyed on the device: a device appearing mid-wizard
    /// must not yank the wizard away, it is the very thing several steps are
    /// waiting for.  A returning user whose device is unplugged keeps the
    /// ordinary console, never this.
    func shouldTakeOverMainWindow() -> Bool {
        if setupRequested { return true }
        if debug.forceWizard { return true }
        guard cohort == .newUser else { return false }
        return !pending(.setup).isEmpty
    }

    /// Opens the wizard on demand.
    ///
    /// Ends any running tour first.  The wizard replaces the console, and the
    /// console is where the tour's overlay lives, so leaving it running would
    /// strand it: no spotlight, no Skip button, and no way out.
    func requestSetup() {
        if basicsTourRunning { endBasicsTour() }
        setupRequested = true
    }

    /// Leaves the wizard, whether it was completed or skipped.  Both record
    /// the setup steps as seen: a skip that reappears next launch is not a
    /// skip, and a user who reached the end does not want it again either.
    func finishSetup() {
        setupRequested = false
        skip(.setup)
    }

    // MARK: The basics tour

    /// The steps this run of the tour will show, frozen when it starts.
    ///
    /// Frozen deliberately: `pending` shrinks as steps are marked seen, and a
    /// list that shortened underneath the tour would renumber "step 3 of 7"
    /// mid-flight and skip whatever moved into the current index.
    @Published private(set) var basicsTourSteps: [OnboardingStep] = []
    @Published private(set) var basicsTourIndex = 0
    @Published private(set) var basicsTourRunning = false

    /// The step on screen, for anything that has to react to it - the console
    /// selects a channel for the steps that describe one, and opens the Matrix
    /// Mixer for the steps hosted in it.
    var basicsTourStep: OnboardingStep? {
        basicsTourSteps.indices.contains(basicsTourIndex) ? basicsTourSteps[basicsTourIndex] : nil
    }

    /// Whether there is a tour worth offering.  Setup steps still pending mean
    /// the wizard has not been dealt with yet, and the tour waits its turn.
    ///
    /// An existing user is a deliberate exception.  Upgrade day seeds every
    /// step as seen so nobody mid-project is dragged through a beginner's
    /// wizard, which leaves them with nothing pending - but the promise was
    /// that they would still be *offered* the tour once, so the offer stands
    /// on the cohort rather than on the pending list.
    var canOfferBasicsTour: Bool {
        guard cohort != .declined, pending(.setup).isEmpty else { return false }
        return cohort == .existingUser || !pending(.basics).isEmpty
    }

    /// Whether the offer should be put in front of the user unprompted.
    ///
    /// An existing user is only ever offered it, never dropped into it, which
    /// is the opt-in promise made to people who were using the app before
    /// onboarding existed.
    @Published var basicsOfferDismissed = false

    var showsBasicsOffer: Bool { canOfferBasicsTour && !basicsOfferDismissed }

    /// Starts the tour, restoring the whole thing if nothing is pending.
    ///
    /// The empty case is someone who was seeded as having seen it all taking
    /// up the offer, or anyone running it again from the Help menu; asking for
    /// the tour is asking for all of it.  Re-evaluating afterwards is what
    /// keeps `pending` honest: rewinding the completed ids without it would
    /// leave the two disagreeing, and the first step marked seen would then
    /// find `pending` empty and quietly reclassify the user as up to date
    /// mid-tour.  It also puts the steps back through their applicability
    /// check, so a replay cannot resurrect a step for hardware that is not
    /// attached.
    func startBasicsTour(vm: DSPViewModel) {
        if pending(.basics).isEmpty {
            completedIDs = completedIDs.subtracting(OnboardingCatalogue.basics.map(\.id))
            evaluate(vm: vm)
        }
        let steps = pending(.basics)
        guard !steps.isEmpty else { return }
        // A window the tour walks through does not also need its first-open
        // card: the card would arrive on top of the coach mark explaining the
        // very same grid, and again on the next open.  Spent at the start
        // rather than on arrival, for the same reason skipping the tour spends
        // the steps it never reached: a run of the tour is the whole run.
        markSeen(Set(steps.compactMap { $0.host.justInTimeKey })
            .compactMap { justInTimeStep(for: $0)?.id })
        basicsTourSteps = steps
        basicsTourIndex = 0
        basicsTourRunning = true
        basicsOfferDismissed = true
    }

    func basicsTourNext() {
        guard basicsTourRunning else { return }
        // Marked one at a time, so a tour interrupted by quitting resumes at
        // the first step the user has not actually read.
        if let step = basicsTourStep { markSeen(step) }
        if basicsTourIndex + 1 < basicsTourSteps.count {
            basicsTourIndex += 1
        } else {
            endBasicsTour()
        }
    }

    func basicsTourBack() {
        guard basicsTourRunning, basicsTourIndex > 0 else { return }
        basicsTourIndex -= 1
    }

    /// Ends the tour, however it ended.  Skipping is as final as finishing:
    /// every step of this run is recorded, including the ones not reached, or
    /// the skip button is a lie that costs the user the same banner tomorrow.
    func endBasicsTour() {
        markSeen(basicsTourSteps.map(\.id))
        basicsTourRunning = false
        basicsTourSteps = []
        basicsTourIndex = 0
        basicsOfferDismissed = true
    }

    /// "Not now."  Leaves the steps pending so the Help menu can still run the
    /// tour, but stops asking for this launch.
    func dismissBasicsOffer() { basicsOfferDismissed = true }

    // MARK: Just-in-time hints

    /// Records that `key`'s first-open card has been seen.
    func markJustInTimeSeen(_ key: String) {
        guard let step = justInTimeStep(for: key) else { return }
        markSeen(step)
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
    ///
    /// Also demands the new-user path next launch.  Clearing the state alone
    /// is not enough: the prior-use heuristic would see the app's other
    /// settings and seed the user as an existing one straight away.
    func resetAll() {
        // Abandoned outright, not ended: `endBasicsTour` records its steps,
        // which would write them straight back into the set being cleared.
        abandonBasicsTour()
        Key.all.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(true, forKey: Key.simulateFresh)
        cohort = .upToDate
        pending = []
    }

    /// Drops a running tour without recording anything.  For the developer
    /// resets only: every path a user can take through the tour records what
    /// they were shown.
    private func abandonBasicsTour() {
        basicsTourRunning = false
        basicsTourSteps = []
        basicsTourIndex = 0
        basicsOfferDismissed = false
    }

    /// Makes the basics tour offerable again without disturbing setup or the
    /// just-in-time cards.
    func replayBasics() {
        abandonBasicsTour()
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
