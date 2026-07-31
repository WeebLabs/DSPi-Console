// Constrained PEQ fitting.
//
// Given a set of measured positions, a target, and the reliability weighting
// that says which features are real, produce a filter bank the connected DSPi
// can actually run.
//
// Three properties matter more than raw fitting accuracy, and the Milestone 0
// corpus established that they cost accuracy to obtain:
//
//   * The objective is evaluated at **every enabled position**, not on the
//     average.  Fitting the average lets a correction that helps one seat
//     wreck another and score well doing it.
//   * Boost is withheld where the positions disagree.  A cancellation that
//     moves with the microphone must not be inverted.
//   * The response being optimized is the *realized* response of the exact
//     cascade the hardware will run, at the live sample rate, for the
//     connected platform.  Fitting an idealized biquad and hoping is how an
//     optimizer converges on a result the device does not produce.
//
// Spec §7.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "dspi_rc/analysis.hpp"
#include "dspi_rc/biquad.hpp"
#include "dspi_rc/target.hpp"
#include "dspi_rc/types.hpp"

namespace dspi_rc {

struct FitConfig {
    // Band budget.  Queried from the live device rather than assumed: ten is
    // today's answer on every channel, and the Milestone 0 corpus saturated it
    // on five of eight fixtures, so this is a binding constraint rather than
    // comfortable headroom.
    int maxFilters = 10;

    // Allow a low and a high shelf among the allocation.  Shelves fit a broad
    // target trend far more cheaply than peaking filters, which matters when
    // the budget is the limit.
    bool allowShelves = true;

    double minFreqHz = 20.0;
    double maxFreqHz = 20000.0;

    // How much of the deviation from the target to chase, 0..1.
    //
    // Applied by moving the target toward the measured response rather than by
    // scaling the finished filters: the fit then optimises the reduced goal
    // honestly, so every other limit here still binds and the reported metrics
    // describe what will actually be heard.  A gentler setting is the usual
    // answer to a correction that measures well and sounds over-processed.
    double strength = 1.0;

    // Asymmetric by design: cutting a resonance is safe, boosting is not.
    double cutLimitDb = -12.0;
    double boostLimitDb = 0.0;        // Advanced mode raises this, typically +3.

    // The combined response ceiling.  No-boost is achieved by placing the
    // target's level so the whole cascade sits at or below this, not by
    // forbidding positive gain on individual bands, which would rule out
    // legitimate overlapping shapes.
    double combinedCeilingDb = -0.5;

    // Q limits.  Boost is held to a low Q because a narrow boost is almost
    // always fighting a null.  Cuts may be narrow at low frequencies, where
    // modes genuinely are narrow, and must broaden with frequency.
    double maxBoostQ = 2.0;
    // Shelves are shaped by their corner, not by their width. Roughly 0.5 to
    // 1.0 is the useful range; beyond that the transition overshoots.
    double maxShelfQ = 1.0;
    double maxCutQBelowTransition = 10.0;
    double maxCutQAtTop = 3.0;
    double minQ = 0.3;

    // Objective shaping.
    double huberDeltaDb = 2.0;
    double overshootToleranceDb = 0.5;

    // Soft hygiene weights, scaled by `hygieneWeight`.  Milestone 0 swept this
    // and settled on 0.25 because it was the only tested value to converge on
    // all eight ten-band scenarios; the neutral metrics barely moved from
    // 0.125 through 1.0, so this is a convergence choice rather than a
    // demonstrated performance knee.
    double hygieneWeight = 0.25;
    double overshootWeight = 2.5;
    double positiveCorrectionWeight = 2.0;
    double unreliableBoostWeight = 10.0;
    double sharpnessWeight = 0.5;
    double complexityWeight = 0.002;

    // Search effort.  Deterministic: same inputs and config give the same
    // filters, which the project format depends on.
    //
    // Raised from 1200 when the line search stopped moving uphill. With every
    // coordinate now either improving or holding, the descent keeps making
    // progress for longer and the old cap truncated it: the hardest corpus
    // scenario hit 75 sweeps on all three starts without stalling. Costs almost
    // nothing in practice, since the stall test fires well before the cap on
    // everything else.
    int maxIterations = 4800;
    int starts = 3;

    std::string validate() const;
};

struct FitMetrics {
    // Neutral metrics, not private terms of this objective.  Milestone 0
    // established that reporting the objective as a quality figure is close to
    // tautological, since the method being compared is the one that optimizes
    // it.
    double rawWorstPositionRmseDb = 0.0;
    double reliableWorstPositionRmseDb = 0.0;
    double reliableMedianAbsErrorDb = 0.0;
    double p95PositiveOvershootDb = 0.0;
    double maxCombinedCorrectionDb = 0.0;
    double minCombinedCorrectionDb = 0.0;
    double maxDisputedBoostDb = 0.0;
    double maxOutsideNativeBoostDb = 0.0;
    double maxBoostFilterQ = 0.0;
    int activeFilterCount = 0;
    int shelfFilterCount = 0;
};

struct FitResult {
    FilterBank filters;

