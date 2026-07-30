#include "dspi_rc/parallel.hpp"

#include "dspi_rc/lstsq.hpp"
#include "dspi_rc/poles.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

double clampd(double v, double lo, double hi) { return std::max(lo, std::min(hi, v)); }

// Value of a curve defined on a log grid, at an arbitrary frequency, held flat
// outside the grid's range.
double sampleLogGrid(const FrequencyGrid& grid, const std::vector<double>& values, double freqHz) {
    if (grid.empty() || values.empty()) return 0.0;
    if (freqHz <= grid.hz.front()) return values.front();
    if (freqHz >= grid.hz.back()) return values.back();

    const auto upper = std::lower_bound(grid.hz.begin(), grid.hz.end(), freqHz);
    const std::size_t hi = static_cast<std::size_t>(upper - grid.hz.begin());
    const std::size_t lo = hi > 0 ? hi - 1 : 0;
    if (hi >= values.size()) return values.back();

    const double span = std::log(grid.hz[hi]) - std::log(grid.hz[lo]);
    if (span <= 0.0) return values[lo];
    const double fraction = (std::log(freqHz) - std::log(grid.hz[lo])) / span;
    return values[lo] + fraction * (values[hi] - values[lo]);
}

// Per-row weights for the stacked real/imaginary system.
//
// The target normalization lives here: dB error is proportional to *relative*
// linear error, so weighting each row by 1/|target|^2 turns a linear-domain
// least squares into an approximation of a log-magnitude one.  Without it the
// fit optimizes a different quantity from the one it is scored on.
std::vector<double> rowWeights(const std::vector<Complex>& target,
                               const std::vector<double>& binWeight,
                               const ParallelConfig& config) {
    const std::size_t n = target.size();
    std::vector<double> weights(2 * n, 0.0);
    for (std::size_t i = 0; i < n; ++i) {
        double w = i < binWeight.size() ? std::max(0.0, binWeight[i]) : 1.0;
        if (config.normalizeByTarget) {
            const double magnitude = std::max(config.targetFloor, std::abs(target[i]));
            w /= magnitude * magnitude;
        }
        weights[2 * i] = w;
        weights[2 * i + 1] = w;
    }
    return weights;
}

// Basis of one pole pair evaluated at a frequency: the pole's own transfer
// function and the same delayed by one sample.
void poleBasis(const ParallelSection& section, const Complex& z1, const Complex& z2,
               Complex& first, Complex& second) {
    const Complex denominator = 1.0 + section.a1 * z1 + section.a2 * z2;
    first = 1.0 / denominator;
    second = z1 / denominator;
}

}  // namespace

void setPole(ParallelSection& section, double freqHz, double q, double sampleRateHz) {
    section.freqHz = freqHz;
    section.q = q;

    const double theta = 2.0 * kPi * freqHz / sampleRateHz;
    const double bandwidth = freqHz / std::max(0.05, q);
    // Held off the unit circle, but only just.  This filter is never run, only
    // evaluated, so the clamp exists to keep the arithmetic finite rather than
    // to guarantee a decay time.  The old value of 0.9995 imposed a floor of
    // about 7.6 Hz of bandwidth at 48 kHz, which broadened every pole below
    // roughly 50 Hz at high section counts - the exact region where the
    // structure is supposed to be strongest.
    const double r = clampd(std::exp(-kPi * bandwidth / sampleRateHz), 0.0, 1.0 - 1e-6);
    section.a1 = -2.0 * r * std::cos(theta);
    section.a2 = r * r;
}

