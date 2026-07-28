#include "dspi_rc/analysis.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

double clampd(double v, double lo, double hi) { return std::max(lo, std::min(hi, v)); }

// Interpolate a value that is piecewise-linear in log frequency between three
// breakpoints.  Used for both the smoothing schedule and the window schedule,
// which want the same shape: constant below, constant above, ramp between.
double scheduleAt(double freqHz, double lowHz, double lowValue,
                  double midHz, double midValue,
                  double highHz, double highValue) {
    if (freqHz <= lowHz) return lowValue;
    if (freqHz >= highHz) return highValue;
    if (freqHz <= midHz) {
        const double span = std::log(midHz / lowHz);
        if (span <= 0.0) return midValue;
        const double t = std::log(freqHz / lowHz) / span;
        return lowValue + t * (midValue - lowValue);
    }
    const double span = std::log(highHz / midHz);
    if (span <= 0.0) return highValue;
    const double t = std::log(freqHz / midHz) / span;
    return midValue + t * (highValue - midValue);
}

std::vector<double> enabledWeights(const std::vector<PositionMeasurement>& positions) {
    std::vector<double> weights;
    weights.reserve(positions.size());
    double total = 0.0;
    for (const PositionMeasurement& p : positions) {
        const double w = (p.enabled && p.weight > 0.0) ? p.weight : 0.0;
        weights.push_back(w);
        total += w;
    }
    if (total > 0.0) {
        for (double& w : weights) w /= total;
    }
    return weights;
}

double weightedMedianAt(const std::vector<PositionMeasurement>& positions,
                        const std::vector<double>& weights,
                        std::size_t bin) {
    std::vector<std::pair<double, double>> pairs;  // value, weight
    pairs.reserve(positions.size());
    double total = 0.0;
    for (std::size_t i = 0; i < positions.size(); ++i) {
        if (weights[i] <= 0.0) continue;
        if (bin >= positions[i].magnitudesDb.size()) continue;
        pairs.emplace_back(positions[i].magnitudesDb[bin], weights[i]);
        total += weights[i];
    }
    if (pairs.empty()) return 0.0;
    std::sort(pairs.begin(), pairs.end());
    double running = 0.0;
    for (const auto& pair : pairs) {
        running += pair.second;
        if (running >= 0.5 * total) return pair.first;
    }
    return pairs.back().first;
}

double weightedMedianOf(std::vector<std::pair<double, double>> pairs) {
    if (pairs.empty()) return 0.0;
    std::sort(pairs.begin(), pairs.end());
    double total = 0.0;
    for (const auto& p : pairs) total += p.second;
    double running = 0.0;
    for (const auto& p : pairs) {
        running += p.second;
        if (running >= 0.5 * total) return p.first;
    }
    return pairs.back().first;
}

}  // namespace

// ---------------------------------------------------------------------------
// Windowing
// ---------------------------------------------------------------------------

std::vector<double> frequencyDependentWindowedResponse(const std::vector<double>& impulse,
                                                       double sampleRateHz,
                                                       std::size_t peakIndex,
                                                       const FrequencyGrid& grid,
                                                       const WindowingConfig& config) {
    std::vector<double> out(grid.size(), 0.0);
    if (impulse.empty() || grid.empty() || sampleRateHz <= 0.0) return out;

    // The window length varies continuously with frequency, but recomputing an
    // FFT per grid point would be gratuitous.  Group the grid into a modest
    // number of window lengths and evaluate each group's DFT directly at its
    // own frequencies: the number of output points is small, so a direct
    // evaluation beats an FFT per group.
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double f = grid.hz[i];
        if (f <= 0.0) continue;

        double windowSeconds;
        if (f <= config.transitionHz) {
            // Below the transition, open toward the whole measurement: modal
            // decay and room gain are what the listener actually experiences.
            windowSeconds = static_cast<double>(impulse.size()) / sampleRateHz;
        } else {
            windowSeconds = std::max(config.minimumWindowSeconds, config.cycles / f);
        }

        const auto halfLength =
            static_cast<std::size_t>(std::llround(windowSeconds * sampleRateHz));
        if (halfLength == 0) continue;

        const std::size_t start = peakIndex > halfLength ? peakIndex - halfLength : 0;
        const std::size_t end = std::min(impulse.size(), peakIndex + halfLength);
        if (end <= start) continue;
        const std::size_t length = end - start;

        // Half-Hann taper on each side of the peak, so truncation does not
        // ring.  A rectangular cut would leak the discontinuity across the
        // spectrum and look like real response detail.
        double realPart = 0.0;
        double imagPart = 0.0;
        const double omega = 2.0 * kPi * f / sampleRateHz;
        for (std::size_t n = 0; n < length; ++n) {
            const std::size_t index = start + n;
            const double distance =
                std::fabs(static_cast<double>(index) - static_cast<double>(peakIndex));
            const double normalized = distance / static_cast<double>(halfLength);
            if (normalized >= 1.0) continue;
            const double taper = 0.5 * (1.0 + std::cos(kPi * normalized));
            const double sample = impulse[index] * taper;
            const double phase = omega * static_cast<double>(index);
            realPart += sample * std::cos(phase);
            imagPart -= sample * std::sin(phase);
        }
        const double magnitude = std::sqrt(realPart * realPart + imagPart * imagPart);
        out[i] = 20.0 * std::log10(std::max(magnitude, 1e-30));
    }
    return out;
}

