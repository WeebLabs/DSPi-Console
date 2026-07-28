// Response preprocessing and multi-position statistics.
//
// This is the part of the pipeline that decides *what is real*.  A single
// measurement cannot distinguish a room mode that everyone in the room hears
// from a cancellation that exists at one ear position, and correcting the
// second as though it were the first is the characteristic failure of naive
// automatic room EQ.  Everything here exists to keep that distinction.
//
// Spec §6.3, §6.4, §6.5.
#pragma once

#include <cstddef>
#include <vector>

#include "dspi_rc/types.hpp"

namespace dspi_rc {

// ---------------------------------------------------------------------------
// Frequency-dependent windowing
// ---------------------------------------------------------------------------

struct WindowingConfig {
    // Cycles of the analysis frequency retained in the window.  Six to fifteen
    // is the conventional range; start wide, because an over-tight window
    // discards real speaker behaviour along with the reflections.
    double cycles = 15.0;

    // Below this frequency the window opens toward the full measurement, so
    // modal decay and room gain are represented as the listener actually
    // experiences them at steady state.  Set from the estimated transition
    // frequency rather than a fixed number.
    double transitionHz = 200.0;

    // Never shorter than this, whatever the cycle rule implies.
    double minimumWindowSeconds = 0.0015;
};

// Frequency-dependent windowed magnitude response.
//
// Implemented as a bank of windows rather than one: each output frequency is
// evaluated from an impulse response truncated to a length appropriate for
// that frequency.  This is more work than a single FFT and it is the reason
// the high end can be freed of seat-specific comb filtering without smearing
// the low end.
std::vector<double> frequencyDependentWindowedResponse(const std::vector<double>& impulse,
                                                       double sampleRateHz,
                                                       std::size_t peakIndex,
                                                       const FrequencyGrid& grid,
                                                       const WindowingConfig& config);

// ---------------------------------------------------------------------------
// Smoothing
// ---------------------------------------------------------------------------

struct SmoothingConfig {
    // Fractional-octave smoothing at the low end, in the modal region, where
    // features are narrow, position-stable and genuinely correctable.
    double lowFractionDenominator = 48.0;
    // ... at the transition ...
    double midFractionDenominator = 6.0;
    // ... and at the top, where the goal is broad tonal balance rather than
    // seat-specific interference.
    double highFractionDenominator = 3.0;

    // Breakpoints.  Expressed relative to the estimated transition frequency
    // by `forTransition` so the policy adapts to the room instead of assuming
    // a typical one.
    double lowBreakHz = 100.0;
    double midBreakHz = 1000.0;
    double highBreakHz = 10000.0;

    static SmoothingConfig forTransition(double transitionHz);
};

// Fixed fractional-octave smoothing, for the UI's manual selector.
std::vector<double> smoothFractionalOctave(const FrequencyGrid& grid,
                                           const std::vector<double>& magnitudesDb,
                                           double fractionDenominator);

// Variable smoothing: fine at the bottom, broad at the top.
std::vector<double> smoothVariable(const FrequencyGrid& grid,
                                   const std::vector<double>& magnitudesDb,
                                   const SmoothingConfig& config);

// ---------------------------------------------------------------------------
// Multi-position statistics
// ---------------------------------------------------------------------------

struct PositionMeasurement {
    std::vector<double> magnitudesDb;   // on the shared grid
    double weight = 1.0;                // main listening position typically 2.0
    bool enabled = true;
};

struct SpatialStatistics {
    // Primary location estimate, computed in the **power domain**.
    //
    // Averaging in dB lets one seat's deep cancellation dominate: a -30 dB
    // null pulls the mean down far harder than the physically meaningful loss
    // of energy justifies, and the correction then chases a hole that exists
    // at one position.  Power averaging weights by energy, so nulls contribute
    // little and the average reflects what the listening area actually
    // receives.
    std::vector<double> powerAverageDb;

    // Robust dB-domain statistics, used for spread, outlier detection and
    // reliability weighting rather than as the location estimate.
    std::vector<double> medianDb;
    std::vector<double> madDb;

    // Fraction of enabled positions whose error points the same way as the
    // average's.  Low agreement means the positions disagree about whether a
    // feature is a peak or a dip, which is the signature of a moving
    // interference null.
    std::vector<double> signAgreement;

    // Combined confidence in [0.05, 1].  Multiplies the optimizer's frequency
    // weighting and gates how much boost is permitted.
    std::vector<double> reliability;

    // Estimated modal/statistical transition (spec §6.5).
    double transitionHz = 200.0;
    // False when there was too little data to estimate it and the fallback was
    // used.  A single position cannot distinguish a mode from a cancellation
    // at all, which is the strongest argument for measuring more than one.
    bool transitionEstimated = false;
};

struct StatisticsConfig {
    // Below this sign-agreement fraction a feature is treated as disputed and
    // boost is withheld.
    double disputedAgreement = 0.5;
    // Spread at which reliability has fallen by 1/e, in dB.
    double spreadToleranceDb = 6.0;
    // Search range for the transition estimate.
    double transitionSearchLowHz = 80.0;
    double transitionSearchHighHz = 500.0;
    double transitionFallbackHz = 200.0;
};

SpatialStatistics computeSpatialStatistics(const FrequencyGrid& grid,
                                           const std::vector<PositionMeasurement>& positions,
                                           const std::vector<double>& targetDb,
                                           const StatisticsConfig& config = {});

// Estimate the modal/statistical transition from the measurements alone.
//
// Uses the spatial spread rather than the Schroeder formula: below the
// transition positions largely agree and spread is low and slowly varying,
// above it spread rises sharply and position-to-position correlation falls
// away.  That gives a per-room, per-channel estimate with no user input, no
// room dimensions and no assumed reverberation time.
//
// Returns the fallback and sets `estimated` false when fewer than two
// positions are available or the data shows no usable transition.
double estimateTransitionFrequency(const FrequencyGrid& grid,
                                   const std::vector<PositionMeasurement>& positions,
                                   const StatisticsConfig& config,
                                   bool& estimated);

}  // namespace dspi_rc
