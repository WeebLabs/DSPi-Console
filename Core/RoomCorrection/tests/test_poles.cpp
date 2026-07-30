// Section placement.
//
// Placement is the part of the fixed-pole method that decides quality at a
// small section count, and it is decided before anything is solved, so it is
// worth testing on its own terms rather than only through a finished fit.
#include "dspi_rc/poles.hpp"

#include <cmath>
#include <vector>

#include "testing.hpp"

using namespace dspi_rc;

namespace {

FrequencyGrid standardGrid() {
    return FrequencyGrid::logSpaced(20.0, 20000.0, 96);
}

// A single resonance in the error curve, so placement has something to find.
std::vector<double> bumpAt(const FrequencyGrid& grid, double freqHz, double gainDb, double q) {
    std::vector<double> error(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double ratio = grid.hz[i] / freqHz;
        const double denominator = 1.0 + q * q * (ratio - 1.0 / ratio) * (ratio - 1.0 / ratio);
        error[i] = gainDb / denominator;
    }
    return error;
}

std::size_t countBetween(const SectionPlacement& placement, double lowHz, double highHz) {
    std::size_t count = 0;
    for (double f : placement.freqHz) {
        if (f >= lowHz && f <= highHz) ++count;
    }
    return count;
}

}  // namespace

TEST_CASE(the_cut_q_ceiling_falls_from_the_transition_to_the_top) {
    QLimits limits;
    limits.transitionHz = 200.0;

    CHECK_NEAR(cutQLimit(50.0, limits), 10.0, 1e-9);
    CHECK_NEAR(cutQLimit(200.0, limits), 10.0, 1e-9);
    CHECK_NEAR(cutQLimit(10000.0, limits), 3.0, 1e-9);
    CHECK_NEAR(cutQLimit(20000.0, limits), 3.0, 1e-9);

    // Monotone in between, which is what makes the rule "less narrow as
    // frequency rises" rather than a step at one frequency.
    double previous = 11.0;
    for (double f = 200.0; f <= 10000.0; f *= 1.2) {
        const double limit = cutQLimit(f, limits);
        CHECK(limit <= previous + 1e-9);
        previous = limit;
    }
}

