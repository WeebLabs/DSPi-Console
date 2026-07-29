#include "dspi_rc/target.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

double clampd(double v, double lo, double hi) { return std::max(lo, std::min(hi, v)); }

// Smooth shelf in log frequency, 1 well below the corner and 0 well above.
// tanh rather than a biquad shelf: a target is an arbitrary curve, and tying
// its shape to the correction's shape family would be an odd constraint.
double lowShelfShape(double freqHz, double cornerHz, double widthOctaves) {
    if (freqHz <= 0.0 || cornerHz <= 0.0) return 0.0;
    const double width = std::max(0.1, widthOctaves);
    const double octaves = std::log2(freqHz / cornerHz);
    return 0.5 * (1.0 - std::tanh(2.0 * octaves / width));
}

}  // namespace

// ---------------------------------------------------------------------------

std::string TargetSpec::validate() const {
    if (pivotHz <= 0.0) return "pivot frequency must be positive";
    if (bassTransitionHz <= 0.0 || trebleTransitionHz <= 0.0) {
        return "shelf transition frequencies must be positive";
    }
    if (lowCurtainHz <= 0.0) return "low curtain must be positive";
    if (highCurtainHz <= lowCurtainHz) return "high curtain must be above the low curtain";
    if (shelfWidthOctaves <= 0.0) return "shelf width must be positive";
    if (!std::isfinite(tiltDbPerOctave) || std::fabs(tiltDbPerOctave) > 6.0) {
        return "tilt must be within +/-6 dB per octave";
    }
    for (const TargetAnchor& a : anchors) {
        if (a.freqHz <= 0.0) return "anchor frequencies must be positive";
    }
    return {};
}

TargetSpec presetFlat() {
    TargetSpec spec;
    spec.tiltDbPerOctave = 0.0;
    return spec;
}

TargetSpec presetNatural() {
    // A gentle downward in-room trend.  Flat measures flat and sounds bright,
    // which is why essentially every published in-room target slopes down.
    TargetSpec spec;
    spec.tiltDbPerOctave = -0.8;
    return spec;
}

TargetSpec presetStudio() {
    TargetSpec spec;
    spec.tiltDbPerOctave = -0.4;
    return spec;
}

TargetSpec presetBassWarm() {
    TargetSpec spec;
    spec.tiltDbPerOctave = -0.8;
    spec.bassGainDb = 4.0;
    spec.bassTransitionHz = 100.0;
    spec.shelfWidthOctaves = 2.0;
    return spec;
}

// ---------------------------------------------------------------------------

std::vector<double> buildTarget(const FrequencyGrid& grid, const TargetSpec& spec) {
    std::vector<double> out(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double f = grid.hz[i];
        if (f <= 0.0) continue;

        // Tilt about the pivot, so changing it does not also change level.
        double value = spec.tiltDbPerOctave * std::log2(f / spec.pivotHz);

        value += spec.bassGainDb * lowShelfShape(f, spec.bassTransitionHz, spec.shelfWidthOctaves);
        value += spec.trebleGainDb *
                 (1.0 - lowShelfShape(f, spec.trebleTransitionHz, spec.shelfWidthOctaves));

        value += spec.levelDb;
        out[i] = value;
    }

    // Anchors are additive and interpolated between, so the user's macro
    // controls survive placing one, and eased back to zero beyond the
    // outermost pair so a point is a local edit rather than a global shift.
    if (!spec.anchors.empty()) {
        std::vector<TargetAnchor> sorted = spec.anchors;
        std::sort(sorted.begin(), sorted.end(),
                  [](const TargetAnchor& a, const TargetAnchor& b) { return a.freqHz < b.freqHz; });

        // Raised cosine rather than linear: a kink in the target is a feature
        // the optimizer will happily spend a filter chasing.
        const double taper = std::max(0.05, spec.anchorTaperOctaves);
        const auto ease = [taper](double octavesBeyond) {
            if (octavesBeyond >= taper) return 0.0;
            return 0.5 * (1.0 + std::cos(kPi * octavesBeyond / taper));
        };

        for (std::size_t i = 0; i < grid.size(); ++i) {
            const double f = grid.hz[i];
            double offset;
            if (f <= sorted.front().freqHz) {
                offset = sorted.front().gainDb *
                         ease(std::log2(sorted.front().freqHz / f));
            } else if (f >= sorted.back().freqHz) {
                offset = sorted.back().gainDb * ease(std::log2(f / sorted.back().freqHz));
            } else {
                const auto upper = std::lower_bound(
                    sorted.begin(), sorted.end(), f,
                    [](const TargetAnchor& a, double value) { return a.freqHz < value; });
                const auto lower = upper - 1;
                const double span = std::log(upper->freqHz / lower->freqHz);
                const double t = span > 0.0 ? std::log(f / lower->freqHz) / span : 0.0;
                offset = lower->gainDb + t * (upper->gainDb - lower->gainDb);
            }
            out[i] += offset;
        }
    }

    return out;
}

