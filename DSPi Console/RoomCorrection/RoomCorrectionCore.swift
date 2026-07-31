import Foundation

/// Swift face over the portable room-correction core's C ABI.
///
/// Only this file knows the C symbols exist; everything above it works in Swift
/// types.  Keeping the boundary in one place is what lets the core be replaced,
/// or pointed at a different implementation, without the change rippling
/// through the app - and it is the same boundary the eventual Windows front end
/// will call, so anything that leaks C types upward is a portability problem
/// disguised as a convenience.
enum RoomCorrectionCore {

    /// Algorithm version, recorded in a saved project so a later recalculation
    /// can tell whether it would reproduce the stored result.
    static var algorithmVersion: String {
        String(cString: dspi_rc_algorithm_version())
    }

    /// Most recent failure reported by the core.
    static var lastError: String {
        String(cString: dspi_rc_last_error())
    }

    enum CoreError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }

        /// Captures the core's thread-local message at the point of failure,
        /// before any later call can overwrite it.
        static func current(_ fallback: String) -> CoreError {
            let message = RoomCorrectionCore.lastError
            return .failed(message.isEmpty ? fallback : message)
        }
    }

    static func check(_ status: dspi_rc_status, _ context: String) throws {
        guard status == DSPI_RC_OK else { throw CoreError.current(context) }
    }
}

// MARK: - Platform

extension RoomCorrectionCore {
    /// Which DSP the connected device runs.  Not cosmetic: the two platforms
    /// realize filters differently, so a prediction made for one is not valid
    /// for the other.
    enum Platform {
        case rp2040
        case rp2350

        var raw: dspi_rc_platform {
            switch self {
            case .rp2040: return DSPI_RC_PLATFORM_RP2040
            case .rp2350: return DSPI_RC_PLATFORM_RP2350
            }
        }

        /// Derived from the device's reported platform name.
        init(platformName: String) {
            self = platformName.uppercased().contains("RP2040") ? .rp2040 : .rp2350
        }
    }
}

// MARK: - Frequency grid

extension RoomCorrectionCore {
    struct Grid {
        let minHz: Double
        let maxHz: Double
        let pointsPerOctave: Int

        /// The analysis grid the spec calls for. Exposed rather than hardcoded
        /// so the diagnostics views can ask for something coarser when they are
        /// only drawing.
        static let standard = Grid(minHz: 20.0, maxHz: 20000.0, pointsPerOctave: 96)
        static let display = Grid(minHz: 20.0, maxHz: 20000.0, pointsPerOctave: 24)

        var pointCount: Int {
            var points = 0
            guard dspi_rc_grid_points(minHz, maxHz, Int32(pointsPerOctave), &points) == DSPI_RC_OK
            else { return 0 }
            return points
        }

        var frequencies: [Double] {
            let count = pointCount
            guard count > 0 else { return [] }
            var values = [Double](repeating: 0, count: count)
            var written = 0
            let status = values.withUnsafeMutableBufferPointer { buffer in
                dspi_rc_grid_frequencies(minHz, maxHz, Int32(pointsPerOctave),
                                         buffer.baseAddress, count, &written)
            }
            return status == DSPI_RC_OK ? values : []
        }
    }
}

// MARK: - Sweep

extension RoomCorrectionCore {
    /// What role a speaker plays, which sets the sweep's band and length.
    enum SpeakerRole: Int32 {
        case fullRange = 0
        case bassLimited = 1
        case subwoofer = 2
    }

    struct SweepSpec {
        var spec: dspi_rc_sweep_spec

        init(sampleRateHz: Double, role: SpeakerRole) throws {
            var value = dspi_rc_sweep_spec()
            try RoomCorrectionCore.check(
                dspi_rc_default_sweep_spec(sampleRateHz, role.rawValue, &value),
                "could not build a default sweep")
            self.spec = value
        }

