// Target construction, native bandwidth detection, level placement and the
// correction mask.
#include <cmath>
#include <vector>

#include "dspi_rc/capi.h"
#include "dspi_rc/target.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

FrequencyGrid grid48() { return FrequencyGrid::logSpaced(20.0, 20000.0, 48); }

std::size_t binNear(const FrequencyGrid& grid, double freqHz) {
    std::size_t best = 0;
    double bestDistance = 1e30;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double d = std::fabs(std::log2(grid.hz[i] / freqHz));
        if (d < bestDistance) { bestDistance = d; best = i; }
    }
    return best;
}

double valueAt(const FrequencyGrid& grid, const std::vector<double>& curve, double freqHz) {
    return curve[binNear(grid, freqHz)];
}

}  // namespace

// ---------------------------------------------------------------------------
// Target shape
// ---------------------------------------------------------------------------

TEST_CASE(flat_target_is_flat) {
    const FrequencyGrid grid = grid48();
    const std::vector<double> curve = buildTarget(grid, presetFlat());
    for (double v : curve) CHECK_NEAR(v, 0.0, 1e-9);
}

TEST_CASE(tilt_pivots_without_changing_level_at_the_pivot) {
    // Adjusting tilt must not also move the whole curve up or down, or the
    // user ends up chasing level every time they touch it.
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetFlat();
    spec.tiltDbPerOctave = -1.0;
    const std::vector<double> curve = buildTarget(grid, spec);

    CHECK_NEAR(valueAt(grid, curve, 1000.0), 0.0, 0.02);
    CHECK_NEAR(valueAt(grid, curve, 500.0), 1.0, 0.02);    // one octave down
    CHECK_NEAR(valueAt(grid, curve, 2000.0), -1.0, 0.02);  // one octave up
    CHECK_NEAR(valueAt(grid, curve, 250.0), 2.0, 0.03);
}

TEST_CASE(natural_preset_slopes_down) {
    const FrequencyGrid grid = grid48();
    const std::vector<double> curve = buildTarget(grid, presetNatural());
    CHECK(valueAt(grid, curve, 50.0) > valueAt(grid, curve, 1000.0));
    CHECK(valueAt(grid, curve, 1000.0) > valueAt(grid, curve, 10000.0));
}

TEST_CASE(bass_shelf_lifts_the_bottom_and_leaves_the_top_alone) {
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetFlat();
    spec.bassGainDb = 6.0;
    spec.bassTransitionHz = 100.0;
    const std::vector<double> curve = buildTarget(grid, spec);

    CHECK_NEAR(valueAt(grid, curve, 25.0), 6.0, 0.4);      // full lift well below
    CHECK_NEAR(valueAt(grid, curve, 100.0), 3.0, 0.3);     // half at the corner
    CHECK_NEAR(valueAt(grid, curve, 2000.0), 0.0, 0.2);    // untouched above
}

TEST_CASE(treble_shelf_lifts_the_top_and_leaves_the_bottom_alone) {
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetFlat();
    spec.trebleGainDb = -4.0;
    spec.trebleTransitionHz = 4000.0;
    const std::vector<double> curve = buildTarget(grid, spec);

    CHECK_NEAR(valueAt(grid, curve, 16000.0), -4.0, 0.4);
    CHECK_NEAR(valueAt(grid, curve, 4000.0), -2.0, 0.3);
    CHECK_NEAR(valueAt(grid, curve, 200.0), 0.0, 0.2);
}

TEST_CASE(shelf_width_controls_the_knee) {
    const FrequencyGrid grid = grid48();
    TargetSpec narrow = presetFlat();
    narrow.bassGainDb = 6.0;
    narrow.bassTransitionHz = 100.0;
    narrow.shelfWidthOctaves = 0.5;

    TargetSpec wide = narrow;
    wide.shelfWidthOctaves = 3.0;

    const std::vector<double> narrowCurve = buildTarget(grid, narrow);
    const std::vector<double> wideCurve = buildTarget(grid, wide);

    // An octave above the corner, the wider knee is still lifting.
    CHECK(valueAt(grid, wideCurve, 200.0) > valueAt(grid, narrowCurve, 200.0));
}

TEST_CASE(level_offsets_the_whole_curve) {
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetNatural();
    const std::vector<double> base = buildTarget(grid, spec);
    spec.levelDb = -7.5;
    const std::vector<double> shifted = buildTarget(grid, spec);
    for (std::size_t i = 0; i < base.size(); ++i) {
        CHECK_NEAR(shifted[i] - base[i], -7.5, 1e-9);
    }
}

