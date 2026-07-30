// Fixed-pole parallel filter design, as a reference rather than a product.
//
// This is Balázs Bank's structure implemented faithfully: K pole pairs placed
// in advance, numerator weights and a direct path solved by linear least
// squares against a complex target.  **DSPi cannot run it.**  The firmware DSP
// is a cascade with no accumulator to sum sections into, and the vendor wire
// carries filter recipes (type, frequency, Q, gain) rather than coefficients,
// so an arbitrary numerator has no representation that can reach the device.
//
// It exists to answer one question with numbers rather than argument: how much
// accuracy is DSPi giving up by having a ten-section cascade of parametric
// recipes instead of a K-section parallel bank?  `dspi_rc_cli poles` runs it
// beside the production fit across the acceptance corpus, and the answer
// decides whether the firmware work is worth doing.
//
// Delete this file once that decision is recorded, whichever way it goes.
//
// Spec `room_correction_fixed_pole_design.md` §3.1, §6, §8.
#pragma once

#include <complex>
#include <string>
#include <vector>

#include "dspi_rc/fft.hpp"
#include "dspi_rc/optimizer.hpp"
#include "dspi_rc/types.hpp"

namespace dspi_rc {

struct ParallelConfig {
    // Section count.  The whole point of the sweep is that this is free here
    // and pinned at ten on the hardware.
    int sections = 32;

    double minFreqHz = 20.0;
    double maxFreqHz = 20000.0;

    // Placement, matched to the production designer's defaults so the
    // comparison is not decided by an allocator setting.  These genuinely are
    // the same numbers, unlike an earlier version of this struct which drifted
    // to 0.75 when the production default moved to 0.5.
    double placementBias = 0.5;
    // Finer than production's sixth of an octave because there are three to
    // five times as many sections to fit into the same band.
    double minSpacingOctaves = 1.0 / 12.0;

    // Take pole Q from the width of the error feature rather than from the
    // spacing to the neighbouring poles.
    //
    // Bank's rule is the spacing one and it is right at high section counts.
    // It is a *handicap* at low ones, for the same reason it is in the cascade,
    // so leaving it forced off made the K=10 and K=16 rows measure the rule
    // rather than the structure.  Now it is a knob and `dspi_rc_cli poles`
    // reports both.
    bool qFromFeatureWidth = true;

    // A direct feed-through path.  Bank's formulation includes one, and without
    // it the bank cannot represent a broadband offset without spending
    // sections on it.
    bool includeDirectPath = true;

    // Weight each frequency by the inverse square of the target magnitude, so
    // a linear-domain least squares approximates a log-magnitude one.
    //
    // This is the single most important setting here.  A linear residual of
    // fixed size costs wildly different amounts of dB depending on level: dB
    // error is proportional to *relative* linear error, so minimizing plain
    // linear residuals is minimizing `|target|^2 * (dB error)^2`.  In a
    // cut-only corpus, where the target sits well below unity across most of
    // the band, that tells the fit to ignore exactly the regions the dB metric
    // cares most about - a bin 12 dB down counts for a sixteenth, one 24 dB
    // down for a two-hundred-and-fiftieth.
    //
    // Worth knowing: PORC, the canonical Python port of Bank's method, does not
    // do this either - it runs a time-domain least squares on minimum-phase
    // impulse responses, which is flat linear weighting.  The correction is
    // needed here because the scoreboard is in dB, not because the reference
    // implementations have it.
    bool normalizeByTarget = true;
    // Floor on |target| used by that normalization, as a magnitude.  Stops a
    // near-null in the target from acquiring unbounded weight.
    double targetFloor = 0.03;   // about -30 dB

    // Refine pole frequencies between numerator solves.
    //
    // Fixed poles are what make Bank's method a linear solve, so this is a
    // departure from it.  It exists because the production cascade refines its
    // centres by up to an octave, and a bound that denies the same freedom to
    // the reference is not an upper bound on what the structure can do - it is
    // a comparison of one designer's refinement against another's lack of it.
    bool refinePoles = true;
    double maxDriftOctaves = 1.0;