        var sampleRateHz: Double { spec.sample_rate_hz }
        var startHz: Double { get { spec.start_hz } set { spec.start_hz = newValue } }
        var endHz: Double { get { spec.end_hz } set { spec.end_hz = newValue } }
        var durationSeconds: Double {
            get { spec.duration_seconds } set { spec.duration_seconds = newValue }
        }
        var preRollSeconds: Double { spec.pre_roll_seconds }
        var postRollSeconds: Double { spec.post_roll_seconds }

        /// Peak level in dBFS.  The level check works in dB; the core works in
        /// linear amplitude, and this is the only place that conversion lives.
        var peakLevelDbfs: Double {
            get { 20.0 * log10(max(spec.amplitude, 1e-9)) }
            set { spec.amplitude = pow(10.0, newValue / 20.0) }
        }

        var totalSamples: Int {
            get throws {
                var samples = 0
                var local = spec
                try RoomCorrectionCore.check(dspi_rc_sweep_length(&local, &samples),
                                             "invalid sweep")
                return samples
            }
        }

        /// The full playback buffer, including pre-roll and post-roll silence.
        func render() throws -> [Float] {
            let count = try totalSamples
            var samples = [Float](repeating: 0, count: count)
            var written = 0
            var local = spec
            let status = samples.withUnsafeMutableBufferPointer { buffer in
                dspi_rc_render_sweep(&local, buffer.baseAddress, count, &written)
            }
            try RoomCorrectionCore.check(status, "could not render the sweep")
            return samples
        }
    }

    struct CaptureAnalysis {
        let magnitudesDb: [Double]
        /// Total loop latency: USB, device buffering, acoustic flight time and
        /// capture buffering combined.  Magnitude correction does not need it;
        /// per-channel distance and delay diagnostics do.
        let latencySeconds: Double
    }

    /// Deconvolve a capture into a magnitude response on `grid`.
    static func analyze(recording: [Float],
                        sweep: SweepSpec,
                        grid: Grid,
                        transitionHz: Double = 0) throws -> CaptureAnalysis {
        let count = grid.pointCount
        guard count > 0 else { throw CoreError.failed("invalid analysis grid") }

        var magnitudes = [Double](repeating: 0, count: count)
        var latency: Double = 0
        var spec = sweep.spec

        let status = recording.withUnsafeBufferPointer { input in
            magnitudes.withUnsafeMutableBufferPointer { output in
                dspi_rc_analyze_capture(&spec, input.baseAddress, recording.count,
                                        grid.minHz, grid.maxHz, Int32(grid.pointsPerOctave),
                                        transitionHz, output.baseAddress, count, &latency)
            }
        }
        try check(status, "could not analyze the capture")
        return CaptureAnalysis(magnitudesDb: magnitudes, latencySeconds: latency)
    }
}

// MARK: - Microphone calibration

extension RoomCorrectionCore {
    /// A parsed microphone calibration file.
    final class Calibration {
        fileprivate let handle: OpaquePointer

        let pointCount: Int
        let minHz: Double
        let maxHz: Double
        let sensitivityDb: Double?
        /// Repairs the parser made, worth showing rather than applying silently.
        let warnings: [String]

        init(contents: String) throws {
            guard let handle = contents.withCString({ dspi_rc_calibration_parse($0) }) else {
                throw CoreError.current("could not parse the calibration file")
            }
            self.handle = handle

            var points = 0
            var low: Double = 0
            var high: Double = 0
            var hasSensitivity: Int32 = 0
            var sensitivity: Double = 0
            dspi_rc_calibration_info(handle, &points, &low, &high, &hasSensitivity, &sensitivity)
            self.pointCount = points
            self.minHz = low
            self.maxHz = high
            self.sensitivityDb = hasSensitivity != 0 ? sensitivity : nil

            var collected: [String] = []
            var index = 0
            var buffer = [CChar](repeating: 0, count: 256)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { pointer in
                    dspi_rc_calibration_warning(handle, index, pointer.baseAddress, 256)
                }
                if status != DSPI_RC_OK { break }
                collected.append(String(cString: buffer))
                index += 1
            }
            self.warnings = collected
        }

