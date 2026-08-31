import Foundation

/// Where a step is shown.
enum OnboardingPhase: Equatable {
    /// The Getting Started wizard: a linear run from a blank board to audio.
    case setup
    /// Coach marks over the real UI, once, after setup.
    case basics
    /// One card the first time a specialist window is opened.  The associated
    /// value is the feature key the window passes when it first appears.
    case justInTime(String)
}

/// One thing onboarding can teach.
///
/// A step is data rather than a view so the decision of *what to show* can be
/// tested without rendering anything, which is the half that silently rots.
struct OnboardingStep: Identifiable, Equatable {
    /// Stable forever.  Persisted in the completed set, so reusing an id would
    /// mark a new step as already seen for every existing user.
    let id: String

    /// The release this step first shipped in.  A user who has run any later
    /// version has, by definition, already been offered every earlier step.
    ///
    /// Typed as `FirmwareVersion` because app and firmware carry the same
    /// version number by policy (CLAUDE.md > Releases), so one triple serves
    /// both and there is no second parser to disagree with the first.
    let introducedIn: FirmwareVersion

    let phase: OnboardingPhase

    /// Shown as the step's heading, and in the developer list.
    let title: String

    /// Whether this step means anything for the hardware in front of the user.
    /// Steps about a feature the connected device does not have are not
    /// merely unhelpful, they describe controls that are not on screen.
    let applies: (DSPViewModel) -> Bool

    static func == (a: OnboardingStep, b: OnboardingStep) -> Bool { a.id == b.id }
}

/// Every onboarding step, in the order they are offered.
///
/// Order matters within a phase: setup runs top to bottom, and the basics tour
/// follows the path a new user actually takes rather than the order the
/// features were built.
enum OnboardingCatalogue {

    /// The release onboarding first shipped in.  Nothing may be dated earlier:
    /// an updater is treated as having already been offered every step from
    /// before their version, so a step backdated past this is shown to nobody.
    static let firstRelease = FirmwareVersion(1, 1, 7)

    static let all: [OnboardingStep] = setup + basics + justInTime

    // MARK: Setup

    /// The wizard.  Stops at the first moment the user can hear their computer
    /// through the DSPi; everything past that is discoverable.
    static let setup: [OnboardingStep] = [
        OnboardingStep(id: "setup.welcome", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .setup, title: "Welcome",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.install-firmware", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .setup, title: "Set up your board",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.describe-hardware", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .setup, title: "Describe your hardware",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.route-audio", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .setup, title: "Send audio to the DSPi",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.finished", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .setup, title: "You are set up",
                       applies: { _ in true }),
    ]

    // MARK: Basics

    static let basics: [OnboardingStep] = [
        OnboardingStep(id: "basics.sidebar", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Inputs and outputs",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.graph", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "The response graph",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.add-filter", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Add a filter",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.volume-and-preamp", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Volume and headroom",
                       applies: { _ in true }),
        // Deliberately before presets: RAM versus flash is the concept people
        // get wrong, and every later step depends on understanding it.
        OnboardingStep(id: "basics.saving", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Saving to the device",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.presets", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Presets",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.where-things-live", introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .basics, title: "Where everything else lives",
                       applies: { _ in true }),
    ]

    // MARK: Just in time

    /// One card each, shown the first time the feature is opened.
    ///
    /// These are not in the tour on purpose.  Each is specialist, most are
    /// conditional on hardware, and none are on the path to first sound, so
    /// explaining them in advance teaches nothing: the user has nowhere to put
    /// the information.  Shown at first open they arrive exactly when they
    /// mean something, and a feature added later needs no version logic of its
    /// own to reach existing users.
    static let justInTime: [OnboardingStep] = [
        jit("matrix-mixer", "Matrix Mixer"),
        jit("control-surfaces", "Control Surfaces", { $0.controlSurfacesSupported }),
        jit("control-interfaces", "Control Interfaces"),
        jit("macros", "Macros", { $0.controlSurfacesSupported }),
        jit("channel-groups", "Channel Groups", { $0.controlSurfacesSupported }),
        jit("adat", "ADAT", { $0.adatSupported }),
        jit("i2s-input", "I2S Input", { $0.i2sInputSupported }),
        jit("upmixer", "Stereo Upmixer", { $0.platformName == "RP2350" }),
        jit("crossfeed", "Headphone Crossfeed"),
        jit("loudness", "Loudness Compensation"),
        jit("leveller", "Volume Leveller"),
        jit("psybass", "Psychoacoustic Bass"),
        jit("autoeq", "AutoEQ"),
        jit("test-signals", "Test Signals"),
        jit("stats", "Stats"),
    ]

    private static func jit(_ key: String,
                            _ title: String,
                            _ applies: @escaping (DSPViewModel) -> Bool = { _ in true }) -> OnboardingStep {
        OnboardingStep(id: "jit.\(key)",
                       introducedIn: FirmwareVersion(1, 1, 7),
                       phase: .justInTime(key),
                       title: title,
                       applies: applies)
    }
}