TEST_CASE(anchors_are_additive_on_top_of_the_macro_controls) {
    // Placing an anchor must not discard the tilt the user already dialled in.
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetNatural();
    const std::vector<double> withoutAnchor = buildTarget(grid, spec);

    spec.anchors.push_back({1000.0, 3.0});
    spec.anchors.push_back({100.0, 0.0});
    const std::vector<double> withAnchor = buildTarget(grid, spec);

    CHECK_NEAR(valueAt(grid, withAnchor, 1000.0) - valueAt(grid, withoutAnchor, 1000.0), 3.0, 0.05);
    CHECK_NEAR(valueAt(grid, withAnchor, 100.0) - valueAt(grid, withoutAnchor, 100.0), 0.0, 0.05);
    // The tilt survives.
    CHECK(valueAt(grid, withAnchor, 50.0) > valueAt(grid, withAnchor, 10000.0));
}

TEST_CASE(anchors_are_order_independent) {
    const FrequencyGrid grid = grid48();
    TargetSpec ascending = presetFlat();
    ascending.anchors = {{100.0, 1.0}, {1000.0, 2.0}, {10000.0, -1.0}};
    TargetSpec shuffled = presetFlat();
    shuffled.anchors = {{10000.0, -1.0}, {100.0, 1.0}, {1000.0, 2.0}};

    const std::vector<double> a = buildTarget(grid, ascending);
    const std::vector<double> b = buildTarget(grid, shuffled);
    for (std::size_t i = 0; i < a.size(); ++i) CHECK_NEAR(a[i], b[i], 1e-12);
}

TEST_CASE(target_validation_rejects_nonsense) {
    CHECK(presetNatural().validate().empty());

    TargetSpec invertedCurtains = presetNatural();
    invertedCurtains.lowCurtainHz = 5000.0;
    invertedCurtains.highCurtainHz = 100.0;
    CHECK(!invertedCurtains.validate().empty());

    TargetSpec absurdTilt = presetNatural();
    absurdTilt.tiltDbPerOctave = -50.0;
    CHECK(!absurdTilt.validate().empty());

    TargetSpec badAnchor = presetNatural();
    badAnchor.anchors.push_back({-100.0, 0.0});
    CHECK(!badAnchor.validate().empty());
}

// ---------------------------------------------------------------------------
// Native bandwidth
// ---------------------------------------------------------------------------

TEST_CASE(native_bandwidth_finds_a_speaker_rolloff) {
    // A sealed box rolling off below 60 Hz and above 18 kHz.
    const FrequencyGrid grid = grid48();
    std::vector<double> response(grid.size(), 80.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double f = grid.hz[i];
        if (f < 60.0) response[i] = 80.0 - 24.0 * std::log2(60.0 / f);
        if (f > 18000.0) response[i] = 80.0 - 24.0 * std::log2(f / 18000.0);
    }

    const NativeBandwidth native = estimateNativeBandwidth(grid, response, 10.0);
    CHECK(native.lowDetected);
    CHECK(native.lowHz > 35.0);
    CHECK(native.lowHz < 65.0);
    CHECK(native.highHz > 15000.0);
}

TEST_CASE(native_bandwidth_of_a_flat_response_is_the_whole_grid) {
    const FrequencyGrid grid = grid48();
    const std::vector<double> flat(grid.size(), 75.0);
    const NativeBandwidth native = estimateNativeBandwidth(grid, flat, 10.0);
    CHECK(!native.lowDetected);
    CHECK(!native.highDetected);
    CHECK_NEAR(native.lowHz, grid.hz.front(), 1e-9);
}

TEST_CASE(native_bandwidth_ignores_a_single_noisy_bin) {
    // Persistence is required, so one dropout inside the passband must not be
    // mistaken for the speaker's corner.
    const FrequencyGrid grid = grid48();
    std::vector<double> response(grid.size(), 80.0);
    response[binNear(grid, 300.0)] = 40.0;
    const NativeBandwidth native = estimateNativeBandwidth(grid, response, 10.0);
    CHECK(native.lowHz < 100.0);
}

TEST_CASE(native_bandwidth_survives_a_tiny_grid) {
    const FrequencyGrid tiny = FrequencyGrid::logSpaced(100.0, 200.0, 2);
    const std::vector<double> data(tiny.size(), 70.0);
    const NativeBandwidth native = estimateNativeBandwidth(tiny, data, 10.0);
    CHECK(native.highHz >= native.lowHz);
}

// ---------------------------------------------------------------------------
// Level placement
// ---------------------------------------------------------------------------

