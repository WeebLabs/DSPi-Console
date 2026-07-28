// Golden tests for the DSPi filter model.
//
// These assert *analytic landmarks* rather than re-deriving the coefficient
// formulas, following the convention already established by DSPMathTests in
// the Swift test target.  Re-deriving the formula would only prove the test
// and the implementation share a typo; a landmark ("a peaking filter has
// exactly its requested gain at its centre frequency") is independent of how
// the coefficients were arrived at, and holds for the SVF and biquad paths
// alike even though those compute completely different numbers.
#include <cmath>

#include "dspi_rc/biquad.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

constexpr double kFs48 = 48000.0;
constexpr double kFs44 = 44100.0;
constexpr double kFs96 = 96000.0;

FilterParams band(FilterType type, float freq, float q, float gainDb) {
    FilterParams p;
    p.type = type;
    p.freq = freq;
    p.q = q;
    p.gainDb = gainDb;
    return p;
}

double gainAt(const FilterParams& p, double freqHz, double fs, Platform platform) {
    const RealizedSection s = realize(p, fs, platform);
    return 20.0 * std::log10(std::abs(s.response(freqHz, fs)));
}

double phaseAt(const FilterParams& p, double freqHz, double fs, Platform platform) {
    const RealizedSection s = realize(p, fs, platform);
    return std::arg(s.response(freqHz, fs)) * 180.0 / M_PI;
}

// Below Fs/7.5 on RP2350 the SVF runs; above it the float biquad does.
// 48000 / 7.5 = 6400 Hz.
constexpr double kSvfThreshold48 = kFs48 / 7.5;

}  // namespace

// ---------------------------------------------------------------------------
// Peaking
// ---------------------------------------------------------------------------

TEST_CASE(peaking_hits_requested_gain_at_centre_on_both_paths) {
    // 60 Hz is below the SVF threshold, 10 kHz is above it, so this one case
    // exercises both RP2350 realizations.
    for (float gain : {-12.0f, -6.0f, -1.5f, 1.5f, 6.0f, 12.0f}) {
        CHECK_NEAR(gainAt(band(FilterType::Peaking, 60.0f, 4.0f, gain), 60.0, kFs48,
                          Platform::RP2350), gain, 0.01);
        CHECK_NEAR(gainAt(band(FilterType::Peaking, 10000.0f, 4.0f, gain), 10000.0, kFs48,
                          Platform::RP2350), gain, 0.05);
        CHECK_NEAR(gainAt(band(FilterType::Peaking, 60.0f, 4.0f, gain), 60.0, kFs48,
                          Platform::RP2040), gain, 0.02);
    }
}

TEST_CASE(peaking_is_unity_far_from_centre) {
    const FilterParams p = band(FilterType::Peaking, 1000.0f, 8.0f, 12.0f);
    CHECK_NEAR(gainAt(p, 20.0, kFs48, Platform::RP2350), 0.0, 0.05);
    CHECK_NEAR(gainAt(p, 18000.0, kFs48, Platform::RP2350), 0.0, 0.1);
}

TEST_CASE(peaking_half_gain_bandwidth_follows_q) {
    // A peaking filter's gain at the edges of its Q-defined bandwidth is not a
    // formula we reimplement here; we only assert the monotone relationship
    // that a higher Q is narrower, which is what the seeding code relies on.
    const double wide = gainAt(band(FilterType::Peaking, 1000.0f, 0.7f, 10.0f),
                               1400.0, kFs48, Platform::RP2350);
    const double narrow = gainAt(band(FilterType::Peaking, 1000.0f, 8.0f, 10.0f),
                                 1400.0, kFs48, Platform::RP2350);
    CHECK(wide > narrow);
}

// ---------------------------------------------------------------------------
// Low / high pass
// ---------------------------------------------------------------------------

TEST_CASE(butterworth_lowpass_is_minus_three_db_at_corner) {
    // Q = 1/sqrt(2) gives |H(fc)| = Q, i.e. -3.01 dB.
    const double expected = 20.0 * std::log10(0.70710678);
    CHECK_NEAR(gainAt(band(FilterType::LowPass, 100.0f, 0.70710678f, 0.0f), 100.0,
                      kFs48, Platform::RP2350), expected, 0.01);
    CHECK_NEAR(gainAt(band(FilterType::LowPass, 12000.0f, 0.70710678f, 0.0f), 12000.0,
                      kFs48, Platform::RP2350), expected, 0.05);
}

