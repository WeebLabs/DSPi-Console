// Faithful model of the DSPi filter implementation.
//
// This is not "a biquad library".  It reproduces what the connected hardware
// will actually run, including the parts that are inconvenient:
//
//   * the truncated pi literal the firmware uses (3.1415926535f, not M_PI);
//   * single-precision coefficient design, because the firmware designs in
//     float and a double design diverges first exactly where high-Q
//     low-frequency filters live;
//   * the RP2350 trapezoidal SVF used below Fs/7.5, whose discrete transfer
//     function is not the bilinear biquad's;
//   * RP2040 Q28 coefficient storage, with truncation toward zero rather than
//     rounding, matching the firmware cast.
//
// Predicting anything less faithfully means the optimizer converges on a
// response the hardware does not produce.  Reference: firmware
// dsp_pipeline.c:96-318 on release/v1.1.5 (9776c2f).
#pragma once

#include <complex>
#include <vector>

#include "dspi_rc/types.hpp"

namespace dspi_rc {

// The firmware's pi literal.  Deliberately not M_PI: matching the constant
// matters more than being correct to more digits, because the goal is to
// predict the firmware rather than to be a better implementation of it.
inline constexpr float kFirmwarePi = 3.1415926535f;

// RP2350 runs the SVF below this fraction of the sample rate
// (dsp_pipeline.c:136).
inline constexpr float kSvfThresholdDivisor = 7.5f;

// RP2040 coefficient storage (config.h:63).
inline constexpr int kFilterShift = 28;

// ---------------------------------------------------------------------------
// Realized filter section
//
// One recipe becomes one of three concrete things depending on type, corner
// frequency and platform.  Keeping the realization explicit, rather than
// collapsing everything to b/a coefficients, is what allows the SVF path to
// be evaluated on its own terms.
// ---------------------------------------------------------------------------
struct RealizedSection {
    enum class Kind {
        Bypass,      // Flat, bypassed, or an unmodelled type: unity gain.
        Biquad,      // TDF2, normalized by a0.
        Svf,         // RP2350 trapezoidal SVF, 2nd order.
        SvfFirst,    // RP2350 trapezoidal SVF, 1st order.
    };

    Kind kind = Kind::Bypass;

    // Biquad path (already divided by a0).
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;

    // SVF path: g and k define the poles, m0/m1/m2 mix the outputs.
    double g = 0.0, k = 0.0;
    double m0 = 0.0, m1 = 0.0, m2 = 0.0;

    // Evaluate H(z) at a frequency, for the given sample rate.
    std::complex<double> response(double freqHz, double sampleRateHz) const;
};

// ---------------------------------------------------------------------------
// Design
// ---------------------------------------------------------------------------

// Apply the firmware's input clamps.  Returns the recipe the hardware will
// actually use, which may differ from what was asked for.  Exposed separately
// so the optimizer can respect the clamps rather than discover them.
FilterParams clampToFirmware(FilterParams p, double sampleRateHz);

// Realize one band for a specific platform and sample rate.
RealizedSection realize(const FilterParams& p, double sampleRateHz, Platform platform);

// Realize a whole bank, skipping bypassed and flat bands.
std::vector<RealizedSection> realizeBank(const FilterBank& bank,
                                         double sampleRateHz,
                                         Platform platform);

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

// Per-frequency trigonometry, precomputed once for a grid.
//
// The optimizer evaluates a cascade tens of thousands of times on the same
// grid, and the only things that change between evaluations are the section
// coefficients.  Recomputing sin/cos per section per grid point made that the
// dominant cost of a fit; caching it is a large win for no loss of accuracy,
// since these are exactly the same values the uncached path computes.
struct ResponseCache {
    std::vector<double> cosW, sinW, cos2W, sin2W;   // biquad path
    std::vector<double> tanHalfW;                   // SVF path: u = j*tan(w/2)

    static ResponseCache forGrid(const FrequencyGrid& grid, double sampleRateHz);
    std::size_t size() const { return cosW.size(); }
};

// Magnitude in dB across a cached grid, written into `out` without allocating.
void magnitudeDbInto(const std::vector<RealizedSection>& sections,
                     const ResponseCache& cache,
                     std::vector<double>& out);

// Magnitude in dB of a realized cascade at one frequency.
double magnitudeDb(const std::vector<RealizedSection>& sections,
                   double freqHz,
                   double sampleRateHz);

// Magnitude in dB across a grid.  This is the hot path for the optimizer, so
// it takes the grid rather than being called per point.
std::vector<double> magnitudeDb(const std::vector<RealizedSection>& sections,
                                const FrequencyGrid& grid,
                                double sampleRateHz);

// Convenience: design and evaluate in one call.
std::vector<double> bankMagnitudeDb(const FilterBank& bank,
                                    const FrequencyGrid& grid,
                                    double sampleRateHz,
                                    Platform platform);

// Unwrapped phase in degrees across a grid.  Not used by version 1 correction,
// but needed by the diagnostics views and cheap to provide here.
std::vector<double> phaseDegrees(const std::vector<RealizedSection>& sections,
                                 const FrequencyGrid& grid,
                                 double sampleRateHz);

}  // namespace dspi_rc
