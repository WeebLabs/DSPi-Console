// Optimizer acceptance tests.
//
// These mirror the Milestone 0 corpus, which is the oracle this production
// implementation has to answer to.  The fixtures are deliberately built from
// Gaussian log-frequency features, analytic roll-offs and complex two-path
// reflections rather than from biquads, so the optimizer is never fitting the
// same shape family that generated the data.
//
// The properties asserted are the ones Milestone 0 established matter, in the
// order they matter: do not boost a local null, respect the safety
// constraints, and improve reliability-weighted error against the uncorrected
// response.  Raw worst-position error is deliberately *not* a hard gate,
// because refusing to invert an unreliable null legitimately increases it.
#include <cmath>
#include <complex>
#include <vector>

#include "dspi_rc/optimizer.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

FrequencyGrid corpusGrid() { return FrequencyGrid::logSpaced(20.0, 20000.0, 24); }

std::size_t binNear(const FrequencyGrid& grid, double freqHz) {
    std::size_t best = 0;
    double bestDistance = 1e30;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double d = std::fabs(std::log2(grid.hz[i] / freqHz));
        if (d < bestDistance) { bestDistance = d; best = i; }
    }
    return best;
}

// Gaussian bump in log frequency: not representable by any single biquad.
void addBump(const FrequencyGrid& grid, std::vector<double>& curve,
             double centreHz, double widthOctaves, double gainDb) {
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double octaves = std::log2(grid.hz[i] / centreHz);
        curve[i] += gainDb * std::exp(-0.5 * (octaves / widthOctaves) * (octaves / widthOctaves));
    }
}

// Nth-order analytic roll-off.
void addRolloff(const FrequencyGrid& grid, std::vector<double>& curve,
                double cornerHz, double order, bool low) {
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double ratio = low ? (cornerHz / grid.hz[i]) : (grid.hz[i] / cornerHz);
        if (ratio > 1.0) curve[i] -= 6.0 * order * std::log2(ratio);
    }
}

// A genuine two-path cancellation: non-minimum-phase, and the thing a PEQ
// must not try to invert.
void addReflection(const FrequencyGrid& grid, std::vector<double>& curve,
                   double delayMs, double amplitude) {
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const std::complex<double> phasor =
            std::polar(amplitude, -2.0 * M_PI * grid.hz[i] * delayMs / 1000.0);
        const double magnitude = std::abs(std::complex<double>(1.0, 0.0) + phasor);
        curve[i] += 20.0 * std::log10(std::max(1e-6, magnitude / (1.0 + amplitude)));
    }
}

// Assemble a complete problem from position curves.
FitProblem makeProblem(const FrequencyGrid& grid,
                       std::vector<std::vector<double>> curves,
                       const TargetSpec& targetSpec = presetFlat(),
                       Platform platform = Platform::RP2350) {
    FitProblem problem;
    problem.grid = grid;
    problem.sampleRateHz = 48000.0;
    problem.platform = platform;

    for (std::size_t i = 0; i < curves.size(); ++i) {
        PositionMeasurement position;
        position.magnitudesDb = std::move(curves[i]);
        position.weight = (i == 0) ? 2.0 : 1.0;  // main listening position
        position.enabled = true;
        problem.positions.push_back(std::move(position));
    }

    problem.native = estimateNativeBandwidth(grid, problem.positions.front().magnitudesDb);

    TargetSpec spec = targetSpec;
    // Provisional statistics to get a power average for level placement.
    const SpatialStatistics provisional = computeSpatialStatistics(grid, problem.positions, {});
    spec.levelDb = chooseAutoLevel(grid, provisional.powerAverageDb, spec, problem.native);

    problem.targetDb = buildTarget(grid, spec);
    problem.statistics = computeSpatialStatistics(grid, problem.positions, problem.targetDb);
    problem.mask = buildCorrectionMask(grid, spec, problem.native, problem.statistics.reliability);
    return problem;
}