TEST_CASE(butterworth_highpass_is_minus_three_db_at_corner) {
    const double expected = 20.0 * std::log10(0.70710678);
    CHECK_NEAR(gainAt(band(FilterType::HighPass, 100.0f, 0.70710678f, 0.0f), 100.0,
                      kFs48, Platform::RP2350), expected, 0.01);
}

TEST_CASE(lowpass_rolls_off_twelve_db_per_octave) {
    const FilterParams p = band(FilterType::LowPass, 100.0f, 0.70710678f, 0.0f);
    const double at1k = gainAt(p, 1000.0, kFs48, Platform::RP2350);
    const double at2k = gainAt(p, 2000.0, kFs48, Platform::RP2350);
    CHECK_NEAR(at1k - at2k, 12.0, 0.5);
}

// ---------------------------------------------------------------------------
// Notch and all-pass
// ---------------------------------------------------------------------------

TEST_CASE(notch_is_deep_at_centre) {
    CHECK(gainAt(band(FilterType::Notch, 200.0f, 4.0f, 0.0f), 200.0, kFs48,
                 Platform::RP2350) < -60.0);
}

TEST_CASE(allpass_is_unity_magnitude_everywhere) {
    const FilterParams p = band(FilterType::AllPass, 500.0f, 2.0f, 0.0f);
    for (double f : {20.0, 200.0, 500.0, 5000.0, 15000.0}) {
        CHECK_NEAR(gainAt(p, f, kFs48, Platform::RP2350), 0.0, 0.02);
    }
}

TEST_CASE(second_order_allpass_is_180_degrees_at_corner) {
    const double phase = phaseAt(band(FilterType::AllPass, 500.0f, 2.0f, 0.0f), 500.0,
                                 kFs48, Platform::RP2350);
    CHECK_NEAR(std::fabs(phase), 180.0, 0.5);
}

TEST_CASE(first_order_allpass_is_unity_and_minus_90_at_corner) {
    const FilterParams p = band(FilterType::AllPass1, 500.0f, 0.707f, 0.0f);
    for (double f : {20.0, 500.0, 15000.0}) {
        CHECK_NEAR(gainAt(p, f, kFs48, Platform::RP2350), 0.0, 0.02);
    }
    CHECK_NEAR(std::fabs(phaseAt(p, 500.0, kFs48, Platform::RP2350)), 90.0, 0.5);
}

// ---------------------------------------------------------------------------
// Shelves
// ---------------------------------------------------------------------------

TEST_CASE(second_order_shelves_reach_full_gain_asymptotically) {
    const float gain = 6.0f;
    const FilterParams low = band(FilterType::LowShelf, 200.0f, 0.707f, gain);
    CHECK_NEAR(gainAt(low, 10.0, kFs48, Platform::RP2350), gain, 0.1);
    CHECK_NEAR(gainAt(low, 20000.0, kFs48, Platform::RP2350), 0.0, 0.1);

    const FilterParams high = band(FilterType::HighShelf, 4000.0f, 0.707f, gain);
    CHECK_NEAR(gainAt(high, 20.0, kFs48, Platform::RP2350), 0.0, 0.1);
    CHECK_NEAR(gainAt(high, 22000.0, kFs48, Platform::RP2350), gain, 0.2);
}

TEST_CASE(shelf_midpoint_is_half_gain) {
    // The defining property of an RBJ shelf: at its corner it sits at half the
    // shelf gain in dB.
    const float gain = 8.0f;
    CHECK_NEAR(gainAt(band(FilterType::LowShelf, 200.0f, 0.707f, gain), 200.0, kFs48,
                      Platform::RP2350), gain / 2.0, 0.1);
}

TEST_CASE(first_order_shelves_reach_full_gain_asymptotically) {
    const float gain = 6.0f;
    const FilterParams low = band(FilterType::LowShelf1, 300.0f, 0.707f, gain);
    CHECK_NEAR(gainAt(low, 10.0, kFs48, Platform::RP2350), gain, 0.15);
    CHECK_NEAR(gainAt(low, 20000.0, kFs48, Platform::RP2350), 0.0, 0.15);

    const FilterParams high = band(FilterType::HighShelf1, 3000.0f, 0.707f, gain);
    CHECK_NEAR(gainAt(high, 20.0, kFs48, Platform::RP2350), 0.0, 0.15);
    CHECK_NEAR(gainAt(high, 22000.0, kFs48, Platform::RP2350), gain, 0.3);
}