// ---------------------------------------------------------------------------
// Smoothing
// ---------------------------------------------------------------------------

SmoothingConfig SmoothingConfig::forTransition(double transitionHz) {
    SmoothingConfig config;
    const double safe = clampd(transitionHz, 40.0, 600.0);
    // Anchor the schedule to the room's own transition rather than to fixed
    // absolutes: the point of estimating it is to use it.
    config.lowBreakHz = safe * 0.5;
    config.midBreakHz = safe * 5.0;
    config.highBreakHz = safe * 50.0;
    return config;
}

std::vector<double> smoothFractionalOctave(const FrequencyGrid& grid,
                                           const std::vector<double>& magnitudesDb,
                                           double fractionDenominator) {
    const std::size_t n = std::min(grid.size(), magnitudesDb.size());
    std::vector<double> out(n, 0.0);
    if (n == 0 || fractionDenominator <= 0.0) return out;

    const double pointsPerOctave = grid.pointsPerOctave();
    if (pointsPerOctave <= 0.0) return magnitudesDb;

    // Full width of the smoothing window in grid points.
    const double widthPoints = pointsPerOctave / fractionDenominator;
    const auto halfWidth = static_cast<std::ptrdiff_t>(std::max(0.0, std::round(widthPoints / 2.0)));

    for (std::size_t i = 0; i < n; ++i) {
        if (halfWidth == 0) { out[i] = magnitudesDb[i]; continue; }
        const auto centre = static_cast<std::ptrdiff_t>(i);
        const std::ptrdiff_t first = std::max<std::ptrdiff_t>(0, centre - halfWidth);
        const std::ptrdiff_t last =
            std::min<std::ptrdiff_t>(static_cast<std::ptrdiff_t>(n) - 1, centre + halfWidth);

        // Hann-weighted mean.  A rectangular mean produces visible plateaus at
        // sharp features, which then seed filters at the wrong frequency.
        double sum = 0.0;
        double weightSum = 0.0;
        for (std::ptrdiff_t j = first; j <= last; ++j) {
            const double offset = static_cast<double>(j - centre) / static_cast<double>(halfWidth);
            const double weight = 0.5 * (1.0 + std::cos(kPi * clampd(offset, -1.0, 1.0)));
            sum += magnitudesDb[static_cast<std::size_t>(j)] * weight;
            weightSum += weight;
        }
        out[i] = weightSum > 0.0 ? sum / weightSum : magnitudesDb[i];
    }
    return out;
}