std::vector<double> flat(const FrequencyGrid& grid, double level = 75.0) {
    return std::vector<double>(grid.size(), level);
}

}  // namespace

// ---------------------------------------------------------------------------
// The headline Milestone 0 result
// ---------------------------------------------------------------------------

TEST_CASE(a_single_seat_null_is_not_boosted) {
    // Four positions flat, one with a deep narrow null at 73 Hz.  A fit to the
    // arithmetic average applies substantial boost there; this must not.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 46.0, 0.25, 5.0);   // shared mode
        curves.push_back(curve);
    }
    std::vector<double> odd = flat(grid);
    addBump(grid, odd, 46.0, 0.25, 5.0);
    addBump(grid, odd, 73.0, 0.05, -30.0);
    curves.push_back(odd);

    const FitProblem problem = makeProblem(grid, curves);
    FitConfig config;
    config.boostLimitDb = 3.0;          // Advanced mode: boost is *permitted*
    config.combinedCeilingDb = 3.0;
    const FitResult result = fitCorrection(problem, config);

    CHECK(result.converged);
    // The null sits between 65 and 82 Hz; correction there must stay near zero.
    double worstBoost = -100.0;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] >= 65.0 && grid.hz[i] <= 82.0) {
            worstBoost = std::max(worstBoost, result.correctionDb[i]);
        }
    }
    CHECK(worstBoost < 0.5);
}

TEST_CASE(a_shared_mode_is_cut) {
    // The counterpart: a peak every position sees must be corrected, or the
    // safety machinery has simply disabled the feature.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 5; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 58.0, 0.2, 9.0);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);

    CHECK(result.converged);
    const std::size_t bin = binNear(grid, 58.0);
    // Relative to the correction's own maximum, the mode must be pulled down.
    double maxCorrection = -100.0;
    for (double v : result.correctionDb) maxCorrection = std::max(maxCorrection, v);
    CHECK(result.correctionDb[bin] < maxCorrection - 4.0);
    CHECK(result.metrics.activeFilterCount >= 1);
}

TEST_CASE(moving_nulls_are_not_boosted) {
    const FrequencyGrid grid = corpusGrid();
    const double centres[] = {76.0, 88.0, 101.0, 118.0, 136.0};
    std::vector<std::vector<double>> curves;
    for (double centre : centres) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 58.0, 0.2, 6.0);
        addBump(grid, curve, centre, 0.05, -18.0);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    FitConfig config;
    config.boostLimitDb = 3.0;
    config.combinedCeilingDb = 3.0;
    const FitResult result = fitCorrection(problem, config);

    CHECK(result.converged);
    double worstBoost = -100.0;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] >= 70.0 && grid.hz[i] <= 145.0) {
            worstBoost = std::max(worstBoost, result.correctionDb[i]);
        }
    }
    CHECK(worstBoost < 1.0);
}

// ---------------------------------------------------------------------------
// Safety constraints
// ---------------------------------------------------------------------------

TEST_CASE(default_mode_produces_no_positive_combined_correction) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 40.0, 0.3, 7.0);
        addBump(grid, curve, 300.0, 0.4, -5.0);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);

    CHECK(result.converged);
    CHECK(result.metrics.maxCombinedCorrectionDb <= -0.5 + 1e-6);
    CHECK(result.trimDb <= 0.0);
}

TEST_CASE(boost_q_is_limited) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 90.0, 0.04, -12.0);   // narrow dip, tempting to fill
        curves.push_back(curve);
    }

    FitConfig config;
    config.boostLimitDb = 3.0;
    config.combinedCeilingDb = 3.0;
    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem, config);

    CHECK(result.metrics.maxBoostFilterQ <= config.maxBoostQ + 0.01);
}

TEST_CASE(no_boost_outside_the_native_band) {
    // A speaker rolling off below 70 Hz.  The optimizer must not spend its
    // budget trying to extend it.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve = flat(grid);
        addRolloff(grid, curve, 70.0, 4.0, true);
        curves.push_back(curve);
    }

    FitConfig config;
    config.boostLimitDb = 3.0;
    config.combinedCeilingDb = 3.0;
    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem, config);

    CHECK(problem.native.lowDetected);
    CHECK(result.metrics.maxOutsideNativeBoostDb < 0.5);
}

