#include "dspi_rc/lstsq.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

// Householder QR of an m-by-n system, applied to the right-hand side as it
// goes, followed by back substitution.  `m` is expected to be at least `n`,
// which the ridge augmentation guarantees.
//
// Returns the rank found; columns whose pivot falls below the tolerance are
// treated as dependent and their coefficient is left at zero, which is the
// conventional minimum-norm-ish response and cannot happen at all when the
// caller passes a positive ridge.
std::size_t householderSolve(std::vector<double>& m,   // rows*cols, row-major, destroyed
                             std::vector<double>& y,   // rows, destroyed
                             std::size_t rows,
                             std::size_t cols,
                             std::vector<double>& x) {
    x.assign(cols, 0.0);
    if (rows == 0 || cols == 0) return 0;

    std::vector<double> v(rows, 0.0);
    std::vector<double> pivots(cols, 0.0);

    for (std::size_t k = 0; k < cols && k < rows; ++k) {
        // Householder vector for column k below the diagonal.
        double norm = 0.0;
        for (std::size_t r = k; r < rows; ++r) {
            const double a = m[r * cols + k];
            norm += a * a;
        }
        norm = std::sqrt(norm);
        if (norm == 0.0) { pivots[k] = 0.0; continue; }

        const double alpha = (m[k * cols + k] > 0.0) ? -norm : norm;
        for (std::size_t r = k; r < rows; ++r) v[r] = m[r * cols + k];
        v[k] -= alpha;

        double vNorm2 = 0.0;
        for (std::size_t r = k; r < rows; ++r) vNorm2 += v[r] * v[r];
        if (vNorm2 <= 0.0) { pivots[k] = std::fabs(alpha); m[k * cols + k] = alpha; continue; }

        // Apply H = I - 2vv'/v'v to the remaining columns and to y.
        for (std::size_t c = k; c < cols; ++c) {
            double dot = 0.0;
            for (std::size_t r = k; r < rows; ++r) dot += v[r] * m[r * cols + c];
            const double scale = 2.0 * dot / vNorm2;
            for (std::size_t r = k; r < rows; ++r) m[r * cols + c] -= scale * v[r];
        }
        double dotY = 0.0;
        for (std::size_t r = k; r < rows; ++r) dotY += v[r] * y[r];
        const double scaleY = 2.0 * dotY / vNorm2;
        for (std::size_t r = k; r < rows; ++r) y[r] -= scaleY * v[r];

        pivots[k] = std::fabs(m[k * cols + k]);
    }

    double maxPivot = 0.0;
    for (double p : pivots) maxPivot = std::max(maxPivot, p);
    const double tolerance = maxPivot * 1e-12;

    std::size_t rank = 0;
    for (std::size_t k = 0; k < cols; ++k) {
        if (pivots[k] > tolerance) ++rank;
    }

    // Back substitution, skipping dependent columns.
    for (std::size_t step = cols; step > 0; --step) {
        const std::size_t k = step - 1;
        if (k >= rows || pivots[k] <= tolerance) { x[k] = 0.0; continue; }
        double sum = y[k];
        for (std::size_t c = k + 1; c < cols; ++c) sum -= m[k * cols + c] * x[c];
        x[k] = sum / m[k * cols + k];
    }

    return rank;
}

// Weighted 2-norm of each column, which is the scale the ridge is expressed
// against.  A column that is entirely zeroed by the weights gets a norm of one
// so it is left alone rather than divided by nothing.
std::vector<double> columnNorms(const DenseMatrix& a, const std::vector<double>& weight) {
    std::vector<double> norms(a.cols, 0.0);
    for (std::size_t c = 0; c < a.cols; ++c) {
        double sum = 0.0;
        for (std::size_t r = 0; r < a.rows; ++r) {
            const double w = weight.empty() ? 1.0 : std::max(0.0, weight[r]);
            sum += w * a.at(r, c) * a.at(r, c);
        }
        norms[c] = sum > 0.0 ? std::sqrt(sum) : 1.0;
    }
    return norms;
}

