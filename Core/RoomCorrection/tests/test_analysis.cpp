// Smoothing, spatial statistics and transition estimation.
//
// The behaviours worth pinning here are the ones that separate a correction
// that sounds right from one that measures right at a single seat: that a
// moving null is recognised as unreliable, that a shared mode is not, and
// that averaging does not let one deep cancellation dominate.
#include <cmath>
#include <vector>

#include "dspi_rc/analysis.hpp"
#include "dspi_rc/sweep.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

FrequencyGrid testGrid(int pointsPerOctave = 48) {
    return FrequencyGrid::logSpaced(20.0, 20000.0, pointsPerOctave);
}

// A Gaussian bump in log frequency: deliberately *not* a biquad, so smoothing
// and statistics are never tested against the same shape family the optimizer
// fits.
std::vector<double> bump(const FrequencyGrid& grid, double centreHz,
                         double widthOctaves, double gainDb) {
    std::vector<double> out(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double octaves = std::log2(grid.hz[i] / centreHz);
        out[i] = gainDb * std::exp(-0.5 * (octaves / widthOctaves) * (octaves / widthOctaves));
    }
    return out;
}

std::vector<double> add(std::vector<double> a, const std::vector<double>& b) {
    for (std::size_t i = 0; i < a.size() && i < b.size(); ++i) a[i] += b[i];
    return a;
}

std::size_t binNear(const FrequencyGrid& grid, double freqHz) {
    std::size_t best = 0;
    double bestDistance = 1e30;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double d = std::fabs(std::log2(grid.hz[i] / freqHz));
        if (d < bestDistance) { bestDistance = d; best = i; }
    }
    return best;
}

}  // namespace

// ---------------------------------------------------------------------------
// Smoothing
// ---------------------------------------------------------------------------

TEST_CASE(smoothing_preserves_a_flat_response) {
    const FrequencyGrid grid = testGrid();
    const std::vector<double> flat(grid.size(), -3.0);
    const std::vector<double> smoothed = smoothFractionalOctave(grid, flat, 6.0);
    for (double v : smoothed) CHECK_NEAR(v, -3.0, 1e-9);
}

TEST_CASE(smoothing_preserves_broad_features_and_attenuates_narrow_ones) {
    const FrequencyGrid grid = testGrid();
    const std::vector<double> broad = bump(grid, 1000.0, 1.0, 6.0);
    const std::vector<double> narrow = bump(grid, 1000.0, 0.03, 6.0);

    const std::vector<double> smoothBroad = smoothFractionalOctave(grid, broad, 6.0);
    const std::vector<double> smoothNarrow = smoothFractionalOctave(grid, narrow, 6.0);

    const std::size_t centre = binNear(grid, 1000.0);
    CHECK_NEAR(smoothBroad[centre], 6.0, 0.2);              // a one-octave feature survives
    CHECK(smoothNarrow[centre] < smoothBroad[centre] - 1.5); // a 1/33-octave one is cut down
}

TEST_CASE(wider_smoothing_attenuates_more) {
    const FrequencyGrid grid = testGrid();
    const std::vector<double> narrow = bump(grid, 1000.0, 0.05, 6.0);
    const std::size_t centre = binNear(grid, 1000.0);
    const double light = smoothFractionalOctave(grid, narrow, 24.0)[centre];
    const double heavy = smoothFractionalOctave(grid, narrow, 3.0)[centre];
    CHECK(light > heavy);
}

TEST_CASE(variable_smoothing_is_finer_at_the_bottom_than_the_top) {
    // The defining property: an identically narrow feature must survive at
    // low frequency, where correction is trustworthy, and be smoothed away at
    // high frequency, where it is seat-specific comb filtering.
    const FrequencyGrid grid = testGrid();
    const SmoothingConfig config = SmoothingConfig::forTransition(200.0);

    const std::vector<double> lowFeature = bump(grid, 60.0, 0.06, 8.0);
    const std::vector<double> highFeature = bump(grid, 8000.0, 0.06, 8.0);

    const double lowKept = smoothVariable(grid, lowFeature, config)[binNear(grid, 60.0)];
    const double highKept = smoothVariable(grid, highFeature, config)[binNear(grid, 8000.0)];

    CHECK(lowKept > 6.5);
    CHECK(highKept < lowKept - 1.0);
}

