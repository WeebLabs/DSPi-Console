// The reference parallel designer.
//
// This is not a product path - DSPi cannot run a parallel bank - so these tests
// establish that it is a faithful implementation of the structure rather than
// that it is safe to ship.  Its job is to give the section-count sweep in
// `room_correction_fixed_pole_design.md` §8 a trustworthy upper bound, and a
// wrong implementation would answer the firmware question wrongly.
#include "dspi_rc/parallel.hpp"

#include <cmath>
#include <complex>
#include <vector>

#include "dspi_rc/analysis.hpp"
#include "dspi_rc/target.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

FrequencyGrid corpusGrid() { return FrequencyGrid::logSpaced(20.0, 20000.0, 24); }

void addBump(const FrequencyGrid& grid, std::vector<double>& curve,
             double centreHz, double widthOctaves, double gainDb) {
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double octaves = std::log2(grid.hz[i] / centreHz);
        curve[i] += gainDb * std::exp(-0.5 * (octaves / widthOctaves) * (octaves / widthOctaves));
    }
}

FitProblem makeProblem(const FrequencyGrid& grid, std::vector<std::vector<double>> curves) {
    FitProblem problem;
    problem.grid = grid;
    problem.sampleRateHz = 48000.0;
    problem.platform = Platform::RP2350;

    for (std::size_t i = 0; i < curves.size(); ++i) {
        PositionMeasurement position;
        position.magnitudesDb = std::move(curves[i]);
        position.weight = (i == 0) ? 2.0 : 1.0;
        position.enabled = true;
        problem.positions.push_back(std::move(position));
    }

    problem.native = estimateNativeBandwidth(grid, problem.positions.front().magnitudesDb);

    TargetSpec spec = presetFlat();
    const SpatialStatistics provisional = computeSpatialStatistics(grid, problem.positions, {});
    spec.levelDb = chooseAutoLevel(grid, provisional.powerAverageDb, spec, problem.native);

    problem.targetDb = buildTarget(grid, spec);
    problem.statistics = computeSpatialStatistics(grid, problem.positions, problem.targetDb);
    problem.mask = buildCorrectionMask(grid, spec, problem.native, problem.statistics.reliability);
    return problem;
}

}  // namespace

// ---------------------------------------------------------------------------
// Minimum phase
// ---------------------------------------------------------------------------

TEST_CASE(a_flat_magnitude_reconstructs_as_unity_with_no_phase) {
    const FrequencyGrid grid = corpusGrid();
    const std::vector<double> flat(grid.size(), 0.0);

    const std::vector<Complex> response = minimumPhaseResponse(grid, flat, 48000.0, 8192);
    CHECK(response.size() == grid.size());
    for (const Complex& value : response) {
        CHECK_NEAR(std::abs(value), 1.0, 1e-6);
        CHECK_NEAR(std::arg(value), 0.0, 1e-6);
    }
}

TEST_CASE(the_reconstruction_has_the_magnitude_it_was_given) {
    // The defining property, and independent of how the phase was derived.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> magnitude(grid.size(), 0.0);
    addBump(grid, magnitude, 80.0, 0.8, -8.0);
    addBump(grid, magnitude, 2500.0, 1.5, 4.0);

    const std::vector<Complex> response = minimumPhaseResponse(grid, magnitude, 48000.0, 32768);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        // Loose at the very edges, where the reconstruction's flat extension
        // beyond the grid meets the grid's own endpoints.
        if (grid.hz[i] < 30.0 || grid.hz[i] > 15000.0) continue;
        const double db = 20.0 * std::log10(std::abs(response[i]));
        CHECK_NEAR(db, magnitude[i], 0.25);
    }
}

