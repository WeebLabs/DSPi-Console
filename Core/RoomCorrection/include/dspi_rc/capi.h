/* C ABI for libdspi_rc.
 *
 * The application layer is Swift today and will be something else on Windows.
 * A C boundary is the one interface both can call without a shim and without
 * pinning either side's compiler or standard library, which is why this exists
 * rather than exposing the C++ headers directly.
 *
 * Conventions:
 *   - Opaque handles.  Callers never see a C++ type.
 *   - Nothing throws.  Every call returns a status code; a failed call leaves
 *     the session untouched and sets a message retrievable with
 *     dspi_rc_last_error().
 *   - The caller owns all input buffers; the session copies what it needs.
 *   - Output buffers are caller-allocated.  Every getter takes a capacity and
 *     returns the number of elements it would have written, so a caller can
 *     size a buffer by calling once with capacity zero.
 *
 * Spec section 9.
 */
#ifndef DSPI_RC_CAPI_H
#define DSPI_RC_CAPI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------- */
/* Status                                                                     */
/* -------------------------------------------------------------------------- */

typedef enum dspi_rc_status {
    DSPI_RC_OK = 0,
    DSPI_RC_INVALID_ARGUMENT = 1,
    DSPI_RC_INVALID_STATE = 2,
    DSPI_RC_NOT_FITTED = 3,
    DSPI_RC_FIT_FAILED = 4
} dspi_rc_status;

/* Message describing the most recent failure on this thread.  Valid until the
 * next call that fails.  Never null. */
const char* dspi_rc_last_error(void);

/* Algorithm version.  Recorded in a saved project so a recalculation can tell
 * whether it would reproduce the stored result. */
const char* dspi_rc_algorithm_version(void);

/* -------------------------------------------------------------------------- */
/* Platform                                                                   */
/* -------------------------------------------------------------------------- */

typedef enum dspi_rc_platform {
    DSPI_RC_PLATFORM_RP2040 = 0,
    DSPI_RC_PLATFORM_RP2350 = 1
} dspi_rc_platform;

/* -------------------------------------------------------------------------- */
/* Filter                                                                     */
/* -------------------------------------------------------------------------- */

/* Mirrors the wire recipe.  `type` uses the firmware's FilterType values, so a
 * caller can hand these straight to REQ_SET_EQ_PARAM. */
typedef struct dspi_rc_filter {
    uint8_t type;
    float freq_hz;
    float q;
    float gain_db;
    float qp;        /* Linkwitz Transform only */
    uint8_t bypass;
} dspi_rc_filter;

/* -------------------------------------------------------------------------- */
/* Sweep and measurement                                                      */
/* -------------------------------------------------------------------------- */

typedef struct dspi_rc_sweep_spec {
    double sample_rate_hz;
    double start_hz;
    double end_hz;
    double duration_seconds;
    double fade_in_seconds;
    double fade_out_seconds;
    double amplitude;          /* linear peak, not dBFS */
    double pre_roll_seconds;
    double post_roll_seconds;
} dspi_rc_sweep_spec;

/* Fill `spec` with the recommended defaults for a role.
 * role: 0 = full range, 1 = bass limited, 2 = subwoofer. */
dspi_rc_status dspi_rc_default_sweep_spec(double sample_rate_hz,
                                          int role,
                                          dspi_rc_sweep_spec* spec);

/* Number of samples the playback buffer needs. */
dspi_rc_status dspi_rc_sweep_length(const dspi_rc_sweep_spec* spec, size_t* out_samples);

/* Render the playback buffer, including pre-roll and post-roll silence. */
dspi_rc_status dspi_rc_render_sweep(const dspi_rc_sweep_spec* spec,
                                    float* out_samples,
                                    size_t capacity,
                                    size_t* out_written);

/* Deconvolve a capture into a magnitude response on a log-frequency grid.
 *
 * `out_magnitudes_db` receives `grid_points` values.  The grid is generated
 * internally as `points_per_octave` between `min_hz` and `max_hz`; call
 * dspi_rc_grid_points() first to size the buffer.
 *
 * `transition_hz` selects the frequency-dependent window transition; pass 0 to
 * use a default.  `out_latency_seconds` receives total loop latency, which
 * magnitude correction does not need but distance diagnostics do. */
dspi_rc_status dspi_rc_analyze_capture(const dspi_rc_sweep_spec* spec,
                                       const float* recording,
                                       size_t recording_samples,
                                       double min_hz,
                                       double max_hz,
                                       int points_per_octave,
                                       double transition_hz,
                                       double* out_magnitudes_db,
                                       size_t capacity,
                                       double* out_latency_seconds);

/* Points in a log-spaced grid, so callers can size buffers. */
dspi_rc_status dspi_rc_grid_points(double min_hz, double max_hz, int points_per_octave,
                                   size_t* out_points);

/* Grid frequencies, for plotting. */
dspi_rc_status dspi_rc_grid_frequencies(double min_hz, double max_hz, int points_per_octave,
                                        double* out_hz, size_t capacity, size_t* out_written);

/* -------------------------------------------------------------------------- */
/* Microphone calibration                                                     */
/* -------------------------------------------------------------------------- */

typedef struct dspi_rc_calibration dspi_rc_calibration;

/* Parse file contents.  Returns NULL on failure; see dspi_rc_last_error(). */
dspi_rc_calibration* dspi_rc_calibration_parse(const char* contents);
void dspi_rc_calibration_free(dspi_rc_calibration* calibration);

dspi_rc_status dspi_rc_calibration_info(const dspi_rc_calibration* calibration,
                                        size_t* out_points,
                                        double* out_min_hz,
                                        double* out_max_hz,
                                        int* out_has_sensitivity,
                                        double* out_sensitivity_db);