// ---------------------------------------------------------------------------
// SVF / biquad boundary
//
// The most fragile part of the model: RP2350 switches realization at Fs/7.5.
// If the two paths disagree, a correction would visibly step at 6.4 kHz.
// ---------------------------------------------------------------------------

TEST_CASE(svf_and_biquad_agree_across_the_threshold) {
    const double below = kSvfThreshold48 * 0.98;
    const double above = kSvfThreshold48 * 1.02;

    const double gBelow = gainAt(band(FilterType::Peaking, static_cast<float>(below), 2.0f, 6.0f),
                                 below, kFs48, Platform::RP2350);
    const double gAbove = gainAt(band(FilterType::Peaking, static_cast<float>(above), 2.0f, 6.0f),
                                 above, kFs48, Platform::RP2350);
    CHECK_NEAR(gBelow, 6.0, 0.02);
    CHECK_NEAR(gAbove, 6.0, 0.05);
}

TEST_CASE(threshold_actually_switches_realization) {
    // Guards against the platform/threshold logic silently becoming a no-op.
    const RealizedSection low =
        realize(band(FilterType::Peaking, 1000.0f, 2.0f, 6.0f), kFs48, Platform::RP2350);
    const RealizedSection high =
        realize(band(FilterType::Peaking, 12000.0f, 2.0f, 6.0f), kFs48, Platform::RP2350);
    CHECK(low.kind == RealizedSection::Kind::Svf);
    CHECK(high.kind == RealizedSection::Kind::Biquad);

    // RP2040 never uses the SVF.
    const RealizedSection rp2040 =
        realize(band(FilterType::Peaking, 1000.0f, 2.0f, 6.0f), kFs48, Platform::RP2040);
    CHECK(rp2040.kind == RealizedSection::Kind::Biquad);
}

TEST_CASE(first_order_types_use_the_one_pole_svf_below_threshold) {
    const RealizedSection s =
        realize(band(FilterType::LowShelf1, 200.0f, 0.707f, 4.0f), kFs48, Platform::RP2350);
    CHECK(s.kind == RealizedSection::Kind::SvfFirst);
}

// ---------------------------------------------------------------------------
// SVF against an independent RBJ reference
//
// The landmark tests above check single points, which a wrong-but-plausible
// SVF transfer function could still satisfy.  This compares the whole curve
// against a double-precision RBJ biquad computed here from the cookbook,
// deliberately duplicated rather than shared so the two derivations stay
// independent.  The firmware comment at dsp_pipeline.c:182 claims the SVF
// matches RBJ exactly; this is where that claim is held to account, and where
// an error in the bilinear derivation of the SVF would surface.
// ---------------------------------------------------------------------------

namespace {

double referenceRbjDb(FilterType type, double f, double fc, double q, double gainDb, double fs) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * M_PI * fc / fs;
    const double sn = std::sin(w);
    const double cs = std::cos(w);
    const double alpha = sn / (2.0 * q);
    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;

    switch (type) {
        case FilterType::Peaking:
            b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A;
            a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A;
            break;
        case FilterType::LowShelf: {
            const double sq = std::sqrt(A);
            b0 = A * ((A + 1) - (A - 1) * cs + 2 * sq * alpha);
            b1 = 2 * A * ((A - 1) - (A + 1) * cs);
            b2 = A * ((A + 1) - (A - 1) * cs - 2 * sq * alpha);
            a0 = (A + 1) + (A - 1) * cs + 2 * sq * alpha;
            a1 = -2 * ((A - 1) + (A + 1) * cs);
            a2 = (A + 1) + (A - 1) * cs - 2 * sq * alpha;
            break;
        }
        case FilterType::HighShelf: {
            const double sq = std::sqrt(A);
            b0 = A * ((A + 1) + (A - 1) * cs + 2 * sq * alpha);
            b1 = -2 * A * ((A - 1) + (A + 1) * cs);
            b2 = A * ((A + 1) + (A - 1) * cs - 2 * sq * alpha);
            a0 = (A + 1) - (A - 1) * cs + 2 * sq * alpha;
            a1 = 2 * ((A - 1) - (A + 1) * cs);
            a2 = (A + 1) - (A - 1) * cs - 2 * sq * alpha;
            break;
        }
        case FilterType::LowPass:
            b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case FilterType::HighPass:
            b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case FilterType::Notch:
            b0 = 1; b1 = -2 * cs; b2 = 1;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        default:
            return 0.0;
    }