TEST_CASE(smoothing_schedule_follows_the_transition_estimate) {
    // The schedule must adapt to the room rather than assume a typical one.
    const SmoothingConfig low = SmoothingConfig::forTransition(100.0);
    const SmoothingConfig high = SmoothingConfig::forTransition(300.0);
    CHECK(high.lowBreakHz > low.lowBreakHz);
    CHECK(high.midBreakHz > low.midBreakHz);

    // Absurd inputs are clamped rather than propagated.
    const SmoothingConfig silly = SmoothingConfig::forTransition(5000.0);
    CHECK(silly.lowBreakHz <= 300.0);
}

TEST_CASE(smoothing_handles_degenerate_input) {
    const FrequencyGrid empty;
    CHECK(smoothFractionalOctave(empty, {}, 6.0).empty());
    const FrequencyGrid grid = testGrid(6);
    const std::vector<double> data(grid.size(), 1.0);
    CHECK(smoothFractionalOctave(grid, data, 0.0).size() == grid.size());
}

// ---------------------------------------------------------------------------
// Spatial statistics
// ---------------------------------------------------------------------------

TEST_CASE(power_average_is_not_dragged_down_by_one_deep_null) {
    // The reason the primary estimate is power-domain.  Four positions at
    // 0 dB and one in a -30 dB cancellation: a dB mean lands near -6 dB and
    // the correction would chase a hole that exists at one seat.  A power
    // average barely moves.
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    for (int i = 0; i < 4; ++i) {
        positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    }
    positions.push_back({std::vector<double>(grid.size(), -30.0), 1.0, true});

    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, {});
    const std::size_t bin = binNear(grid, 100.0);

    const double dbMean = (0.0 * 4 + -30.0) / 5.0;
    CHECK_NEAR(dbMean, -6.0, 1e-9);            // what the naive answer would be
    CHECK(stats.powerAverageDb[bin] > -1.5);   // what the power average gives
    CHECK_NEAR(stats.medianDb[bin], 0.0, 1e-9);
}

TEST_CASE(a_shared_mode_is_reliable) {
    // Every position sees the same peak, so the correction should trust it.
    const FrequencyGrid grid = testGrid();
    const std::vector<double> mode = bump(grid, 60.0, 0.15, 9.0);
    std::vector<PositionMeasurement> positions;
    for (int i = 0; i < 5; ++i) positions.push_back({mode, 1.0, true});

    const std::vector<double> target(grid.size(), 0.0);
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, target);

    const std::size_t bin = binNear(grid, 60.0);
    CHECK_NEAR(stats.madDb[bin], 0.0, 0.01);
    CHECK_NEAR(stats.signAgreement[bin], 1.0, 0.01);
    CHECK(stats.reliability[bin] > 0.9);
}

TEST_CASE(a_moving_null_is_unreliable) {
    // Each position has a deep null at a different frequency, which is what a
    // spatially unstable cancellation looks like.  Reliability at those
    // frequencies must collapse so the optimizer refuses to boost them.
    const FrequencyGrid grid = testGrid();
    const double nullCentres[] = {76.0, 88.0, 101.0, 118.0, 136.0};
    std::vector<PositionMeasurement> positions;
    for (double centre : nullCentres) {
        positions.push_back({bump(grid, centre, 0.04, -18.0), 1.0, true});
    }

    const std::vector<double> target(grid.size(), 0.0);
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, target);

    const std::size_t disputed = binNear(grid, 101.0);
    const std::size_t agreed = binNear(grid, 1000.0);
    CHECK(stats.reliability[disputed] < stats.reliability[agreed]);
    CHECK(stats.reliability[disputed] < 0.7);
    CHECK(stats.reliability[agreed] > 0.9);
}

