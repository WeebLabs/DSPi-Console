#include "dspi_rc/poles.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

double clampd(double v, double lo, double hi) { return std::max(lo, std::min(hi, v)); }

// A greedy pick is only a feature if it carries this fraction of the strongest
// one's energy.  Energy is squared error, so 4% is a fifth of the amplitude.
constexpr double kFeatureFloor = 0.04;

// Box smoothing in log frequency, so one noisy bin cannot claim a section.
// A sixth of an octave is narrow enough to keep a genuine mode intact and wide
// enough that grid noise stops looking like a feature.
std::vector<double> smoothLog(const std::vector<double>& values, double pointsPerOctave) {
    const auto half = static_cast<std::ptrdiff_t>(std::round(pointsPerOctave / 12.0));
    if (half <= 0) return values;

    std::vector<double> out(values.size(), 0.0);
    const auto n = static_cast<std::ptrdiff_t>(values.size());
    for (std::ptrdiff_t i = 0; i < n; ++i) {
        double sum = 0.0;
        double count = 0.0;
        for (std::ptrdiff_t j = i - half; j <= i + half; ++j) {
            if (j < 0 || j >= n) continue;
            sum += values[static_cast<std::size_t>(j)];
            count += 1.0;
        }
        out[static_cast<std::size_t>(i)] = count > 0.0 ? sum / count : 0.0;
    }
    return out;
}

// Bandwidth in octaves to Q, the standard relation.
double qForOctaves(double octaves) {
    const double ratio = std::pow(2.0, std::max(1e-4, octaves));
    return std::sqrt(ratio) / (ratio - 1.0);
}

// Width of the error feature under a centre, in octaves, measured at half its
// depth and bounded by the nearest sign change.
//
// Half depth rather than a fixed fraction of an octave, because that is the
// same definition the Q relation above uses, so a filter given this width will
// sit on the feature rather than merely near it.  The sign change matters as
// much as the half-depth crossing: a cut placed on a peak must not widen into
// the dip beside it, which is exactly how a broad correction turns one problem
// into two.
//
// Returns 0 when there is no usable feature, and the caller falls back to the
// spacing rule.
double featureOctaves(const std::vector<double>& logF,
                      const std::vector<double>& errorDb,
                      std::size_t index) {
    if (index >= errorDb.size() || logF.size() != errorDb.size()) return 0.0;

    const double peak = errorDb[index];
    if (std::fabs(peak) < 0.25) return 0.0;   // nothing here worth sizing
    const double half = 0.5 * std::fabs(peak);
    const double sign = peak > 0.0 ? 1.0 : -1.0;

    double lowEdge = logF.front();
    for (std::size_t i = index; i > 0; --i) {
        const double value = errorDb[i - 1] * sign;
        if (value < half) { lowEdge = logF[i - 1]; break; }
        lowEdge = logF[i - 1];
    }

    double highEdge = logF.back();
    for (std::size_t i = index + 1; i < errorDb.size(); ++i) {
        const double value = errorDb[i] * sign;
        if (value < half) { highEdge = logF[i]; break; }
        highEdge = logF[i];
    }

    return (highEdge - lowEdge) / std::log(2.0);
}

}  // namespace

double cutQLimit(double freqHz, const QLimits& limits) {
    if (freqHz <= limits.transitionHz) return limits.maxCutQBelowTransition;
    constexpr double kTopHz = 10000.0;
    if (limits.transitionHz <= 0.0 || kTopHz <= limits.transitionHz) {
        return limits.maxCutQAtTop;
    }
    const double fraction = clampd(
        std::log(freqHz / limits.transitionHz) / std::log(kTopHz / limits.transitionHz), 0.0, 1.0);
    return limits.maxCutQBelowTransition +
           fraction * (limits.maxCutQAtTop - limits.maxCutQBelowTransition);
}