    // Share of the log-spaced sections placed below `logDensityBreakHz`.
    // Bank's own pole sets are weighted this way; PORC ships half its poles
    // below 200 Hz.  Zero spreads them evenly over the whole band.
    double logDensityLowShare = 0.5;
    double logDensityBreakHz = 200.0;

    double ridge = 1e-6;
    double huberDeltaDb = 2.0;
    int solvePasses = 6;

    // Length of the FFT used for the minimum-phase reconstruction.  Rounded up
    // to a power of two.
    std::size_t phaseFftSize = 16384;
};

struct ParallelSection {
    double freqHz = 1000.0;
    double q = 4.0;
    // Denominator, 1 + a1 z^-1 + a2 z^-2.  Fixed before the solve.
    double a1 = 0.0;
    double a2 = 0.0;
    // Numerator, b0 + b1 z^-1.  Solved.
    double b0 = 0.0;
    double b1 = 0.0;
};

struct ParallelDesign {
    std::vector<ParallelSection> sections;
    double d0 = 0.0;   // direct path, feed-through
    double d1 = 0.0;   // direct path, one sample delayed

    // Realized magnitude on the problem's grid, including the trim, directly
    // comparable with `FitResult::correctionDb`.
    std::vector<double> correctionDb;
    double trimDb = 0.0;

    FitMetrics metrics;
    double residualDb = 0.0;
    bool ok = false;
    std::string message;
};

// Minimum-phase reconstruction of a magnitude curve, by the real cepstrum.
//
// A parallel bank is fitted to a complex response, and a room measurement gives
// magnitude.  Minimum phase is the right completion rather than merely the
// convenient one: it is the causal stable filter with that magnitude and the
// least group delay, and fitting a magnitude-only target with arbitrary phase
// would spend sections on phase behaviour nobody asked for.
//
// Returns one complex value per grid point.
std::vector<Complex> minimumPhaseResponse(const FrequencyGrid& grid,
                                          const std::vector<double>& magnitudeDb,
                                          double sampleRateHz,
                                          std::size_t fftSize);

// Evaluate a design's complex response on a grid.
std::vector<Complex> parallelResponse(const ParallelDesign& design,
                                      const FrequencyGrid& grid,
                                      double sampleRateHz);

// Set a section's denominator from a centre frequency and Q.
//
// `r = exp(-pi * f / (Q * Fs))`, which is Bank's pole radius written for a
// half-power bandwidth of `f/Q`.  Verified against PORC's `freqpoles.py`, which
// computes `exp(-dwp/2)` for an angular bandwidth `dwp`: the same number.
void setPole(ParallelSection& section, double freqHz, double q, double sampleRateHz);

// Solve the numerator weights and direct path for a fixed pole set, against an
// arbitrary complex target.
//
// Separated from `designParallel` so the linear algebra can be tested without
// a measurement, a target curve or a minimum-phase reconstruction in the way.
// `binWeight` is per grid point; the target normalization in `config` is
// applied on top of it here rather than by the caller.
//
// Returns false only for a malformed problem.
bool solveParallelNumerators(const std::vector<Complex>& target,
                             const std::vector<double>& binWeight,
                             const FrequencyGrid& grid,
                             double sampleRateHz,
                             const ParallelConfig& config,
                             ParallelDesign& design,
                             double* residualNorm = nullptr);

// Design a parallel bank for the same problem the production fit solves.
//
// Scored by the same metrics, against the same mask and robust weighting, so
// the comparison isolates the structure.  It is nevertheless an *optimistic*
// bound: the numerator weights carry no per-section bound, because a bound on
// a numerator coefficient has no acoustic meaning, so the constraint the
// cascade carries in §5.5 has no counterpart here.  The mask still removes
// disputed regions from the objective and the trim still enforces the ceiling.
ParallelDesign designParallel(const FitProblem& problem,
                              const FitConfig& config,
                              const ParallelConfig& parallelConfig);

}  // namespace dspi_rc