TEST_CASE(mad_alone_does_not_catch_a_single_outlier_position) {
    // Documents why reliability is not built on spread alone.  MAD is robust
    // by construction, so with five positions and one deep null the median
    // absolute deviation is zero: four positions agree and the outlier is
    // discarded.  Sign agreement is the term that actually catches it, and
    // the composite reliability is what the optimizer consumes.
    const FrequencyGrid grid = testGrid();
    std::vector<PositionMeasurement> positions;
    for (int i = 0; i < 4; ++i) {
        positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    }
    positions.push_back({bump(grid, 101.0, 0.04, -18.0), 1.0, true});

    const std::vector<double> target(grid.size(), 0.0);
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, target);
    const std::size_t bin = binNear(grid, 101.0);

    CHECK_NEAR(stats.madDb[bin], 0.0, 0.01);        // spread says nothing
    CHECK(stats.signAgreement[bin] < 0.5);          // agreement does
    CHECK(stats.reliability[bin] < 0.5);
}

TEST_CASE(a_region_already_meeting_target_is_fully_reliable) {
    // Regression for a real inversion: where the average already sits on
    // target there is no correction to dispute, but a naive sign-agreement
    // count returns zero and marks the region maximally *un*reliable.  That
    // de-weights exactly the parts of the band that are already correct and
    // licenses the optimizer to overshoot through them.
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    for (int i = 0; i < 4; ++i) {
        positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    }
    const std::vector<double> target(grid.size(), 0.0);
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, target);

    for (double r : stats.reliability) CHECK_NEAR(r, 1.0, 1e-9);
    for (double a : stats.signAgreement) CHECK_NEAR(a, 1.0, 1e-9);
}

TEST_CASE(reliability_stays_within_bounds) {
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    positions.push_back({std::vector<double>(grid.size(), -40.0), 1.0, true});
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, {});
    for (double r : stats.reliability) {
        CHECK(r >= 0.05);
        CHECK(r <= 1.0);
    }
}

TEST_CASE(disabled_positions_are_excluded) {
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});
    positions.push_back({std::vector<double>(grid.size(), -40.0), 1.0, false});

    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, {});
    const std::size_t bin = binNear(grid, 200.0);
    CHECK_NEAR(stats.powerAverageDb[bin], 0.0, 0.01);
    CHECK_NEAR(stats.madDb[bin], 0.0, 0.01);
}

TEST_CASE(position_weights_are_honoured) {
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    positions.push_back({std::vector<double>(grid.size(), 0.0), 9.0, true});
    positions.push_back({std::vector<double>(grid.size(), -12.0), 1.0, true});

    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, {});
    const std::size_t bin = binNear(grid, 200.0);
    // Heavily weighted toward the 0 dB position.
    CHECK(stats.powerAverageDb[bin] > -1.0);
}

TEST_CASE(statistics_survive_no_enabled_positions) {
    const FrequencyGrid grid = testGrid(12);
    std::vector<PositionMeasurement> positions;
    positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, false});
    const SpatialStatistics stats = computeSpatialStatistics(grid, positions, {});
    CHECK(stats.powerAverageDb.size() == grid.size());
    CHECK(!stats.transitionEstimated);
}

// ---------------------------------------------------------------------------
// Transition frequency
// ---------------------------------------------------------------------------

TEST_CASE(one_position_cannot_estimate_a_transition) {
    // Stated in the spec as the strongest argument for measuring more than one
    // position: a single seat cannot tell a mode from a cancellation.
    const FrequencyGrid grid = testGrid();
    std::vector<PositionMeasurement> positions;
    positions.push_back({std::vector<double>(grid.size(), 0.0), 1.0, true});

    bool estimated = true;
    const double transition = estimateTransitionFrequency(grid, positions, {}, estimated);
    CHECK(!estimated);
    CHECK_NEAR(transition, 200.0, 1e-9);
}