std::vector<Complex> minimumPhaseResponse(const FrequencyGrid& grid,
                                          const std::vector<double>& magnitudeDb,
                                          double sampleRateHz,
                                          std::size_t fftSize) {
    std::vector<Complex> out(grid.size(), Complex(1.0, 0.0));
    if (grid.empty() || magnitudeDb.size() < grid.size() || sampleRateHz <= 0.0) return out;

    const std::size_t n = nextPowerOfTwo(std::max<std::size_t>(fftSize, 1024));
    const double lnTenOverTwenty = std::log(10.0) / 20.0;

    // Natural log magnitude on a linear frequency grid, made even-symmetric so
    // the cepstrum is real.
    std::vector<Complex> work(n, Complex(0.0, 0.0));
    for (std::size_t k = 0; k <= n / 2; ++k) {
        const double freq = static_cast<double>(k) * sampleRateHz / static_cast<double>(n);
        const double db = sampleLogGrid(grid, magnitudeDb, freq);
        const double logMagnitude = db * lnTenOverTwenty;
        work[k] = Complex(logMagnitude, 0.0);
        if (k > 0 && k < n / 2) work[n - k] = Complex(logMagnitude, 0.0);
    }

    // Real cepstrum, folded onto the causal half.  Doubling the positive
    // quefrencies and discarding the negative ones is what turns an arbitrary
    // magnitude into the minimum-phase spectrum that has it.
    fftInPlace(work, true);
    std::vector<Complex> folded(n, Complex(0.0, 0.0));
    folded[0] = Complex(work[0].real(), 0.0);
    for (std::size_t k = 1; k < n / 2; ++k) folded[k] = Complex(2.0 * work[k].real(), 0.0);
    folded[n / 2] = Complex(work[n / 2].real(), 0.0);

    fftInPlace(folded, false);
    for (Complex& value : folded) value = std::exp(value);

    // Back onto the analysis grid.
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double bin = grid.hz[i] * static_cast<double>(n) / sampleRateHz;
        if (bin <= 0.0) { out[i] = folded[0]; continue; }
        if (bin >= static_cast<double>(n / 2)) { out[i] = folded[n / 2]; continue; }
        const auto lo = static_cast<std::size_t>(bin);
        const double fraction = bin - static_cast<double>(lo);
        out[i] = folded[lo] * (1.0 - fraction) + folded[lo + 1] * fraction;
    }
    return out;
}

std::vector<Complex> parallelResponse(const ParallelDesign& design,
                                      const FrequencyGrid& grid,
                                      double sampleRateHz) {
    std::vector<Complex> response(grid.size(), Complex(0.0, 0.0));
    for (std::size_t i = 0; i < grid.size(); ++i) {
        const double omega = 2.0 * kPi * grid.hz[i] / sampleRateHz;
        const Complex z1 = std::polar(1.0, -omega);
        const Complex z2 = z1 * z1;

        Complex total(design.d0, 0.0);
        total += design.d1 * z1;
        for (const ParallelSection& section : design.sections) {
            Complex first, second;
            poleBasis(section, z1, z2, first, second);
            total += section.b0 * first + section.b1 * second;
        }
        response[i] = total;
    }
    return response;
}

bool solveParallelNumerators(const std::vector<Complex>& target,
                             const std::vector<double>& binWeight,
                             const FrequencyGrid& grid,
                             double sampleRateHz,
                             const ParallelConfig& config,
                             ParallelDesign& design,
                             double* residualNorm) {
    const std::size_t n = grid.size();
    if (n == 0 || target.size() < n || design.sections.empty()) return false;

    const std::size_t sectionCount = design.sections.size();
    const std::size_t directColumns = config.includeDirectPath ? 2 : 0;
    const std::size_t columns = 2 * sectionCount + directColumns;

    // Real and imaginary parts stacked, the standard reduction of a complex
    // least-squares problem with real unknowns.
    DenseMatrix basis(2 * n, columns);
    std::vector<double> rhs(2 * n, 0.0);

    for (std::size_t i = 0; i < n; ++i) {
        const double omega = 2.0 * kPi * grid.hz[i] / sampleRateHz;
        const Complex z1 = std::polar(1.0, -omega);
        const Complex z2 = z1 * z1;

        for (std::size_t s = 0; s < sectionCount; ++s) {
            Complex first, second;
            poleBasis(design.sections[s], z1, z2, first, second);
            basis.at(2 * i, 2 * s) = first.real();
            basis.at(2 * i + 1, 2 * s) = first.imag();
            basis.at(2 * i, 2 * s + 1) = second.real();
            basis.at(2 * i + 1, 2 * s + 1) = second.imag();
        }
        if (directColumns == 2) {
            basis.at(2 * i, 2 * sectionCount) = 1.0;
            basis.at(2 * i + 1, 2 * sectionCount) = 0.0;
            basis.at(2 * i, 2 * sectionCount + 1) = z1.real();
            basis.at(2 * i + 1, 2 * sectionCount + 1) = z1.imag();
        }
        rhs[2 * i] = target[i].real();
        rhs[2 * i + 1] = target[i].imag();
    }

    const std::vector<double> weights = rowWeights(target, binWeight, config);
    const LeastSquaresResult solved = solveRidge(basis, rhs, weights, config.ridge);
    if (!solved.ok) return false;

    for (std::size_t s = 0; s < sectionCount; ++s) {
        design.sections[s].b0 = solved.x[2 * s];
        design.sections[s].b1 = solved.x[2 * s + 1];
    }
    if (directColumns == 2) {
        design.d0 = solved.x[2 * sectionCount];
        design.d1 = solved.x[2 * sectionCount + 1];
    } else {
        design.d0 = 0.0;
        design.d1 = 0.0;
    }

    if (residualNorm) {
        double weightSum = 0.0;
        for (double w : weights) weightSum += w;
        *residualNorm =
            weightSum > 0.0 ? solved.residualNorm / std::sqrt(weightSum) : solved.residualNorm;
    }
    return true;
}

