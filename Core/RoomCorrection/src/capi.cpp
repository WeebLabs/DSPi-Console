#include "dspi_rc/capi.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "dspi_rc/analysis.hpp"
#include "dspi_rc/calibration.hpp"
#include "dspi_rc/optimizer.hpp"
#include "dspi_rc/parallel.hpp"
#include "dspi_rc/sweep.hpp"
#include "dspi_rc/target.hpp"

using namespace dspi_rc;

namespace {

// Thread-local so two sessions on two threads cannot overwrite each other's
// diagnostics, which would make a failure report point at the wrong call.
thread_local std::string g_lastError = "";

dspi_rc_status fail(dspi_rc_status status, const std::string& message) {
    g_lastError = message;
    return status;
}

std::size_t copyOut(const std::vector<double>& source, double* out, std::size_t capacity) {
    const std::size_t count = std::min(source.size(), capacity);
    for (std::size_t i = 0; i < count; ++i) out[i] = source[i];
    return source.size();
}

}  // namespace

// ---------------------------------------------------------------------------

struct dspi_rc_calibration {
    MicCalibration calibration;
    std::vector<std::string> warnings;
};

struct dspi_rc_session {
    FrequencyGrid grid;
    double sampleRateHz = 48000.0;
    Platform platform = Platform::RP2350;

    std::vector<PositionMeasurement> positions;
    TargetSpec targetSpec = presetNatural();
    std::vector<TargetAnchor> anchors;
    bool targetSet = false;

    FitProblem problem;
    FitResult result;
    FitMetrics uncorrected;
    bool fitted = false;

    // Evaluation only; never written to hardware.  See capi.h.
    ParallelDesign parallelDesign;
    bool parallelDesigned = false;
};

// ---------------------------------------------------------------------------

const char* dspi_rc_last_error(void) { return g_lastError.c_str(); }

const char* dspi_rc_algorithm_version(void) {
    // Bump whenever a change would alter a fitted result for identical input.
    // A saved project records this so a recalculation can tell whether it
    // reproduces the stored answer.
    return "dspi_rc/1.0.0";
}

// ---------------------------------------------------------------------------
// Sweep
// ---------------------------------------------------------------------------

dspi_rc_status dspi_rc_default_sweep_spec(double sample_rate_hz, int role,
                                          dspi_rc_sweep_spec* spec) {
    if (!spec) return fail(DSPI_RC_INVALID_ARGUMENT, "spec is null");
    if (sample_rate_hz <= 0.0) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid sample rate");

    SweepSpec defaults;
    defaults.sampleRateHz = sample_rate_hz;
    switch (role) {
        case 2:  // subwoofer: narrow band, long sweep for low-end SNR
            defaults.startHz = 5.0;
            defaults.endHz = 1000.0;
            defaults.durationSeconds = 12.0;
            break;
        case 1:  // bass limited
        case 0:  // full range
        default:
            defaults.startHz = 10.0;
            defaults.endHz = std::min(22000.0, sample_rate_hz * 0.45);
            defaults.durationSeconds = 8.0;
            break;
    }
    defaults.amplitude = std::pow(10.0, -20.0 / 20.0);  // -20 dBFS peak

    spec->sample_rate_hz = defaults.sampleRateHz;
    spec->start_hz = defaults.startHz;
    spec->end_hz = defaults.endHz;
    spec->duration_seconds = defaults.durationSeconds;
    spec->fade_in_seconds = defaults.fadeInSeconds;
    spec->fade_out_seconds = defaults.fadeOutSeconds;
    spec->amplitude = defaults.amplitude;
    spec->pre_roll_seconds = defaults.preRollSeconds;
    spec->post_roll_seconds = defaults.postRollSeconds;
    return DSPI_RC_OK;
}

namespace {

SweepSpec toSweepSpec(const dspi_rc_sweep_spec& c) {
    SweepSpec spec;
    spec.sampleRateHz = c.sample_rate_hz;
    spec.startHz = c.start_hz;
    spec.endHz = c.end_hz;
    spec.durationSeconds = c.duration_seconds;
    spec.fadeInSeconds = c.fade_in_seconds;
    spec.fadeOutSeconds = c.fade_out_seconds;
    spec.amplitude = c.amplitude;
    spec.preRollSeconds = c.pre_roll_seconds;
    spec.postRollSeconds = c.post_roll_seconds;
    return spec;
}

}  // namespace

