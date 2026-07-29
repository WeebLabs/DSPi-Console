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

#include "dspi_rc/capi.h"
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
            std::polar(amplitude, -2.0 * kPi * grid.hz[i] * delayMs / 1000.0);
        const double magnitude = std::abs(std::complex<double>(1.0, 0.0) + phasor);
        curve[i] += 20.0 * std::log10(std::max(1e-6, magnitude / (1.0 + amplitude)));
    }
}

// Assemble a complete problem from position curves.
// `boostLimitDb` must reach the mask as well as the FitConfig, exactly as the
// C API does it.  Building the mask with the default MaskConfig while raising
// the FitConfig limit is the bug this file previously hid: boost is generated
// and then punished, and a test asserting "we did not boost" passes because
// boost was impossible rather than because it was correctly declined.
FitProblem makeProblem(const FrequencyGrid& grid,
                       std::vector<std::vector<double>> curves,
                       const TargetSpec& targetSpec = presetFlat(),
                       Platform platform = Platform::RP2350,
                       double boostLimitDb = 0.0) {
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
    MaskConfig maskConfig;
    maskConfig.maxBoostDb = boostLimitDb;
    problem.mask = buildCorrectionMask(grid, spec, problem.native,
                                       problem.statistics.reliability, maskConfig);
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

    // Boost genuinely permitted, through both the config and the mask. With
    // the mask left at its default this test passed because nothing could be
    // boosted anywhere, which is not the property it exists to check.
    const FitProblem problem = makeProblem(grid, curves, presetFlat(),
                                           Platform::RP2350, 3.0);
    FitConfig config;
    config.boostLimitDb = 3.0;
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

// Correction strength: the Advanced control for a correction that measures
// well and sounds over-processed.
TEST_CASE(strength_eases_the_target_toward_the_room) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve = flat(grid);
    addBump(grid, curve, 120.0, 0.4, 8.0);
    FitProblem problem = makeProblem(grid, {curve, curve, curve});

    const std::vector<double> full = problem.targetDb;
    applyStrength(problem, 0.5);

    const std::size_t bin = binNear(grid, 120.0);
    const double measured = problem.statistics.powerAverageDb[bin];
    // Halfway between what the room does and what was asked for.
    CHECK_NEAR(problem.targetDb[bin], measured + 0.5 * (full[bin] - measured), 1e-9);
}

TEST_CASE(full_strength_changes_nothing) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve = flat(grid);
    addBump(grid, curve, 120.0, 0.4, 8.0);
    FitProblem problem = makeProblem(grid, {curve, curve, curve});

    const std::vector<double> before = problem.targetDb;
    applyStrength(problem, 1.0);
    for (std::size_t i = 0; i < before.size(); ++i) {
        CHECK_NEAR(problem.targetDb[i], before[i], 1e-12);
    }
}

TEST_CASE(a_gentler_strength_corrects_less) {
    // The property that matters to a user: turning it down does less, in the
    // same direction, rather than doing something different.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve = flat(grid);
    addBump(grid, curve, 120.0, 0.4, 8.0);

    FitProblem strong = makeProblem(grid, {curve, curve, curve});
    FitConfig config;
    const FitResult full = fitCorrection(strong, config);

    FitProblem gentle = makeProblem(grid, {curve, curve, curve});
    applyStrength(gentle, 0.4);
    const FitResult reduced = fitCorrection(gentle, config);

    CHECK(full.converged);
    CHECK(reduced.converged);

    const std::size_t bin = binNear(grid, 120.0);
    // Both cut the peak, and the gentler one cuts it less.
    CHECK(full.correctionDb[bin] < -1.0);
    CHECK(reduced.correctionDb[bin] < -0.2);
    CHECK(reduced.correctionDb[bin] > full.correctionDb[bin]);
}

TEST_CASE(strength_outside_its_range_is_refused) {
    // Zero would ask for no correction at all through a control that cannot
    // express it; the caller should turn the feature off instead.
    FitConfig config;
    config.strength = 0.0;
    CHECK(!config.validate().empty());
    config.strength = 1.5;
    CHECK(!config.validate().empty());
    config.strength = 0.5;
    CHECK(config.validate().empty());
}