TEST_CASE(a_room_with_no_spread_change_reports_no_transition) {
    // Identical positions have no transition to find.  Inventing one from
    // noise would silently reshape the smoothing and Q limits.
    const FrequencyGrid grid = testGrid();
    const std::vector<double> same = bump(grid, 500.0, 0.5, 4.0);
    std::vector<PositionMeasurement> positions;
    for (int i = 0; i < 5; ++i) positions.push_back({same, 1.0, true});

    bool estimated = true;
    const double transition = estimateTransitionFrequency(grid, positions, {}, estimated);
    CHECK(!estimated);
    CHECK_NEAR(transition, 200.0, 1e-9);
}

TEST_CASE(transition_is_found_where_spread_starts_climbing) {
    // Construct a room that agrees below 150 Hz and diverges above it.
    const FrequencyGrid grid = testGrid();
    const std::vector<double> shared = bump(grid, 50.0, 0.3, 8.0);

    std::vector<PositionMeasurement> positions;
    for (int p = 0; p < 5; ++p) {
        std::vector<double> curve = shared;
        // Position-specific interference, only above the transition.
        for (int k = 0; k < 6; ++k) {
            const double centre = 220.0 * std::pow(1.35, k) * (1.0 + 0.09 * p);
            curve = add(curve, bump(grid, centre, 0.05, (k % 2 == 0 ? -9.0 : 7.0)));
        }
        positions.push_back({curve, 1.0, true});
    }

    bool estimated = false;
    const double transition = estimateTransitionFrequency(grid, positions, {}, estimated);
    CHECK(estimated);
    CHECK(transition >= 100.0);
    CHECK(transition <= 400.0);
}

TEST_CASE(transition_estimate_is_clamped_to_a_sane_band) {
    const FrequencyGrid grid = testGrid();
    std::vector<PositionMeasurement> positions;
    for (int p = 0; p < 4; ++p) {
        std::vector<double> curve(grid.size(), 0.0);
        for (int k = 0; k < 10; ++k) {
            curve = add(curve, bump(grid, 30.0 * std::pow(1.5, k) * (1.0 + 0.2 * p), 0.05, -12.0));
        }
        positions.push_back({curve, 1.0, true});
    }
    bool estimated = false;
    const double transition = estimateTransitionFrequency(grid, positions, {}, estimated);
    CHECK(transition >= 100.0);
    CHECK(transition <= 400.0);
}

// ---------------------------------------------------------------------------
// Frequency-dependent windowing
// ---------------------------------------------------------------------------

TEST_CASE(windowing_recovers_a_flat_system_flat) {
    SweepSpec spec;
    spec.sampleRateHz = 48000.0;
    spec.startHz = 20.0;
    spec.endHz = 20000.0;
    spec.durationSeconds = 3.0;
    spec.preRollSeconds = 0.05;
    spec.postRollSeconds = 0.4;

    const ImpulseResponse ir = deconvolve(generatePlaybackBuffer(spec), spec);
    const FrequencyGrid grid = FrequencyGrid::logSpaced(50.0, 15000.0, 12);

    WindowingConfig config;
    config.transitionHz = 200.0;
    const std::vector<double> response = frequencyDependentWindowedResponse(
        ir.samples, spec.sampleRateHz, ir.peakIndex, grid, config);

    CHECK(response.size() == grid.size());
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] < 100.0 || grid.hz[i] > 12000.0) continue;
        CHECK_NEAR(response[i], 0.0, 1.0);
    }
}

TEST_CASE(windowing_tolerates_an_empty_impulse) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 6);
    const std::vector<double> response =
        frequencyDependentWindowedResponse({}, 48000.0, 0, grid, {});
    CHECK(response.size() == grid.size());
}
