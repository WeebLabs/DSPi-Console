import XCTest
@testable import DSPi_Console

/// Pure-logic tests for what onboarding decides to show.
///
/// This is the part that rots quietly: a wrong answer here does not crash, it
/// just shows a beginner's wizard to a long-time user, or silently hides a new
/// feature's introduction from everyone who upgraded. None of it is visible
/// until someone complains, and none of it needs a window to test. No device.
final class OnboardingCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A private suite per test: the real one carries whatever this machine
        // has accumulated, and these tests are entirely about persisted state.
        suiteName = "onboarding-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Cohorts

    /// A genuinely new install gets everything, framed as setup.
    func testNewUserGetsEveryApplicableStep() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        XCTAssertEqual(coordinator.cohort, .newUser)
        XCTAssertFalse(coordinator.pending(.setup).isEmpty)
        XCTAssertFalse(coordinator.pending(.basics).isEmpty)
    }

    /// Someone already using the app must not be dropped into a beginner's
    /// wizard on upgrade day, so prior use marks everything shipped as seen
    /// and the tour becomes an offer rather than a sequence.
    func testExistingUserIsSeededRatherThanOnboarded() {
        defaults.set(250.0, forKey: "graphHeight")   // evidence of prior use
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        XCTAssertEqual(coordinator.cohort, .existingUser)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    /// The seeding happens once. A later launch is an ordinary launch, not a
    /// second seeding, and must not wipe progress made in between.
    func testSeedingHappensOnlyOnce() {
        defaults.set(250.0, forKey: "graphHeight")
        makeCoordinator().evaluate(vm: DSPViewModel())

        let second = makeCoordinator()
        second.evaluate(vm: DSPViewModel())
        XCTAssertEqual(second.cohort, .upToDate)
    }

    /// An updater sees only what is new since their last version, which is the
    /// entire reason steps carry ids rather than a single "seen" flag.
    func testUpdaterGetsOnlyTheStepsTheyHaveNotSeen() {
        let seen = OnboardingCatalogue.all.dropLast(2).map(\.id)
        defaults.set(seen, forKey: OnboardingCoordinator.Key.completed)

        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        XCTAssertEqual(coordinator.cohort, .updater)
        XCTAssertEqual(coordinator.pending.count, 2)
    }

    func testDecliningSilencesEverything() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.declineEverything()

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertEqual(next.cohort, .declined)
        XCTAssertTrue(next.pending.isEmpty)
    }

    // MARK: - Recording

    /// Skipping has to be as final as completing, or the skip button is a lie
    /// and the wizard returns on the next launch.
    func testSkippingAPhaseIsPermanent() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.skip(.setup)

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertTrue(next.pending(.setup).isEmpty)
        XCTAssertFalse(next.pending(.basics).isEmpty, "skipping setup must not skip the tour")
    }

    func testMarkingASingleStepSeenRemovesOnlyThatStep() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        let before = coordinator.pending.count
        coordinator.markSeen(OnboardingCatalogue.basics[0])

        XCTAssertEqual(coordinator.pending.count, before - 1)
        XCTAssertFalse(coordinator.pending.contains(OnboardingCatalogue.basics[0]))
    }

    /// Ids already in defaults that no longer exist in the catalogue are a
    /// normal consequence of removing a step; they must be ignored, not
    /// crashed on or counted as pending.
    func testUnknownStoredIdsAreIgnored() {
        defaults.set(["some.retired.step", "another.one"], forKey: OnboardingCoordinator.Key.completed)
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        let applicable = OnboardingCatalogue.all.filter { $0.applies(DSPViewModel()) }.count
        XCTAssertEqual(coordinator.pending.count, applicable)
        XCTAssertEqual(coordinator.cohort, .updater)
    }

    // MARK: - Applicability

    /// A step about a feature the connected device does not have describes
    /// controls that are not on screen, so it is worse than useless.
    func testStepsAreGatedOnDeviceCapability() {
        let vm = DSPViewModel()
        vm.controlSurfacesSupported = false
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: vm)

        XCTAssertNil(coordinator.justInTimeStep(for: "control-surfaces"))

        vm.controlSurfacesSupported = true
        coordinator.evaluate(vm: vm)
        XCTAssertNotNil(coordinator.justInTimeStep(for: "control-surfaces"))
    }

    /// A hidden step is not a seen step: plugging in a device that has the
    /// feature must surface its card, even years later.
    func testAnInapplicableStepIsNotMarkedSeen() {
        let vm = DSPViewModel()
        vm.controlSurfacesSupported = false
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: vm)
        coordinator.skip(.setup)

        let stored = Set(defaults.stringArray(forKey: OnboardingCoordinator.Key.completed) ?? [])
        XCTAssertFalse(stored.contains("jit.control-surfaces"))
    }

    // MARK: - Just in time

    func testJustInTimeCardIsOfferedOnceThenNeverAgain() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        guard let card = coordinator.justInTimeStep(for: "matrix-mixer") else {
            return XCTFail("expected a matrix mixer card for a new user")
        }
        coordinator.markSeen(card)
        XCTAssertNil(coordinator.justInTimeStep(for: "matrix-mixer"))
    }

    // MARK: - Developer overrides

    func testFreshOverrideProducesANewUser() {
        defaults.set(Array(OnboardingCatalogue.all.map(\.id)), forKey: OnboardingCoordinator.Key.completed)
        defaults.set("fresh", forKey: OnboardingDebug.Key.cohort)

        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        XCTAssertEqual(coordinator.cohort, .newUser)
    }

    /// The override applies once rather than pinning the app into that cohort,
    /// so the next launch shows what a real user in that position would see.
    func testCohortOverrideIsConsumed() {
        defaults.set("fresh", forKey: OnboardingDebug.Key.cohort)
        makeCoordinator().evaluate(vm: DSPViewModel())
        XCTAssertNil(defaults.string(forKey: OnboardingDebug.Key.cohort))
    }

    /// Simulating an upgrade from a named release is how a new step's
    /// introduction gets tested without waiting for a release.
    func testUpdaterOverrideMarksEverythingFromThatReleaseSeen() {
        defaults.set("updater:1.1.7", forKey: OnboardingDebug.Key.cohort)
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())

        // Every step currently ships in 1.1.7, so an updater from it has
        // nothing left; when later steps are added this becomes the interesting
        // case, and the assertion still holds for whatever remains.
        let leftover = coordinator.pending.filter { $0.introducedIn <= FirmwareVersion(1, 1, 7) }
        XCTAssertTrue(leftover.isEmpty)
    }

    /// The bug this guards: every machine that develops or tests onboarding
    /// has years of the app's own settings on it, so clearing onboarding state
    /// alone let the prior-use heuristic re-seed the user as an existing one
    /// on the very next launch. A first run was unreachable on exactly the
    /// machines that needed to see one.
    func testResetReachesAFirstRunOnAMachineThatHasUsedTheApp() {
        defaults.set(282.25, forKey: "graphHeight")   // years of prior use
        defaults.set(true, forKey: "showDebugInfo")

        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        XCTAssertEqual(coordinator.cohort, .existingUser)

        coordinator.resetAll()

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertEqual(next.cohort, .newUser)
        XCTAssertTrue(next.shouldTakeOverMainWindow())
    }

    /// Simulating a fresh install lasts one launch. Left set, the app could
    /// never become an ordinary returning user again.
    func testSimulatedFreshInstallAppliesOnlyOnce() {
        defaults.set(282.25, forKey: "graphHeight")
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.resetAll()

        let first = makeCoordinator()
        first.evaluate(vm: DSPViewModel())
        XCTAssertEqual(first.cohort, .newUser)
        first.finishSetup()

        let second = makeCoordinator()
        second.evaluate(vm: DSPViewModel())
        XCTAssertFalse(second.shouldTakeOverMainWindow())
    }

    /// The launch-argument override has the same hole and the same fix.
    func testFreshOverrideWorksOnAMachineThatHasUsedTheApp() {
        defaults.set(282.25, forKey: "graphHeight")
        defaults.set("fresh", forKey: OnboardingDebug.Key.cohort)

        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        XCTAssertEqual(coordinator.cohort, .newUser)
    }

    func testResetForgetsEverything() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.skip(.basics)
        coordinator.resetAll()

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertEqual(next.cohort, .newUser)
    }

    /// Replaying the tour must not also re-run the wizard: they are separate
    /// requests and a user asking for one has not asked for the other.
    func testReplayingBasicsLeavesSetupAlone() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.skip(.setup)
        coordinator.skip(.basics)
        coordinator.replayBasics()

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertTrue(next.pending(.setup).isEmpty)
        XCTAssertFalse(next.pending(.basics).isEmpty)
    }

    /// Replaying the tour also has to lift a previous "never again", or the
    /// menu item does nothing for the people most likely to use it.
    func testReplayingBasicsUndoesDeclining() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.declineEverything()
        coordinator.replayBasics()

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertNotEqual(next.cohort, .declined)
    }

    // MARK: - When the wizard takes over the window

    /// A genuinely new user gets the wizard.  Deliberately independent of
    /// whether a device is connected: the wizard adapts its steps to what is
    /// attached, and keying the takeover on the device meant a board plugged
    /// in mid-wizard yanked the wizard away - the very event several of its
    /// steps sit waiting for.  (This reverses the original rule, which stood
    /// aside for a connected device; that rule predates the wizard being able
    /// to do anything useful with one.)
    func testWizardTakesOverForANewUser() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        XCTAssertTrue(coordinator.shouldTakeOverMainWindow())
    }

    /// A returning user whose device is simply unplugged gets the empty state.
    /// Seizing their window would be a regression dressed as help.
    func testWizardNeverTakesOverForAReturningUser() {
        defaults.set(Array(OnboardingCatalogue.all.map(\.id)), forKey: OnboardingCoordinator.Key.completed)
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        XCTAssertFalse(coordinator.shouldTakeOverMainWindow())
    }

    /// Asked for from the Help menu, it opens regardless of cohort or
    /// hardware, because the user asked.
    func testRequestingSetupOpensItForAnyone() {
        defaults.set(Array(OnboardingCatalogue.all.map(\.id)), forKey: OnboardingCoordinator.Key.completed)
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.requestSetup()
        XCTAssertTrue(coordinator.shouldTakeOverMainWindow())
    }

    /// Finishing hands the window back and does not come round again, whether
    /// the user completed the wizard or skipped it.
    func testFinishingSetupReleasesTheWindowPermanently() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.finishSetup()
        XCTAssertFalse(coordinator.shouldTakeOverMainWindow())

        let next = makeCoordinator()
        next.evaluate(vm: DSPViewModel())
        XCTAssertFalse(next.shouldTakeOverMainWindow())
    }

    /// Skipping setup must not also skip the tour: they are separate offers.
    func testFinishingSetupLeavesTheTourPending() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(vm: DSPViewModel())
        coordinator.finishSetup()
        XCTAssertFalse(coordinator.pending(.basics).isEmpty)
    }

    // MARK: - Catalogue hygiene

    /// Two steps sharing an id would mark each other as seen. Cheap to check,
    /// impossible to spot by reading.
    func testStepIDsAreUnique() {
        let ids = OnboardingCatalogue.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// A just-in-time step whose key is not unique would show the wrong card.
    func testJustInTimeKeysAreUnique() {
        let keys = OnboardingCatalogue.justInTime.compactMap { step -> String? in
            if case .justInTime(let key) = step.phase { return key }
            return nil
        }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys.count, OnboardingCatalogue.justInTime.count)
    }

    /// A step dated earlier than the release onboarding actually shipped in is
    /// invisible to every updater, because they are treated as having already
    /// been offered it. That is a copy-paste slip, not a decision.
    ///
    /// There is no matching ceiling check here: the version a step will ship
    /// in is not knowable while it is being written, so keeping `introducedIn`
    /// in step with the release is a checklist item (CLAUDE.md > Releases)
    /// rather than something a test can decide.
    func testNoStepPredatesOnboardingItself() {
        for step in OnboardingCatalogue.all {
            XCTAssertGreaterThanOrEqual(step.introducedIn, OnboardingCatalogue.firstRelease,
                                        "\(step.id) is dated before onboarding existed")
        }
    }

    // MARK: - Helpers

    private func makeCoordinator() -> OnboardingCoordinator {
        OnboardingCoordinator(defaults: defaults, debug: .fromDefaults(defaults))
    }
}