TEST_CASE(a_low_shelf_reconstruction_has_the_phase_sign_minimum_phase_requires) {
    // A minimum-phase system's phase is the Hilbert transform of its log
    // magnitude, so a rising magnitude carries positive phase.  Checking the
    // sign rather than the value keeps this independent of the FFT length.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> magnitude(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        magnitude[i] = 6.0 / (1.0 + std::exp(-(std::log2(grid.hz[i] / 1000.0))));
    }

    const std::vector<Complex> response = minimumPhaseResponse(grid, magnitude, 48000.0, 32768);
    std::size_t risingBin = 0;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] >= 1000.0) { risingBin = i; break; }
    }
    CHECK(std::arg(response[risingBin]) > 0.0);
}

// ---------------------------------------------------------------------------
// The bank
// ---------------------------------------------------------------------------

TEST_CASE(a_designed_bank_evaluates_to_the_response_it_was_fitted_to) {
    // The solved coefficients and the reported correction curve must describe
    // the same filter: if they drift, the section-count sweep is comparing a
    // fit to a curve that no bank produces.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 55.0, 0.5, 9.0);
    addBump(grid, curve, 180.0, 0.7, -6.0);

    const FitProblem problem = makeProblem(grid, {curve, curve});
    ParallelConfig parallelConfig;
    parallelConfig.sections = 24;

    const ParallelDesign design = designParallel(problem, FitConfig{}, parallelConfig);
    CHECK(design.ok);
    CHECK(design.sections.size() == 24);

    const std::vector<Complex> evaluated = parallelResponse(design, grid, problem.sampleRateHz);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double db = 20.0 * std::log10(std::max(1e-9, std::abs(evaluated[i]))) + design.trimDb;
        CHECK_NEAR(db, design.correctionDb[i], 1e-9);
    }
}

TEST_CASE(every_pole_pair_is_stable) {
    // A pole on or outside the unit circle is a permanent oscillator, and the
    // fit has no way to know it should not use one.  Stability is a property of
    // the placement, so it holds regardless of what the solve returns.
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 40.0, 0.3, 14.0);

    const FitProblem problem = makeProblem(grid, {curve});
    ParallelConfig parallelConfig;
    parallelConfig.sections = 32;

    const ParallelDesign design = designParallel(problem, FitConfig{}, parallelConfig);
    CHECK(design.ok);
    for (const ParallelSection& section : design.sections) {
        // For 1 + a1 z^-1 + a2 z^-2 the poles lie inside the unit circle when
        // |a2| < 1 and |a1| < 1 + a2.
        CHECK(std::fabs(section.a2) < 1.0);
        CHECK(std::fabs(section.a1) < 1.0 + section.a2);
    }
}

TEST_CASE(the_bank_corrects_a_consistent_room_and_more_sections_do_not_hurt) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 48.0, 0.4, 10.0);
    addBump(grid, curve, 95.0, 0.35, -7.0);
    addBump(grid, curve, 3000.0, 1.2, 3.0);

    const FitProblem problem = makeProblem(grid, {curve, curve, curve});
    const FitMetrics uncorrected =
        evaluateCorrection(problem, std::vector<double>(grid.size(), 0.0));

    ParallelConfig parallelConfig;
    parallelConfig.sections = 10;
    const ParallelDesign small = designParallel(problem, FitConfig{}, parallelConfig);
    parallelConfig.sections = 32;
    const ParallelDesign large = designParallel(problem, FitConfig{}, parallelConfig);

    CHECK(small.ok && large.ok);
    CHECK(small.metrics.reliableWorstPositionRmseDb < uncorrected.reliableWorstPositionRmseDb);

    // More sections spanning the same band must not be materially worse.
    //
    // Not asserted exactly, and the tolerance is the honest part.  Pole sets at
    // different section counts are not nested - the allocator re-places
    // everything - so a larger bank does not contain the smaller one's solution
    // and monotonicity is not guaranteed by the mathematics.  What the sweep is
    // entitled to assume is that adding sections does not *hurt*, and a tenth
    // of a decibel is the line between allocator jitter and the pathology this
    // exists to catch: before the target-normalization fix this fixture's
    // sibling went from 1.779 dB at K=10 to 3.092 dB at K=16.
    CHECK(large.metrics.reliableWorstPositionRmseDb <=
          small.metrics.reliableWorstPositionRmseDb + 0.1);
}