        convenience init(contentsOf url: URL) throws {
            try self.init(contents: try String(contentsOf: url, encoding: .utf8))
        }

        deinit {
            dspi_rc_calibration_free(handle)
        }

        /// Whether the file spans the range we intend to analyze.  Outside its
        /// range the core holds the endpoint value rather than extrapolating,
        /// so a short file is usable but the user should be told.
        func covers(minHz low: Double, maxHz high: Double) -> Bool {
            minHz <= low && maxHz >= high
        }

        /// Apply to a measured curve in place.  The file describes the
        /// microphone's own deviation, so this subtracts.
        func apply(to magnitudesDb: inout [Double], frequencies: [Double]) throws {
            let count = min(magnitudesDb.count, frequencies.count)
            guard count > 0 else { return }
            let status = frequencies.withUnsafeBufferPointer { hz in
                magnitudesDb.withUnsafeMutableBufferPointer { db in
                    dspi_rc_calibration_apply(handle, hz.baseAddress, db.baseAddress, count)
                }
            }
            try RoomCorrectionCore.check(status, "could not apply the calibration")
        }
    }
}

// MARK: - Target

extension RoomCorrectionCore {
    enum TargetPreset: Int32, CaseIterable {
        case flat = 0
        case natural = 1
        case studio = 2
        case bassWarm = 3

        var displayName: String {
            switch self {
            case .flat: return "Flat"
            case .natural: return "Natural"
            case .studio: return "Studio"
            case .bassWarm: return "Bass Warm"
            }
        }
    }

    struct Target {
        var spec: dspi_rc_target_spec

        init(preset: TargetPreset = .natural) {
            var value = dspi_rc_target_spec()
            dspi_rc_target_preset(preset.rawValue, &value)
            self.spec = value
        }

        var tiltDbPerOctave: Double {
            get { spec.tilt_db_per_octave } set { spec.tilt_db_per_octave = newValue }
        }
        var bassGainDb: Double {
            get { spec.bass_gain_db } set { spec.bass_gain_db = newValue }
        }
        var bassTransitionHz: Double {
            get { spec.bass_transition_hz } set { spec.bass_transition_hz = newValue }
        }
        var trebleGainDb: Double {
            get { spec.treble_gain_db } set { spec.treble_gain_db = newValue }
        }
        var trebleTransitionHz: Double {
            get { spec.treble_transition_hz } set { spec.treble_transition_hz = newValue }
        }
        var shelfWidthOctaves: Double {
            get { spec.shelf_width_octaves } set { spec.shelf_width_octaves = newValue }
        }
        var levelDb: Double { get { spec.level_db } set { spec.level_db = newValue } }
        var lowCurtainHz: Double {
            get { spec.low_curtain_hz } set { spec.low_curtain_hz = newValue }
        }
        var highCurtainHz: Double {
            get { spec.high_curtain_hz } set { spec.high_curtain_hz = newValue }
        }
    }
}

extension RoomCorrectionCore {

    /// How a curve is smoothed for display.
    ///
    /// Display only. The fit is deliberately not smoothed: pre-smoothing would
    /// destroy narrow modal detail that is genuinely correctable, and the
    /// optimizer relies on its reliability mask to decide what to trust.
    enum Smoothing: Hashable, CaseIterable {
        /// Fine in the modal region, broad at the top, anchored to the room's
        /// own measured transition.
        case variable
        case fixed(denominator: Int)

        static var allCases: [Smoothing] {
            [.variable, .fixed(denominator: 48), .fixed(denominator: 24),
             .fixed(denominator: 12), .fixed(denominator: 6), .fixed(denominator: 3)]
        }

        var displayName: String {
            switch self {
            case .variable: return "Variable"
            case .fixed(let denominator): return "1/\(denominator) octave"
            }
        }

        fileprivate var denominator: Double {
            switch self {
            case .variable: return 0
            case .fixed(let value): return Double(value)
            }
        }
    }

