// Where the resonances go.
//
// Both the production cascade fit and the reference parallel fit decide their
// section frequencies and Qs *before* solving anything, which is what keeps the
// solve linear.  This is that decision, in one place, so the two cannot drift
// apart on the question that most decides the result.
//
// Spec `room_correction_fixed_pole_design.md` §4.
#pragma once

#include <cstddef>
#include <vector>

#include "dspi_rc/types.hpp"

namespace dspi_rc {

// Q ceilings, tightening with frequency.  Modes genuinely are narrow at the
// bottom of the band; a narrow cut at 8 kHz is fitting a measurement artifact.
struct QLimits {
    double minQ = 0.3;
    double maxCutQBelowTransition = 10.0;
    double maxCutQAtTop = 3.0;
    double maxBoostQ = 2.0;
    double maxShelfQ = 1.0;
    double transitionHz = 200.0;
};

// The cut ceiling at a frequency, interpolated in log frequency between the
// transition and 10 kHz.
double cutQLimit(double freqHz, const QLimits& limits);

struct PlacementConfig {
    int count = 10;

    // Correctable band.  Sections are never placed outside it, since the mask
    // has already decided that correction there is not wanted.
    double minFreqHz = 20.0;
    double maxFreqHz = 20000.0;

    // How the budget divides between sections aimed at measured features and
    // sections that simply cover the band: 1 is all coverage, 0 is all feature.
    //
    // Neither endpoint is usable on its own.  All-coverage spends a tenth of a
    // ten-section budget on each decade whether or not anything is wrong there;
    // all-feature keeps picking after the real features are claimed and puts
    // the surplus on whatever noise the suppression left behind.  Section 4.2
    // of the spec has the measured comparison.
    double placementBias = 0.75;

    // Two sections closer than this fight over one feature and the solve
    // resolves the fight with a large cancelling pair.
    double minSpacingOctaves = 1.0 / 6.0;

    // Weight the log-spaced coverage sections toward the bottom of the band:
    // `logDensityLowShare` of them go below `logDensityBreakHz`, log-spaced
    // within each part.  Zero spreads them evenly across the whole band.
    //
    // This is what Bank's method actually does and what a room asks for.  PORC,
    // the canonical Python port, ships 14 poles across 20-200 Hz and 13 across
    // 250-20000 Hz: half the budget in the bottom decade, because that is where
    // the modes are and where correction is both possible and worthwhile.
    // Spreading evenly in log frequency across three decades spends as much
    // resolution on 2-20 kHz, where the measurement is least trustworthy and
    // correction should be broadest, as on 20-200 Hz.
    double logDensityLowShare = 0.0;
    double logDensityBreakHz = 200.0;

    // Take each section's Q from the width of the error feature it sits on,
    // rather than from the distance to its neighbours.
    //
    // Bank's bank sets Q from the spacing, which is right when there are thirty
    // to a hundred sections: adjacent sections then meet near their half-power
    // points and the bank can represent any smooth curve.  At ten sections over
    // three decades the same rule yields Q near 1.3, broader than every room
    // mode worth correcting, so the fit can only offer a gentle wide cut where
    // the measurement wants a narrow deep one.  On the acceptance corpus that
    // cost about a decibel of reliability-weighted error against a free search
    // on the modal fixtures.
    //
    // The reference parallel designer leaves this off: at thirty-two sections
    // Bank's rule is the correct one, and it is what the comparison is about.
    bool qFromFeatureWidth = true;

    QLimits qLimits;
};

// Section centres and Qs, lowest frequency first.
struct SectionPlacement {
    std::vector<double> freqHz;
    std::vector<double> q;

    // False when the error curve carried no usable energy and the placement
    // fell back to uniform log spacing.  Not an error: it is the right answer
    // for an already-flat measurement, and worth reporting rather than hiding.
    bool energyDriven = false;

    std::size_t size() const { return freqHz.size(); }
};

// Place `config.count` sections against a weighted error curve.
//
// `errorDb` is the correction the room wants, target minus measured, and
// `weight` is the mask times the position weighting.  Both are on `grid`.
// Deterministic and computed once per fit.
SectionPlacement placeSections(const FrequencyGrid& grid,
                               const std::vector<double>& errorDb,
                               const std::vector<double>& weight,
                               const PlacementConfig& config);

}  // namespace dspi_rc
