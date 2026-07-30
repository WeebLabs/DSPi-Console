#include "dspi_rc/optimizer.hpp"

#include "dspi_rc/analysis.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

double clampd(double v, double lo, double hi) { return std::max(lo, std::min(hi, v)); }

// Smooth hinge.  Milestone 0 found that hard max(x, 0) terms make the
// objective non-smooth enough that finite-difference gradient methods stall;
// after softening the hinges, convergence became reliable.  The scale is small
// so the penalty still behaves like a hinge where it matters.
double softHinge(double x, double scale = 0.05) {
    const double z = x / scale;
    if (z > 30.0) return x;          // avoid overflow; softplus == identity here
    if (z < -30.0) return 0.0;
    return scale * std::log1p(std::exp(z));
}

// Pseudo-Huber: quadratic near zero, linear far out, and differentiable
// everywhere unlike the piecewise form.
double pseudoHuber(double residual, double delta) {
    const double r = residual / delta;
    return delta * delta * (std::sqrt(1.0 + r * r) - 1.0);
}

// Ceiling on cut Q, tightening with frequency.  Modes genuinely are narrow at
// the bottom of the band; a narrow cut at 8 kHz is fitting a measurement
// artifact.
double cutQLimit(double freqHz, double transitionHz, const FitConfig& config) {
    if (freqHz <= transitionHz) return config.maxCutQBelowTransition;
    constexpr double kTopHz = 10000.0;
    if (transitionHz <= 0.0 || kTopHz <= transitionHz) return config.maxCutQAtTop;
    const double fraction =
        clampd(std::log(freqHz / transitionHz) / std::log(kTopHz / transitionHz), 0.0, 1.0);
    return config.maxCutQBelowTransition +
           fraction * (config.maxCutQAtTop - config.maxCutQBelowTransition);
}