TEST_CASE(band_budget_is_respected) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve = flat(grid);
        for (int k = 0; k < 14; ++k) {
            addBump(grid, curve, 40.0 * std::pow(1.5, k), 0.12, (k % 2 == 0) ? 6.0 : -6.0);
        }
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    for (int budget : {1, 2, 5, 10}) {
        FitConfig config;
        config.maxFilters = budget;
        const FitResult result = fitCorrection(problem, config);
        CHECK(static_cast<int>(result.filters.size()) <= budget);
    }
}

TEST_CASE(filters_respect_firmware_limits) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 25.0, 0.08, 14.0);   // near the bottom of the grid
        addBump(grid, curve, 18000.0, 0.08, 10.0);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);

    for (const FilterParams& p : result.filters) {
        CHECK(p.freq >= FirmwareLimits::minFreqHz - 1e-3);
        CHECK(p.freq <= problem.sampleRateHz * FirmwareLimits::freqNyquistFraction + 1e-3);
        CHECK(p.q >= FirmwareLimits::minQ - 1e-6);
        CHECK(p.q <= FirmwareLimits::maxQ + 1e-6);
        CHECK(p.gainDb >= -12.0 - 1e-3);
    }
}

// ---------------------------------------------------------------------------
// Benefit
// ---------------------------------------------------------------------------

TEST_CASE(correction_improves_reliability_weighted_error) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 5; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 48.0, 0.22, 8.0);
        addBump(grid, curve, 120.0, 0.3, 5.0);
        addBump(grid, curve, 620.0, 0.5, 2.5);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);

    // Score the uncorrected response by evaluating an empty bank.
    const FitMetrics uncorrected = evaluateBank(problem, {}, 0.0);

    CHECK(result.metrics.reliableWorstPositionRmseDb <
          uncorrected.reliableWorstPositionRmseDb);
}

TEST_CASE(correction_improves_a_cancellation_dominated_room_only_modestly) {
    // Documents an honest limitation rather than a success.  A room whose
    // error is mostly spatially unstable cancellation cannot be fixed by
    // magnitude EQ, and the Milestone 0 corpus measured only 3 to 15 percent
    // improvement on such fixtures.  The gate is that it improves and does not
    // make things worse, not that it improves a lot.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int p = 0; p < 9; ++p) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 55.0, 0.25, 6.0);
        addReflection(grid, curve, 4.0 + 0.9 * p, 0.75);
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);
    const FitMetrics uncorrected = evaluateBank(problem, {}, 0.0);

    CHECK(result.metrics.reliableWorstPositionRmseDb <=
          uncorrected.reliableWorstPositionRmseDb);
}

TEST_CASE(shelves_are_used_for_a_broad_trend) {
    // A tilted room against a flat target is what shelves are for; spending
    // several peaking filters on it would waste a budget that is already tight.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 3; ++i) {
        std::vector<double> curve(grid.size(), 0.0);
        for (std::size_t k = 0; k < grid.size(); ++k) {
            curve[k] = 75.0 - 2.0 * std::log2(grid.hz[k] / 1000.0);
        }
        curves.push_back(curve);
    }

    const FitProblem problem = makeProblem(grid, curves);
    FitConfig config;
    config.allowShelves = true;
    const FitResult result = fitCorrection(problem, config);
    CHECK(result.metrics.shelfFilterCount >= 1);
}

// ---------------------------------------------------------------------------
// Determinism and platform
// ---------------------------------------------------------------------------