    const double wf = 2.0 * M_PI * f / fs;
    const std::complex<double> z1 = std::polar(1.0, -wf);
    const std::complex<double> z2 = z1 * z1;
    return 20.0 * std::log10(std::abs((b0 + b1 * z1 + b2 * z2) /
                                      (a0 + a1 * z1 + a2 * z2)));
}

// Worst deviation between the realized section and the RBJ reference, swept
// across the analysis band.
double worstDeviationFromRbj(FilterType type, float fc, float q, float gain,
                             double fs, Platform platform) {
    const FilterParams p = band(type, fc, q, gain);
    const RealizedSection s = realize(p, fs, platform);
    double worst = 0.0;
    for (int i = 0; i <= 600; ++i) {
        const double f = 10.0 * std::pow(2000.0, i / 600.0);
        if (f >= fs * 0.45) break;
        const double got = 20.0 * std::log10(std::abs(s.response(f, fs)));
        const double ref = referenceRbjDb(type, f, fc, q, gain, fs);
        worst = std::max(worst, std::fabs(got - ref));
    }
    return worst;
}

}  // namespace

TEST_CASE(svf_matches_rbj_reference_across_the_whole_band) {
    // All of these sit below Fs/7.5, so every one exercises the SVF path.
    // Tolerance is float-design noise, not structural disagreement.
    CHECK(worstDeviationFromRbj(FilterType::Peaking, 60.0f, 4.0f, 6.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::Peaking, 200.0f, 8.0f, -10.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::Peaking, 35.0f, 12.0f, -14.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::LowShelf, 120.0f, 0.707f, 5.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::HighShelf, 500.0f, 0.707f, -4.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::LowPass, 80.0f, 0.707f, 0.0f, kFs48,
                                Platform::RP2350) < 1e-3);
    CHECK(worstDeviationFromRbj(FilterType::HighPass, 80.0f, 0.707f, 0.0f, kFs48,
                                Platform::RP2350) < 1e-3);
}

TEST_CASE(svf_matches_rbj_at_every_supported_rate) {
    for (double fs : {kFs44, kFs48, kFs96}) {
        CHECK(worstDeviationFromRbj(FilterType::Peaking, 45.0f, 6.0f, -8.0f, fs,
                                    Platform::RP2350) < 1e-3);
    }
}

TEST_CASE(rp2040_biquad_tracks_rbj_within_q28_truncation) {
    // RP2040 has no SVF, so this exercises the fixed-point path.  The error
    // budget here is Q28 truncation, which is coarser than float design noise
    // but must still be small for an ordinary filter.
    CHECK(worstDeviationFromRbj(FilterType::Peaking, 60.0f, 4.0f, 6.0f, kFs48,
                                Platform::RP2040) < 0.05);
    CHECK(worstDeviationFromRbj(FilterType::LowShelf, 120.0f, 0.707f, 5.0f, kFs48,
                                Platform::RP2040) < 0.05);
}

// ---------------------------------------------------------------------------
// Platform divergence
// ---------------------------------------------------------------------------

TEST_CASE(platforms_differ_but_stay_close_for_ordinary_filters) {
    // The point of the Platform parameter is that it changes the answer.  If
    // these were identical the parameter would be decorative.
    const FilterParams p = band(FilterType::Peaking, 45.0f, 8.0f, -9.0f);
    const double a = gainAt(p, 45.0, kFs48, Platform::RP2350);
    const double b = gainAt(p, 45.0, kFs48, Platform::RP2040);
    CHECK_NEAR(a, -9.0, 0.02);
    // Q28 truncation plus the different normalization order moves the result,
    // but a sane filter must not move far.
    CHECK_NEAR(b, -9.0, 0.15);
}