dspi_rc_status dspi_rc_sweep_length(const dspi_rc_sweep_spec* spec, size_t* out_samples) {
    if (!spec || !out_samples) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    const SweepSpec native = toSweepSpec(*spec);
    const std::string error = native.validate();
    if (!error.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, error);
    *out_samples = native.totalSamples();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_render_sweep(const dspi_rc_sweep_spec* spec, float* out_samples,
                                    size_t capacity, size_t* out_written) {
    if (!spec || !out_samples || !out_written) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    const SweepSpec native = toSweepSpec(*spec);
    const std::string error = native.validate();
    if (!error.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, error);

    const std::vector<double> buffer = generatePlaybackBuffer(native);
    const std::size_t count = std::min(buffer.size(), capacity);
    for (std::size_t i = 0; i < count; ++i) out_samples[i] = static_cast<float>(buffer[i]);
    *out_written = buffer.size();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_grid_points(double min_hz, double max_hz, int points_per_octave,
                                   size_t* out_points) {
    if (!out_points) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    *out_points = grid.size();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_grid_frequencies(double min_hz, double max_hz, int points_per_octave,
                                        double* out_hz, size_t capacity, size_t* out_written) {
    if (!out_hz || !out_written) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    *out_written = copyOut(grid.hz, out_hz, capacity);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_analyze_capture(const dspi_rc_sweep_spec* spec,
                                       const float* recording, size_t recording_samples,
                                       double min_hz, double max_hz, int points_per_octave,
                                       double transition_hz,
                                       double* out_magnitudes_db, size_t capacity,
                                       double* out_latency_seconds) {
    if (!spec || !recording || !out_magnitudes_db) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    const SweepSpec native = toSweepSpec(*spec);
    const std::string error = native.validate();
    if (!error.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, error);

    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    if (capacity < grid.size()) return fail(DSPI_RC_INVALID_ARGUMENT, "buffer too small");

    std::vector<double> samples(recording_samples);
    for (std::size_t i = 0; i < recording_samples; ++i) samples[i] = recording[i];

    const ImpulseResponse ir = deconvolve(samples, native);
    if (ir.samples.empty()) return fail(DSPI_RC_FIT_FAILED, "deconvolution produced nothing");

    WindowingConfig windowing;
    windowing.transitionHz = transition_hz > 0.0 ? transition_hz : 200.0;

    const std::vector<double> response = frequencyDependentWindowedResponse(
        ir.samples, native.sampleRateHz, ir.peakIndex, grid, windowing);
    copyOut(response, out_magnitudes_db, capacity);
    if (out_latency_seconds) *out_latency_seconds = ir.latencySeconds;
    return DSPI_RC_OK;
}

// ---------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------

dspi_rc_calibration* dspi_rc_calibration_parse(const char* contents) {
    if (!contents) { g_lastError = "contents is null"; return nullptr; }
    const CalibrationParseResult parsed = parseCalibration(contents);
    if (!parsed.ok()) { g_lastError = parsed.error; return nullptr; }
    auto* handle = new dspi_rc_calibration();
    handle->calibration = parsed.calibration;
    handle->warnings = parsed.warnings;
    return handle;
}

void dspi_rc_calibration_free(dspi_rc_calibration* calibration) { delete calibration; }

dspi_rc_status dspi_rc_calibration_info(const dspi_rc_calibration* calibration,
                                        size_t* out_points, double* out_min_hz,
                                        double* out_max_hz, int* out_has_sensitivity,
                                        double* out_sensitivity_db) {
    if (!calibration) return fail(DSPI_RC_INVALID_ARGUMENT, "calibration is null");
    if (out_points) *out_points = calibration->calibration.points.size();
    if (out_min_hz) *out_min_hz = calibration->calibration.minFreqHz();
    if (out_max_hz) *out_max_hz = calibration->calibration.maxFreqHz();
    if (out_has_sensitivity) *out_has_sensitivity = calibration->calibration.hasSensitivity ? 1 : 0;
    if (out_sensitivity_db) *out_sensitivity_db = calibration->calibration.sensitivityDb;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_calibration_warning(const dspi_rc_calibration* calibration,
                                           size_t index, char* out_text, size_t capacity) {
    if (!calibration || !out_text) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (index >= calibration->warnings.size()) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "warning index out of range");
    }
    const std::string& text = calibration->warnings[index];
    if (capacity == 0) return fail(DSPI_RC_INVALID_ARGUMENT, "zero capacity");
    const std::size_t count = std::min(text.size(), capacity - 1);
    std::memcpy(out_text, text.data(), count);
    out_text[count] = '\0';
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_calibration_apply(const dspi_rc_calibration* calibration,
                                         const double* freqs_hz, double* magnitudes_db,
                                         size_t count) {
    if (!calibration || !freqs_hz || !magnitudes_db) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    std::vector<double> freqs(freqs_hz, freqs_hz + count);
    std::vector<double> magnitudes(magnitudes_db, magnitudes_db + count);
    calibration->calibration.applyTo(freqs, magnitudes);
    for (std::size_t i = 0; i < count; ++i) magnitudes_db[i] = magnitudes[i];
    return DSPI_RC_OK;
}

// ---------------------------------------------------------------------------
// Target
// ---------------------------------------------------------------------------

namespace {

void toCTarget(const TargetSpec& spec, dspi_rc_target_spec* out) {
    out->tilt_db_per_octave = spec.tiltDbPerOctave;
    out->pivot_hz = spec.pivotHz;
    out->bass_gain_db = spec.bassGainDb;
    out->bass_transition_hz = spec.bassTransitionHz;
    out->treble_gain_db = spec.trebleGainDb;
    out->treble_transition_hz = spec.trebleTransitionHz;
    out->shelf_width_octaves = spec.shelfWidthOctaves;
    out->level_db = spec.levelDb;
    out->low_curtain_hz = spec.lowCurtainHz;
    out->high_curtain_hz = spec.highCurtainHz;
}

TargetSpec fromCTarget(const dspi_rc_target_spec& c) {
    TargetSpec spec;
    spec.tiltDbPerOctave = c.tilt_db_per_octave;
    spec.pivotHz = c.pivot_hz;
    spec.bassGainDb = c.bass_gain_db;
    spec.bassTransitionHz = c.bass_transition_hz;
    spec.trebleGainDb = c.treble_gain_db;
    spec.trebleTransitionHz = c.treble_transition_hz;
    spec.shelfWidthOctaves = c.shelf_width_octaves;
    spec.levelDb = c.level_db;
    spec.lowCurtainHz = c.low_curtain_hz;
    spec.highCurtainHz = c.high_curtain_hz;
    return spec;
}

}  // namespace

dspi_rc_status dspi_rc_target_preset(int preset, dspi_rc_target_spec* spec) {
    if (!spec) return fail(DSPI_RC_INVALID_ARGUMENT, "spec is null");
    switch (preset) {
        case 0: toCTarget(presetFlat(), spec); return DSPI_RC_OK;
        case 1: toCTarget(presetNatural(), spec); return DSPI_RC_OK;
        case 2: toCTarget(presetStudio(), spec); return DSPI_RC_OK;
        case 3: toCTarget(presetBassWarm(), spec); return DSPI_RC_OK;
        default: return fail(DSPI_RC_INVALID_ARGUMENT, "unknown preset");
    }
}

dspi_rc_status dspi_rc_band_level(const double* magnitudes_db, size_t points,
                                  double min_hz, double max_hz,
                                  int points_per_octave,
                                  double band_low_hz, double band_high_hz,
                                  double* out_db) {
    if (!magnitudes_db || !out_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (band_high_hz <= band_low_hz) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "empty band");
    }

    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    if (points != grid.size()) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "curve does not match the grid");
    }

    double power = 0.0;
    std::size_t counted = 0;
    for (std::size_t i = 0; i < points; ++i) {
        if (grid.hz[i] < band_low_hz || grid.hz[i] > band_high_hz) continue;
        power += std::pow(10.0, magnitudes_db[i] / 10.0);
        ++counted;
    }
    if (counted == 0) return fail(DSPI_RC_INVALID_ARGUMENT, "no grid bin inside the band");

    // Mean per bin rather than a total: the grid is log spaced, so a mean over
    // bins is a mean per octave up to a constant, and that constant is what
    // makes the figure independent of the band's width.
    *out_db = 10.0 * std::log10(power / static_cast<double>(counted));
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_spatial_statistics(const double* positions_db,
                                          size_t position_count,
                                          size_t points,
                                          double min_hz, double max_hz,
                                          int points_per_octave,
                                          double* out_average_db,
                                          double* out_spread_db) {
    if (!positions_db) return fail(DSPI_RC_INVALID_ARGUMENT, "positions are null");
    if (position_count == 0) return fail(DSPI_RC_INVALID_ARGUMENT, "no positions");
    if (!out_average_db && !out_spread_db) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "nothing to write");
    }

    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    if (points != grid.size()) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "positions do not match the grid");
    }

    std::vector<PositionMeasurement> positions;
    positions.reserve(position_count);
    for (size_t i = 0; i < position_count; ++i) {
        PositionMeasurement position;
        position.magnitudesDb.assign(positions_db + i * points,
                                     positions_db + (i + 1) * points);
        positions.push_back(std::move(position));
    }

    // No target: the average and the spread are properties of the measurements
    // alone, and the caller has not necessarily chosen a target yet.
    const SpatialStatistics statistics =
        computeSpatialStatistics(grid, positions, {});

    if (out_average_db) {
        std::copy(statistics.powerAverageDb.begin(), statistics.powerAverageDb.end(),
                  out_average_db);
    }
    if (out_spread_db) {
        std::copy(statistics.madDb.begin(), statistics.madDb.end(), out_spread_db);
    }
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_smooth_curve(const double* magnitudes_db, size_t points,
                                    double min_hz, double max_hz,
                                    int points_per_octave,
                                    double fraction_denominator,
                                    double transition_hz,
                                    double* out_db) {
    if (!magnitudes_db || !out_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");

    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    if (points != grid.size()) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "curve does not match the grid");
    }

    const std::vector<double> input(magnitudes_db, magnitudes_db + points);
    const std::vector<double> smoothed =
        fraction_denominator > 0.0
            ? smoothFractionalOctave(grid, input, fraction_denominator)
            : smoothVariable(grid, input, SmoothingConfig::forTransition(transition_hz));

    std::copy(smoothed.begin(), smoothed.end(), out_db);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_evaluate_target(const dspi_rc_target_spec* spec,
                                       const double* anchor_hz,
                                       const double* anchor_db,
                                       size_t anchor_count,
                                       double min_hz, double max_hz,
                                       int points_per_octave,
                                       double* out_db, size_t capacity,
                                       size_t* out_written) {
    if (!spec) return fail(DSPI_RC_INVALID_ARGUMENT, "spec is null");
    if (!out_db) return fail(DSPI_RC_INVALID_ARGUMENT, "output is null");
    if (anchor_count > 0 && (!anchor_hz || !anchor_db)) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "anchor arrays are null");
    }

    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, "invalid grid");
    if (capacity < grid.size()) return fail(DSPI_RC_INVALID_ARGUMENT, "output too small");

    TargetSpec target = fromCTarget(*spec);
    target.anchors.clear();
    for (size_t i = 0; i < anchor_count; ++i) {
        target.anchors.push_back(TargetAnchor{anchor_hz[i], anchor_db[i]});
    }

    const std::string problem = target.validate();
    if (!problem.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, problem.c_str());

    const std::vector<double> curve = buildTarget(grid, target);
    std::copy(curve.begin(), curve.end(), out_db);
    if (out_written) *out_written = curve.size();
    return DSPI_RC_OK;
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