    /// Mean power per bin over a band, in dB.
    ///
    /// Band-independent by construction, which is what lets a subwoofer and a
    /// midband channel be compared without any frequency range in common.
    static func bandLevel(_ magnitudesDb: [Double],
                          grid: Grid,
                          band: ClosedRange<Double>) throws -> Double {
        guard magnitudesDb.count == grid.pointCount, !magnitudesDb.isEmpty else {
            throw CoreError.failed("the curve does not match the analysis grid")
        }
        var level: Double = 0
        let status = magnitudesDb.withUnsafeBufferPointer { input in
            dspi_rc_band_level(input.baseAddress, magnitudesDb.count,
                               grid.minHz, grid.maxHz, Int32(grid.pointsPerOctave),
                               band.lowerBound, band.upperBound, &level)
        }
        try check(status, "could not measure the band level")
        return level
    }

    /// The spatial average and spread of a set of positions, with no fit.
    ///
    /// The same power-domain average the fit will use, so the curve a user
    /// watches converge is the one that will be corrected against rather than
    /// a second answer that happens to look similar.
    ///
    /// `spread` is the median absolute deviation across positions and needs
    /// three or more to mean anything.
    static func spatialStatistics(positions: [[Double]],
                                  grid: Grid) throws -> (average: [Double],
                                                         spread: [Double]) {
        let points = grid.pointCount
        guard !positions.isEmpty, points > 0 else { return ([], []) }
        guard positions.allSatisfy({ $0.count == points }) else {
            throw CoreError.failed("a measurement does not match the analysis grid")
        }

        let packed = positions.flatMap { $0 }
        var average = [Double](repeating: 0, count: points)
        var spread = [Double](repeating: 0, count: points)

        let status = packed.withUnsafeBufferPointer { input in
            average.withUnsafeMutableBufferPointer { averageOut in
                spread.withUnsafeMutableBufferPointer { spreadOut in
                    dspi_rc_spatial_statistics(input.baseAddress, positions.count, points,
                                               grid.minHz, grid.maxHz,
                                               Int32(grid.pointsPerOctave),
                                               averageOut.baseAddress,
                                               spreadOut.baseAddress)
                }
            }
        }
        try check(status, "could not compute the spatial average")
        return (average, spread)
    }

    /// Smooth a curve for display.
    static func smooth(_ magnitudesDb: [Double],
                       grid: Grid,
                       using smoothing: Smoothing,
                       transitionHz: Double = 200) throws -> [Double] {
        guard magnitudesDb.count == grid.pointCount, !magnitudesDb.isEmpty else {
            return magnitudesDb
        }
        var output = [Double](repeating: 0, count: magnitudesDb.count)
        let status = magnitudesDb.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                dspi_rc_smooth_curve(input.baseAddress, magnitudesDb.count,
                                     grid.minHz, grid.maxHz,
                                     Int32(grid.pointsPerOctave),
                                     smoothing.denominator, transitionHz,
                                     out.baseAddress)
            }
        }
        try check(status, "could not smooth the curve")
        return output
    }

    /// The target curve alone, with no measurement involved.
    ///
    /// A house curve is chosen before anything is measured, so the design view
    /// has to be able to draw what is being chosen. Session curves cannot serve
    /// that: they are only readable after a fit, and a fit needs positions.
    static func evaluateTarget(_ target: Target,
                               anchors: [(freqHz: Double, gainDb: Double)] = [],
                               grid: Grid = .display) throws -> [Double] {
        let count = grid.pointCount
        guard count > 0 else { return [] }

        var spec = target.spec
        var values = [Double](repeating: 0, count: count)
        var written = 0
        let anchorHz = anchors.map(\.freqHz)
        let anchorDb = anchors.map(\.gainDb)

        let status = values.withUnsafeMutableBufferPointer { output in
            anchorHz.withUnsafeBufferPointer { hz in
                anchorDb.withUnsafeBufferPointer { db in
                    dspi_rc_evaluate_target(&spec,
                                            anchors.isEmpty ? nil : hz.baseAddress,
                                            anchors.isEmpty ? nil : db.baseAddress,
                                            anchors.count,
                                            grid.minHz, grid.maxHz,
                                            Int32(grid.pointsPerOctave),
                                            output.baseAddress, count, &written)
                }
            }
        }
        try check(status, "could not evaluate the target")
        return values
    }
}