// ---------------------------------------------------------------------------

NativeBandwidth estimateNativeBandwidth(const FrequencyGrid& grid,
                                        const std::vector<double>& magnitudesDb,
                                        double rolloffThresholdDb) {
    NativeBandwidth native;
    const std::size_t n = std::min(grid.size(), magnitudesDb.size());
    if (n < 8) {
        if (!grid.empty()) {
            native.lowHz = grid.hz.front();
            native.highHz = grid.hz.back();
        }
        return native;
    }

    native.lowHz = grid.hz.front();
    native.highHz = grid.hz[n - 1];

    // Reference level from the middle of the measured band.  Using the median
    // rather than the mean keeps a single large mode from setting the bar.
    std::vector<double> midBand;
    for (std::size_t i = 0; i < n; ++i) {
        if (grid.hz[i] >= 200.0 && grid.hz[i] <= 4000.0) midBand.push_back(magnitudesDb[i]);
    }
    if (midBand.size() < 4) {
        midBand.assign(magnitudesDb.begin(), magnitudesDb.begin() + static_cast<std::ptrdiff_t>(n));
    }
    std::sort(midBand.begin(), midBand.end());
    const double reference = midBand[midBand.size() / 2];
    const double threshold = reference - std::fabs(rolloffThresholdDb);

    // Walk up from the bottom to the first point that climbs above threshold
    // and stays there.  Requiring persistence stops a single noisy bin inside
    // the roll-off from being mistaken for the corner.
    const auto persistence = static_cast<std::size_t>(
        std::max(3.0, std::round(grid.pointsPerOctave() / 6.0)));

    for (std::size_t i = 0; i + persistence < n; ++i) {
        bool sustained = true;
        for (std::size_t k = 0; k < persistence; ++k) {
            if (magnitudesDb[i + k] < threshold) { sustained = false; break; }
        }
        if (sustained) {
            if (i > 0) {
                native.lowHz = grid.hz[i];
                native.lowDetected = true;
            }
            break;
        }
    }

    for (std::size_t i = n; i-- > persistence;) {
        bool sustained = true;
        for (std::size_t k = 0; k < persistence; ++k) {
            if (magnitudesDb[i - k] < threshold) { sustained = false; break; }
        }
        if (sustained) {
            if (i + 1 < n) {
                native.highHz = grid.hz[i];
                native.highDetected = true;
            }
            break;
        }
    }

    if (native.highHz <= native.lowHz) {
        native.lowHz = grid.hz.front();
        native.highHz = grid.hz[n - 1];
        native.lowDetected = false;
        native.highDetected = false;
    }
    return native;
}

// ---------------------------------------------------------------------------