dspi_rc_session* dspi_rc_session_create(double min_hz, double max_hz, int points_per_octave,
                                        double sample_rate_hz, dspi_rc_platform platform) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(min_hz, max_hz, points_per_octave);
    if (grid.empty()) { g_lastError = "invalid grid"; return nullptr; }
    if (sample_rate_hz <= 0.0) { g_lastError = "invalid sample rate"; return nullptr; }

    auto* session = new dspi_rc_session();
    session->grid = grid;
    session->sampleRateHz = sample_rate_hz;
    session->platform =
        (platform == DSPI_RC_PLATFORM_RP2040) ? Platform::RP2040 : Platform::RP2350;
    return session;
}

void dspi_rc_session_free(dspi_rc_session* session) { delete session; }

dspi_rc_status dspi_rc_session_add_position(dspi_rc_session* session,
                                            const double* magnitudes_db, size_t count,
                                            double weight, int enabled) {
    if (!session || !magnitudes_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (count != session->grid.size()) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "position length does not match the grid");
    }
    PositionMeasurement position;
    position.magnitudesDb.assign(magnitudes_db, magnitudes_db + count);
    position.weight = weight;
    position.enabled = enabled != 0;
    session->positions.push_back(std::move(position));
    session->fitted = false;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_clear_positions(dspi_rc_session* session) {
    if (!session) return fail(DSPI_RC_INVALID_ARGUMENT, "session is null");
    session->positions.clear();
    session->fitted = false;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_add_target_anchor(dspi_rc_session* session,
                                                  double freq_hz, double gain_db) {
    if (!session) return fail(DSPI_RC_INVALID_ARGUMENT, "session is null");
    if (freq_hz <= 0.0) return fail(DSPI_RC_INVALID_ARGUMENT, "anchor frequency must be positive");
    session->anchors.push_back({freq_hz, gain_db});
    session->fitted = false;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_set_target(dspi_rc_session* session,
                                          const dspi_rc_target_spec* spec, int auto_level) {
    if (!session || !spec) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (session->positions.empty()) {
        return fail(DSPI_RC_INVALID_STATE, "add at least one position before setting the target");
    }

    TargetSpec target = fromCTarget(*spec);
    target.anchors = session->anchors;
    const std::string error = target.validate();
    if (!error.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, error);

    const NativeBandwidth native =
        estimateNativeBandwidth(session->grid, session->positions.front().magnitudesDb);
    if (auto_level != 0) {
        const SpatialStatistics provisional =
            computeSpatialStatistics(session->grid, session->positions, {});
        target.levelDb =
            chooseAutoLevel(session->grid, provisional.powerAverageDb, target, native);
    }

    session->targetSpec = target;
    session->targetSet = true;
    session->fitted = false;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_default_fit_config(dspi_rc_fit_config* config) {
    if (!config) return fail(DSPI_RC_INVALID_ARGUMENT, "config is null");
    const FitConfig defaults;
    config->max_filters = defaults.maxFilters;
    config->allow_shelves = defaults.allowShelves ? 1 : 0;
    config->strength = defaults.strength;
    config->cut_limit_db = defaults.cutLimitDb;
    config->boost_limit_db = defaults.boostLimitDb;
    config->combined_ceiling_db = defaults.combinedCeilingDb;
    config->max_boost_q = defaults.maxBoostQ;
    config->hygiene_weight = defaults.hygieneWeight;
    config->max_iterations = defaults.maxIterations;
    config->starts = defaults.starts;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_fit(dspi_rc_session* session, const dspi_rc_fit_config* config) {
    if (!session) return fail(DSPI_RC_INVALID_ARGUMENT, "session is null");
    if (session->positions.empty()) return fail(DSPI_RC_INVALID_STATE, "no positions");
    if (!session->targetSet) return fail(DSPI_RC_INVALID_STATE, "target not set");

    FitConfig fit;
    if (config) {
        fit.maxFilters = config->max_filters;
        fit.allowShelves = config->allow_shelves != 0;
        fit.strength = config->strength;
        fit.cutLimitDb = config->cut_limit_db;
        fit.boostLimitDb = config->boost_limit_db;
        fit.combinedCeilingDb = config->combined_ceiling_db;
        fit.maxBoostQ = config->max_boost_q;
        fit.hygieneWeight = config->hygiene_weight;
        fit.maxIterations = config->max_iterations;
        fit.starts = config->starts;
    }
    const std::string configError = fit.validate();
    if (!configError.empty()) return fail(DSPI_RC_INVALID_ARGUMENT, configError);

    FitProblem problem;
    problem.grid = session->grid;
    problem.positions = session->positions;
    problem.sampleRateHz = session->sampleRateHz;
    problem.platform = session->platform;
    problem.native =
        estimateNativeBandwidth(session->grid, session->positions.front().magnitudesDb);
    problem.targetDb = buildTarget(session->grid, session->targetSpec);
    problem.statistics =
        computeSpatialStatistics(session->grid, session->positions, problem.targetDb);

    // After the statistics, so the power average being eased toward is the real
    // one, and before the mask, so reliability weighting still applies.
    applyStrength(problem, fit.strength);
    // The caller's boost limit has to reach the mask, not just the per-filter
    // bound. Without it the ceiling stays at zero while individual filters are
    // free to take positive gain: boost gets generated, then punished by
    // requiredTrim attenuating the whole channel, so raising the limit made
    // the corrected response worse instead of better.
    MaskConfig maskConfig;
    maskConfig.maxBoostDb = fit.boostLimitDb;
    problem.mask = buildCorrectionMask(session->grid, session->targetSpec, problem.native,
                                       problem.statistics.reliability, maskConfig);

    const FitResult result = fitCorrection(problem, fit);
    if (result.filters.empty() && !result.converged) {
        return fail(DSPI_RC_FIT_FAILED, result.message.empty() ? "fit failed" : result.message);
    }

    session->problem = std::move(problem);
    session->result = result;
    session->uncorrected = evaluateBank(session->problem, {}, 0.0, fit);
    session->fitted = true;
    // A stale parallel design would silently describe the previous target.
    session->parallelDesigned = false;
    session->parallelDesign = ParallelDesign{};
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_default_parallel_config(dspi_rc_parallel_config* config) {
    if (!config) return fail(DSPI_RC_INVALID_ARGUMENT, "config is null");
    const ParallelConfig defaults;
    config->sections = 32;
    config->min_freq_hz = defaults.minFreqHz;
    config->max_freq_hz = defaults.maxFreqHz;
    // Bank's method as specified, which is what the evaluation reports:
    // logarithmic placement weighted toward the modal region, spacing-rule Q,
    // poles fixed.  The C++ defaults differ because they are tuned for the
    // sweeps rather than for fidelity to the published method.
    config->placement_bias = 1.0;
    config->log_density_low_share = defaults.logDensityLowShare;
    config->log_density_break_hz = defaults.logDensityBreakHz;
    config->q_from_feature_width = 0;
    config->refine_poles = 0;
    config->include_direct_path = defaults.includeDirectPath ? 1 : 0;
    config->normalize_by_target = defaults.normalizeByTarget ? 1 : 0;
    config->ridge = defaults.ridge;
    config->solve_passes = defaults.solvePasses;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_design_parallel(dspi_rc_session* session,
                                               const dspi_rc_parallel_config* config) {
    if (!session) return fail(DSPI_RC_INVALID_ARGUMENT, "session is null");
    if (!session->fitted) {
        return fail(DSPI_RC_INVALID_STATE, "fit the correction first");
    }

    ParallelConfig parallel;
    if (config) {
        parallel.sections = config->sections;
        parallel.minFreqHz = config->min_freq_hz;
        parallel.maxFreqHz = config->max_freq_hz;
        parallel.placementBias = config->placement_bias;
        parallel.logDensityLowShare = config->log_density_low_share;
        parallel.logDensityBreakHz = config->log_density_break_hz;
        parallel.qFromFeatureWidth = config->q_from_feature_width != 0;
        parallel.refinePoles = config->refine_poles != 0;
        parallel.includeDirectPath = config->include_direct_path != 0;
        parallel.normalizeByTarget = config->normalize_by_target != 0;
        parallel.ridge = config->ridge;
        parallel.solvePasses = config->solve_passes;
    } else {
        dspi_rc_parallel_config defaults;
        dspi_rc_default_parallel_config(&defaults);
        return dspi_rc_session_design_parallel(session, &defaults);
    }
    if (parallel.sections < 1) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "at least one section is required");
    }

    // The same problem the fit solved, so the comparison isolates the design.
    FitConfig fit;
    const ParallelDesign design = designParallel(session->problem, fit, parallel);
    if (!design.ok) {
        return fail(DSPI_RC_FIT_FAILED,
                    design.message.empty() ? "the parallel design failed" : design.message);
    }

    session->parallelDesign = design;
    session->parallelDesigned = true;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_parallel_section_count(dspi_rc_session* session,
                                                      size_t* out_count) {
    if (!session || !out_count) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->parallelDesigned) return fail(DSPI_RC_INVALID_STATE, "no parallel design");
    *out_count = session->parallelDesign.sections.size();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_parallel_sections(dspi_rc_session* session,
                                                 dspi_rc_parallel_section* out_sections,
                                                 size_t capacity, size_t* out_written) {
    if (!session || !out_sections || !out_written) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    if (!session->parallelDesigned) return fail(DSPI_RC_INVALID_STATE, "no parallel design");

    const std::vector<ParallelSection>& sections = session->parallelDesign.sections;
    const std::size_t count = std::min(sections.size(), capacity);
    for (std::size_t i = 0; i < count; ++i) {
        out_sections[i].freq_hz = sections[i].freqHz;
        out_sections[i].q = sections[i].q;
        out_sections[i].a1 = sections[i].a1;
        out_sections[i].a2 = sections[i].a2;
        out_sections[i].b0 = sections[i].b0;
        out_sections[i].b1 = sections[i].b1;
    }
    *out_written = sections.size();
    return DSPI_RC_OK;
}


// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

namespace {

void toCMetrics(const FitMetrics& in, dspi_rc_metrics* out) {
    out->raw_worst_position_rmse_db = in.rawWorstPositionRmseDb;
    out->reliable_worst_position_rmse_db = in.reliableWorstPositionRmseDb;
    out->reliable_median_abs_error_db = in.reliableMedianAbsErrorDb;
    out->p95_positive_overshoot_db = in.p95PositiveOvershootDb;
    out->max_combined_correction_db = in.maxCombinedCorrectionDb;
    out->min_combined_correction_db = in.minCombinedCorrectionDb;
    out->max_disputed_boost_db = in.maxDisputedBoostDb;
    out->max_outside_native_boost_db = in.maxOutsideNativeBoostDb;
    out->max_boost_filter_q = in.maxBoostFilterQ;
    out->active_filter_count = in.activeFilterCount;
    out->shelf_filter_count = in.shelfFilterCount;
}

}  // namespace

dspi_rc_status dspi_rc_session_filter_count(const dspi_rc_session* session, size_t* out_count) {
    if (!session || !out_count) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    *out_count = session->result.filters.size();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_filters(const dspi_rc_session* session,
                                       dspi_rc_filter* out_filters, size_t capacity,
                                       size_t* out_written) {
    if (!session || !out_filters || !out_written) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");

    const std::size_t count = std::min(session->result.filters.size(), capacity);
    for (std::size_t i = 0; i < count; ++i) {
        const FilterParams& p = session->result.filters[i];
        out_filters[i].type = static_cast<uint8_t>(p.type);
        out_filters[i].freq_hz = p.freq;
        out_filters[i].q = p.q;
        out_filters[i].gain_db = p.gainDb;
        out_filters[i].qp = p.qp;
        out_filters[i].bypass = p.bypass ? 1 : 0;
    }
    *out_written = session->result.filters.size();
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_trim_db(const dspi_rc_session* session, double* out_trim_db) {
    if (!session || !out_trim_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    *out_trim_db = session->result.trimDb;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_metrics(const dspi_rc_session* session, dspi_rc_metrics* out) {
    if (!session || !out) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    toCMetrics(session->result.metrics, out);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_uncorrected_metrics(const dspi_rc_session* session,
                                                   dspi_rc_metrics* out) {
    if (!session || !out) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    toCMetrics(session->uncorrected, out);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_parallel_metrics(dspi_rc_session* session,
                                                dspi_rc_metrics* out_metrics) {
    if (!session || !out_metrics) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->parallelDesigned) return fail(DSPI_RC_INVALID_STATE, "no parallel design");
    toCMetrics(session->parallelDesign.metrics, out_metrics);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_parallel_trim_db(dspi_rc_session* session, double* out_db) {
    if (!session || !out_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->parallelDesigned) return fail(DSPI_RC_INVALID_STATE, "no parallel design");
    *out_db = session->parallelDesign.trimDb;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_level_change(const dspi_rc_session* session,
                                            double* out_db) {
    if (!session || !out_db) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");

    const std::vector<double>& correction = session->result.correctionDb;
    const std::vector<double>& weight = session->problem.mask.weight;
    const std::size_t n = std::min(correction.size(), weight.size());

    // Weighted in the power domain, because a level change is an energy
    // statement: averaging decibels would let one deep narrow cut count as
    // heavily as a broad shallow one.
    double weighted = 0.0;
    double total = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        if (weight[i] <= 0.0) continue;
        weighted += weight[i] * std::pow(10.0, correction[i] / 10.0);
        total += weight[i];
    }
    if (total <= 0.0) { *out_db = 0.0; return DSPI_RC_OK; }

    *out_db = 10.0 * std::log10(weighted / total);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_curve(const dspi_rc_session* session, int which,
                                     int position_index, double* out_values,
                                     size_t capacity, size_t* out_written) {
    if (!session || !out_values || !out_written) {
        return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    }
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");

    const std::vector<double>* source = nullptr;
    switch (which) {
        case DSPI_RC_CURVE_TARGET: source = &session->problem.targetDb; break;
        case DSPI_RC_CURVE_POWER_AVERAGE: source = &session->problem.statistics.powerAverageDb; break;
        case DSPI_RC_CURVE_SPREAD: source = &session->problem.statistics.madDb; break;
        case DSPI_RC_CURVE_RELIABILITY: source = &session->problem.statistics.reliability; break;
        case DSPI_RC_CURVE_CORRECTION: source = &session->result.correctionDb; break;
        case DSPI_RC_CURVE_PARALLEL_CORRECTION:
            if (!session->parallelDesigned) {
                return fail(DSPI_RC_INVALID_STATE, "no parallel design");
            }
            source = &session->parallelDesign.correctionDb;
            break;
        case DSPI_RC_CURVE_MASK_WEIGHT: source = &session->problem.mask.weight; break;
        case DSPI_RC_CURVE_POSITION: {
            if (position_index < 0 ||
                static_cast<std::size_t>(position_index) >= session->problem.positions.size()) {
                return fail(DSPI_RC_INVALID_ARGUMENT, "position index out of range");
            }
            source = &session->problem.positions[static_cast<std::size_t>(position_index)].magnitudesDb;
            break;
        }
        case DSPI_RC_CURVE_PREDICTED: {
            if (position_index < 0 ||
                static_cast<std::size_t>(position_index) >= session->result.predictedDb.size()) {
                return fail(DSPI_RC_INVALID_ARGUMENT, "position index out of range");
            }
            source = &session->result.predictedDb[static_cast<std::size_t>(position_index)];
            break;
        }
        default:
            return fail(DSPI_RC_INVALID_ARGUMENT, "unknown curve");
    }

    *out_written = copyOut(*source, out_values, capacity);
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_transition_hz(const dspi_rc_session* session, double* out_hz,
                                             int* out_estimated) {
    if (!session || !out_hz) return fail(DSPI_RC_INVALID_ARGUMENT, "null argument");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    *out_hz = session->problem.statistics.transitionHz;
    if (out_estimated) *out_estimated = session->problem.statistics.transitionEstimated ? 1 : 0;
    return DSPI_RC_OK;
}

dspi_rc_status dspi_rc_session_native_band(const dspi_rc_session* session, double* out_low_hz,
                                           double* out_high_hz, int* out_low_detected,
                                           int* out_high_detected) {
    if (!session) return fail(DSPI_RC_INVALID_ARGUMENT, "session is null");
    if (!session->fitted) return fail(DSPI_RC_NOT_FITTED, "session has not been fitted");
    if (out_low_hz) *out_low_hz = session->problem.native.lowHz;
    if (out_high_hz) *out_high_hz = session->problem.native.highHz;
    if (out_low_detected) *out_low_detected = session->problem.native.lowDetected ? 1 : 0;
    if (out_high_detected) *out_high_detected = session->problem.native.highDetected ? 1 : 0;
    return DSPI_RC_OK;
}