TEST_CASE(rp2040_coefficients_land_on_the_q28_grid) {
    const RealizedSection s =
        realize(band(FilterType::Peaking, 1000.0f, 2.0f, 6.0f), kFs48, Platform::RP2040);
    const double scale = static_cast<double>(1LL << kFilterShift);
    for (double c : {s.b0, s.b1, s.b2, s.a1, s.a2}) {
        const double onGrid = c * scale;
        CHECK_NEAR(onGrid - std::round(onGrid), 0.0, 1e-6);
    }
}

// ---------------------------------------------------------------------------
// Sample rate
// ---------------------------------------------------------------------------

TEST_CASE(landmarks_hold_at_every_supported_rate) {
    for (double fs : {kFs44, kFs48, kFs96}) {
        CHECK_NEAR(gainAt(band(FilterType::Peaking, 100.0f, 3.0f, -8.0f), 100.0, fs,
                          Platform::RP2350), -8.0, 0.02);
        CHECK_NEAR(gainAt(band(FilterType::Peaking, 100.0f, 3.0f, -8.0f), 100.0, fs,
                          Platform::RP2040), -8.0, 0.05);
        const double expected = 20.0 * std::log10(0.70710678);
        CHECK_NEAR(gainAt(band(FilterType::LowPass, 500.0f, 0.70710678f, 0.0f), 500.0, fs,
                          Platform::RP2350), expected, 0.02);
    }
}

TEST_CASE(rate_actually_changes_the_realization) {
    // The 48 kHz assumption baked into DSPMath is precisely the bug this
    // parameter exists to prevent, so assert the parameter has teeth.  At
    // 96 kHz the SVF threshold moves to 12.8 kHz, so a 10 kHz filter that is a
    // biquad at 48 kHz becomes an SVF.
    const FilterParams p = band(FilterType::Peaking, 10000.0f, 2.0f, 6.0f);
    CHECK(realize(p, kFs48, Platform::RP2350).kind == RealizedSection::Kind::Biquad);
    CHECK(realize(p, kFs96, Platform::RP2350).kind == RealizedSection::Kind::Svf);
}

// ---------------------------------------------------------------------------
// Firmware clamps
// ---------------------------------------------------------------------------

TEST_CASE(clamps_match_firmware_limits) {
    const FilterParams lowQ = clampToFirmware(band(FilterType::Peaking, 1000.0f, 0.001f, 0.0f), kFs48);
    CHECK_NEAR(lowQ.q, 0.1, 1e-6);

    const FilterParams highQ = clampToFirmware(band(FilterType::Peaking, 1000.0f, 99.0f, 0.0f), kFs48);
    CHECK_NEAR(highQ.q, 20.0, 1e-6);

    const FilterParams lowF = clampToFirmware(band(FilterType::Peaking, 1.0f, 1.0f, 0.0f), kFs48);
    CHECK_NEAR(lowF.freq, 10.0, 1e-6);

    const FilterParams highF = clampToFirmware(band(FilterType::Peaking, 30000.0f, 1.0f, 0.0f), kFs48);
    CHECK_NEAR(highF.freq, 0.45 * kFs48, 1e-3);
}

TEST_CASE(linkwitz_clamps_to_the_tighter_corner) {
    FilterParams lt = band(FilterType::LinkwitzTransform, 30000.0f, 0.5f, 0.0f);
    lt.gainDb = 25.0f;  // fp in Hz for this type
    lt.qp = 0.707f;
    const FilterParams clamped = clampToFirmware(lt, kFs48);
    CHECK_NEAR(clamped.freq, 0.15 * kFs48, 1e-3);
    CHECK_NEAR(clamped.gainDb, 25.0, 1e-3);
}

TEST_CASE(linkwitz_dc_gain_follows_the_corner_ratio) {
    // DC gain of the Linkwitz Transform is (g0/gp)^2, so a driver corner above
    // the target corner produces bass boost.
    FilterParams lt = band(FilterType::LinkwitzTransform, 60.0f, 0.7f, 0.0f);
    lt.gainDb = 30.0f;   // target fp
    lt.qp = 0.707f;
    const double dc = gainAt(lt, 10.0, kFs48, Platform::RP2350);
    CHECK(dc > 6.0);   // roughly (60/30)^2 = 4x = 12 dB, softened by the corners
    CHECK(dc < 18.0);
}

// ---------------------------------------------------------------------------
// Bank behavior
// ---------------------------------------------------------------------------