SectionPlacement placeSections(const FrequencyGrid& grid,
                               const std::vector<double>& errorDb,
                               const std::vector<double>& weight,
                               const PlacementConfig& config) {
    SectionPlacement placement;
    const int count = config.count;
    if (count <= 0 || grid.empty()) return placement;

    const double lo = std::max(config.minFreqHz, grid.hz.front());
    const double hi = std::min(config.maxFreqHz, grid.hz.back());
    if (!(hi > lo)) return placement;

    const double logLo = std::log(lo);
    const double logHi = std::log(hi);

    // In-band grid points, with their weighted error energy and the error
    // itself.  The error is kept unsmoothed: it sizes the features, and
    // smoothing it would widen every mode before the Q rule could measure one.
    std::vector<double> logF;
    std::vector<double> energy;
    std::vector<double> error;
    logF.reserve(grid.size());
    energy.reserve(grid.size());
    error.reserve(grid.size());
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double f = grid.hz[i];
        if (f < lo || f > hi) continue;
        const double e = i < errorDb.size() ? errorDb[i] : 0.0;
        const double w = i < weight.size() ? std::max(0.0, weight[i]) : 1.0;
        logF.push_back(std::log(f));
        energy.push_back(w * e * e);
        // Masked-out bins carry no feature, so a section placed at the edge of
        // the correctable band does not size itself on what lies beyond it.
        error.push_back(w > 0.0 ? e : 0.0);
    }

    energy = smoothLog(energy, grid.pointsPerOctave());

    // Cumulative energy in log frequency: equal increments of this are equal
    // shares of the problem, which is what one section should be worth.
    std::vector<double> cumulative(logF.size(), 0.0);
    for (std::size_t i = 1; i < logF.size(); ++i) {
        cumulative[i] = cumulative[i - 1] +
                        0.5 * (energy[i] + energy[i - 1]) * (logF[i] - logF[i - 1]);
    }
    const double total = cumulative.empty() ? 0.0 : cumulative.back();
    const bool usable = total > 1e-9 && logF.size() >= 2;
    placement.energyDriven = usable;

    // Split the budget between sections aimed at measured features and sections
    // that simply cover the band.
    const double bias = usable ? clampd(config.placementBias, 0.0, 1.0) : 1.0;
    const auto coverageCount = static_cast<int>(std::lround(bias * count));
    const int featureCount = count - coverageCount;

    std::vector<double> centres;
    centres.reserve(static_cast<std::size_t>(count));

    // Features first, greedily, strongest first.
    //
    // Deliberately not the equal-cumulative-energy quantiles this started as.
    // Quantiles are the right instinct with thirty sections and the wrong one
    // with ten: an isolated narrow mode makes the cumulative curve jump, so the
    // quantile boundaries land on the *edges* of the feature rather than on it.
    // On the modal fixture that put sections at 58 and 124 Hz for modes at 48
    // and 118 Hz - each about a full feature-width off centre, which for a
    // quarter-octave mode is as good as missing it.
    if (featureCount > 0) {
        std::vector<double> remaining = energy;
        double strongest = 0.0;
        for (int placed = 0; placed < featureCount; ++placed) {
            std::size_t peak = remaining.size();
            double best = 0.0;
            for (std::size_t i = 0; i < remaining.size(); ++i) {
                if (remaining[i] > best) { best = remaining[i]; peak = i; }
            }
            if (peak == remaining.size()) break;   // nothing left worth a section

            if (placed == 0) strongest = best;
            // Stop once what is left is not a feature.  Without this the greedy
            // pass keeps spending slots after the real features are claimed,
            // putting them on whatever noise the suppression left behind, and
            // those slots do worse than the even coverage they displaced: on
            // the modal fixture, six greedy picks scored 0.91 dB where two
            // picks and six coverage slots scored 0.18.
            if (best < kFeatureFloor * strongest) break;

            centres.push_back(logF[peak]);

            // Suppress the feature just claimed, over its own width, so the
            // next pick goes to a different problem rather than to the same
            // one's shoulder.
            const double width = featureOctaves(logF, error, peak);
            const double halfSpan =
                0.5 * std::max(width, config.minSpacingOctaves * 2.0) * std::log(2.0);
            for (std::size_t i = 0; i < remaining.size(); ++i) {
                if (std::fabs(logF[i] - logF[peak]) <= halfSpan) remaining[i] = 0.0;
            }
        }
    }

    // Fill the rest by bisecting the widest remaining gap, which gives even
    // coverage of whatever the features did not claim without any slot landing
    // on top of one that did.
    if (centres.empty()) {
        // Pure log spacing, optionally weighted toward the bottom of the band.
        const double lowShare = clampd(config.logDensityLowShare, 0.0, 1.0);
        const double logBreak = std::log(clampd(config.logDensityBreakHz, lo, hi));

        const auto lowCount = static_cast<int>(std::lround(lowShare * count));
        const int highCount = count - lowCount;

        for (int i = 0; i < lowCount; ++i) {
            const double t = (static_cast<double>(i) + 0.5) / static_cast<double>(lowCount);
            centres.push_back(logLo + t * (logBreak - logLo));
        }
        for (int i = 0; i < highCount; ++i) {
            const double t = (static_cast<double>(i) + 0.5) / static_cast<double>(highCount);
            const double from = lowCount > 0 ? logBreak : logLo;
            centres.push_back(from + t * (logHi - from));
        }
    } else {
        while (centres.size() < static_cast<std::size_t>(count)) {
            std::sort(centres.begin(), centres.end());

            double widest = 0.0;
            double insertAt = 0.5 * (logLo + logHi);
            const double firstGap = centres.front() - logLo;
            if (firstGap > widest) { widest = firstGap; insertAt = 0.5 * (logLo + centres.front()); }
            for (std::size_t i = 1; i < centres.size(); ++i) {
                const double gap = centres[i] - centres[i - 1];
                if (gap > widest) { widest = gap; insertAt = 0.5 * (centres[i - 1] + centres[i]); }
            }
            const double lastGap = logHi - centres.back();
            if (lastGap > widest) { widest = lastGap; insertAt = 0.5 * (centres.back() + logHi); }

            centres.push_back(insertAt);
        }
    }

    std::sort(centres.begin(), centres.end());

    // Minimum separation.  When the band cannot hold `count` sections at the
    // requested spacing the request is impossible rather than merely tight, so
    // spread them uniformly and let the solve deal with the overlap.
    const double minSeparation = std::max(0.0, config.minSpacingOctaves) * std::log(2.0);
    if (minSeparation * static_cast<double>(count - 1) >= (logHi - logLo)) {
        for (int i = 0; i < count; ++i) {
            const double t = count > 1 ? static_cast<double>(i) / static_cast<double>(count - 1) : 0.5;
            centres[static_cast<std::size_t>(i)] = logLo + t * (logHi - logLo);
        }
    } else {
        for (std::size_t i = 1; i < centres.size(); ++i) {
            centres[i] = std::max(centres[i], centres[i - 1] + minSeparation);
        }
        // The forward pass can push the top section past the band, so walk back
        // down and re-open the spacing from the ceiling.
        centres.back() = std::min(centres.back(), logHi);
        for (std::size_t step = centres.size() - 1; step > 0; --step) {
            const std::size_t i = step - 1;
            centres[i] = std::min(centres[i], centres[i + 1] - minSeparation);
        }
        for (double& c : centres) c = clampd(c, logLo, logHi);
    }

    placement.freqHz.reserve(centres.size());
    for (double c : centres) placement.freqHz.push_back(std::exp(c));

    placement.q.resize(placement.freqHz.size());
    for (std::size_t i = 0; i < placement.freqHz.size(); ++i) {
        // Spacing width, so adjacent sections meet near their half-power points
        // and the bank can represent a smooth curve without ripple.  This is
        // Bank's rule, and it is the fallback wherever there is no feature to
        // measure.
        double octaves;
        if (placement.freqHz.size() == 1) {
            octaves = std::min(2.0, (logHi - logLo) / std::log(2.0));
        } else if (i == 0) {
            octaves = (centres[1] - centres[0]) / std::log(2.0);
        } else if (i + 1 == placement.freqHz.size()) {
            octaves = (centres[i] - centres[i - 1]) / std::log(2.0);
        } else {
            octaves = 0.5 * (centres[i + 1] - centres[i - 1]) / std::log(2.0);
        }

        if (config.qFromFeatureWidth && !logF.empty()) {
            const auto nearest = std::lower_bound(logF.begin(), logF.end(), centres[i]);
            std::size_t index = static_cast<std::size_t>(nearest - logF.begin());
            if (index >= logF.size()) index = logF.size() - 1;
            if (index > 0 && (centres[i] - logF[index - 1]) < (logF[index] - centres[i])) --index;

            const double measured = featureOctaves(logF, error, index);
            if (measured > 0.0) octaves = measured;
        }

        const double ceiling = std::min(cutQLimit(placement.freqHz[i], config.qLimits),
                                        static_cast<double>(FirmwareLimits::maxQ));
        placement.q[i] = clampd(qForOctaves(octaves), config.qLimits.minQ, ceiling);
    }

    return placement;
}

}  // namespace dspi_rc