// MARK: - Fitting

extension RoomCorrectionCore {
    struct FitOptions {
        var config: dspi_rc_fit_config

        init() {
            var value = dspi_rc_fit_config()
            dspi_rc_default_fit_config(&value)
            self.config = value
        }

        /// Band budget, queried from the live device rather than assumed.
        var maxFilters: Int {
            get { Int(config.max_filters) } set { config.max_filters = Int32(newValue) }
        }
        var allowShelves: Bool {
            get { config.allow_shelves != 0 } set { config.allow_shelves = newValue ? 1 : 0 }
        }
        /// How much of the deviation from the target to chase, 0 < s <= 1.
        ///
        /// The target is eased toward the measured response rather than the
        /// finished filters being scaled down, so the fit solves the reduced
        /// goal under the same constraints and the metrics stay honest.
        var strength: Double {
            get { config.strength }
            set { config.strength = min(1, max(0.05, newValue)) }
        }

        /// Signed, as the core expects: cuts are negative and boosts positive,
        /// asymmetric by design because cutting a resonance is safe and
        /// boosting is not. The core rejects a non-negative cut limit outright.
        var cutLimitDb: Double { get { config.cut_limit_db } set { config.cut_limit_db = newValue } }

        /// The same limit as a positive magnitude, which is how a user thinks
        /// about it and therefore what the UI binds to.
        ///
        /// Clamped away from zero because the core requires a strictly negative
        /// cut limit and would refuse the whole fit.
        var maxCutDb: Double {
            get { -cutLimitDb }
            set { cutLimitDb = -max(0.5, abs(newValue)) }
        }

        /// Advanced mode. Default is cut-only, and raising this must be paired
        /// with the headroom the results screen reports.
        var boostLimitDb: Double {
            get { config.boost_limit_db } set { config.boost_limit_db = newValue }
        }
        var combinedCeilingDb: Double {
            get { config.combined_ceiling_db } set { config.combined_ceiling_db = newValue }
        }

        /// How narrow a boosting band may be.
        ///
        /// Held low because a narrow boost is nearly always fighting a
        /// cancellation, and inverting one is the characteristic failure of
        /// automatic room EQ. What stops that is the reliability floor - boost
        /// is refused outright where the positions disagree - so this decides
        /// how finely a dip the seats *do* agree on can be filled.
        ///
        /// Only has an effect when some boost is permitted.
        var maxBoostQ: Double {
            get { config.max_boost_q }
            set { config.max_boost_q = min(10, max(0.5, newValue)) }
        }
    }

    /// Settings for the fixed-pole parallel design.
    ///
    /// This design **cannot be written to a DSPi**: the firmware DSP is a
    /// cascade with no accumulator, and the vendor wire carries filter recipes
    /// rather than coefficients.  It exists so a real measurement can be run
    /// through it and the predicted correction looked at, which is the input
    /// the firmware decision is missing.
    ///
    /// Defaults are Bank's method as specified - logarithmic pole placement
    /// weighted toward the modal region, Q from the spacing to the neighbours,
    /// poles fixed - so what the app shows matches what the evaluation reports.
    struct ParallelOptions {
        var config: dspi_rc_parallel_config

        init() {
            var value = dspi_rc_parallel_config()
            dspi_rc_default_parallel_config(&value)
            self.config = value
        }

        /// Pole pairs.  The hardware's ten PEQ bands are not a limit here; the
        /// whole question is what more sections would buy.
        var sections: Int {
            get { Int(config.sections) }
            set { config.sections = Int32(max(1, newValue)) }
        }