double percentile(std::vector<double> values, double fraction) {
    if (values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    const auto index = static_cast<std::size_t>(
        clampd(std::round(fraction * static_cast<double>(values.size() - 1)), 0.0,
               static_cast<double>(values.size() - 1)));
    return values[index];
}

double medianOf(std::vector<double> values) {
    if (values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

// ---------------------------------------------------------------------------
// Parameter vector encoding
//
// Frequency in log10 and Q in log, so a step means the same thing at 30 Hz as
// at 3 kHz and the optimizer's coordinate scales are comparable.  Fitting in
// linear Hz makes the low end effectively frozen.
// ---------------------------------------------------------------------------

struct Slot {
    FilterType type = FilterType::Peaking;
};

std::vector<double> encode(const FilterBank& bank) {
    std::vector<double> x;
    x.reserve(bank.size() * 3);
    for (const FilterParams& p : bank) {
        x.push_back(std::log10(std::max(1.0, static_cast<double>(p.freq))));
        x.push_back(std::log(std::max(0.01, static_cast<double>(p.q))));
        x.push_back(p.gainDb);
    }
    return x;
}

// Q is bounded differently depending on the sign of the gain, which a box
// constraint on the parameter vector cannot express: the same coordinate may
// go to 10 as a cut and only to 2 as a boost.  Enforcing it structurally here,
// rather than leaving it to the sharpness penalty, is the difference between a
// limit and a suggestion - the CLI corpus caught the soft version being outbid
// and producing boost filters at Q 2.25 against a stated ceiling of 2.
void applyQLimits(FilterParams& p, double transitionHz, const FitConfig& config) {
    const bool isShelf =
        p.type == FilterType::LowShelf || p.type == FilterType::HighShelf;

    // A shelf's Q sets how sharply its transition turns, not how narrow a
    // feature it corrects. Past about 1 it overshoots at the corner, which is
    // the opposite of what a shelf is for - so it gets its own limit rather
    // than the peaking filter's, which reaches 10 below the transition.
    double limit = isShelf
        ? config.maxShelfQ
        : cutQLimit(p.freq, transitionHz, config);
    if (!isShelf && p.gainDb > 0.0) limit = std::min(limit, config.maxBoostQ);
    limit = std::min(limit, static_cast<double>(FirmwareLimits::maxQ));
    if (static_cast<double>(p.q) > limit) p.q = static_cast<float>(limit);
    if (static_cast<double>(p.q) < config.minQ) p.q = static_cast<float>(config.minQ);
}

FilterBank decode(const std::vector<double>& x, const std::vector<Slot>& slots,
                  double transitionHz, const FitConfig& config) {
    FilterBank bank;
    bank.reserve(slots.size());
    for (std::size_t i = 0; i < slots.size(); ++i) {
        FilterParams p;
        p.type = slots[i].type;
        p.freq = static_cast<float>(std::pow(10.0, x[i * 3 + 0]));
        p.q = static_cast<float>(std::exp(x[i * 3 + 1]));
        p.gainDb = static_cast<float>(x[i * 3 + 2]);
        applyQLimits(p, transitionHz, config);
        bank.push_back(p);
    }
    return bank;
}

// ---------------------------------------------------------------------------
// Objective
// ---------------------------------------------------------------------------

class Objective {
public:
    Objective(const FitProblem& problem, const FitConfig& config, std::vector<Slot> slots)
        : problem_(problem), config_(config), slots_(std::move(slots)) {
        const std::size_t n = problem_.grid.size();
        weights_.assign(n, 0.0);
        boostConfidence_.assign(n, 0.0);
        for (std::size_t i = 0; i < n; ++i) {
            weights_[i] = i < problem_.mask.weight.size() ? problem_.mask.weight[i] : 1.0;
            const double reliability =
                i < problem_.statistics.reliability.size() ? problem_.statistics.reliability[i] : 1.0;
            const double agreement =
                i < problem_.statistics.signAgreement.size() ? problem_.statistics.signAgreement[i] : 1.0;
            boostConfidence_[i] = clampd(reliability * clampd((agreement - 0.5) / 0.5, 0.0, 1.0), 0.0, 1.0);
        }

        cache_ = ResponseCache::forGrid(problem_.grid, problem_.sampleRateHz);
        scratch_.assign(n, 0.0);

        totalPositionWeight_ = 0.0;
        for (const PositionMeasurement& p : problem_.positions) {
            if (p.enabled && p.weight > 0.0) totalPositionWeight_ += p.weight;
        }
    }

    // Realized correction for a bank, including the trim.
    std::vector<double> correction(const FilterBank& bank, double& trimDb) const {
        const std::vector<RealizedSection> sections =
            realizeBank(bank, problem_.sampleRateHz, problem_.platform);
        std::vector<double> response;
        magnitudeDbInto(sections, cache_, response);
        trimDb = requiredTrim(response);
        for (double& v : response) v += trimDb;
        return response;
    }

    // Allocation-free variant for the inner loop.
    const std::vector<double>& correctionScratch(const FilterBank& bank, double& trimDb) const {
        const std::vector<RealizedSection> sections =
            realizeBank(bank, problem_.sampleRateHz, problem_.platform);
        magnitudeDbInto(sections, cache_, scratch_);
        trimDb = requiredTrim(scratch_);
        for (double& v : scratch_) v += trimDb;
        return scratch_;
    }

    // The trim enforces three things at once, deterministically, rather than
    // leaving them to a soft penalty that a large error reduction can outbid:
    //
    //   * the combined response stays under the configured ceiling;
    //   * no positive correction outside the speaker's native band, where boost
    //     buys excursion rather than output;
    //   * no positive correction where the positions disagree.
    //
    // Attenuating the whole channel to guarantee the last two is a real cost,
    // and it is the right one: the alternative is boosting into a null.
    double requiredTrim(const std::vector<double>& response) const {
        return requiredTrimDb(problem_, config_, response);
    }

    double operator()(const std::vector<double>& x) const {
        ++evaluations_;
        const FilterBank bank = decode(x, slots_, problem_.statistics.transitionHz, config_);
        double trimDb = 0.0;
        return score(correctionScratch(bank, trimDb), bank);
    }

    double score(const std::vector<double>& response, const FilterBank& bank) const {
        const std::size_t n = problem_.grid.size();

        // Level-normalize before scoring tonal error.
        //
        // One trim applies to the whole channel, and the balance-preserving
        // compensation restores inter-channel level afterwards, so absolute
        // offset is not a tonal defect.  Scoring it as one makes the optimizer
        // fight its own trim: it would spend filters trying to hit an absolute
        // level that the trim then shifts away.  The offset is shared across
        // positions, not per position, because the trim is one number.
        const double offset = sharedOffset(response);

        double errorSum = 0.0;
        double errorWeight = 0.0;
        double overshoot = 0.0;

        for (const PositionMeasurement& position : problem_.positions) {
            if (!position.enabled || position.weight <= 0.0) continue;
            for (std::size_t i = 0; i < n; ++i) {
                if (i >= position.magnitudesDb.size()) break;
                const double residual =
                    position.magnitudesDb[i] + response[i] - problem_.targetDb[i] - offset;
                const double weight = position.weight * weights_[i];
                errorSum += weight * pseudoHuber(residual, config_.huberDeltaDb);
                errorWeight += weight;

                // Overshoot is evaluated per position, not on the average.  A
                // boost that fills a dip at one seat while making another
                // excessive must be penalized for the second seat.
                const double excess = softHinge(residual - config_.overshootToleranceDb);
                overshoot += position.weight * excess * excess;
            }
        }
        const double robustError = errorWeight > 0.0 ? errorSum / errorWeight : 0.0;
        const double overshootPenalty =
            n > 0 ? overshoot / static_cast<double>(n) : 0.0;

        double positive = 0.0;
        double unreliableBoost = 0.0;
        for (std::size_t i = 0; i < n; ++i) {
            const double ceiling =
                i < problem_.mask.boostCeilingDb.size() ? problem_.mask.boostCeilingDb[i] : 0.0;
            const double excess = softHinge(response[i] - ceiling);
            positive += excess * excess;
            const double distrust = 1.0 - boostConfidence_[i];
            const double unreliable = softHinge(response[i]) * distrust;
            unreliableBoost += unreliable * unreliable;
        }
        if (n > 0) {
            positive /= static_cast<double>(n);
            unreliableBoost /= static_cast<double>(n);
        }

        double sharpness = 0.0;
        double complexity = 0.0;
        for (const FilterParams& p : bank) {
            double limit = cutQLimit(p.freq, problem_.statistics.transitionHz, config_);
            if (p.gainDb > 0.0) limit = std::min(limit, config_.maxBoostQ);
            const double excess = softHinge(static_cast<double>(p.q) - limit);
            sharpness += excess * excess * (0.25 + std::fabs(p.gainDb)) *
                         (0.25 + std::fabs(p.gainDb));
            complexity += std::sqrt(static_cast<double>(p.gainDb) * p.gainDb + 0.01);
        }

        return robustError +
               config_.hygieneWeight *
                   (config_.overshootWeight * overshootPenalty +
                    config_.positiveCorrectionWeight * positive +
                    config_.unreliableBoostWeight * unreliableBoost +
                    config_.sharpnessWeight * sharpness) +
               config_.complexityWeight * complexity;
    }

    // Weighted mean residual across every enabled position and bin.  Removing
    // it makes the error term level-invariant.
    double sharedOffset(const std::vector<double>& response) const {
        double sum = 0.0;
        double weight = 0.0;
        for (const PositionMeasurement& position : problem_.positions) {
            if (!position.enabled || position.weight <= 0.0) continue;
            for (std::size_t i = 0; i < problem_.grid.size(); ++i) {
                if (i >= position.magnitudesDb.size()) break;
                const double w = position.weight * weights_[i];
                sum += w * (position.magnitudesDb[i] + response[i] - problem_.targetDb[i]);
                weight += w;
            }
        }
        return weight > 0.0 ? sum / weight : 0.0;
    }

    std::size_t evaluations() const { return evaluations_; }
    const std::vector<Slot>& slots() const { return slots_; }

private:
    const FitProblem& problem_;
    const FitConfig& config_;
    std::vector<Slot> slots_;
    std::vector<double> weights_;
    std::vector<double> boostConfidence_;
    ResponseCache cache_;
    mutable std::vector<double> scratch_;
    double totalPositionWeight_ = 0.0;
    mutable std::size_t evaluations_ = 0;
};

// ---------------------------------------------------------------------------
// Bounds
// ---------------------------------------------------------------------------

struct Bounds {
    std::vector<double> lower;
    std::vector<double> upper;
};

Bounds makeBounds(const FitProblem& problem, const FitConfig& config,
                  const std::vector<Slot>& slots) {
    Bounds bounds;
    const double maxFreq =
        std::min(config.maxFreqHz, problem.sampleRateHz * FirmwareLimits::freqNyquistFraction);
    for (std::size_t i = 0; i < slots.size(); ++i) {
        bounds.lower.push_back(std::log10(std::max(
            static_cast<double>(FirmwareLimits::minFreqHz), config.minFreqHz)));
        bounds.upper.push_back(std::log10(maxFreq));
        bounds.lower.push_back(std::log(std::max(0.05, config.minQ)));
        bounds.upper.push_back(std::log(static_cast<double>(FirmwareLimits::maxQ)));
        bounds.lower.push_back(config.cutLimitDb);
        bounds.upper.push_back(std::max(0.0, config.boostLimitDb));
    }
    return bounds;
}

// ---------------------------------------------------------------------------
// Seeding
//
// Greedy, by the *area* of the remaining error feature rather than its depth.
// Picking the deepest point chases narrow artifacts; picking the largest area
// finds the feature that actually costs the most across the band.
// ---------------------------------------------------------------------------

FilterBank seedFilters(const FitProblem& problem, const FitConfig& config,
                       const std::vector<Slot>& slots) {
    const FrequencyGrid& grid = problem.grid;
    const std::size_t n = grid.size();

    std::vector<double> residual(n, 0.0);
    for (std::size_t i = 0; i < n; ++i) {
        const double measured = i < problem.statistics.powerAverageDb.size()
                                    ? problem.statistics.powerAverageDb[i]
                                    : 0.0;
        residual[i] = problem.targetDb[i] - measured;
    }

    const double pointsPerOctave = std::max(1.0, grid.pointsPerOctave());
    auto areaHalfWidth = static_cast<std::ptrdiff_t>(std::max(1.0, std::round(pointsPerOctave / 4.0)));

    FilterBank bank;
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        // Weight the residual by how much we trust a boost there, so seeding
        // does not place a filter on a disputed null in the first place.
        std::vector<double> weighted(n, 0.0);
        for (std::size_t i = 0; i < n; ++i) {
            const double maskWeight = i < problem.mask.weight.size() ? problem.mask.weight[i] : 1.0;
            double value = residual[i] * maskWeight;
            if (value > 0.0) {
                const double ceiling = i < problem.mask.boostCeilingDb.size()
                                           ? problem.mask.boostCeilingDb[i]
                                           : 0.0;
                if (ceiling <= 0.0) value *= 0.15;  // strongly discourage
            }
            weighted[i] = value;
        }

        // Integrated absolute error in a half-octave neighbourhood.
        double bestScore = -1.0;
        std::size_t bestIndex = 0;
        for (std::size_t i = 0; i < n; ++i) {
            if (i < problem.mask.weight.size() && problem.mask.weight[i] <= 0.01) continue;

            bool tooClose = false;
            for (const FilterParams& existing : bank) {
                if (std::fabs(std::log2(grid.hz[i] / existing.freq)) < 0.3) { tooClose = true; break; }
            }
            if (tooClose) continue;

            const auto centre = static_cast<std::ptrdiff_t>(i);
            const std::ptrdiff_t first = std::max<std::ptrdiff_t>(0, centre - areaHalfWidth);
            const std::ptrdiff_t last = std::min<std::ptrdiff_t>(
                static_cast<std::ptrdiff_t>(n) - 1, centre + areaHalfWidth);
            double positiveArea = 0.0;
            double negativeArea = 0.0;
            for (std::ptrdiff_t j = first; j <= last; ++j) {
                const double v = weighted[static_cast<std::size_t>(j)];
                if (v > 0.0) positiveArea += v; else negativeArea -= v;
            }
            const double score = std::max(positiveArea, negativeArea);
            if (score > bestScore) { bestScore = score; bestIndex = i; }
        }

        if (bestScore <= 1e-6) break;  // nothing worth another filter

        const double centreHz = grid.hz[bestIndex];
        const double gain = clampd(residual[bestIndex], config.cutLimitDb,
                                   std::max(0.0, config.boostLimitDb));

        // Q from the feature's half-height width, which is what a peaking
        // filter's Q actually parameterizes.
        const double sign = residual[bestIndex] >= 0.0 ? 1.0 : -1.0;
        const double halfHeight = std::fabs(residual[bestIndex]) * 0.5;
        std::size_t left = bestIndex;
        std::size_t right = bestIndex;
        while (left > 0 && residual[left - 1] * sign >= halfHeight) --left;
        while (right + 1 < n && residual[right + 1] * sign >= halfHeight) ++right;
        const double lowHz = grid.hz[left > 0 ? left - 1 : 0];
        const double highHz = grid.hz[std::min(n - 1, right + 1)];
        const double bandwidthOctaves = std::max(1.0 / pointsPerOctave, std::log2(highHz / lowHz));
        const double ratio = std::pow(2.0, bandwidthOctaves);
        double q = std::sqrt(ratio) / std::max(1e-6, ratio - 1.0);

        double limit = cutQLimit(centreHz, problem.statistics.transitionHz, config);
        if (gain > 0.0) limit = std::min(limit, config.maxBoostQ);
        q = clampd(q, config.minQ, limit);

        FilterParams p;
        p.type = slots[slot].type;
        p.freq = static_cast<float>(centreHz);
        p.q = static_cast<float>(q);
        p.gainDb = static_cast<float>(gain);
        bank.push_back(p);

        // Subtract what this filter will do, so the next pick sees what is left.
        const std::vector<RealizedSection> sections =
            realizeBank({p}, problem.sampleRateHz, problem.platform);
        const std::vector<double> contribution =
            magnitudeDb(sections, grid, problem.sampleRateHz);
        for (std::size_t i = 0; i < n; ++i) residual[i] -= contribution[i];
    }

    // Pad unused slots with inert bands so the parameter vector has fixed
    // length; they optimize toward zero gain and are dropped afterwards.
    while (bank.size() < slots.size()) {
        FilterParams p;
        p.type = slots[bank.size()].type;
        p.freq = static_cast<float>(clampd(200.0 * std::pow(2.4, static_cast<double>(bank.size())),
                                           config.minFreqHz, config.maxFreqHz));
        p.q = 1.0f;
        p.gainDb = 0.0f;
        bank.push_back(p);
    }
    return bank;
}

// ---------------------------------------------------------------------------
// Box-constrained minimization
//
// Cyclic coordinate descent with a golden-section line search per coordinate.
// Chosen over a quasi-Newton method because it is deterministic, respects box
// bounds without projection subtleties, needs no gradient, and suits a problem
// whose parameters are close to separable in frequency.
//
// Milestone 0's finding that SLSQP beat finite-difference L-BFGS-B remains the
// reason not to reach for an FD gradient method here.  If this in-tree
// minimizer proves inadequate against the Milestone 0 corpus, the replacement
// is NLopt/SLSQP behind this same interface; that is a dependency decision, not
// an algorithmic one.
// ---------------------------------------------------------------------------

double lineSearch(const Objective& objective, std::vector<double>& x, std::size_t index,
                  double lower, double upper, int iterations) {
    constexpr double kInvPhi = 0.61803398874989484820;
    double a = lower;
    double b = upper;
    const double original = x[index];

    // Bracket around the current value so a good starting point is not thrown
    // away by searching the entire bound range.
    const double span = (upper - lower) * 0.25;
    a = std::max(lower, original - span);
    b = std::min(upper, original + span);
    if (b - a < 1e-12) return objective(x);

    double c = b - kInvPhi * (b - a);
    double d = a + kInvPhi * (b - a);
    x[index] = c;
    double fc = objective(x);
    x[index] = d;
    double fd = objective(x);

    for (int i = 0; i < iterations; ++i) {
        if (fc < fd) {
            b = d; d = c; fd = fc;
            c = b - kInvPhi * (b - a);
            x[index] = c;
            fc = objective(x);
        } else {
            a = c; c = d; fc = fd;
            d = a + kInvPhi * (b - a);
            x[index] = d;
            fd = objective(x);
        }
        if (b - a < 1e-9) break;
    }

    // Never leave a coordinate worse than it started.
    //
    // Golden section finds the minimum only where the bracket contains it and
    // the function is unimodal along the coordinate. Neither holds here: the
    // objective carries softplus hinges, overlapping filters, and a trim term
    // that is a max over bins, and the bracket is only the current value plus
    // or minus a quarter of the range. Without this the search moved uphill
    // whenever both probes were worse than the starting point, which is why
    // extra iterations and extra bands could each make the fit worse.
    x[index] = original;
    const double f0 = objective(x);
    double bestX = original;
    double bestF = f0;
    if (fc < bestF) { bestF = fc; bestX = c; }
    if (fd < bestF) { bestF = fd; bestX = d; }
    x[index] = clampd(bestX, lower, upper);
    return objective(x);
}

struct MinimizeResult {
    double value = 0.0;
    int sweeps = 0;
    bool converged = false;
};

MinimizeResult minimize(const Objective& objective, std::vector<double>& x,
                        const Bounds& bounds, int maxIterations) {
    MinimizeResult result;
    result.value = objective(x);

    // Sweeps, not raw function evaluations.  Golden-section converges quickly
    // per coordinate, so the useful budget is "how many times round the
    // parameter set", and the stall test below usually stops well short.
    const int maxSweeps = std::max(4, maxIterations / 16);
    double previous = result.value;

    for (int sweep = 0; sweep < maxSweeps; ++sweep) {
        for (std::size_t i = 0; i < x.size(); ++i) {
            result.value = lineSearch(objective, x, i, bounds.lower[i], bounds.upper[i], 14);
        }
        ++result.sweeps;
        const double improvement = previous - result.value;
        // Stall threshold set by what is acoustically meaningless rather than
        // by numerical taste.  Coordinate descent tails off slowly on this
        // problem, and a tight criterion reports "not converged" on results
        // already accurate to a tenth of a dB.  The error term is roughly
        // mean(residual^2)/2, so 1e-4 relative corresponds to a change in
        // predicted response well under 0.001 dB - far below anything audible,
        // measurable in a room, or representable on the wire.
        if (improvement >= 0.0 && improvement < 1e-4 * (1.0 + std::fabs(previous))) {
            result.converged = true;
            break;
        }
        previous = result.value;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Slot layout
// ---------------------------------------------------------------------------

std::vector<Slot> buildSlots(const FitConfig& config) {
    std::vector<Slot> slots;
    const int count = std::max(1, config.maxFilters);
    // Reserve the first and last slot for shelves when allowed: they carry a
    // broad target trend for one band each, where peaking filters would need
    // several.
    for (int i = 0; i < count; ++i) {
        Slot slot;
        if (config.allowShelves && count >= 4 && i == 0) {
            slot.type = FilterType::LowShelf;
        } else if (config.allowShelves && count >= 4 && i == count - 1) {
            slot.type = FilterType::HighShelf;
        } else {
            slot.type = FilterType::Peaking;
        }
        slots.push_back(slot);
    }
    return slots;
}

}  // namespace

// ---------------------------------------------------------------------------
// Shared scoring
// ---------------------------------------------------------------------------

double requiredTrimDb(const FitProblem& problem,
                      const FitConfig& config,
                      const std::vector<double>& responseDb) {
    double peak = -1e300;
    double forbiddenPeak = -1e300;
    for (std::size_t i = 0; i < responseDb.size(); ++i) {
        peak = std::max(peak, responseDb[i]);
        const double ceiling =
            i < problem.mask.boostCeilingDb.size() ? problem.mask.boostCeilingDb[i] : 0.0;
        if (ceiling <= 0.0) forbiddenPeak = std::max(forbiddenPeak, responseDb[i]);
    }
    double trim = std::min(0.0, config.combinedCeilingDb - peak);
    if (forbiddenPeak > -1e299) trim = std::min(trim, -forbiddenPeak);
    return trim;
}

CollapsedProblem collapsePositions(const FitProblem& problem,
                                   const std::vector<double>& responseDb,
                                   double huberDeltaDb) {
    const std::size_t n = problem.grid.size();
    CollapsedProblem collapsed;
    collapsed.errorDb.assign(n, 0.0);
    collapsed.weight.assign(n, 0.0);

    std::vector<double> maskWeight(n, 1.0);
    for (std::size_t i = 0; i < n; ++i) {
        maskWeight[i] = i < problem.mask.weight.size() ? problem.mask.weight[i] : 1.0;
    }

    // Level-normalize before scoring tonal error: one trim applies to the whole
    // channel and the balance compensation restores level afterwards, so an
    // absolute offset is not a tonal defect.
    //
    // The offset must be taken under **the same weights the loss uses**, which
    // is not obvious and is easy to get wrong twice.  Taken under plain mask
    // weights while the loss carries Huber weights, a uniform downward shift no
    // longer cancels: it still reduces the loss, so a fit can buy score by
    // attenuating, and no metric here can see it because they all level-
    // normalize.  The weights depend on the residual and the residual depends on
    // the offset, so this is a two-step fixed point; it converges immediately
    // because the weights are bounded.
    double offset = 0.0;
    for (int pass = 0; pass < 3; ++pass) {
        double sum = 0.0;
        double total = 0.0;
        for (const PositionMeasurement& position : problem.positions) {
            if (!position.enabled || position.weight <= 0.0) continue;
            for (std::size_t i = 0; i < n && i < position.magnitudesDb.size(); ++i) {
                const double error =
                    position.magnitudesDb[i] + responseDb[i] - problem.targetDb[i];
                // The first pass has no offset to weight against, so it is the
                // plain weighted mean and the two after it refine from there.
                const double robust =
                    pass == 0 ? 1.0
                              : (std::fabs(error - offset) <= huberDeltaDb
                                     ? 1.0
                                     : huberDeltaDb / std::fabs(error - offset));
                const double w = position.weight * maskWeight[i] * robust;
                sum += w * error;
                total += w;
            }
        }
        if (total > 0.0) offset = sum / total;
    }

    for (std::size_t i = 0; i < n; ++i) {
        double numerator = 0.0;
        double denominator = 0.0;
        for (const PositionMeasurement& position : problem.positions) {
            if (!position.enabled || position.weight <= 0.0) continue;
            if (i >= position.magnitudesDb.size()) continue;

            const double residual =
                position.magnitudesDb[i] + responseDb[i] - problem.targetDb[i] - offset;
            const double magnitude = std::fabs(residual);
            const double robust = magnitude <= huberDeltaDb ? 1.0 : huberDeltaDb / magnitude;

            const double w = position.weight * robust;
            numerator += w * (problem.targetDb[i] + offset - position.magnitudesDb[i]);
            denominator += w;
        }
        collapsed.errorDb[i] = denominator > 0.0 ? numerator / denominator : 0.0;
        collapsed.weight[i] = maskWeight[i] * denominator;
    }
    return collapsed;
}

// ---------------------------------------------------------------------------

void applyStrength(FitProblem& problem, double strength) {
    if (strength >= 1.0 || problem.positions.empty()) return;
    const std::vector<double>& measured = problem.statistics.powerAverageDb;
    const std::size_t n = std::min(problem.targetDb.size(), measured.size());
    for (std::size_t i = 0; i < n; ++i) {
        problem.targetDb[i] = measured[i] + strength * (problem.targetDb[i] - measured[i]);
    }
    problem.statistics =
        computeSpatialStatistics(problem.grid, problem.positions, problem.targetDb);
}

std::string FitConfig::validate() const {
    if (maxFilters < 1) return "at least one filter is required";
    if (minFreqHz <= 0.0 || maxFreqHz <= minFreqHz) return "invalid frequency range";
    if (strength <= 0.0 || strength > 1.0) return "strength must be in (0, 1]";
    if (cutLimitDb >= 0.0) return "cut limit must be negative";
    if (boostLimitDb < 0.0) return "boost limit must not be negative";
    if (maxBoostQ <= 0.0 || maxCutQBelowTransition <= 0.0 || maxCutQAtTop <= 0.0) {
        return "Q limits must be positive";
    }
    if (huberDeltaDb <= 0.0) return "Huber delta must be positive";
    if (starts < 1) return "at least one start is required";
    if (maxIterations < 1) return "at least one iteration is required";
    return {};
}

std::string FitProblem::validate() const {
    if (grid.empty()) return "empty frequency grid";
    if (targetDb.size() != grid.size()) return "target does not match the grid";
    if (positions.empty()) return "no measurement positions";
    bool anyEnabled = false;
    for (const PositionMeasurement& p : positions) {
        if (p.enabled && p.weight > 0.0) {
            anyEnabled = true;
            if (p.magnitudesDb.size() != grid.size()) return "a position does not match the grid";
        }
    }
    if (!anyEnabled) return "no enabled measurement positions";
    if (sampleRateHz <= 0.0) return "invalid sample rate";
    return {};
}

// ---------------------------------------------------------------------------

FitMetrics evaluateCorrection(const FitProblem& problem,
                              const std::vector<double>& response) {
    FitMetrics metrics;
    const std::size_t n = problem.grid.size();
    if (n == 0 || response.size() < n) return metrics;

    metrics.maxCombinedCorrectionDb = -1e300;
    metrics.minCombinedCorrectionDb = 1e300;
    for (double v : response) {
        metrics.maxCombinedCorrectionDb = std::max(metrics.maxCombinedCorrectionDb, v);
        metrics.minCombinedCorrectionDb = std::min(metrics.minCombinedCorrectionDb, v);
    }

    // Level-normalize, for the same reason the objective does: one trim applies
    // to the whole channel and the balance-preserving compensation restores
    // level afterwards, so an absolute offset is not a tonal defect.  Without
    // this, a correction that fixes the shape perfectly but sits 6 dB low
    // scores worse than no correction at all, and comparisons between variants
    // measure their trim rather than their tonal accuracy.
    double offsetSum = 0.0;
    double offsetWeight = 0.0;
    for (const PositionMeasurement& position : problem.positions) {
        if (!position.enabled || position.weight <= 0.0) continue;
        for (std::size_t i = 0; i < n && i < position.magnitudesDb.size(); ++i) {
            const double weight =
                position.weight * (i < problem.mask.weight.size() ? problem.mask.weight[i] : 1.0);
            offsetSum += weight * (position.magnitudesDb[i] + response[i] - problem.targetDb[i]);
            offsetWeight += weight;
        }
    }
    const double offset = offsetWeight > 0.0 ? offsetSum / offsetWeight : 0.0;

    std::vector<double> overshoots;
    std::vector<double> reliableErrors;

    for (const PositionMeasurement& position : problem.positions) {
        if (!position.enabled || position.weight <= 0.0) continue;
        double rawSum = 0.0;
        double reliableSum = 0.0;
        double reliableWeight = 0.0;
        std::size_t count = 0;
        for (std::size_t i = 0; i < n && i < position.magnitudesDb.size(); ++i) {
            const double residual =
                position.magnitudesDb[i] + response[i] - problem.targetDb[i] - offset;
            rawSum += residual * residual;
            ++count;

            const double weight = i < problem.mask.weight.size() ? problem.mask.weight[i] : 1.0;
            reliableSum += weight * residual * residual;
            reliableWeight += weight;
            if (weight > 0.05) reliableErrors.push_back(std::fabs(residual));
            overshoots.push_back(std::max(0.0, residual));
        }
        if (count > 0) {
            metrics.rawWorstPositionRmseDb =
                std::max(metrics.rawWorstPositionRmseDb,
                         std::sqrt(rawSum / static_cast<double>(count)));
        }
        if (reliableWeight > 0.0) {
            metrics.reliableWorstPositionRmseDb =
                std::max(metrics.reliableWorstPositionRmseDb, std::sqrt(reliableSum / reliableWeight));
        }
    }

    metrics.reliableMedianAbsErrorDb = medianOf(std::move(reliableErrors));
    metrics.p95PositiveOvershootDb = percentile(std::move(overshoots), 0.95);

    for (std::size_t i = 0; i < n; ++i) {
        const double reliability =
            i < problem.statistics.reliability.size() ? problem.statistics.reliability[i] : 1.0;
        if (reliability < 0.5 && response[i] > 0.0) {
            metrics.maxDisputedBoostDb = std::max(metrics.maxDisputedBoostDb, response[i]);
        }
        const double f = problem.grid.hz[i];
        if ((f < problem.native.lowHz || f > problem.native.highHz) && response[i] > 0.0) {
            metrics.maxOutsideNativeBoostDb =
                std::max(metrics.maxOutsideNativeBoostDb, response[i]);
        }
    }

    return metrics;
}

FitMetrics evaluateBank(const FitProblem& problem,
                        const FilterBank& bank,
                        double trimDb,
                        const FitConfig& config) {
    const std::vector<RealizedSection> sections =
        realizeBank(bank, problem.sampleRateHz, problem.platform);
    std::vector<double> response = magnitudeDb(sections, problem.grid, problem.sampleRateHz);
    for (double& v : response) v += trimDb;

    FitMetrics metrics = evaluateCorrection(problem, response);

    for (const FilterParams& p : bank) {
        if (p.bypass || p.type == FilterType::Flat) continue;
        if (std::fabs(p.gainDb) < 0.05) continue;
        ++metrics.activeFilterCount;
        if (p.type == FilterType::LowShelf || p.type == FilterType::HighShelf) {
            ++metrics.shelfFilterCount;
        }
        if (p.gainDb > 0.05) {
            metrics.maxBoostFilterQ = std::max(metrics.maxBoostFilterQ, static_cast<double>(p.q));
        }
    }

    (void)config;
    return metrics;
}

// ---------------------------------------------------------------------------

FitResult fitCorrection(const FitProblem& problem, const FitConfig& config) {
    FitResult result;

    const std::string problemError = problem.validate();
    if (!problemError.empty()) { result.message = problemError; return result; }
    const std::string configError = config.validate();
    if (!configError.empty()) { result.message = configError; return result; }

    const std::vector<Slot> slots = buildSlots(config);
    const Objective objective(problem, config, slots);
    const Bounds bounds = makeBounds(problem, config, slots);

    const FilterBank seeded = seedFilters(problem, config, slots);

    // Deterministic starts around the seed.  Perturbing frequency and Q rather
    // than gain, since gain is the coordinate the line search recovers most
    // easily and frequency is where local minima live.
    std::vector<std::vector<double>> starts;
    starts.push_back(encode(seeded));
    for (int s = 1; s < config.starts; ++s) {
        std::vector<double> perturbed = starts.front();
        const double direction = (s % 2 == 0) ? 1.0 : -1.0;
        // Integer division is intentional: starts pair up as +/- the same step.
        const int step = (s + 1) / 2;
        const double scale = 0.05 * static_cast<double>(step);
        for (std::size_t i = 0; i < slots.size(); ++i) {
            perturbed[i * 3 + 0] += direction * scale * ((i % 2 == 0) ? 1.0 : -1.0);
            perturbed[i * 3 + 1] -= scale;
        }
        for (std::size_t i = 0; i < perturbed.size(); ++i) {
            perturbed[i] = clampd(perturbed[i], bounds.lower[i], bounds.upper[i]);
        }
        starts.push_back(std::move(perturbed));
    }

    std::vector<double> best;
    double bestValue = 1e300;
    int totalSweeps = 0;
    bool anyConverged = false;
    // Tracked separately so a converged candidate is never beaten by one that
    // merely ran out of sweeps. Reporting "converged" because a *different*
    // start converged, while returning a truncated candidate, described a run
    // that never happened.
    bool bestConverged = false;

    for (std::vector<double>& start : starts) {
        std::vector<double> candidate = start;
        for (std::size_t i = 0; i < candidate.size(); ++i) {
            candidate[i] = clampd(candidate[i], bounds.lower[i], bounds.upper[i]);
        }
        const MinimizeResult minimized =
            minimize(objective, candidate, bounds, config.maxIterations);
        totalSweeps += minimized.sweeps;
        anyConverged = anyConverged || minimized.converged;

        // A converged candidate outranks an unconverged one outright; among
        // equals, the lower objective wins.
        const bool preferable = (minimized.converged && !bestConverged)
            || (minimized.converged == bestConverged && minimized.value < bestValue);
        if (preferable) {
            bestConverged = minimized.converged;
        }
        if (preferable) {
            bestValue = minimized.value;
            best = candidate;
        }
    }

    if (best.empty()) { result.message = "optimization produced no solution"; return result; }

    // Quantize to the wire representation and re-optimize the gains only.  The
    // wire carries float32, so frequency and Q survive; gain is re-fitted
    // because rounding the others shifts the optimum slightly.
    FilterBank quantized = decode(best, slots, problem.statistics.transitionHz, config);
    for (FilterParams& p : quantized) {
        p = clampToFirmware(p, problem.sampleRateHz);
    }
    std::vector<double> refined = encode(quantized);
    for (std::size_t i = 0; i < refined.size(); ++i) {
        refined[i] = clampd(refined[i], bounds.lower[i], bounds.upper[i]);
    }
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        const std::size_t index = slot * 3 + 2;
        lineSearch(objective, refined, index, bounds.lower[index], bounds.upper[index], 32);
    }

    FilterBank finalBank = decode(refined, slots, problem.statistics.transitionHz, config);
    for (FilterParams& p : finalBank) p = clampToFirmware(p, problem.sampleRateHz);

    // Drop bands that ended up doing nothing, so the written bank is honest
    // about how much of the budget was actually used.
    FilterBank pruned;
    for (const FilterParams& p : finalBank) {
        // 0.1 dB is inaudible, so a band contributing less than that should
        // not consume a slot the user could see reported as used.
        if (std::fabs(p.gainDb) >= 0.1) pruned.push_back(p);
    }

    double trimDb = 0.0;
    result.correctionDb = objective.correction(pruned, trimDb);

    result.filters = pruned;
    result.trimDb = trimDb;
    result.objective = bestValue;
    result.converged = anyConverged;
    result.iterations = totalSweeps;
    result.evaluations = static_cast<int>(objective.evaluations());
    result.message = anyConverged ? "converged" : "iteration limit reached";
    result.metrics = evaluateBank(problem, pruned, trimDb, config);

    result.predictedDb.reserve(problem.positions.size());
    for (const PositionMeasurement& position : problem.positions) {
        std::vector<double> predicted(problem.grid.size(), 0.0);
        for (std::size_t i = 0; i < problem.grid.size() && i < position.magnitudesDb.size(); ++i) {
            predicted[i] = position.magnitudesDb[i] + result.correctionDb[i];
        }
        result.predictedDb.push_back(std::move(predicted));
    }

    return result;
}

}  // namespace dspi_rc