TEST_CASE(the_bank_respects_the_combined_ceiling_through_the_shared_trim) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 60.0, 0.6, -9.0);   // a broad dip invites boost

    const FitProblem problem = makeProblem(grid, {curve, curve});
    FitConfig config;
    config.combinedCeilingDb = -0.5;

    ParallelConfig parallelConfig;
    parallelConfig.sections = 24;
    const ParallelDesign design = designParallel(problem, config, parallelConfig);
    CHECK(design.ok);

    for (double v : design.correctionDb) CHECK(v <= config.combinedCeilingDb + 1e-9);
    CHECK(design.metrics.maxCombinedCorrectionDb <= config.combinedCeilingDb + 1e-9);
}

TEST_CASE(the_design_is_deterministic) {
    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 70.0, 0.5, 8.0);

    const FitProblem problem = makeProblem(grid, {curve, curve});
    ParallelConfig parallelConfig;
    parallelConfig.sections = 16;

    const ParallelDesign first = designParallel(problem, FitConfig{}, parallelConfig);
    const ParallelDesign second = designParallel(problem, FitConfig{}, parallelConfig);
    CHECK(first.ok && second.ok);
    CHECK(first.sections.size() == second.sections.size());
    for (std::size_t i = 0; i < first.sections.size(); ++i) {
        CHECK_NEAR(first.sections[i].b0, second.sections[i].b0, 0.0);
        CHECK_NEAR(first.sections[i].b1, second.sections[i].b1, 0.0);
    }
    CHECK_NEAR(first.trimDb, second.trimDb, 0.0);
}

TEST_CASE(a_rejected_problem_comes_back_explained_rather_than_throwing) {
    FitProblem empty;
    const ParallelDesign design = designParallel(empty, FitConfig{}, ParallelConfig{});
    CHECK(!design.ok);
    CHECK(!design.message.empty());
}

// ---------------------------------------------------------------------------
// Canaries
//
// A reference implementation is only useful as an upper bound if it actually
// extracts what the structure can deliver, and the corpus cannot tell the
// difference between "the structure is limited" and "the fit is broken".
// These do: they hand the designer a target the bank can represent exactly and
// require it back.
//
// Two stages on purpose.  A consistent linear system is recovered exactly under
// *any* positive weights, so a single end-to-end canary would pass regardless
// of the row weighting and prove less than it appears to.  The first stage
// isolates the basis and the solver; the second adds the minimum-phase
// reconstruction, which is the only other thing between a target and a fit.
// ---------------------------------------------------------------------------

namespace {

// A bank with known, arbitrary numerators over log-spaced poles.
ParallelDesign knownBank(double sampleRateHz, int count) {
    ParallelDesign design;
    design.sections.resize(static_cast<std::size_t>(count));

    const double logLo = std::log(30.0);
    const double logHi = std::log(12000.0);
    for (int i = 0; i < count; ++i) {
        const double t = (static_cast<double>(i) + 0.5) / static_cast<double>(count);
        const double freq = std::exp(logLo + t * (logHi - logLo));
        // Spacing-derived Q, so the poles overlap the way a real bank's do.
        const double octaves = (logHi - logLo) / (static_cast<double>(count) * std::log(2.0));
        const double ratio = std::pow(2.0, octaves);
        setPole(design.sections[static_cast<std::size_t>(i)], freq,
                std::sqrt(ratio) / (ratio - 1.0), sampleRateHz);

        // Deterministic, non-trivial, and of both signs.
        design.sections[static_cast<std::size_t>(i)].b0 = 0.35 * std::cos(1.7 * i + 0.4);
        design.sections[static_cast<std::size_t>(i)].b1 = 0.22 * std::sin(2.3 * i + 1.1);
    }
    design.d0 = 0.9;
    design.d1 = -0.15;
    return design;
}

}  // namespace

