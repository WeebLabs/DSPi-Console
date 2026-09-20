import Foundation

// Per-module parameter stores for the tool windows.
//
// These exist for one reason: `DSPViewModel` is a single ObservableObject that
// 37 view declarations across the app observe, so writing any `@Published`
// property on it invalidates every on-screen view, the main window included.
// A slider drag delivers 30 values a second, and the RTA graphs draw on the
// main thread (MTKView), so a drag in a tool window used to stall the main
// window's spectrum until the gesture ended.
//
// Splitting a module's continuous parameters into their own ObservableObject
// stops that: SwiftUI does not propagate a nested observable's changes to its
// parent, so a drag here invalidates only the views that observe this object,
// which is the module's own window.
//
// **The master `<module>Enabled` switch deliberately stays on `DSPViewModel`.**
// The main window's toggle pills read it, and it changes on a click rather than
// during a gesture, so leaving it on the shared object keeps the pills live at
// no cost. Everything a slider or stepper can sweep belongs here.
//
// A view that needs both observes both (`@ObservedObject var vm` plus
// `@ObservedObject var tube`). Non-view code reaches them through the view
// model, e.g. `vm.tube.driveDB`.

/// Tube Modeller parameters (spec §2). `tubeEnabled` stays on the view model;
/// everything the window can sweep lives here. Defaults are the firmware's, so
/// an unconnected app and a fresh device agree before the first bulk read.
final class TubeParameters: ObservableObject {
    @Published var outputMask: UInt16 = TUBE_DEFAULT_OUTPUT_MASK
    /// 0 = Custom, 1..16 = a row of TUBE_TYPE_ROWS. Selecting a row loads the
    /// four character knobs; editing one of them drops the type back to Custom.
    @Published var type: Int = TUBE_DEFAULT_TUBE_TYPE
    @Published var driveDB: Float = TUBE_DEFAULT_DRIVE_DB          // -6..24 dB
    @Published var biasPct: Float = TUBE_DEFAULT_BIAS_PCT          // -100..+100 %
    @Published var asymDB: Float = TUBE_DEFAULT_ASYM_DB            // -12..+12 dB
    @Published var hardnessPct: Float = TUBE_DEFAULT_HARDNESS_PCT  // 0..100 %
    @Published var sagPct: Float = TUBE_DEFAULT_SAG_PCT            // 0..100 %
    @Published var rectifier: Int = TUBE_DEFAULT_RECTIFIER
    @Published var xfmrEnabled: Bool = false
    @Published var xfmrDamping: Float = TUBE_DEFAULT_XFMR_DAMPING  // 1..20
    @Published var xfmrResHz: Float = TUBE_DEFAULT_XFMR_RES_HZ     // 30..150 Hz
    @Published var mixPct: Float = TUBE_DEFAULT_MIX_PCT            // 0..100 %
    @Published var trimDB: Float = TUBE_DEFAULT_TRIM_DB            // -12..+12 dB
}

/// Loudness compensation parameters. `loudnessEnabled` stays on the view model.
final class LoudnessParameters: ObservableObject {
    @Published var refSPL: Float = 83.0
    @Published var intensity: Float = 100.0
    /// Per-output loudness mask (V19+): bit k enables compensation on output
    /// channel k. Default 0xFFFF = every output compensated.
    @Published var outputMask: UInt16 = LOUDNESS_DEFAULT_OUTPUT_MASK
}

/// Crossfeed parameters. `crossfeedEnabled` stays on the view model.
final class CrossfeedParameters: ObservableObject {
    @Published var preset: Int = 0
    @Published var freq: Float = 700.0
    @Published var feed: Float = 4.5
    @Published var itd: Bool = true
    /// Crossfeed output-pair mask (V20+): bit p runs crossfeed on output pair p
    /// (outputs 2p / 2p+1). Default 0x01 = pair 1 only (outputs 0/1). Filter
    /// settings stay global; the mask only selects which pairs are crossfed.
    @Published var outputMask: UInt8 = CROSSFEED_DEFAULT_OUTPUT_MASK
}

/// Psychoacoustic Bass (V23): one global parameter set applied per output
/// channel selected by `outputMask`, exactly like loudness. The firmware clamps
/// each value to the range shown; the app enforces the same ranges so its state
/// stays identical without a read-back. `psybassEnabled` stays on the view model.
final class PsybassParameters: ObservableObject {
    @Published var cutoffHz: Float = 80.0      // 30..300 Hz
    @Published var harmonicsDB: Float = 0.0    // -24..+12 dB
    @Published var driveDB: Float = 6.0        // 0..18 dB
    @Published var characterPct: Float = 50.0  // 0..100 % (warm..aggressive)
    @Published var originalDB: Float = 0.0     // -60..0 dB (speaker protection)
    /// Per-output psybass mask: bit k processes output channel k (PDM sub = bit 8
    /// on RP2350 / bit 4 on RP2040). Default 0xFFFF = every output.
    @Published var outputMask: UInt16 = PSYBASS_DEFAULT_OUTPUT_MASK
}