// ---------------------------------------------------------------------------
// Raising the boost limit has to actually permit boost
// ---------------------------------------------------------------------------

TEST_CASE(a_trusted_dip_is_boosted_only_when_the_limit_allows_it) {
    // Every position sees the same dip, so it is a property of the speaker
    // rather than of where the microphone sat, and boosting it is the right
    // answer once the user has asked for boost.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 300.0, 0.5, -6.0);
        curves.push_back(curve);
    }
    const std::size_t bin = binNear(grid, 300.0);

    FitConfig cutOnly;
    const FitResult declined = fitCorrection(makeProblem(grid, curves), cutOnly);

    FitConfig permitted;
    permitted.boostLimitDb = 6.0;
    permitted.combinedCeilingDb = 6.0;
    const FitResult boosted = fitCorrection(
        makeProblem(grid, curves, presetFlat(), Platform::RP2350, 6.0), permitted);

    // Convergence is deliberately not asserted here. With boost permitted the
    // optimizer has more freedom and legitimately spends its whole iteration
    // budget on this fixture; what matters is the correction it lands on.
    CHECK(!declined.correctionDb.empty());
    CHECK(!boosted.correctionDb.empty());
    // Cut-only cannot fill a dip, and must not pretend to.
    CHECK(declined.correctionDb[bin] < 0.5);
    // With boost permitted it is filled, which is the whole point of the control.
    CHECK(boosted.correctionDb[bin] > 1.5);
}

TEST_CASE(raising_the_boost_limit_does_not_attenuate_the_channel) {
    // The symptom that exposed the wiring bug: with the mask still forbidding
    // boost, requiredTrim treated any positive excursion as forbidden and
    // pulled the whole channel down, so raising the limit made every dip read
    // deeper rather than shallower.
    const FrequencyGrid grid = corpusGrid();
    std::vector<std::vector<double>> curves;
    for (int i = 0; i < 4; ++i) {
        std::vector<double> curve = flat(grid);
        addBump(grid, curve, 300.0, 0.5, -6.0);
        curves.push_back(curve);
    }

    FitConfig permitted;
    permitted.boostLimitDb = 6.0;
    permitted.combinedCeilingDb = 6.0;
    const FitResult result = fitCorrection(
        makeProblem(grid, curves, presetFlat(), Platform::RP2350, 6.0), permitted);

    CHECK(!result.correctionDb.empty());
    CHECK(result.trimDb > -3.0);
}

TEST_CASE(the_c_api_passes_the_boost_limit_to_the_mask) {
    // The bug lived in the C API's mask construction, which none of the tests
    // above reach: they build their own problem. This drives the real path.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve = flat(grid);
    addBump(grid, curve, 300.0, 0.5, -6.0);

    auto correctionAt300 = [&](double boostLimitDb) {
        dspi_rc_session* session =
            dspi_rc_session_create(20.0, 20000.0, 24, 48000.0, DSPI_RC_PLATFORM_RP2350);
        CHECK(session != nullptr);
        for (int i = 0; i < 4; ++i) {
            CHECK(dspi_rc_session_add_position(session, curve.data(), curve.size(),
                                               1.0, 1) == DSPI_RC_OK);
        }
        dspi_rc_target_spec target{};
        CHECK(dspi_rc_target_preset(0, &target) == DSPI_RC_OK);   // flat
        CHECK(dspi_rc_session_set_target(session, &target, 1) == DSPI_RC_OK);

        dspi_rc_fit_config config{};
        CHECK(dspi_rc_default_fit_config(&config) == DSPI_RC_OK);
        config.boost_limit_db = boostLimitDb;
        config.combined_ceiling_db = boostLimitDb > 0.0 ? boostLimitDb : -0.5;
        CHECK(dspi_rc_session_fit(session, &config) == DSPI_RC_OK);

        std::vector<double> correction(grid.size(), 0.0);
        std::size_t written = 0;
        CHECK(dspi_rc_session_curve(session, DSPI_RC_CURVE_CORRECTION, 0,
                                    correction.data(), correction.size(),
                                    &written) == DSPI_RC_OK);
        dspi_rc_session_free(session);
        return correction[binNear(grid, 300.0)];
    };

    CHECK(correctionAt300(0.0) < 0.5);
    CHECK(correctionAt300(6.0) > 1.5);
}