TEST_CASE(auto_level_sits_near_the_lower_envelope_so_cuts_suffice) {
    // The direction matters and is easy to get backwards.  Correction is
    // `target - measured`, so a target *above* the measurement demands boost.
    // Under a cut-only policy the target must sit low enough that the band can
    // be brought down to it; placing it at the upper envelope would need boost
    // everywhere and come out worse than no correction.
    const FrequencyGrid grid = grid48();
    std::vector<double> measured(grid.size(), 70.0);
    // A broad region 6 dB hot, which is what should be cut away.
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] > 80.0 && grid.hz[i] < 300.0) measured[i] = 76.0;
    }

    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;

    const double level = chooseAutoLevel(grid, measured, presetFlat(), native);
    // Near the 70 dB floor, not the 76 dB peak and not the ~71 dB mean.
    CHECK_NEAR(level, 70.0, 0.5);

    // And the resulting correction is cuts only.
    const std::vector<double> target = [&] {
        TargetSpec spec = presetFlat();
        spec.levelDb = level;
        return buildTarget(grid, spec);
    }();
    for (std::size_t i = 0; i < grid.size(); ++i) {
        CHECK(target[i] - measured[i] <= 0.5);
    }
}

TEST_CASE(auto_level_ignores_frequencies_outside_the_correctable_band) {
    const FrequencyGrid grid = grid48();
    std::vector<double> measured(grid.size(), 70.0);
    // Enormous output below 30 Hz, which is outside the native band and must
    // not drag the level up.
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] < 30.0) measured[i] = 100.0;
    }

    NativeBandwidth native;
    native.lowHz = 40.0;
    native.highHz = 18000.0;

    const double level = chooseAutoLevel(grid, measured, presetFlat(), native);
    CHECK_NEAR(level, 70.0, 1.0);
}

TEST_CASE(auto_level_accounts_for_the_target_shape) {
    // A tilted target must not be levelled as though it were flat.
    const FrequencyGrid grid = grid48();
    std::vector<double> measured(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        measured[i] = 70.0 - 0.8 * std::log2(grid.hz[i] / 1000.0);
    }
    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;

    // Measured response exactly matches the natural tilt, so the required
    // offset is just its level.
    const double level = chooseAutoLevel(grid, measured, presetNatural(), native);
    CHECK_NEAR(level, 70.0, 0.5);
}

// ---------------------------------------------------------------------------
// Correction mask
// ---------------------------------------------------------------------------

TEST_CASE(mask_tapers_at_the_curtains_rather_than_stepping) {
    // A hard edge puts a discontinuity in the error curve and the optimizer
    // places a filter on it, producing correction that is an artifact of the
    // boundary rather than of the room.
    const FrequencyGrid grid = grid48();
    TargetSpec spec = presetFlat();
    spec.lowCurtainHz = 100.0;
    spec.highCurtainHz = 10000.0;

    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;

    const std::vector<double> reliability(grid.size(), 1.0);
    const CorrectionMask mask = buildCorrectionMask(grid, spec, native, reliability);

    CHECK_NEAR(mask.weight[binNear(grid, 1000.0)], 1.0, 1e-9);
    // Safely inside the curtain, full weight.  Not tested exactly *at* the
    // curtain: the nearest grid bin may sit fractionally below it, where the
    // taper has legitimately already begun.
    CHECK_NEAR(mask.weight[binNear(grid, 120.0)], 1.0, 1e-9);
    CHECK(mask.weight[binNear(grid, 100.0)] > 0.95);
    // Half an octave below the curtain the taper has run out.
    CHECK_NEAR(mask.weight[binNear(grid, 70.0)], 0.0, 0.05);
    // Partway down it is between the two, not at either.
    const double partial = mask.weight[binNear(grid, 85.0)];
    CHECK(partial > 0.05);
    CHECK(partial < 0.95);
}

TEST_CASE(mask_forbids_boost_outside_the_native_band) {
    const FrequencyGrid grid = grid48();
    NativeBandwidth native;
    native.lowHz = 50.0;
    native.highHz = 15000.0;

    MaskConfig config;
    config.maxBoostDb = 3.0;

    const std::vector<double> reliability(grid.size(), 1.0);
    const CorrectionMask mask =
        buildCorrectionMask(grid, presetFlat(), native, reliability, config);

    CHECK_NEAR(mask.boostCeilingDb[binNear(grid, 1000.0)], 3.0, 1e-9);
    CHECK_NEAR(mask.boostCeilingDb[binNear(grid, 30.0)], 0.0, 1e-9);
    CHECK_NEAR(mask.boostCeilingDb[binNear(grid, 18000.0)], 0.0, 1e-9);
}