/// Subharmonic Synthesizer (V29, extended V30): a dbx-style octave divider that
/// adds a real fundamental an octave below the program bass, per output channel
/// selected by `outputMask`. `subharmEnabled` stays on the view model.
final class SubharmParameters: ObservableObject {
    @Published var lowDB: Float = 0.0      // -30..+12 dB (24-36 Hz sub; -30 = band off)
    @Published var highDB: Float = 0.0     // -30..+12 dB (36-56 Hz sub; -30 = band off)
    @Published var topDB: Float = -30.0    // -30..+12 dB (56-80 Hz sub; ships off)
    @Published var boostDB: Float = 0.0    // 0..+6 dB (70 Hz LF boost bell)
    /// Per-output subharm mask: bit k processes output channel k (PDM sub = bit 8
    /// on RP2350 / bit 4 on RP2040). Default 0xFFFF = every output.
    @Published var outputMask: UInt16 = SUBHARM_DEFAULT_OUTPUT_MASK
    /// Selectivity: which kind of bass material gets a sub, how hard the rest is
    /// gated down, and the span the decision is made over. Depth and hold do
    /// nothing while the mode is `all`.
    @Published var selectMode: Int = SUBHARM_SELECT_ALL
    @Published var selectDepthPct: Float = 100.0   // 0..100 %
    @Published var selectHoldMs: Float = 150.0     // 50..400 ms
    /// Soft limit on the synthesized sub before it is mixed in (dBFS); 0 = off.
    @Published var ceilingDB: Float = 0.0
    /// Synthesize one sub per output pair from its mono sum rather than one per
    /// channel, so a panned event cannot leave the two dividers in opposite
    /// polarity. On by default, as on the dbx.
    @Published var linkPairs: Bool = true
    /// Runtime-only monitor: masked outputs carry the sub with the program signal
    /// removed. Never persisted, absent from the bulk image, so it has to be read
    /// with 0x2D rather than coming back with `fetchAllParams`.
    @Published var solo: Bool = false
    /// Worst-case gain of the live configuration (dB), read back with 0x1A after
    /// every change. Not carried on the wire and not part of the preset: it is
    /// derived from enable, the band levels, the boost and the ceiling, and
    /// nothing else - not the mask, the pair link or the sample rate.
    @Published var headroomDB: Float = 0.0
    /// Decaying peak of the synthesized sub per output channel (0x1F), normalized
    /// to 0..1 like `SystemStatus.peaks` so one meter widget drives either.
    /// Polled only while the subharm window is open; empty when never read.
    @Published var subMeter: [Float] = []
}

/// Volume Leveller parameters (firmware factory defaults, overwritten on
/// connect). `levellerEnabled` stays on the view model.
final class LevellerParameters: ObservableObject {
    @Published var amount: Float = 50.0
    @Published var speed: Int = 0        // 0=Slow, 1=Medium, 2=Fast
    @Published var maxGainDB: Float = 15.0
    @Published var lookahead: Bool = true
    @Published var gateDB: Float = -96.0
    // V18 channel masks: bit k = input channel k. Default all-on = classic stereo link.
    @Published var detectorMask: UInt8 = 0xFF
    @Published var applyMask: UInt8 = 0xFF
}

/// Stereo Upmixer (V25) parameters and live telemetry. `upmixEnabled` stays on
/// the view model. The telemetry below is written by the shared poll timer at
/// roughly 16 Hz while the window is open, which is the other reason this
/// module needs its own observable: on the view model it re-rendered the whole
/// app continuously, with no user input at all.
final class UpmixParameters: ObservableObject {
    @Published var centerMode: Int = UPMIX_CENTER_MODE_ADAPTIVE       // 0/1/2
    @Published var surroundMode: Int = UPMIX_SURROUND_MODE_ADAPTIVE   // 0/1/2
    @Published var strengthPct: Float = 100.0        // 0..100 %
    @Published var centerWidthPct: Float = 25.0      // 0..100 %
    @Published var thresholdPct: Float = 30.0        // 0..95 %
    @Published var attackMs: Float = 10.0            // 1..500 ms
    @Published var releaseMs: Float = 100.0          // 5..2000 ms
    @Published var detectorHpfHz: Float = 200.0      // 20..1000 Hz
    @Published var surroundDelayMs: Float = 12.0     // 0..20 ms
    @Published var surroundHpfHz: Float = 300.0      // 20..2000 Hz
    @Published var surroundLpfHz: Float = 7000.0     // 1000..20000 Hz
    @Published var decorrPct: Float = 90.0           // 0..100 %
    /// Centre presence bell gain at 3 kHz / Q 0.6 (V26+). Stored on the device in
    /// 0.5 dB steps (config byte presence_q1 = dB x 2); the app keeps the dB value.
    @Published var presenceDB: Float = 0.0           // -12..+12 dB

    // Live telemetry (REQ_UPMIX_GET_STATUS, spec §6.3). Polled only while the
    // upmixer window is open (`statusPolling`).
    @Published var active: Bool = false
    @Published var parkedReason: UInt8 = UPMIX_PARKED_DISABLED
    @Published var corr: Float = 0.0          // smoothed L/R correlation, -1..+1
    @Published var balance: Float = 0.0       // level balance, 0 (centred)..1
    @Published var centerGain: Float = 0.0    // live centre extraction gain, 0..1
    @Published var lsGain: Float = 0.0        // live Ls steering gain, 0..1
    @Published var rsGain: Float = 0.0        // live Rs steering gain, 0..1
    /// Set by the upmixer window while visible so the shared poll timer fetches
    /// UpmixStatus (~16 Hz); left false everywhere else to avoid the extra I/O.
    @Published var statusPolling: Bool = false
}