    // Attenuation the channel takes so the combined correction respects the
    // ceiling.  Applied at the destination: output trim for an output-side
    // correction, input preamp for an input-side one.
    double trimDb = 0.0;

    // Realized correction on the grid, including trim, for the platform the
    // fit targeted.  This is what to plot; it is not a recomputation of an
    // ideal cascade.
    std::vector<double> correctionDb;

    // Predicted corrected response per position.
    std::vector<std::vector<double>> predictedDb;

    double objective = 0.0;
    bool converged = false;
    int iterations = 0;
    int evaluations = 0;
    std::string message;

    FitMetrics metrics;
};

// Everything the fit needs about the measurement.  Grouped rather than passed
// as eleven arguments so a caller cannot accidentally pair a target with the
// wrong grid.
struct FitProblem {
    FrequencyGrid grid;
    std::vector<PositionMeasurement> positions;
    std::vector<double> targetDb;
    SpatialStatistics statistics;
    CorrectionMask mask;
    NativeBandwidth native;

    // Where the user said correction may act at all.
    //
    // The mask already tapers the *error weight* to zero outside these, which
    // makes the fit indifferent to what happens there - but indifferent is not
    // the same as forbidden, and the two were being confused.  With the bounds
    // running to the full 20 Hz - 20 kHz the search could drag a filter outside
    // the curtains for free, because nothing out there was scored.  A user who
    // sets the low curtain to 120 Hz and is handed a filter at 58 Hz has been
    // ignored, whatever the objective thinks.
    //
    // Defaults span the whole band, so a caller that does not set them gets the
    // previous behaviour rather than a silently narrowed correction.
    double lowCurtainHz = 20.0;
    double highCurtainHz = 20000.0;

    double sampleRateHz = 48000.0;
    Platform platform = Platform::RP2350;

    std::string validate() const;
};

// Fit a correction.  Never throws; a rejected problem comes back with
// `converged == false` and an explanatory `message`.
// Ease the target toward what the room actually does.
//
// `strength` of 1 leaves the problem untouched; 0.5 asks the fit to close half
// the gap.  Expressed as a change to the target rather than as a scaling of the
// finished filters, so the optimizer solves the reduced goal under all the same
// constraints and the reported metrics describe what will really be heard.
//
// Recomputes the spatial statistics, which are defined relative to the target.
void applyStrength(FitProblem& problem, double strength);

FitResult fitCorrection(const FitProblem& problem, const FitConfig& config = {});

// Evaluate an arbitrary bank against a problem without fitting it.  Used for
// the ablation comparisons, for scoring a hand-edited bank, and for scoring
// the uncorrected response by passing an empty bank.
FitMetrics evaluateBank(const FitProblem& problem,
                        const FilterBank& bank,
                        double trimDb,
                        const FitConfig& config = {});

// ---------------------------------------------------------------------------
// Shared scoring
//
// Public because the reference fixed-pole designer in `parallel.hpp` must be
// scored by exactly this code.  A comparison between two designers that each
// computed their own metrics would be measuring the metrics.
// ---------------------------------------------------------------------------

// Score an arbitrary realized correction curve, for designs that are not a
// FilterBank.  The filter-count metrics are left at zero.  `evaluateBank` is
// this plus the counts.
FitMetrics evaluateCorrection(const FitProblem& problem,
                              const std::vector<double>& correctionDb);

// Attenuation the channel must take so the combined response respects the
// ceiling and takes no positive gain where boost is forbidden.
double requiredTrimDb(const FitProblem& problem,
                      const FitConfig& config,
                      const std::vector<double>& responseDb);

// The positions collapsed onto a single weighted error curve.
//
// The correction is common to every position, so the weighted sum of squares
// over positions separates into a term in the weighted mean error and a term in
// the across-position variance that does not contain the unknowns.  Minimizing
// against the mean is therefore identical to minimizing against every position,
// for the weights in force.  Weights are Huber weights on each position's
// residual, which is what stops one position's deep cancellation null from
// owning the fit.
//
// Used by the fixed-pole designer; the search in this file predates it and
// iterates the positions directly.
struct CollapsedProblem {
    std::vector<double> errorDb;   // what the correction is being asked to be
    std::vector<double> weight;
};

CollapsedProblem collapsePositions(const FitProblem& problem,
                                   const std::vector<double>& responseDb,
                                   double huberDeltaDb);

}  // namespace dspi_rc