namespace {

// One Gauss-Newton step on the pole centre frequencies, numerators held fixed.
//
// The response is linear in the numerators and not in the pole positions, so
// this alternates rather than solving jointly: move the poles a little, re-fit
// the numerators exactly, repeat.  Bounded per step and in total, for the same
// reason the cascade's centres are.
void refinePoleFrequencies(const std::vector<Complex>& target,
                           const std::vector<double>& binWeight,
                           const FrequencyGrid& grid,
                           double sampleRateHz,
                           const ParallelConfig& config,
                           const std::vector<double>& placedLogF,
                           ParallelDesign& design) {
    const std::size_t n = grid.size();
    const std::size_t sectionCount = design.sections.size();
    if (sectionCount == 0) return;

    constexpr double kLogFStep = 0.02;
    const double maxStep = std::log(2.0) / 6.0;
    const double maxDrift = std::log(2.0) * std::max(0.0, config.maxDriftOctaves);

    const std::vector<Complex> current = parallelResponse(design, grid, sampleRateHz);

    DenseMatrix jacobian(2 * n, sectionCount);
    std::vector<double> residual(2 * n, 0.0);
    for (std::size_t i = 0; i < n; ++i) {
        residual[2 * i] = target[i].real() - current[i].real();
        residual[2 * i + 1] = target[i].imag() - current[i].imag();
    }

    // Central differences in log frequency, one section at a time.
    for (std::size_t s = 0; s < sectionCount; ++s) {
        ParallelSection high = design.sections[s];
        ParallelSection low = design.sections[s];
        const double logF = std::log(design.sections[s].freqHz);
        setPole(high, std::exp(logF + kLogFStep), design.sections[s].q, sampleRateHz);
        setPole(low, std::exp(logF - kLogFStep), design.sections[s].q, sampleRateHz);

        for (std::size_t i = 0; i < n; ++i) {
            const double omega = 2.0 * kPi * grid.hz[i] / sampleRateHz;
            const Complex z1 = std::polar(1.0, -omega);
            const Complex z2 = z1 * z1;

            Complex highFirst, highSecond, lowFirst, lowSecond;
            poleBasis(high, z1, z2, highFirst, highSecond);
            poleBasis(low, z1, z2, lowFirst, lowSecond);

            const Complex derivative =
                ((design.sections[s].b0 * highFirst + design.sections[s].b1 * highSecond) -
                 (design.sections[s].b0 * lowFirst + design.sections[s].b1 * lowSecond)) /
                (2.0 * kLogFStep);
            jacobian.at(2 * i, s) = derivative.real();
            jacobian.at(2 * i + 1, s) = derivative.imag();
        }
    }

    std::vector<double> lower(sectionCount, 0.0);
    std::vector<double> upper(sectionCount, 0.0);
    for (std::size_t s = 0; s < sectionCount; ++s) {
        const double logF = std::log(design.sections[s].freqHz);
        const double floor = std::max(std::log(config.minFreqHz), placedLogF[s] - maxDrift);
        const double ceiling = std::min(std::log(std::min(config.maxFreqHz, 0.45 * sampleRateHz)),
                                        placedLogF[s] + maxDrift);
        lower[s] = std::max(floor - logF, -maxStep);
        upper[s] = std::min(ceiling - logF, maxStep);
        if (upper[s] < lower[s]) lower[s] = upper[s] = 0.0;
    }

    const std::vector<double> weights = rowWeights(target, binWeight, config);
    const LeastSquaresResult solved =
        solveBounded(jacobian, residual, weights, lower, upper, config.ridge);
    if (!solved.ok) return;

    for (std::size_t s = 0; s < sectionCount; ++s) {
        const double logF = std::log(design.sections[s].freqHz);
        const double moved = clampd(logF + solved.x[s],
                                    std::max(std::log(config.minFreqHz), placedLogF[s] - maxDrift),
                                    std::min(std::log(config.maxFreqHz), placedLogF[s] + maxDrift));
        setPole(design.sections[s], std::exp(moved), design.sections[s].q, sampleRateHz);
    }
}

}  // namespace

