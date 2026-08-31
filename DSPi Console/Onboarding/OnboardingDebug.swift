import Foundation

/// Developer overrides for onboarding.
///
/// Everything onboarding does depends on persisted state that takes weeks of
/// real use to reach, so every cohort has to be reachable on demand or the
/// branches only ever get exercised by users.  Read from `UserDefaults`, which
/// picks up `-key value` launch arguments for free, so the same overrides work
/// from an Xcode scheme, the command line, and the settings panel.
struct OnboardingDebug {

    enum Key {
        /// "fresh", "existing", "declined", or "updater:1.1.6".
        static let cohort = "DSPiOnboardingCohort"
        /// Show the wizard even when the ordinary rules would not.
        static let forceWizard = "DSPiOnboardingForceWizard"
    }

    let cohortOverride: String?
    let forceWizard: Bool

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> OnboardingDebug {
        OnboardingDebug(cohortOverride: defaults.string(forKey: Key.cohort),
                        forceWizard: defaults.bool(forKey: Key.forceWizard))
    }

    static var none: OnboardingDebug { OnboardingDebug(cohortOverride: nil, forceWizard: false) }

    /// Rewrites persisted state to match the requested cohort, then clears the
    /// request so it applies once rather than pinning the app into that state
    /// forever.  A no-op when nothing is overridden.
    func applyCohortOverride(to defaults: UserDefaults, catalogue: [OnboardingStep]) {
        guard let cohortOverride else { return }
        defer { defaults.removeObject(forKey: Key.cohort) }

        OnboardingCoordinator.Key.all.forEach { defaults.removeObject(forKey: $0) }

        switch cohortOverride {
        case "fresh":
            break  // no keys at all is exactly a new install

        case "existing":
            // Prior use without any onboarding state: the upgrade-day case.
            defaults.set(250.0, forKey: "graphHeight")

        case "declined":
            defaults.set(true, forKey: OnboardingCoordinator.Key.declined)
            defaults.set([String](), forKey: OnboardingCoordinator.Key.completed)

        case let value where value.hasPrefix("updater:"):
            // Everything introduced at or before the named version counts as
            // already seen, which is what an updater from it would carry.
            let from = FirmwareVersion(String(value.dropFirst("updater:".count)))
            let seen = catalogue.filter { step in
                guard let from else { return false }
                return step.introducedIn <= from
            }
            defaults.set(seen.map(\.id).sorted(), forKey: OnboardingCoordinator.Key.completed)
            defaults.set(String(value.dropFirst("updater:".count)),
                         forKey: OnboardingCoordinator.Key.lastSeenVersion)

        default:
            break
        }
    }
}
