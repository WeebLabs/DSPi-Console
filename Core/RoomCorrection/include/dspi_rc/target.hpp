// Target curve construction.
//
// The user-facing model is the one mature room-correction tools converged on:
// a tilt, a bass adjustment, a treble adjustment, and a pair of curtains
// bounding where correction is allowed at all.  Those four controls cover
// almost every request, and the expert escape hatch is a list of free-form
// anchor points for the house curve that does not fit them.
//
// A target is *not* a filter.  It is an arbitrary curve, so the shelves here
// are smooth log-frequency transitions rather than biquad shelves; tying the
// target's shape to the correction's shape family would be an odd constraint
// with no acoustic justification.
//
// Spec §5.7.
#pragma once

#include <string>
#include <vector>

#include "dspi_rc/types.hpp"

namespace dspi_rc {

// A user-placed point on the curve.  Anchors are additive on top of the macro
// controls, so adding one does not discard the tilt the user already dialled.
struct TargetAnchor {
    double freqHz = 1000.0;
    double gainDb = 0.0;
};

struct TargetSpec {
    // Broadband tilt, pivoting at `pivotHz` so adjusting it does not also
    // change overall level.  A gentle downward in-room trend is the usual
    // starting point; flat measures flat and sounds bright.
    double tiltDbPerOctave = -0.8;
    double pivotHz = 1000.0;

    // Bass and treble adjustments.  Both may be positive or negative.
    double bassGainDb = 0.0;
    double bassTransitionHz = 120.0;
    double trebleGainDb = 0.0;
    double trebleTransitionHz = 4000.0;

    // How abruptly the shelves turn, in octaves.  Exposed because a "warm but
    // not boomy" target and a "subwoofer shelf" want visibly different knees.
    double shelfWidthOctaves = 1.5;

    // Vertical offset.  `chooseAutoLevel` picks this to minimize required
    // boost; the user can override.
    double levelDb = 0.0;

    // Correction range.  Outside the curtains the target is still drawn, but
    // no correction is applied, so the curve stays readable while the filters
    // stay bounded.
    double lowCurtainHz = 20.0;
    double highCurtainHz = 20000.0;

    // Additive expert points.
    std::vector<TargetAnchor> anchors;

    std::string validate() const;
};

// Named starting points.  These are ordinary editable control values, not
// special algorithm modes: choosing one and then dragging a handle must not
// feel like leaving a supported path.
TargetSpec presetFlat();
TargetSpec presetNatural();   // gentle downward tilt, the default
TargetSpec presetStudio();    // shallower tilt, no bass lift
TargetSpec presetBassWarm();  // natural tilt plus a low shelf

// Evaluate the target on a grid.
std::vector<double> buildTarget(const FrequencyGrid& grid, const TargetSpec& spec);

// ---------------------------------------------------------------------------
// Native bandwidth
// ---------------------------------------------------------------------------

// The band over which a speaker is actually producing output.
struct NativeBandwidth {
    double lowHz = 20.0;
    double highHz = 20000.0;
    bool lowDetected = false;
    bool highDetected = false;
};

// Find where the measured response falls away from its own in-band level.
//
// Correction must not try to extend a speaker past its roll-off: demanding
// boost below a sealed box's corner buys distortion and excursion, not bass,
// and the optimizer will happily spend its entire boost budget doing it.  The
// threshold is measured against the response's own mid-band level rather than
// an absolute, since the measurement is not calibrated to SPL.
NativeBandwidth estimateNativeBandwidth(const FrequencyGrid& grid,
                                        const std::vector<double>& magnitudesDb,
                                        double rolloffThresholdDb = 10.0);

// ---------------------------------------------------------------------------
// Level placement
// ---------------------------------------------------------------------------

// Choose the vertical offset that minimizes the boost the correction will need.
//
// With a cut-only policy the whole correction is pinned by its highest point,
// so where the target sits vertically decides how much attenuation the channel
// takes.  Placing it against the measured response's upper envelope inside the
// correctable band gets most of the level back.
double chooseAutoLevel(const FrequencyGrid& grid,
                       const std::vector<double>& measuredDb,
                       const TargetSpec& spec,
                       const NativeBandwidth& native);

// ---------------------------------------------------------------------------
// Correction weighting
// ---------------------------------------------------------------------------

struct CorrectionMask {
    // Per-bin weight in [0, 1] for how much the optimizer should care.
    std::vector<double> weight;
    // Per-bin ceiling on positive correction, in dB.  Zero means cut-only at
    // that frequency.
    std::vector<double> boostCeilingDb;
};

struct MaskConfig {
    // Width of the taper at each curtain, in octaves.  A hard edge would put a
    // step in the error curve and the optimizer would place a filter on it.
    double curtainTaperOctaves = 0.5;
    // Boost allowed where the measurement is fully trusted.
    double maxBoostDb = 0.0;
    // Reliability below which no boost is permitted at all.
    double boostReliabilityFloor = 0.5;
};

// Combine curtains, native bandwidth and reliability into the weighting the
// optimizer consumes.  Keeping this in one place means the rules about where
// correction is allowed are stated once rather than rediscovered inside the
// fitting loop.
CorrectionMask buildCorrectionMask(const FrequencyGrid& grid,
                                   const TargetSpec& spec,
                                   const NativeBandwidth& native,
                                   const std::vector<double>& reliability,
                                   const MaskConfig& config = {});

}  // namespace dspi_rc