ParallelDesign designParallel(const FitProblem& problem,
                              const FitConfig& config,
                              const ParallelConfig& parallelConfig) {
    ParallelDesign design;

    const std::string problemError = problem.validate();
    if (!problemError.empty()) { design.message = problemError; return design; }
    if (parallelConfig.sections < 1) {
        design.message = "at least one section is required";
        return design;
    }

    const std::size_t n = problem.grid.size();
    const double sampleRateHz = problem.sampleRateHz;

    // Placement, driven by the uncorrected error exactly as the production fit
    // is, so the comparison isolates the structure rather than the allocator.
    std::vector<double> responseDb(n, 0.0);
    const CollapsedProblem uncorrected =
        collapsePositions(problem, responseDb, parallelConfig.huberDeltaDb);

    PlacementConfig placementConfig;
    placementConfig.count = parallelConfig.sections;
    placementConfig.minFreqHz = std::max(parallelConfig.minFreqHz, 1.0);
    placementConfig.maxFreqHz = std::min(parallelConfig.maxFreqHz, 0.45 * sampleRateHz);
    placementConfig.placementBias = parallelConfig.placementBias;
    placementConfig.minSpacingOctaves = parallelConfig.minSpacingOctaves;
    placementConfig.qFromFeatureWidth = parallelConfig.qFromFeatureWidth;
    // Bank's log spacing, weighted toward the modal region the way PORC's
    // default pole set is.
    placementConfig.logDensityLowShare = parallelConfig.logDensityLowShare;
    placementConfig.logDensityBreakHz = parallelConfig.logDensityBreakHz;
    // These are poles, not cut filters.  The frequency-dependent Q ceilings in
    // spec 7.3 exist to stop a *correction* being narrower than the measurement
    // supports; a pole's Q here decides how the bank partitions the band.
    placementConfig.qLimits.minQ = 0.5;
    placementConfig.qLimits.maxCutQBelowTransition = 200.0;
    placementConfig.qLimits.maxCutQAtTop = 200.0;
    placementConfig.qLimits.transitionHz = problem.statistics.transitionHz;

    const SectionPlacement placed =
        placeSections(problem.grid, uncorrected.errorDb, uncorrected.weight, placementConfig);
    if (placed.size() == 0) { design.message = "no correctable band"; return design; }

    design.sections.resize(placed.size());
    std::vector<double> placedLogF(placed.size(), 0.0);
    for (std::size_t i = 0; i < placed.size(); ++i) {
        setPole(design.sections[i], placed.freqHz[i], placed.q[i], sampleRateHz);
        placedLogF[i] = std::log(placed.freqHz[i]);
    }

    bool ok = false;
    for (int pass = 0; pass < std::max(1, parallelConfig.solvePasses); ++pass) {
        const CollapsedProblem collapsed =
            collapsePositions(problem, responseDb, parallelConfig.huberDeltaDb);
        const std::vector<Complex> target = minimumPhaseResponse(
            problem.grid, collapsed.errorDb, sampleRateHz, parallelConfig.phaseFftSize);

        ok = solveParallelNumerators(target, collapsed.weight, problem.grid, sampleRateHz,
                                     parallelConfig, design, &design.residualDb);
        if (!ok) { design.message = "the linear solve failed"; return design; }

        if (parallelConfig.refinePoles && pass > 0) {
            refinePoleFrequencies(target, collapsed.weight, problem.grid, sampleRateHz,
                                  parallelConfig, placedLogF, design);
            // The numerators were solved for the old poles; re-solve exactly
            // rather than carrying an approximation into the next pass.
            ok = solveParallelNumerators(target, collapsed.weight, problem.grid, sampleRateHz,
                                         parallelConfig, design, &design.residualDb);
            if (!ok) { design.message = "the linear solve failed"; return design; }
        }

        const std::vector<Complex> realized = parallelResponse(design, problem.grid, sampleRateHz);
        for (std::size_t i = 0; i < n; ++i) {
            responseDb[i] = 20.0 * std::log10(std::max(1e-9, std::abs(realized[i])));
        }
    }

    design.trimDb = requiredTrimDb(problem, config, responseDb);
    design.correctionDb = responseDb;
    for (double& v : design.correctionDb) v += design.trimDb;

    design.metrics = evaluateCorrection(problem, design.correctionDb);
    design.ok = ok;
    design.message = ok ? "solved" : "the linear solve failed";
    return design;
}

}  // namespace dspi_rc