// Assemble the weighted, ridge-augmented system for a subset of columns, with
// the fixed columns' contributions already moved to the right-hand side and the
// free columns normalized.  The caller unscales the answer by `norms`.
void buildSystem(const DenseMatrix& a,
                 const std::vector<double>& b,
                 const std::vector<double>& weight,
                 const std::vector<double>& norms,
                 const std::vector<std::size_t>& freeColumns,
                 const std::vector<double>& fixedValues,
                 const std::vector<bool>& isFixed,
                 double ridge,
                 const std::vector<double>& ridgeTarget,
                 std::vector<double>& outM,
                 std::vector<double>& outY,
                 std::size_t& outRows) {
    const std::size_t n = freeColumns.size();
    outRows = a.rows + n;
    outM.assign(outRows * n, 0.0);
    outY.assign(outRows, 0.0);

    const double ridgeRoot = std::sqrt(std::max(0.0, ridge));

    for (std::size_t r = 0; r < a.rows; ++r) {
        const double w = weight.empty() ? 1.0 : std::max(0.0, weight[r]);
        const double root = std::sqrt(w);
        if (root == 0.0) continue;

        double rhs = b[r];
        for (std::size_t c = 0; c < a.cols; ++c) {
            if (isFixed[c] && fixedValues[c] != 0.0) rhs -= a.at(r, c) * fixedValues[c];
        }
        outY[r] = root * rhs;
        for (std::size_t j = 0; j < n; ++j) {
            const std::size_t c = freeColumns[j];
            outM[r * n + j] = root * a.at(r, c) / norms[c];
        }
    }

    // Uniform, because the columns above are now unit norm.  That is the whole
    // point: the ridge shrinks each coefficient in proportion to how much its
    // column actually contributes, rather than in proportion to the units it
    // happens to be measured in.
    for (std::size_t j = 0; j < n; ++j) {
        const std::size_t c = freeColumns[j];
        outM[(a.rows + j) * n + j] = ridgeRoot;
        // Scaled the same way the column was, so the target is expressed in the
        // caller's units on both sides.
        outY[a.rows + j] =
            ridgeTarget.empty() ? 0.0 : ridgeRoot * ridgeTarget[c] * norms[c];
    }
}

double weightedResidualNorm(const DenseMatrix& a,
                            const std::vector<double>& b,
                            const std::vector<double>& weight,
                            const std::vector<double>& x) {
    double sum = 0.0;
    for (std::size_t r = 0; r < a.rows; ++r) {
        const double w = weight.empty() ? 1.0 : std::max(0.0, weight[r]);
        if (w == 0.0) continue;
        double predicted = 0.0;
        for (std::size_t c = 0; c < a.cols; ++c) predicted += a.at(r, c) * x[c];
        const double residual = predicted - b[r];
        sum += w * residual * residual;
    }
    return std::sqrt(sum);
}

// Gradient of the weighted ridge objective, used to decide which bound
// variables want to be released.
std::vector<double> gradient(const DenseMatrix& a,
                             const std::vector<double>& b,
                             const std::vector<double>& weight,
                             const std::vector<double>& norms,
                             const std::vector<double>& x,
                             double ridge,
                             const std::vector<double>& ridgeTarget) {
    std::vector<double> g(a.cols, 0.0);
    for (std::size_t r = 0; r < a.rows; ++r) {
        const double w = weight.empty() ? 1.0 : std::max(0.0, weight[r]);
        if (w == 0.0) continue;
        double predicted = 0.0;
        for (std::size_t c = 0; c < a.cols; ++c) predicted += a.at(r, c) * x[c];
        const double scaled = 2.0 * w * (predicted - b[r]);
        for (std::size_t c = 0; c < a.cols; ++c) g[c] += scaled * a.at(r, c);
    }
    // The penalty is on the normalized coefficients, so its gradient in the
    // caller's units carries the column scale squared.
    for (std::size_t c = 0; c < a.cols; ++c) {
        const double target = ridgeTarget.empty() ? 0.0 : ridgeTarget[c];
        g[c] += 2.0 * ridge * norms[c] * norms[c] * (x[c] - target);
    }
    return g;
}

}  // namespace

LeastSquaresResult solveRidge(const DenseMatrix& a,
                              const std::vector<double>& b,
                              const std::vector<double>& weight,
                              double ridge,
                              const std::vector<double>& ridgeTarget) {
    LeastSquaresResult result;
    if (a.rows == 0 || a.cols == 0 || b.size() < a.rows) return result;
    if (!weight.empty() && weight.size() < a.rows) return result;
    if (!ridgeTarget.empty() && ridgeTarget.size() != a.cols) return result;

    std::vector<std::size_t> freeColumns(a.cols);
    for (std::size_t c = 0; c < a.cols; ++c) freeColumns[c] = c;
    const std::vector<double> fixedValues(a.cols, 0.0);
    const std::vector<bool> isFixed(a.cols, false);
    const std::vector<double> norms = columnNorms(a, weight);

    std::vector<double> m, y, x;
    std::size_t rows = 0;
    buildSystem(a, b, weight, norms, freeColumns, fixedValues, isFixed, ridge,
                ridgeTarget, m, y, rows);
    result.rank = householderSolve(m, y, rows, a.cols, x);
    for (std::size_t c = 0; c < a.cols; ++c) x[c] /= norms[c];
    result.x = std::move(x);
    result.residualNorm = weightedResidualNorm(a, b, weight, result.x);
    result.passes = 1;
    result.ok = true;
    return result;
}