        /// 1 is pure logarithmic placement, which is Bank's method.
        var placementBias: Double {
            get { config.placement_bias }
            set { config.placement_bias = min(1, max(0, newValue)) }
        }

        /// Off keeps the poles fixed, which is what makes the design a linear
        /// solve. On refines them, which is not Bank's method but is what the
        /// cascade's centres get.
        var refinePoles: Bool {
            get { config.refine_poles != 0 }
            set { config.refine_poles = newValue ? 1 : 0 }
        }

        /// Off is Bank's spacing rule; on takes Q from the measured feature
        /// width, which helps at low section counts.
        var qFromFeatureWidth: Bool {
            get { config.q_from_feature_width != 0 }
            set { config.q_from_feature_width = newValue ? 1 : 0 }
        }
    }

    /// One pole pair and its solved numerator.
    ///
    /// Deliberately not a `FilterParams`: there is no type, no gain in dB, and
    /// no PEQ recipe that expresses it.
    struct ParallelSection: Identifiable {
        let id = UUID()
        let freqHz: Double
        let q: Double
        let b0: Double
        let b1: Double
    }

    struct Metrics {
        let rawWorstPositionRmseDb: Double
        let reliableWorstPositionRmseDb: Double
        let reliableMedianAbsErrorDb: Double
        let p95PositiveOvershootDb: Double
        let maxCombinedCorrectionDb: Double
        let minCombinedCorrectionDb: Double
        let maxDisputedBoostDb: Double
        let maxOutsideNativeBoostDb: Double
        let maxBoostFilterQ: Double
        let activeFilterCount: Int
        let shelfFilterCount: Int

        init(_ raw: dspi_rc_metrics) {
            rawWorstPositionRmseDb = raw.raw_worst_position_rmse_db
            reliableWorstPositionRmseDb = raw.reliable_worst_position_rmse_db
            reliableMedianAbsErrorDb = raw.reliable_median_abs_error_db
            p95PositiveOvershootDb = raw.p95_positive_overshoot_db
            maxCombinedCorrectionDb = raw.max_combined_correction_db
            minCombinedCorrectionDb = raw.min_combined_correction_db
            maxDisputedBoostDb = raw.max_disputed_boost_db
            maxOutsideNativeBoostDb = raw.max_outside_native_boost_db
            maxBoostFilterQ = raw.max_boost_filter_q
            activeFilterCount = Int(raw.active_filter_count)
            shelfFilterCount = Int(raw.shelf_filter_count)
        }
    }

    /// Which curve to read back for plotting.
    enum Curve {
        case target
        case powerAverage
        case spread
        case reliability
        case correction
        case maskWeight
        case position(Int)
        case predicted(Int)
        /// The fixed-pole parallel bank's predicted correction, including its
        /// own trim.  Evaluation only; see `ParallelOptions`.
        case parallelCorrection

        var raw: Int32 {
            switch self {
            case .target: return Int32(DSPI_RC_CURVE_TARGET)
            case .powerAverage: return Int32(DSPI_RC_CURVE_POWER_AVERAGE)
            case .spread: return Int32(DSPI_RC_CURVE_SPREAD)
            case .reliability: return Int32(DSPI_RC_CURVE_RELIABILITY)
            case .correction: return Int32(DSPI_RC_CURVE_CORRECTION)
            case .maskWeight: return Int32(DSPI_RC_CURVE_MASK_WEIGHT)
            case .position: return Int32(DSPI_RC_CURVE_POSITION)
            case .predicted: return Int32(DSPI_RC_CURVE_PREDICTED)
            case .parallelCorrection: return Int32(DSPI_RC_CURVE_PARALLEL_CORRECTION)
            }
        }

        var index: Int32 {
            switch self {
            case .position(let i), .predicted(let i): return Int32(i)
            default: return 0
            }
        }
    }

