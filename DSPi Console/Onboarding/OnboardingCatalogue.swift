import Foundation

/// Where a step is shown.
enum OnboardingPhase: Equatable {
    /// The Getting Started wizard: a linear run from a blank board to verified
    /// firmware.
    case setup
    /// Coach marks over the real UI, once, after setup.
    case basics
    /// One card the first time a specialist window is opened.  The associated
    /// value is the feature key the window passes when it first appears.
    case justInTime(String)
}

/// Which window a step is shown in.
///
/// The tour started life inside the main window, which was fine until routing:
/// the Matrix Mixer is the one screen a user cannot skip and it is a window of
/// its own, so a step that only pointed at the button that opens it was
/// describing a grid the user had never seen.  A step now names the window it
/// belongs to, the tour opens and closes that window as it crosses the
/// boundary, and each window hosts the same overlay.
enum OnboardingHost: Equatable {
    case mainWindow
    case matrixMixer

    /// The first-open card this window's tour steps replace.
    ///
    /// A window the tour walks through has already been explained by the time
    /// it is next opened, so its hint would be a second explanation of what
    /// the user just did - and, worse, would land on top of the coach mark
    /// that is explaining it.
    var justInTimeKey: String? {
        switch self {
        case .mainWindow: return nil
        case .matrixMixer: return "matrix-mixer"
        }
    }
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

    /// The body of the coach mark or hint card.  Empty for setup steps, whose
    /// copy belongs to the wizard screens themselves.
    let message: String

    /// The window this step is shown in.  Its anchor is resolved against that
    /// window's own layout, so an id may repeat across windows.
    let host: OnboardingHost

    /// For a basics step, the `.onboardingAnchor` id it points at.  A step
    /// whose anchor is absent from the window still shows its card, without a
    /// spotlight, rather than stalling the tour.
    let anchor: String?

    /// Whether this step's target only exists once a channel is selected.
    /// The console opens on its overview, where the filter table and the
    /// channel header are simply not on screen, so the tour asks for a
    /// channel before describing them.
    let needsChannelDetail: Bool

    /// Whether this step invites the user to type into the control it is
    /// pointing at.  Where it does, Next gives up the return key: otherwise
    /// committing a frequency would advance the tour instead.
    let invitesTyping: Bool

    /// Whether this step means anything for the hardware in front of the user.
    /// Steps about a feature the connected device does not have are not
    /// merely unhelpful, they describe controls that are not on screen.
    let applies: (DSPViewModel) -> Bool

    init(id: String,
         introducedIn: FirmwareVersion,
         phase: OnboardingPhase,
         title: String,
         message: String = "",
         host: OnboardingHost = .mainWindow,
         anchor: String? = nil,
         needsChannelDetail: Bool = false,
         invitesTyping: Bool = false,
         applies: @escaping (DSPViewModel) -> Bool) {
        self.id = id
        self.introducedIn = introducedIn
        self.phase = phase
        self.title = title
        self.message = message
        self.host = host
        self.anchor = anchor
        self.needsChannelDetail = needsChannelDetail
        self.invitesTyping = invitesTyping
        self.applies = applies
    }

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
    static let firstRelease = FirmwareVersion(1, 1, 6, 3)

    static let all: [OnboardingStep] = setup + basics + justInTime

    // MARK: Setup

    /// The wizard.  Its one objective is a Pico running verified DSPi
    /// firmware; outputs, wiring and audio routing belong to the app proper,
    /// where they can be revisited.
    ///
    /// These records exist for persistence: finishing or skipping the wizard
    /// marks them all seen.
    static let setup: [OnboardingStep] = [
        OnboardingStep(id: "setup.welcome", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .setup, title: "Welcome",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.board", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .setup, title: "Get your board running",
                       applies: { _ in true }),
        OnboardingStep(id: "setup.finished", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .setup, title: "You are set up",
                       applies: { _ in true }),
    ]

    // MARK: Basics