TEST_CASE(placement_returns_the_requested_count_sorted_and_inside_the_band) {
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error = bumpAt(grid, 60.0, 8.0, 4.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 10;
    config.minFreqHz = 30.0;
    config.maxFreqHz = 16000.0;

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    CHECK(placement.size() == 10);
    CHECK(placement.q.size() == 10);
    for (std::size_t i = 0; i < placement.size(); ++i) {
        CHECK(placement.freqHz[i] >= config.minFreqHz - 1e-9);
        CHECK(placement.freqHz[i] <= config.maxFreqHz + 1e-9);
        if (i > 0) CHECK(placement.freqHz[i] > placement.freqHz[i - 1]);
    }
}

TEST_CASE(a_flat_error_curve_falls_back_to_uniform_log_spacing) {
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error(grid.size(), 0.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 8;

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    CHECK(placement.size() == 8);
    CHECK(!placement.energyDriven);

    // Equal ratios between neighbours is the signature of log spacing.
    const double first = placement.freqHz[1] / placement.freqHz[0];
    for (std::size_t i = 2; i < placement.size(); ++i) {
        CHECK_NEAR(placement.freqHz[i] / placement.freqHz[i - 1], first, 1e-6);
    }
}

TEST_CASE(energy_placement_concentrates_sections_on_the_feature) {
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error = bumpAt(grid, 60.0, 10.0, 6.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 10;

    config.placementBias = 1.0;   // uniform log
    const SectionPlacement uniform = placeSections(grid, error, weight, config);
    config.placementBias = 0.0;   // pure energy
    const SectionPlacement energy = placeSections(grid, error, weight, config);

    CHECK(energy.energyDriven);
    // The mode is at 60 Hz; pure energy placement must put materially more of
    // the budget near it than uniform spacing does.
    CHECK(countBetween(energy, 40.0, 90.0) > countBetween(uniform, 40.0, 90.0));
}

TEST_CASE(the_placement_bias_splits_the_budget_monotonically) {
    // Bias divides the budget between sections aimed at measured features and
    // sections that simply cover the band, so raising it must move sections off
    // the feature and onto the rest of the spectrum, one at a time rather than
    // switching between two regimes.
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error = bumpAt(grid, 60.0, 10.0, 6.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 8;
    config.minSpacingOctaves = 0.0;   // isolate the split from the spacing rule

    std::size_t previous = config.count + 1;
    for (double bias : {0.0, 0.25, 0.5, 0.75, 1.0}) {
        config.placementBias = bias;
        const SectionPlacement placement = placeSections(grid, error, weight, config);
        CHECK(placement.size() == 8);

        const std::size_t onFeature = countBetween(placement, 40.0, 90.0);
        CHECK(onFeature <= previous);
        previous = onFeature;
    }
    CHECK(previous <= 2);   // at full bias the allocator has stopped chasing it
}

TEST_CASE(sections_are_never_closer_than_the_minimum_spacing) {
    const FrequencyGrid grid = standardGrid();
    // A very sharp feature, which pure energy placement would otherwise stack
    // every section onto.
    const std::vector<double> error = bumpAt(grid, 45.0, 14.0, 25.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 10;
    config.placementBias = 0.0;
    config.minSpacingOctaves = 1.0 / 6.0;

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    CHECK(placement.size() == 10);
    for (std::size_t i = 1; i < placement.size(); ++i) {
        const double octaves =
            std::log2(placement.freqHz[i] / placement.freqHz[i - 1]);
        CHECK(octaves >= config.minSpacingOctaves - 1e-6);
    }
}

TEST_CASE(an_impossible_spacing_request_spreads_the_band_instead_of_failing) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 96);
    const std::vector<double> error(grid.size(), 1.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 10;
    config.minFreqHz = 100.0;
    config.maxFreqHz = 200.0;        // one octave
    config.minSpacingOctaves = 0.5;  // nine gaps of half an octave will not fit

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    CHECK(placement.size() == 10);
    CHECK_NEAR(placement.freqHz.front(), 100.0, 1e-6);
    CHECK_NEAR(placement.freqHz.back(), 200.0, 1e-6);
}

TEST_CASE(q_follows_spacing_and_respects_the_frequency_dependent_ceiling) {
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error(grid.size(), 0.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig config;
    config.count = 10;
    config.qLimits.transitionHz = 200.0;

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    for (std::size_t i = 0; i < placement.size(); ++i) {
        CHECK(placement.q[i] >= config.qLimits.minQ - 1e-9);
        CHECK(placement.q[i] <= cutQLimit(placement.freqHz[i], config.qLimits) + 1e-9);
        CHECK(placement.q[i] <= static_cast<double>(FirmwareLimits::maxQ) + 1e-9);
    }

    // Ten sections across three decades is about one per octave, and a filter
    // one octave wide has a Q near 1.4.  Denser placement must raise it.
    PlacementConfig dense = config;
    dense.count = 30;
    const SectionPlacement denser = placeSections(grid, error, weight, dense);
    CHECK(denser.q[15] > placement.q[5]);
}

TEST_CASE(zero_weight_regions_attract_no_sections) {
    const FrequencyGrid grid = standardGrid();
    // Large error everywhere, but the mask trusts only the bottom two octaves.
    const std::vector<double> error(grid.size(), 6.0);
    std::vector<double> weight(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] <= 80.0) weight[i] = 1.0;
    }

    PlacementConfig config;
    config.count = 6;
    config.placementBias = 0.0;
    config.minSpacingOctaves = 0.0;

    const SectionPlacement placement = placeSections(grid, error, weight, config);
    CHECK(placement.energyDriven);
    // Everything above the trusted band carries no energy, so no section should
    // be placed there; the smoothing kernel is allowed to bleed a little past
    // the edge.
    CHECK(placement.freqHz.back() < 100.0);
}

TEST_CASE(a_degenerate_request_returns_nothing_rather_than_guessing) {
    const FrequencyGrid grid = standardGrid();
    const std::vector<double> error(grid.size(), 1.0);
    const std::vector<double> weight(grid.size(), 1.0);

    PlacementConfig zero;
    zero.count = 0;
    CHECK(placeSections(grid, error, weight, zero).size() == 0);

    PlacementConfig inverted;
    inverted.count = 4;
    inverted.minFreqHz = 5000.0;
    inverted.maxFreqHz = 1000.0;
    CHECK(placeSections(grid, error, weight, inverted).size() == 0);
}