    /// One channel's correction, from measurements through to filters.
    ///
    /// Owns a core session handle, so it is a class rather than a struct.
    final class Fit {
        private let handle: OpaquePointer
        let grid: Grid
        private(set) var positionCount = 0
        private(set) var isFitted = false
        private(set) var hasParallelDesign = false

        init(grid: Grid, sampleRateHz: Double, platform: Platform) throws {
            guard let handle = dspi_rc_session_create(grid.minHz, grid.maxHz,
                                                      Int32(grid.pointsPerOctave),
                                                      sampleRateHz, platform.raw) else {
                throw CoreError.current("could not create a correction session")
            }
            self.handle = handle
            self.grid = grid
        }

        deinit {
            dspi_rc_session_free(handle)
        }

        /// Add one position's calibrated magnitude response.  The main
        /// listening position is conventionally weighted 2.0.
        func addPosition(magnitudesDb: [Double], weight: Double = 1.0, enabled: Bool = true) throws {
            let status = magnitudesDb.withUnsafeBufferPointer { buffer in
                dspi_rc_session_add_position(handle, buffer.baseAddress,
                                             magnitudesDb.count, weight, enabled ? 1 : 0)
            }
            try RoomCorrectionCore.check(status, "could not add the measurement")
            positionCount += 1
            isFitted = false
        }

        func clearPositions() throws {
            try RoomCorrectionCore.check(
                dspi_rc_session_clear_positions(handle),
                "could not clear measurements")
            positionCount = 0
            isFitted = false
        }

        /// Free-form target points, additive on top of the macro controls.
        func addTargetAnchor(freqHz: Double, gainDb: Double) throws {
            try RoomCorrectionCore.check(
                dspi_rc_session_add_target_anchor(handle, freqHz, gainDb),
                "could not add the target anchor")
            isFitted = false
        }

        func setTarget(_ target: Target, autoLevel: Bool = true) throws {
            var spec = target.spec
            try RoomCorrectionCore.check(
                dspi_rc_session_set_target(handle, &spec, autoLevel ? 1 : 0),
                "could not set the target")
            isFitted = false
        }

        func fit(_ options: FitOptions = FitOptions()) throws {
            var config = options.config
            try RoomCorrectionCore.check(
                dspi_rc_session_fit(handle, &config),
                "the correction could not be calculated")
            isFitted = true
            hasParallelDesign = false
        }

        /// Design a fixed-pole parallel bank for the same problem the fit just
        /// solved, so the two are directly comparable.  Requires a prior `fit`.
        ///
        /// Nothing here can be applied to the hardware.
        func designParallel(_ options: ParallelOptions = ParallelOptions()) throws {
            var config = options.config
            try RoomCorrectionCore.check(
                dspi_rc_session_design_parallel(handle, &config),
                "the fixed-pole design could not be calculated")
            hasParallelDesign = true
        }

        var parallelMetrics: Metrics {
            get throws {
                var raw = dspi_rc_metrics()
                try RoomCorrectionCore.check(
                    dspi_rc_session_parallel_metrics(handle, &raw), "no fixed-pole design")
                return Metrics(raw)
            }
        }

        /// Attenuation the fixed-pole design forces.  Expect large negative
        /// values: it carries no per-section limits, so it takes gain where
        /// boost is forbidden and the trim pulls the channel down to match.
        var parallelTrimDb: Double {
            get throws {
                var value: Double = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_parallel_trim_db(handle, &value), "no fixed-pole design")
                return value
            }
        }