/* Warnings the parser raised.  Index from 0 until DSPI_RC_INVALID_ARGUMENT. */
dspi_rc_status dspi_rc_calibration_warning(const dspi_rc_calibration* calibration,
                                           size_t index,
                                           char* out_text,
                                           size_t capacity);

/* Apply to a magnitude curve in place. */
dspi_rc_status dspi_rc_calibration_apply(const dspi_rc_calibration* calibration,
                                         const double* freqs_hz,
                                         double* magnitudes_db,
                                         size_t count);

/* -------------------------------------------------------------------------- */
/* Target                                                                     */
/* -------------------------------------------------------------------------- */

typedef struct dspi_rc_target_spec {
    double tilt_db_per_octave;
    double pivot_hz;
    double bass_gain_db;
    double bass_transition_hz;
    double treble_gain_db;
    double treble_transition_hz;
    double shelf_width_octaves;
    double level_db;
    double low_curtain_hz;
    double high_curtain_hz;
} dspi_rc_target_spec;

/* preset: 0 = flat, 1 = natural, 2 = studio, 3 = bass warm. */
dspi_rc_status dspi_rc_target_preset(int preset, dspi_rc_target_spec* spec);

/* -------------------------------------------------------------------------- */
/* Session                                                                    */
/* -------------------------------------------------------------------------- */

typedef struct dspi_rc_session dspi_rc_session;

dspi_rc_session* dspi_rc_session_create(double min_hz, double max_hz, int points_per_octave,
                                        double sample_rate_hz, dspi_rc_platform platform);
void dspi_rc_session_free(dspi_rc_session* session);

/* Add one position's magnitude response, already calibrated, on the session
 * grid.  `weight` is typically 2.0 for the main listening position. */
dspi_rc_status dspi_rc_session_add_position(dspi_rc_session* session,
                                            const double* magnitudes_db,
                                            size_t count,
                                            double weight,
                                            int enabled);

dspi_rc_status dspi_rc_session_clear_positions(dspi_rc_session* session);

/* Anchor points are additive on top of the macro controls. */
dspi_rc_status dspi_rc_session_add_target_anchor(dspi_rc_session* session,
                                                  double freq_hz, double gain_db);

/* Set the target.  Pass auto_level non-zero to have the level chosen. */
dspi_rc_status dspi_rc_session_set_target(dspi_rc_session* session,
                                          const dspi_rc_target_spec* spec,
                                          int auto_level);

typedef struct dspi_rc_fit_config {
    int max_filters;
    int allow_shelves;
    double cut_limit_db;
    double boost_limit_db;
    double combined_ceiling_db;
    double max_boost_q;
    double hygiene_weight;
    int max_iterations;
    int starts;
} dspi_rc_fit_config;

dspi_rc_status dspi_rc_default_fit_config(dspi_rc_fit_config* config);

/* Compute statistics, mask, and the fit.  Deterministic. */
dspi_rc_status dspi_rc_session_fit(dspi_rc_session* session,
                                   const dspi_rc_fit_config* config);

/* -------------------------------------------------------------------------- */
/* Results                                                                    */
/* -------------------------------------------------------------------------- */

typedef struct dspi_rc_metrics {
    double raw_worst_position_rmse_db;
    double reliable_worst_position_rmse_db;
    double reliable_median_abs_error_db;
    double p95_positive_overshoot_db;
    double max_combined_correction_db;
    double min_combined_correction_db;
    double max_disputed_boost_db;
    double max_outside_native_boost_db;
    double max_boost_filter_q;
    int active_filter_count;
    int shelf_filter_count;
} dspi_rc_metrics;

dspi_rc_status dspi_rc_session_filter_count(const dspi_rc_session* session, size_t* out_count);
dspi_rc_status dspi_rc_session_filters(const dspi_rc_session* session,
                                       dspi_rc_filter* out_filters,
                                       size_t capacity,
                                       size_t* out_written);

dspi_rc_status dspi_rc_session_trim_db(const dspi_rc_session* session, double* out_trim_db);
dspi_rc_status dspi_rc_session_metrics(const dspi_rc_session* session, dspi_rc_metrics* out);

/* Metrics for the uncorrected response, for an honest before/after. */
dspi_rc_status dspi_rc_session_uncorrected_metrics(const dspi_rc_session* session,
                                                   dspi_rc_metrics* out);

/* Curves, each `grid_points` long.  All are what to plot; none is recomputed
 * from an idealized cascade. */
dspi_rc_status dspi_rc_session_curve(const dspi_rc_session* session,
                                     int which,          /* see below */
                                     int position_index, /* only for POSITION curves */
                                     double* out_values,
                                     size_t capacity,
                                     size_t* out_written);

enum {
    DSPI_RC_CURVE_TARGET = 0,
    DSPI_RC_CURVE_POWER_AVERAGE = 1,
    DSPI_RC_CURVE_SPREAD = 2,          /* median absolute deviation */
    DSPI_RC_CURVE_RELIABILITY = 3,
    DSPI_RC_CURVE_CORRECTION = 4,      /* includes trim */
    DSPI_RC_CURVE_MASK_WEIGHT = 5,
    DSPI_RC_CURVE_POSITION = 6,        /* measured, per position */
    DSPI_RC_CURVE_PREDICTED = 7        /* corrected, per position */
};

dspi_rc_status dspi_rc_session_transition_hz(const dspi_rc_session* session,
                                             double* out_hz,
                                             int* out_estimated);

dspi_rc_status dspi_rc_session_native_band(const dspi_rc_session* session,
                                           double* out_low_hz,
                                           double* out_high_hz,
                                           int* out_low_detected,
                                           int* out_high_detected);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* DSPI_RC_CAPI_H */