LeastSquaresResult solveBounded(const DenseMatrix& a,
                                const std::vector<double>& b,
                                const std::vector<double>& weight,
                                const std::vector<double>& lower,
                                const std::vector<double>& upper,
                                double ridge,
                                const std::vector<double>& ridgeTarget) {
    LeastSquaresResult result;
    if (a.rows == 0 || a.cols == 0 || b.size() < a.rows) return result;
    if (lower.size() != a.cols || upper.size() != a.cols) return result;
    if (!weight.empty() && weight.size() < a.rows) return result;
    if (!ridgeTarget.empty() && ridgeTarget.size() != a.cols) return result;

    const std::size_t n = a.cols;
    std::vector<bool> isFixed(n, false);
    std::vector<double> value(n, 0.0);
    const std::vector<double> norms = columnNorms(a, weight);

    // Start from the feasible point nearest zero.  A coordinate whose bounds
    // exclude zero starts on the nearer bound rather than at an infeasible 0,
    // so the first solve is already inside the box.
    for (std::size_t c = 0; c < n; ++c) {
        value[c] = std::min(std::max(0.0, lower[c]), upper[c]);
    }

    // Each pass either fixes a variable or releases one, and both strictly
    // reduce the objective, so this terminates.  The cap is a backstop against
    // a cycle induced by rounding, not an expected exit.
    const int maxPasses = static_cast<int>(4 * n) + 8;
    int passes = 0;
    std::size_t rank = 0;

    while (passes < maxPasses) {
        ++passes;

        std::vector<std::size_t> freeColumns;
        freeColumns.reserve(n);
        for (std::size_t c = 0; c < n; ++c) {
            if (!isFixed[c]) freeColumns.push_back(c);
        }

        std::vector<double> candidate = value;
        if (!freeColumns.empty()) {
            std::vector<double> m, y, x;
            std::size_t rows = 0;
            buildSystem(a, b, weight, norms, freeColumns, value, isFixed, ridge,
                        ridgeTarget, m, y, rows);
            rank = householderSolve(m, y, rows, freeColumns.size(), x);
            for (std::size_t j = 0; j < freeColumns.size(); ++j) {
                candidate[freeColumns[j]] = x[j] / norms[freeColumns[j]];
            }
        }

        // Fix the worst bound violation, measured relative to the coordinate's
        // own scale so one large-gain section cannot always win the race.
        std::size_t worst = n;
        double worstExcess = 0.0;
        for (std::size_t j : freeColumns) {
            double excess = 0.0;
            if (candidate[j] < lower[j]) excess = lower[j] - candidate[j];
            else if (candidate[j] > upper[j]) excess = candidate[j] - upper[j];
            if (excess > worstExcess) { worstExcess = excess; worst = j; }
        }

        if (worst != n) {
            isFixed[worst] = true;
            value[worst] = (candidate[worst] < lower[worst]) ? lower[worst] : upper[worst];
            // The other free coordinates are re-solved next pass against the
            // newly fixed one, so their candidate values are discarded rather
            // than kept: keeping them would leave the point off the solution
            // manifold of every subproblem.
            continue;
        }

        value = candidate;

        // Feasible and optimal on the free set.  Release a bound variable if
        // the gradient says the objective falls by moving it inward.
        const std::vector<double> g = gradient(a, b, weight, norms, value, ridge, ridgeTarget);
        double gradientScale = 0.0;
        for (double component : g) gradientScale = std::max(gradientScale, std::fabs(component));
        const double releaseTolerance = std::max(1e-12, 1e-9 * gradientScale);

        std::size_t release = n;
        double bestGain = releaseTolerance;
        for (std::size_t c = 0; c < n; ++c) {
            if (!isFixed[c]) continue;
            // A coordinate whose bounds coincide has nowhere to go.  Releasing
            // it would let the next pass re-fix it at the same value, and the
            // pair would cycle until the backstop fired: the gradient promises
            // an improvement that the box cannot deliver.
            if (!(lower[c] < upper[c])) continue;

            const bool atLower = value[c] <= lower[c];
            // Moving up from a lower bound helps when the gradient is negative;
            // moving down from an upper bound helps when it is positive.
            const double gain = atLower ? -g[c] : g[c];
            if (gain > bestGain) { bestGain = gain; release = c; }
        }

        if (release == n) break;
        isFixed[release] = false;
    }

    result.x = std::move(value);
    result.rank = rank;
    result.passes = passes;
    result.residualNorm = weightedResidualNorm(a, b, weight, result.x);
    result.ok = passes < maxPasses;
    return result;
}

}  // namespace dspi_rc