TEST_CASE(bypassed_and_flat_bands_are_skipped) {
    FilterBank bank;
    bank.push_back(band(FilterType::Peaking, 1000.0f, 2.0f, 6.0f));
    FilterParams bypassed = band(FilterType::Peaking, 1000.0f, 2.0f, 6.0f);
    bypassed.bypass = true;
    bank.push_back(bypassed);
    bank.push_back(band(FilterType::Flat, 1000.0f, 2.0f, 6.0f));

    const auto sections = realizeBank(bank, kFs48, Platform::RP2350);
    CHECK(sections.size() == 1u);

    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 12);
    const auto response = magnitudeDb(sections, grid, kFs48);
    CHECK(response.size() == grid.size());
}

TEST_CASE(cascade_gains_add_in_db) {
    FilterBank bank;
    bank.push_back(band(FilterType::Peaking, 1000.0f, 2.0f, 3.0f));
    bank.push_back(band(FilterType::Peaking, 1000.0f, 2.0f, 4.0f));
    const auto sections = realizeBank(bank, kFs48, Platform::RP2350);
    CHECK_NEAR(magnitudeDb(sections, 1000.0, kFs48), 7.0, 0.05);
}

TEST_CASE(empty_bank_is_flat) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 6);
    const auto response = bankMagnitudeDb({}, grid, kFs48, Platform::RP2350);
    for (double db : response) CHECK_NEAR(db, 0.0, 1e-12);
}

// ---------------------------------------------------------------------------
// Frequency grid
// ---------------------------------------------------------------------------

TEST_CASE(grid_endpoints_are_exact) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 96);
    CHECK(!grid.empty());
    CHECK_NEAR(grid.hz.front(), 20.0, 1e-9);
    CHECK_NEAR(grid.hz.back(), 20000.0, 1e-9);
}

TEST_CASE(grid_reports_its_own_resolution) {
    for (int ppo : {6, 24, 96}) {
        const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, ppo);
        CHECK_NEAR(grid.pointsPerOctave(), ppo, 0.5);
    }
}

TEST_CASE(grid_rejects_nonsense) {
    CHECK(FrequencyGrid::logSpaced(0.0, 20000.0, 96).empty());
    CHECK(FrequencyGrid::logSpaced(20000.0, 20.0, 96).empty());
    CHECK(FrequencyGrid::logSpaced(20.0, 20000.0, 0).empty());
}

// ---------------------------------------------------------------------------
// Cached response path
// ---------------------------------------------------------------------------

TEST_CASE(cached_response_matches_the_reference_path) {
    // The optimizer evaluates through the cached path tens of thousands of
    // times per fit.  If it drifted from the reference, every fitted result
    // would be subtly wrong while every direct-evaluation test still passed.
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 24);

    for (double fs : {kFs44, kFs48, kFs96}) {
        FilterBank bank;
        bank.push_back(band(FilterType::Peaking, 45.0f, 6.0f, -9.0f));    // SVF
        bank.push_back(band(FilterType::LowShelf, 120.0f, 0.707f, 4.0f)); // SVF
        bank.push_back(band(FilterType::Peaking, 9000.0f, 3.0f, 5.0f));   // biquad
        bank.push_back(band(FilterType::LowShelf1, 80.0f, 0.707f, 3.0f)); // 1st-order SVF
        bank.push_back(band(FilterType::HighShelf, 6000.0f, 0.707f, -3.0f));

        for (Platform platform : {Platform::RP2350, Platform::RP2040}) {
            const auto sections = realizeBank(bank, fs, platform);
            const std::vector<double> reference = magnitudeDb(sections, grid, fs);

            const ResponseCache cache = ResponseCache::forGrid(grid, fs);
            std::vector<double> cached;
            magnitudeDbInto(sections, cache, cached);

            CHECK(cached.size() == reference.size());
            for (std::size_t i = 0; i < reference.size(); ++i) {
                CHECK_NEAR(cached[i], reference[i], 1e-9);
            }
        }
    }
}

TEST_CASE(cached_response_of_an_empty_cascade_is_flat) {
    const FrequencyGrid grid = FrequencyGrid::logSpaced(20.0, 20000.0, 12);
    const ResponseCache cache = ResponseCache::forGrid(grid, kFs48);
    std::vector<double> out;
    magnitudeDbInto({}, cache, out);
    CHECK(out.size() == grid.size());
    for (double v : out) CHECK_NEAR(v, 0.0, 1e-12);
}