TEST_CASE(the_solver_recovers_a_bank_it_could_have_produced) {
    // Stage one: exact complex target, no minimum-phase step, no measurement.
    // If this fails, nothing downstream of it means anything.
    const FrequencyGrid grid = corpusGrid();
    const double sampleRateHz = 48000.0;

    const ParallelDesign truth = knownBank(sampleRateHz, 16);
    const std::vector<Complex> target = parallelResponse(truth, grid, sampleRateHz);

    ParallelDesign fitted;
    fitted.sections = truth.sections;
    for (ParallelSection& section : fitted.sections) { section.b0 = 0.0; section.b1 = 0.0; }

    ParallelConfig config;
    config.ridge = 0.0;   // an exactly consistent system needs no regularization
    const std::vector<double> weight(grid.size(), 1.0);
    CHECK(solveParallelNumerators(target, weight, grid, sampleRateHz, config, fitted));

    for (std::size_t i = 0; i < truth.sections.size(); ++i) {
        CHECK_NEAR(fitted.sections[i].b0, truth.sections[i].b0, 1e-6);
        CHECK_NEAR(fitted.sections[i].b1, truth.sections[i].b1, 1e-6);
    }
    CHECK_NEAR(fitted.d0, truth.d0, 1e-6);
    CHECK_NEAR(fitted.d1, truth.d1, 1e-6);

    const std::vector<Complex> realized = parallelResponse(fitted, grid, sampleRateHz);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        CHECK_NEAR(std::abs(realized[i] - target[i]), 0.0, 1e-7);
    }
}

TEST_CASE(recovery_does_not_depend_on_the_row_weighting) {
    // The property that makes stage one insufficient on its own, asserted
    // directly: a consistent system comes back exactly however the rows are
    // weighted, so a passing canary is no evidence that the weighting is right.
    const FrequencyGrid grid = corpusGrid();
    const double sampleRateHz = 48000.0;

    const ParallelDesign truth = knownBank(sampleRateHz, 12);
    const std::vector<Complex> target = parallelResponse(truth, grid, sampleRateHz);
    const std::vector<double> weight(grid.size(), 1.0);

    for (bool normalize : {false, true}) {
        ParallelDesign fitted;
        fitted.sections = truth.sections;
        for (ParallelSection& s : fitted.sections) { s.b0 = 0.0; s.b1 = 0.0; }

        ParallelConfig config;
        config.ridge = 0.0;
        config.normalizeByTarget = normalize;
        CHECK(solveParallelNumerators(target, weight, grid, sampleRateHz, config, fitted));

        for (std::size_t i = 0; i < truth.sections.size(); ++i) {
            CHECK_NEAR(fitted.sections[i].b0, truth.sections[i].b0, 1e-6);
        }
    }
}

TEST_CASE(a_realizable_magnitude_survives_the_minimum_phase_round_trip) {
    // Stage two: the same bank, but reached through the reconstruction the real
    // designer uses.  A minimum-phase bank must come back through a
    // minimum-phase target, so what this pins is the cepstral step rather than
    // the solver.
    //
    // The bank is built from a *single* pole pair with a positive numerator, so
    // its zeros are inside the unit circle and it genuinely is minimum phase.
    // A bank with arbitrary numerators is not, and asking for it back through a
    // minimum-phase reconstruction would be asking for the wrong filter.
    const FrequencyGrid grid = corpusGrid();
    const double sampleRateHz = 48000.0;

    ParallelDesign truth;
    truth.sections.resize(1);
    setPole(truth.sections[0], 90.0, 3.0, sampleRateHz);
    truth.sections[0].b0 = 0.30;
    truth.sections[0].b1 = 0.0;
    truth.d0 = 1.0;
    truth.d1 = 0.0;

    const std::vector<Complex> exact = parallelResponse(truth, grid, sampleRateHz);
    std::vector<double> magnitudeDb(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        magnitudeDb[i] = 20.0 * std::log10(std::abs(exact[i]));
    }

    const std::vector<Complex> reconstructed =
        minimumPhaseResponse(grid, magnitudeDb, sampleRateHz, 32768);

    // The reconstruction is band-limited by the grid, so the comparison holds
    // away from the edges where its flat extension takes over.
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] < 30.0 || grid.hz[i] > 15000.0) continue;
        const double db = 20.0 * std::log10(std::abs(reconstructed[i]));
        CHECK_NEAR(db, magnitudeDb[i], 0.2);
    }
}