TEST_CASE(mask_forbids_boost_where_positions_disagree) {
    const FrequencyGrid grid = grid48();
    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;

    MaskConfig config;
    config.maxBoostDb = 3.0;
    config.boostReliabilityFloor = 0.5;

    std::vector<double> reliability(grid.size(), 1.0);
    reliability[binNear(grid, 120.0)] = 0.2;  // disputed

    const CorrectionMask mask =
        buildCorrectionMask(grid, presetFlat(), native, reliability, config);

    CHECK_NEAR(mask.boostCeilingDb[binNear(grid, 120.0)], 0.0, 1e-9);
    CHECK_NEAR(mask.boostCeilingDb[binNear(grid, 1000.0)], 3.0, 1e-9);
}

TEST_CASE(mask_weight_follows_reliability) {
    const FrequencyGrid grid = grid48();
    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;

    std::vector<double> reliability(grid.size(), 1.0);
    reliability[binNear(grid, 200.0)] = 0.25;

    const CorrectionMask mask = buildCorrectionMask(grid, presetFlat(), native, reliability);
    CHECK_NEAR(mask.weight[binNear(grid, 200.0)], 0.25, 1e-9);
}

TEST_CASE(default_mask_is_cut_only) {
    // No-boost is the normal mode; boost is an Advanced opt-in.
    const FrequencyGrid grid = grid48();
    NativeBandwidth native;
    native.lowHz = 20.0;
    native.highHz = 20000.0;
    const std::vector<double> reliability(grid.size(), 1.0);
    const CorrectionMask mask = buildCorrectionMask(grid, presetFlat(), native, reliability);
    for (double ceiling : mask.boostCeilingDb) CHECK_NEAR(ceiling, 0.0, 1e-12);
}

// The standalone evaluator, which the design UI uses to draw a house curve
// before any measurement exists.  Session curves cannot serve that: they are
// only readable after a fit, and a fit needs positions.
TEST_CASE(evaluate_target_matches_build_target) {
    const FrequencyGrid grid = grid48();
    const TargetSpec spec = presetNatural();

    dspi_rc_target_spec c{};
    CHECK(dspi_rc_target_preset(1, &c) == DSPI_RC_OK);

    std::vector<double> viaC(grid.size(), 0.0);
    std::size_t written = 0;
    CHECK(dspi_rc_evaluate_target(&c, nullptr, nullptr, 0,
                                  20.0, 20000.0, 48,
                                  viaC.data(), viaC.size(), &written) == DSPI_RC_OK);
    CHECK(written == grid.size());

    const std::vector<double> direct = buildTarget(grid, spec);
    CHECK(direct.size() == viaC.size());
    for (std::size_t i = 0; i < direct.size(); ++i) CHECK_NEAR(viaC[i], direct[i], 1e-12);
}

TEST_CASE(evaluate_target_applies_anchors) {
    dspi_rc_target_spec c{};
    CHECK(dspi_rc_target_preset(0, &c) == DSPI_RC_OK);   // flat

    const FrequencyGrid grid = grid48();
    std::vector<double> plain(grid.size(), 0.0);
    CHECK(dspi_rc_evaluate_target(&c, nullptr, nullptr, 0, 20.0, 20000.0, 48,
                                  plain.data(), plain.size(), nullptr) == DSPI_RC_OK);

    const double anchorHz[1] = {500.0};
    const double anchorDb[1] = {5.0};
    std::vector<double> anchored(grid.size(), 0.0);
    CHECK(dspi_rc_evaluate_target(&c, anchorHz, anchorDb, 1, 20.0, 20000.0, 48,
                                  anchored.data(), anchored.size(), nullptr) == DSPI_RC_OK);

    const std::size_t bin = binNear(grid, 500.0);
    CHECK(anchored[bin] > plain[bin] + 1.0);
}

TEST_CASE(evaluate_target_rejects_bad_arguments) {
    dspi_rc_target_spec c{};
    CHECK(dspi_rc_target_preset(1, &c) == DSPI_RC_OK);
    std::vector<double> out(4096, 0.0);

    CHECK(dspi_rc_evaluate_target(nullptr, nullptr, nullptr, 0, 20.0, 20000.0, 48,
                                  out.data(), out.size(), nullptr) != DSPI_RC_OK);
    CHECK(dspi_rc_evaluate_target(&c, nullptr, nullptr, 0, 20.0, 20000.0, 48,
                                  nullptr, 0, nullptr) != DSPI_RC_OK);
    // A count with no arrays would otherwise read off the end of nothing.
    CHECK(dspi_rc_evaluate_target(&c, nullptr, nullptr, 2, 20.0, 20000.0, 48,
                                  out.data(), out.size(), nullptr) != DSPI_RC_OK);
    // Too small an output buffer must be refused, not truncated.
    CHECK(dspi_rc_evaluate_target(&c, nullptr, nullptr, 0, 20.0, 20000.0, 48,
                                  out.data(), 4, nullptr) != DSPI_RC_OK);
}