TEST_CASE(fitting_is_deterministic) {
    // The project format promises a saved session recalculates identically.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 52.0 + 3.0 * i, 0.2, 7.0);
        curves.push_back(curve);
    }
    const FitProblem problem = makeProblem(grid, curves);

    const FitResult a = fitCorrection(problem);
    const FitResult b = fitCorrection(problem);

    CHECK(a.filters.size() == b.filters.size());
    for (std::size_t i = 0; i < a.filters.size(); ++i) {
        CHECK_NEAR(a.filters[i].freq, b.filters[i].freq, 1e-9);
        CHECK_NEAR(a.filters[i].q, b.filters[i].q, 1e-9);
        CHECK_NEAR(a.filters[i].gainDb, b.filters[i].gainDb, 1e-9);
    }
    CHECK_NEAR(a.trimDb, b.trimDb, 1e-12);
    CHECK_NEAR(a.objective, b.objective, 1e-12);
}

TEST_CASE(both_platforms_fit_and_are_scored_independently) {
    // Cross-platform recipe identity is explicitly not required; equivalent
    // measured quality is.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 44.0, 0.25, 8.0);
        addBump(grid, curve, 155.0, 0.35, 4.0);
        curves.push_back(curve);
    }

    const FitProblem rp2350 = makeProblem(grid, curves, presetFlat(), Platform::RP2350);
    const FitProblem rp2040 = makeProblem(grid, curves, presetFlat(), Platform::RP2040);

    const FitResult a = fitCorrection(rp2350);
    const FitResult b = fitCorrection(rp2040);

    CHECK(a.converged);
    CHECK(b.converged);
    CHECK_NEAR(a.metrics.reliableWorstPositionRmseDb,
               b.metrics.reliableWorstPositionRmseDb, 0.5);
}

TEST_CASE(fitting_works_at_every_supported_rate) {
    const FrequencyGrid grid = corpusGrid();
    for (double fs : {44100.0, 48000.0, 96000.0}) {
        std::vector<std::vector<double>> curves;
        for (int i = 0; i < 3; ++i) {
            std::vector<double> curve = flat(grid);
            addBump(grid, curve, 70.0, 0.25, 7.0);
            curves.push_back(curve);
        }
        FitProblem problem = makeProblem(grid, curves);
        problem.sampleRateHz = fs;
        const FitResult result = fitCorrection(problem);
        CHECK(result.converged);
        CHECK(result.metrics.maxCombinedCorrectionDb <= -0.5 + 1e-6);
    }
}

// ---------------------------------------------------------------------------
// Degenerate input
// ---------------------------------------------------------------------------

TEST_CASE(rejects_an_invalid_problem_without_throwing) {
    FitProblem empty;
    const FitResult result = fitCorrection(empty);
    CHECK(!result.converged);
    CHECK(!result.message.empty());

    const FrequencyGrid grid = corpusGrid();
    FitProblem mismatched;
    mismatched.grid = grid;
    mismatched.targetDb.assign(grid.size(), 0.0);
    PositionMeasurement position;
    position.magnitudesDb.assign(grid.size() / 2, 0.0);   // wrong length
    mismatched.positions.push_back(position);
    const FitResult second = fitCorrection(mismatched);
    CHECK(!second.converged);
    CHECK(!second.message.empty());
}

TEST_CASE(rejects_an_invalid_config_without_throwing) {
    const FrequencyGrid grid = corpusGrid();
    const FitProblem problem = makeProblem(grid, {flat(grid), flat(grid)});

    FitConfig bad;
    bad.maxFilters = 0;
    CHECK(!fitCorrection(problem, bad).converged);

    FitConfig positiveCut;
    positiveCut.cutLimitDb = 3.0;
    CHECK(!fitCorrection(problem, positiveCut).converged);
}

TEST_CASE(an_already_perfect_room_gets_essentially_no_correction) {
    // A response that already matches the target should be left alone, not
    // decorated with filters that happen to reduce the objective by noise.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) curves.push_back(flat(grid));

    const FitProblem problem = makeProblem(grid, curves);
    const FitResult result = fitCorrection(problem);

    double span = 0.0;
    for (double v : result.correctionDb) {
        span = std::max(span, std::fabs(v - result.correctionDb.front()));
    }
    CHECK(span < 1.0);
}