TEST_CASE(target_normalization_changes_where_the_error_lands) {
    // The weighting bug needs its own probe, since the canaries cannot see it.
    // A target with a deep narrow cut, fitted with too few sections to match it
    // exactly: without normalization the linear-domain fit under-weights the
    // bottom of the cut by the square of its depth, so the dB error there must
    // improve when the normalization is switched on.
    const FrequencyGrid grid = corpusGrid();
    const double sampleRateHz = 48000.0;

    std::vector<double> magnitudeDb(grid.size(), 0.0);
    addBump(grid, magnitudeDb, 70.0, 0.22, -18.0);

    const std::vector<Complex> target =
        minimumPhaseResponse(grid, magnitudeDb, sampleRateHz, 32768);
    const std::vector<double> weight(grid.size(), 1.0);

    const auto worstDeepError = [&](bool normalize) {
        ParallelDesign design;
        design.sections.resize(6);
        for (std::size_t i = 0; i < 6; ++i) {
            const double t = (static_cast<double>(i) + 0.5) / 6.0;
            const double freq = std::exp(std::log(25.0) + t * (std::log(15000.0) - std::log(25.0)));
            setPole(design.sections[i], freq, 2.0, sampleRateHz);
        }

        ParallelConfig config;
        config.normalizeByTarget = normalize;
        config.ridge = 1e-9;
        if (!solveParallelNumerators(target, weight, grid, sampleRateHz, config, design)) {
            return 1e9;
        }

        const std::vector<Complex> realized = parallelResponse(design, grid, sampleRateHz);
        double worst = 0.0;
        for (std::size_t i = 0; i < grid.size(); ++i) {
            // Only where the target is genuinely deep, which is the region the
            // un-normalized fit is being accused of neglecting.
            if (magnitudeDb[i] > -9.0) continue;
            const double db = 20.0 * std::log10(std::max(1e-9, std::abs(realized[i])));
            worst = std::max(worst, std::fabs(db - magnitudeDb[i]));
        }
        return worst;
    };

    const double plain = worstDeepError(false);
    const double normalized = worstDeepError(true);
    CHECK(normalized < plain);
}

// ---------------------------------------------------------------------------
// The C ABI path
//
// This is the exact sequence the macOS app runs, through the same boundary.
// The C++ tests above can pass while the ABI is broken - a missing state check,
// a curve that reads back empty, a metrics call that returns the cascade's
// numbers - and none of that shows up until someone takes a measurement.
// ---------------------------------------------------------------------------

#include "dspi_rc/capi.h"