std::vector<double> smoothVariable(const FrequencyGrid& grid,
                                   const std::vector<double>& magnitudesDb,
                                   const SmoothingConfig& config) {
    const std::size_t n = std::min(grid.size(), magnitudesDb.size());
    std::vector<double> out(n, 0.0);
    if (n == 0) return out;

    const double pointsPerOctave = grid.pointsPerOctave();
    if (pointsPerOctave <= 0.0) return magnitudesDb;

    for (std::size_t i = 0; i < n; ++i) {
        // Interpolate the *denominator* in log space: 1/48 to 1/6 to 1/3.
        const double denominator = scheduleAt(grid.hz[i],
                                              config.lowBreakHz, config.lowFractionDenominator,
                                              config.midBreakHz, config.midFractionDenominator,
                                              config.highBreakHz, config.highFractionDenominator);
        const double widthPoints = pointsPerOctave / std::max(0.5, denominator);
        const auto halfWidth =
            static_cast<std::ptrdiff_t>(std::max(0.0, std::round(widthPoints / 2.0)));
        if (halfWidth == 0) { out[i] = magnitudesDb[i]; continue; }

        const auto centre = static_cast<std::ptrdiff_t>(i);
        const std::ptrdiff_t first = std::max<std::ptrdiff_t>(0, centre - halfWidth);
        const std::ptrdiff_t last =
            std::min<std::ptrdiff_t>(static_cast<std::ptrdiff_t>(n) - 1, centre + halfWidth);

        double sum = 0.0;
        double weightSum = 0.0;
        for (std::ptrdiff_t j = first; j <= last; ++j) {
            const double offset = static_cast<double>(j - centre) / static_cast<double>(halfWidth);
            const double weight = 0.5 * (1.0 + std::cos(kPi * clampd(offset, -1.0, 1.0)));
            sum += magnitudesDb[static_cast<std::size_t>(j)] * weight;
            weightSum += weight;
        }
        out[i] = weightSum > 0.0 ? sum / weightSum : magnitudesDb[i];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Transition frequency
// ---------------------------------------------------------------------------

double estimateTransitionFrequency(const FrequencyGrid& grid,
                                   const std::vector<PositionMeasurement>& positions,
                                   const StatisticsConfig& config,
                                   bool& estimated) {
    estimated = false;

    const std::vector<double> weights = enabledWeights(positions);
    std::size_t active = 0;
    for (double w : weights) if (w > 0.0) ++active;
    // One position cannot distinguish a room mode from a cancellation, so
    // there is nothing to estimate from.
    if (active < 2 || grid.size() < 8) return config.transitionFallbackHz;

    // Weighted spread across positions, per bin.
    std::vector<double> spread(grid.size(), 0.0);
    for (std::size_t bin = 0; bin < grid.size(); ++bin) {
        double mean = 0.0;
        for (std::size_t p = 0; p < positions.size(); ++p) {
            if (weights[p] <= 0.0 || bin >= positions[p].magnitudesDb.size()) continue;
            mean += weights[p] * positions[p].magnitudesDb[bin];
        }
        double variance = 0.0;
        for (std::size_t p = 0; p < positions.size(); ++p) {
            if (weights[p] <= 0.0 || bin >= positions[p].magnitudesDb.size()) continue;
            const double delta = positions[p].magnitudesDb[bin] - mean;
            variance += weights[p] * delta * delta;
        }
        spread[bin] = std::sqrt(std::max(0.0, variance));
    }

    // Smooth the spread so a single noisy bin cannot define the transition.
    const double pointsPerOctave = grid.pointsPerOctave();
    const auto smoothWidth =
        static_cast<std::ptrdiff_t>(std::max(2.0, std::round(pointsPerOctave / 6.0)));
    std::vector<double> smoothSpread(grid.size(), 0.0);
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const auto centre = static_cast<std::ptrdiff_t>(i);
        const std::ptrdiff_t first = std::max<std::ptrdiff_t>(0, centre - smoothWidth);
        const std::ptrdiff_t last = std::min<std::ptrdiff_t>(
            static_cast<std::ptrdiff_t>(grid.size()) - 1, centre + smoothWidth);
        double sum = 0.0;
        for (std::ptrdiff_t j = first; j <= last; ++j) sum += spread[static_cast<std::size_t>(j)];
        smoothSpread[i] = sum / static_cast<double>(last - first + 1);
    }

    // Search the candidate band for the steepest rise in spread against log
    // frequency.  Below the transition spread is low and slowly varying;
    // above it, it climbs.
    std::vector<std::size_t> candidates;
    for (std::size_t i = 0; i < grid.size(); ++i) {
        if (grid.hz[i] >= config.transitionSearchLowHz &&
            grid.hz[i] <= config.transitionSearchHighHz) {
            candidates.push_back(i);
        }
    }
    if (candidates.size() < 7) return config.transitionFallbackHz;

    double minSpread = smoothSpread[candidates.front()];
    double maxSpread = minSpread;
    for (std::size_t i : candidates) {
        minSpread = std::min(minSpread, smoothSpread[i]);
        maxSpread = std::max(maxSpread, smoothSpread[i]);
    }
    // A room whose spread barely moves across the candidate band has no
    // detectable transition; say so rather than inventing one from noise.
    if (maxSpread - minSpread < 0.75) return config.transitionFallbackHz;

    double bestGradient = -1e30;
    std::size_t bestIndex = candidates[candidates.size() / 2];
    // Skip the first and last couple of candidates so the gradient has support
    // on both sides.
    for (std::size_t k = 2; k + 2 < candidates.size(); ++k) {
        const std::size_t i = candidates[k];
        const std::size_t before = candidates[k - 2];
        const std::size_t after = candidates[k + 2];
        const double deltaOctaves = std::log2(grid.hz[after] / grid.hz[before]);
        if (deltaOctaves <= 0.0) continue;
        const double gradient = (smoothSpread[after] - smoothSpread[before]) / deltaOctaves;
        if (gradient > bestGradient) {
            bestGradient = gradient;
            bestIndex = i;
        }
    }

    estimated = true;
    return clampd(grid.hz[bestIndex], 100.0, 400.0);
}

// ---------------------------------------------------------------------------
// Spatial statistics
// ---------------------------------------------------------------------------

SpatialStatistics computeSpatialStatistics(const FrequencyGrid& grid,
                                           const std::vector<PositionMeasurement>& positions,
                                           const std::vector<double>& targetDb,
                                           const StatisticsConfig& config) {
    SpatialStatistics stats;
    const std::size_t n = grid.size();
    stats.powerAverageDb.assign(n, 0.0);
    stats.medianDb.assign(n, 0.0);
    stats.madDb.assign(n, 0.0);
    stats.signAgreement.assign(n, 0.0);
    stats.reliability.assign(n, 1.0);
    stats.transitionHz = config.transitionFallbackHz;
    if (n == 0 || positions.empty()) return stats;

    const std::vector<double> weights = enabledWeights(positions);
    double totalWeight = 0.0;
    for (double w : weights) totalWeight += w;
    if (totalWeight <= 0.0) return stats;

    for (std::size_t bin = 0; bin < n; ++bin) {
        // Power-domain average.  See the header for why this is not a dB mean.
        double power = 0.0;
        for (std::size_t p = 0; p < positions.size(); ++p) {
            if (weights[p] <= 0.0 || bin >= positions[p].magnitudesDb.size()) continue;
            power += weights[p] * std::pow(10.0, positions[p].magnitudesDb[bin] / 10.0);
        }
        stats.powerAverageDb[bin] = 10.0 * std::log10(std::max(power, 1e-30));

        stats.medianDb[bin] = weightedMedianAt(positions, weights, bin);

        std::vector<std::pair<double, double>> deviations;
        deviations.reserve(positions.size());
        for (std::size_t p = 0; p < positions.size(); ++p) {
            if (weights[p] <= 0.0 || bin >= positions[p].magnitudesDb.size()) continue;
            deviations.emplace_back(
                std::fabs(positions[p].magnitudesDb[bin] - stats.medianDb[bin]), weights[p]);
        }
        stats.madDb[bin] = weightedMedianOf(std::move(deviations));
    }

    // Sign agreement needs a target to define which way the error points.  A
    // flat pseudo-target is a reasonable stand-in when none is supplied, since
    // only the *direction* matters here.
    const bool haveTarget = targetDb.size() >= n;
    for (std::size_t bin = 0; bin < n; ++bin) {
        const double target = haveTarget ? targetDb[bin] : stats.powerAverageDb[bin];
        const double desired = target - stats.powerAverageDb[bin];

        // Deadband, in dB, below which there is no correction worth disputing.
        constexpr double kDeadbandDb = 0.25;

        if (std::fabs(desired) <= kDeadbandDb) {
            // The average already meets the target here, so no filter will be
            // placed and there is nothing for the positions to disagree about.
            // Scoring this as zero agreement would be perverse: it would mark
            // the regions that are already correct as the least trustworthy,
            // and then de-weight them in the optimizer, licensing it to
            // overshoot through a part of the band that was fine.
            stats.signAgreement[bin] = 1.0;
        } else {
            const double direction = (desired > 0.0) ? 1.0 : -1.0;
            double agreeing = 0.0;
            for (std::size_t p = 0; p < positions.size(); ++p) {
                if (weights[p] <= 0.0 || bin >= positions[p].magnitudesDb.size()) continue;
                const double individual = target - positions[p].magnitudesDb[bin];
                // A position already at target is not "agreeing": correcting
                // in the average's direction would actively move it away.
                if (individual * direction > kDeadbandDb) agreeing += weights[p];
            }
            stats.signAgreement[bin] = clampd(agreeing, 0.0, 1.0);
        }

        const double spreadPenalty = std::exp(-stats.madDb[bin] / config.spreadToleranceDb);
        stats.reliability[bin] = clampd(stats.signAgreement[bin] * spreadPenalty, 0.05, 1.0);
    }

    stats.transitionHz =
        estimateTransitionFrequency(grid, positions, config, stats.transitionEstimated);
    return stats;
}

}  // namespace dspi_rc