    /// The tour, in the order a new user meets these things rather than the
    /// order they were built.  Everything specialist is a just-in-time card
    /// instead; the only subsystem that earns a place here is routing, which
    /// is not optional knowledge and gets its own window visit.
    static let basics: [OnboardingStep] = [
        OnboardingStep(id: "basics.sidebar", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Inputs and outputs",
                       message: "Every channel lives here: inputs are what arrives from your computer, outputs are what leaves for your speakers, and each row's meter shows what is reaching it. Click a channel's name or meter to open its page and edit its filters. The small coloured tag at the end of the row is a separate control - it shows or hides that channel's curve on the graph, and leaves whichever page you have open alone.",
                       anchor: "basics.sidebar",
                       applies: { _ in true }),
        // Routing earns three steps because nothing else in the app matters if
        // the sound is not reaching the right output, and the default only
        // covers plain stereo on the first output pair.  The first points at
        // the button; the two after it are shown inside the Matrix Mixer,
        // which the tour opens on the user's behalf.  Describing the grid from
        // the outside taught nobody anything: it named controls the user had
        // never seen and left them to go and find them afterwards.
        OnboardingStep(id: "basics.routing", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "The Matrix Mixer",
                       message: "The Matrix Mixer decides which sound reaches which output, and it is the one screen standing between you and working audio: to begin with your left and right channels reach the first pair of outputs and nothing else is connected, so everything past plain stereo starts here. This button opens it, and it is worth remembering where it is. Next opens it for you.",
                       anchor: "basics.routing",
                       applies: { _ in true }),
        // Anchored to the whole grid rather than one crosspoint, so every
        // circle in it stays clickable through the spotlight and the
        // invitation to try one is real.
        OnboardingStep(id: "basics.matrix-grid", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Connecting an input to an output",
                       message: "Every input has a row and every output has a column. The circle where a row meets a column is the connection: click one and that input plays through that output. A connected circle grows a level field above it and an INV switch below, which flips its polarity for a driver wired backwards. Try one now. An input can feed several outputs at once, which is how you send bass to a subwoofer while the main speakers carry the rest.",
                       host: .matrixMixer,
                       anchor: "matrix.grid",
                       invitesTyping: true,
                       applies: { _ in true }),
        OnboardingStep(id: "basics.matrix-outputs", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "What each output does",
                       message: "These rows act on a whole output rather than on one connection. ENABLE switches an output off and gives its processing time back to the device, GAIN and DELAY set its level and time it against your other speakers, and MUTE silences it while you work. Each output also has its own filters, which is how a crossover is built: send the same input to two outputs and filter each one differently.",
                       host: .matrixMixer,
                       anchor: "matrix.outputs",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.graph", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "The response graph",
                       message: "This draws what your filters do to the sound. Each curve is the result of every filter on that channel combined, so you can see the shape you are building as you build it. The coloured tags in the sidebar decide which curves are drawn, so you can compare a few channels or narrow it down to one.",
                       anchor: "basics.graph",
                       applies: { _ in true }),
        // The one step that asks for an action.  A tour with something real in
        // it is remembered; a tour that only points at things is not.
        OnboardingStep(id: "basics.add-filter", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Add a filter",
                       message: "Each channel has ten filter slots, empty until you give one a type. Try it now: set a slot to Peaking, then give it a frequency, a gain and a Q. Q is how wide the filter reaches around its frequency - low Q is broad and gentle, high Q is narrow. The graph redraws as you type, and so does the device.",
                       anchor: "basics.add-filter",
                       needsChannelDetail: true,
                       invitesTyping: true,
                       applies: { _ in true }),
        OnboardingStep(id: "basics.volume-controls", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Volume Controls",
                       message: "Two volume controls share this spot and clicking the label above the slider enables you to switch between them. User Volume is the everyday control and chooses the amount by which your input source will be attenuated. Master Volume is stored on DSPi and has the final word on the highest volume that will actually come out of your speakers or headphones.",
                       anchor: "basics.volume",
                       applies: { _ in true }),
        // Deliberately before presets: RAM versus flash is the concept people
        // get wrong, and every later step depends on understanding it.
        //
        // No anchor on purpose.  The controls it describes are menu items,
        // which live outside the window and cannot be spotlit, so the card
        // stands on its own rather than pointing at something that is only
        // half the story.
        OnboardingStep(id: "basics.saving", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Saving to the device",
                       message: "This is the one thing worth reading twice. Changes take effect on the device immediately, but they live in memory until you commit them, and a power cycle loses anything uncommitted. Commit Parameters and Revert to Saved are both in the Tools menu. An asterisk beside the preset name means there is uncommitted work.",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.presets", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Presets",
                       message: "The device holds ten named presets, each a complete configuration you can name and switch between. Switching discards anything uncommitted, so commit first if you want to keep what you have been working on.",
                       anchor: "basics.presets",
                       applies: { _ in true }),
        OnboardingStep(id: "basics.where-things-live", introducedIn: FirmwareVersion(1, 1, 6, 3),
                       phase: .basics, title: "Where everything else lives",
                       message: "That is the whole of the everyday interface. Everything else lives in these icons and in the Tools menu, including crossfeed, loudness compensation, upmixing and test signals. Each one explains itself the first time you open it, so there is nothing to learn in advance.",
                       anchor: "basics.tools",
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
        jit("matrix-mixer", "Matrix Mixer",
            "Every input has a row and every output has a column. Switch on the square where they meet and that input plays through that output. Each connection carries its own level, so you can blend several inputs into one output without overloading it, and its own polarity switch for a driver that is wired backwards. The controls above the grid set the level, delay and mute for each output as a whole."),
        jit("control-surfaces", "Control Surfaces",
            "Wire real buttons, knobs, switches or an infrared remote to the Pico and bind them to anything the device can change. Each slot is one physical control, one pin and one thing it acts on.",
            { $0.controlSurfacesSupported }),
        jit("control-interfaces", "Control Interfaces",
            "Lets another device drive the DSPi over UART or I2C - a microcontroller, a home automation box, anything that can send bytes. Changes here are prepared and then applied together, so a half-typed setting never reaches the hardware."),
        jit("macros", "Macros",
            "One control, several actions. A macro runs a short list of steps in order, with optional delays, so a single button press can change volume, switch a preset and mute an output together.",
            { $0.controlSurfacesSupported }),
        jit("aux-outputs", "Auxiliary Outputs",
            "A GPIO the DSPi switches or dims for you and never reads itself: an amplifier trigger, a speaker relay, a panel lamp, a fan. Add one here on a spare pin, then point a button, knob, remote key or macro at it from the Control Surfaces page.",
            { $0.csAuxSupported }),
        jit("channel-groups", "Channel Groups",
            "Groups let one control move several channels at once, keeping their relative levels or setting them all to the same value. Useful when a pair of speakers should always track together.",
            { $0.controlSurfacesSupported }),
        // Attached to the Outputs page, so the copy leads with the output and
        // names where the input half lives rather than describing a control
        // that is not on this page.
        jit("adat", "ADAT",
            "ADAT carries eight channels of audio down one optical cable, so the DSPi can reach an interface or a mixer without eight separate leads. Switch it on here to send all eight output channels; receiving eight channels in is set up on the Inputs page.",
            { $0.adatSupported }),
        jit("i2s-input", "I2S Input",
            "I2S brings audio in directly from an ADC or another digital source over a few wires, instead of over USB. The important choice is which side generates the clock; everything else follows from it.",
            { $0.i2sInputSupported }),
        jit("upmixer", "Stereo Upmixer",
            "Derives centre and surround channels from an ordinary stereo recording, so a two-channel source can drive more speakers. Nothing is invented: the extra channels are pulled out of what the stereo pair already contains.",
            { $0.platformName == "RP2350" }),
        jit("crossfeed", "Headphone Crossfeed",
            "On headphones each ear hears only its own channel, which is not how speakers in a room work and is why some recordings feel oddly wide. Crossfeed blends a little of each channel into the other, with a short delay, to relax that effect."),
        jit("loudness", "Loudness Compensation",
            "Ears lose sensitivity to bass and treble as things get quieter, so music thins out at low volume. This adds back what quiet listening takes away, tracking your volume setting so the balance stays even as you turn it down."),
        jit("leveller", "Volume Leveller",
            "Evens out material that swings between quiet and loud - late-night listening, mixed playlists, films with whispered dialogue and loud effects. It watches the level and applies gentle gain, rather than squashing the peaks."),
        jit("psybass", "Psychoacoustic Bass",
            "Small speakers cannot reproduce the lowest notes, but the ear will still hear a note whose harmonics are present even when the fundamental is missing. This synthesises those harmonics, so bass reads as deeper without asking the driver for anything it cannot do."),
        jit("subharm", "Subharmonic Synthesizer",
            "The opposite of psychoacoustic bass: instead of implying a low note a speaker cannot play, this synthesises a real one an octave below the bass already in the music. Only worth switching on for an output that can reproduce 24 to 80 Hz - a subwoofer, or a large full-range system.",
            { $0.firmwareSupportsSubharm }),
        jit("tube", "Tube Modeller",
            "Adds the harmonic colour, gentle compression and transformer weight of a valve amplifier. Pick a tube to load its character, then use drive to decide how hard the stage works: a few dB is warmth, a lot is overdrive.",
            { $0.firmwareSupportsTube },
            introducedIn: FirmwareVersion(1, 1, 6, 4)),
        jit("limiter", "Output Limiter",
            "Holds this output under the ceiling you set, so a loud track or a slip of the volume cannot drive an amplifier or a tweeter into clipping. Switch it on only where you need it: while any limiter is on, every output is delayed by a fraction of a millisecond.",
            { $0.firmwareSupportsLimiter },
            introducedIn: FirmwareVersion(1, 1, 6, 4)),
        jit("autoeq", "AutoEQ",
            "A library of measured headphone corrections. Find your model, load its filters, and the DSPi applies the correction that measurement suggests - a good starting point to adjust by ear afterwards."),
        jit("test-signals", "Signal Generator",
            "Generates tones, sweeps and noise on the device itself, so you can check wiring, identify a channel or take a measurement without needing a source playing. Start quiet: test signals are far more consistent than music and will happily drive a speaker hard."),
        jit("stats", "Stats",
            "Live diagnostics from the device: processor load, sample rates, clock lock state and the health of each input. The first place to look when something sounds wrong or a source will not lock."),
    ]

    private static func jit(_ key: String,
                            _ title: String,
                            _ message: String,
                            _ applies: @escaping (DSPViewModel) -> Bool = { _ in true },
                            introducedIn: FirmwareVersion = FirmwareVersion(1, 1, 6, 3)) -> OnboardingStep {
        OnboardingStep(id: "jit.\(key)",
                       introducedIn: introducedIn,
                       phase: .justInTime(key),
                       title: title,
                       message: message,
                       applies: applies)
    }
}