TEST_CASE(the_c_abi_designs_a_parallel_bank_for_a_fitted_session) {
    dspi_rc_session* session =
        dspi_rc_session_create(20.0, 20000.0, 24, 48000.0, DSPI_RC_PLATFORM_RP2350);
    CHECK(session != nullptr);

    const FrequencyGrid grid = corpusGrid();
    std::vector<double> curve(grid.size(), 75.0);
    addBump(grid, curve, 52.0, 0.35, 9.0);
    addBump(grid, curve, 3200.0, 1.1, -4.0);

    for (int i = 0; i < 3; ++i) {
        CHECK(dspi_rc_session_add_position(session, curve.data(), curve.size(),
                                           i == 0 ? 2.0 : 1.0, 1) == DSPI_RC_OK);
    }

    dspi_rc_target_spec target;
    dspi_rc_target_preset(1, &target);
    CHECK(dspi_rc_session_set_target(session, &target, 1) == DSPI_RC_OK);

    // Designing before fitting must be refused rather than producing something
    // against an empty problem.
    CHECK(dspi_rc_session_design_parallel(session, nullptr) != DSPI_RC_OK);

    CHECK(dspi_rc_session_fit(session, nullptr) == DSPI_RC_OK);

    // ... and reading a design that has not been made must also be refused.
    double trim = 0.0;
    CHECK(dspi_rc_session_parallel_trim_db(session, &trim) != DSPI_RC_OK);

    dspi_rc_parallel_config config;
    CHECK(dspi_rc_default_parallel_config(&config) == DSPI_RC_OK);
    // The defaults are Bank's method as specified.
    CHECK_NEAR(config.placement_bias, 1.0, 0.0);
    CHECK(config.refine_poles == 0);
    CHECK(config.q_from_feature_width == 0);

    config.sections = 16;
    CHECK(dspi_rc_session_design_parallel(session, &config) == DSPI_RC_OK);

    std::size_t sectionCount = 0;
    CHECK(dspi_rc_session_parallel_section_count(session, &sectionCount) == DSPI_RC_OK);
    CHECK(sectionCount == 16);

    std::vector<dspi_rc_parallel_section> sections(sectionCount);
    std::size_t written = 0;
    CHECK(dspi_rc_session_parallel_sections(session, sections.data(), sections.size(),
                                            &written) == DSPI_RC_OK);
    CHECK(written == 16);
    for (const dspi_rc_parallel_section& s : sections) {
        CHECK(s.freq_hz > 0.0);
        CHECK(std::fabs(s.a2) < 1.0);                 // stable
        CHECK(std::fabs(s.a1) < 1.0 + s.a2);
        CHECK(std::isfinite(s.b0) && std::isfinite(s.b1));
    }

    // The curve must come back on the session grid and be a real correction,
    // not zeros - an empty read is the failure mode that looks like success.
    std::size_t points = 0;
    CHECK(dspi_rc_grid_points(20.0, 20000.0, 24, &points) == DSPI_RC_OK);
    std::vector<double> correction(points, 0.0);
    std::size_t got = 0;
    CHECK(dspi_rc_session_curve(session, DSPI_RC_CURVE_PARALLEL_CORRECTION, 0,
                                correction.data(), correction.size(), &got) == DSPI_RC_OK);
    CHECK(got == points);
    double span = 0.0;
    for (double v : correction) {
        CHECK(std::isfinite(v));
        span = std::max(span, std::fabs(v));
    }
    CHECK(span > 1.0);

    // The parallel metrics must be the parallel design's, not the cascade's.
    dspi_rc_metrics parallelMetrics;
    dspi_rc_metrics fitMetrics;
    CHECK(dspi_rc_session_parallel_metrics(session, &parallelMetrics) == DSPI_RC_OK);
    CHECK(dspi_rc_session_metrics(session, &fitMetrics) == DSPI_RC_OK);
    CHECK(parallelMetrics.reliable_worst_position_rmse_db !=
          fitMetrics.reliable_worst_position_rmse_db);
    CHECK(dspi_rc_session_parallel_trim_db(session, &trim) == DSPI_RC_OK);
    CHECK(trim <= 0.0);

    // Re-fitting must invalidate the design rather than leave one describing
    // the previous target.
    CHECK(dspi_rc_session_fit(session, nullptr) == DSPI_RC_OK);
    CHECK(dspi_rc_session_parallel_trim_db(session, &trim) != DSPI_RC_OK);

    dspi_rc_session_free(session);
}