double chooseAutoLevel(const FrequencyGrid& grid,
                       const std::vector<double>& measuredDb,
                       const TargetSpec& spec,
                       const NativeBandwidth& native) {
    const std::size_t n = std::min(grid.size(), measuredDb.size());
    if (n == 0) return 0.0;

    TargetSpec zeroed = spec;
    zeroed.levelDb = 0.0;
    const std::vector<double> shape = buildTarget(grid, zeroed);

    // Differences between the measurement and the un-levelled target shape,
    // inside the band we will actually correct.
    std::vector<double> deltas;
    deltas.reserve(n);
    const double low = std::max(spec.lowCurtainHz, native.lowHz);
    const double high = std::min(spec.highCurtainHz, native.highHz);
    for (std::size_t i = 0; i < n; ++i) {
        if (grid.hz[i] < low || grid.hz[i] > high) continue;
        deltas.push_back(measuredDb[i] - shape[i]);
    }
    if (deltas.empty()) return 0.0;

    // Place the target near the *lower* envelope of the measurement.
    //
    // The direction matters and is easy to get backwards.  The correction is
    // `target - measured`, so a target above the measurement demands boost and
    // a target below it demands cuts.  Under a cut-only policy the target must
    // therefore sit low enough that almost the whole band can be brought down
    // to it; a target at the upper envelope would need boost everywhere and
    // the fit would come out worse than no correction at all.
    //
    // Not the minimum, though: a single deep null would drag the level down
    // and force the whole channel to be cut to match a hole nobody sits in.  A
    // low percentile leaves the dips alone (the boost mask declines to fill
    // them anyway) while the peaks get cut.
    std::sort(deltas.begin(), deltas.end());
    const auto index = static_cast<std::size_t>(
        clampd(std::round(0.20 * static_cast<double>(deltas.size() - 1)), 0.0,
               static_cast<double>(deltas.size() - 1)));
    return deltas[index];
}

// ---------------------------------------------------------------------------

CorrectionMask buildCorrectionMask(const FrequencyGrid& grid,
                                   const TargetSpec& spec,
                                   const NativeBandwidth& native,
                                   const std::vector<double>& reliability,
                                   const MaskConfig& config) {
    CorrectionMask mask;
    mask.weight.assign(grid.size(), 0.0);
    mask.boostCeilingDb.assign(grid.size(), 0.0);

    const double taper = std::max(0.05, config.curtainTaperOctaves);

    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double f = grid.hz[i];
        if (f <= 0.0) continue;

        // Taper in from each curtain rather than stepping.  A hard edge puts a
        // discontinuity in the error curve and the optimizer places a filter
        // on it, producing a correction that is an artifact of the boundary.
        double weight = 1.0;
        const double belowLow = std::log2(spec.lowCurtainHz / f);
        if (belowLow > 0.0) weight *= clampd(1.0 - belowLow / taper, 0.0, 1.0);
        const double aboveHigh = std::log2(f / spec.highCurtainHz);
        if (aboveHigh > 0.0) weight *= clampd(1.0 - aboveHigh / taper, 0.0, 1.0);

        // Taper outside the speaker's own passband as well.  Without this the
        // optimizer scores error in the roll-off, where the "error" is just the
        // speaker running out, and spends filters chasing it.
        const double belowNative = std::log2(native.lowHz / f);
        if (belowNative > 0.0) weight *= clampd(1.0 - belowNative / taper, 0.0, 1.0);
        const double aboveNative = std::log2(f / native.highHz);
        if (aboveNative > 0.0) weight *= clampd(1.0 - aboveNative / taper, 0.0, 1.0);

        const double reliabilityHere =
            i < reliability.size() ? clampd(reliability[i], 0.0, 1.0) : 1.0;
        weight *= reliabilityHere;
        mask.weight[i] = weight;

        // Boost is permitted only inside the speaker's own passband and only
        // where the positions agree.  Outside the native band, boost buys
        // excursion and distortion rather than output.
        const bool insideNative = (f >= native.lowHz && f <= native.highHz);
        const bool trusted = reliabilityHere >= config.boostReliabilityFloor;
        mask.boostCeilingDb[i] =
            (insideNative && trusted) ? std::max(0.0, config.maxBoostDb) : 0.0;
    }

    return mask;
}

}  // namespace dspi_rc