        var parallelSections: [ParallelSection] {
            get throws {
                var count = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_parallel_section_count(handle, &count),
                    "no fixed-pole design")
                guard count > 0 else { return [] }

                var raw = [dspi_rc_parallel_section](repeating: dspi_rc_parallel_section(),
                                                     count: count)
                var written = 0
                let status = raw.withUnsafeMutableBufferPointer { buffer in
                    dspi_rc_session_parallel_sections(handle, buffer.baseAddress, count, &written)
                }
                try RoomCorrectionCore.check(status, "could not read the pole sections")
                return raw.map {
                    ParallelSection(freqHz: $0.freq_hz, q: $0.q, b0: $0.b0, b1: $0.b1)
                }
            }
        }

        /// Filters ready to write to the device.  `type` carries the firmware's
        /// FilterType value, so these map straight onto the EQ write path.
        var filters: [FilterParams] {
            get throws {
                var count = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_filter_count(handle, &count), "no fit available")
                guard count > 0 else { return [] }

                var raw = [dspi_rc_filter](repeating: dspi_rc_filter(), count: count)
                var written = 0
                let status = raw.withUnsafeMutableBufferPointer { buffer in
                    dspi_rc_session_filters(handle, buffer.baseAddress, count, &written)
                }
                try RoomCorrectionCore.check(status, "could not read the filters")

                return raw.map { item in
                    var params = FilterParams()
                    params.type = FilterType(rawValue: Int(item.type)) ?? .peaking
                    params.freq = item.freq_hz
                    params.q = item.q
                    params.gain = item.gain_db
                    params.qp = item.qp
                    params.bypass = item.bypass != 0
                    return params
                }
            }
        }

        /// Attenuation the channel takes so the correction respects its
        /// ceiling.  Applied at the destination: output trim for an
        /// output-side correction, input preamp for an input-side one.
        var trimDb: Double {
            get throws {
                var value: Double = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_trim_db(handle, &value), "no fit available")
                return value
            }
        }

        /// Broadband level the correction adds, weighted over the correction
        /// band. Negative for a typical cut-only result.
        ///
        /// Spec section 7.5: every channel loses a different amount to its
        /// cuts, so applying correction without giving this back rebalances
        /// the system even though no level control was touched.
        var levelChangeDb: Double {
            get throws {
                var value: Double = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_level_change(handle, &value), "no fit available")
                return value
            }
        }

        var metrics: Metrics {
            get throws {
                var raw = dspi_rc_metrics()
                try RoomCorrectionCore.check(
                    dspi_rc_session_metrics(handle, &raw), "no fit available")
                return Metrics(raw)
            }
        }

        /// Metrics for the uncorrected response, so before/after is honest.
        var uncorrectedMetrics: Metrics {
            get throws {
                var raw = dspi_rc_metrics()
                try RoomCorrectionCore.check(
                    dspi_rc_session_uncorrected_metrics(handle, &raw), "no fit available")
                return Metrics(raw)
            }
        }

        func curve(_ which: Curve) throws -> [Double] {
            let count = grid.pointCount
            guard count > 0 else { return [] }
            var values = [Double](repeating: 0, count: count)
            var written = 0
            let status = values.withUnsafeMutableBufferPointer { buffer in
                dspi_rc_session_curve(handle, which.raw, which.index,
                                      buffer.baseAddress, count, &written)
            }
            try RoomCorrectionCore.check(status, "could not read the curve")
            return values
        }

        /// Estimated modal/statistical transition, and whether it could be
        /// estimated at all.  A single position cannot distinguish a room mode
        /// from a cancellation, so `estimated` is false there and the UI should
        /// say so rather than presenting a fallback as a measurement.
        var transition: (hz: Double, estimated: Bool) {
            get throws {
                var hz: Double = 0
                var estimated: Int32 = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_transition_hz(handle, &hz, &estimated), "no fit available")
                return (hz, estimated != 0)
            }
        }

        /// The band over which the speaker is actually producing output.
        var nativeBand: (lowHz: Double, highHz: Double, lowDetected: Bool, highDetected: Bool) {
            get throws {
                var low: Double = 0
                var high: Double = 0
                var lowDetected: Int32 = 0
                var highDetected: Int32 = 0
                try RoomCorrectionCore.check(
                    dspi_rc_session_native_band(handle, &low, &high, &lowDetected, &highDetected),
                    "no fit available")
                return (low, high, lowDetected != 0, highDetected != 0)
            }
        }
    }
}
