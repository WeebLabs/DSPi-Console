// Dense least squares with box constraints.
//
// The correction designer is a linear solve, so this is the whole numerical
// core of it.  Kept separate from the designer because both the production
// cascade fit and the reference parallel fit use it, and because a solver with
// its own tests is much easier to trust than one buried in a fitting loop.
//
// Small by design: the systems here are a few hundred to a few thousand rows by
// ten to fifty columns.  Nothing about this is written for large problems.
//
// Spec `room_correction_fixed_pole_design.md` §5.5, §5.7.
#pragma once

#include <cstddef>
#include <vector>

namespace dspi_rc {

// A dense matrix in row-major order.  A bare vector with a stride, rather than
// a matrix class, because it crosses no interface that would benefit from one.
struct DenseMatrix {
    std::size_t rows = 0;
    std::size_t cols = 0;
    std::vector<double> values;

    DenseMatrix() = default;
    DenseMatrix(std::size_t r, std::size_t c) : rows(r), cols(c), values(r * c, 0.0) {}

    double& at(std::size_t r, std::size_t c) { return values[r * cols + c]; }
    double at(std::size_t r, std::size_t c) const { return values[r * cols + c]; }
};

struct LeastSquaresResult {
    std::vector<double> x;

    // Norm of the weighted residual, excluding the ridge rows: the ridge is a
    // conditioning device and reporting it as fit error would make a
    // better-conditioned solve look worse.
    double residualNorm = 0.0;

    // Rank of the augmented system.  With a positive ridge this is always the
    // column count; it is reported anyway so a caller passing ridge 0 can tell.
    std::size_t rank = 0;

    // Active-set passes taken.  Bounded by construction; a caller seeing the
    // cap has a degenerate problem worth knowing about.
    int passes = 0;

    bool ok = false;
};

// Unconstrained weighted ridge least squares.
//
// Minimizes sum_r weight[r] * (A x - b)_r^2 plus a ridge penalty, by
// Householder QR on the weighted, ridge-augmented system.  `weight` may be
// empty, meaning uniform.  Weights are variance-style, applied as sqrt() to the
// rows, so a weight of zero removes a row rather than skewing it.
//
// **The ridge is relative to each column's own weighted norm**, not absolute
// and not relative to the matrix as a whole.  Columns are normalized before the
// solve and the coefficients unscaled afterwards, so `ridge` means the same
// thing whatever units a column happens to be in.
//
// This is not a refinement.  The parallel designer's columns span ten orders of
// magnitude - a pole placed at 24 Hz with a sample rate of 48 kHz sits at a
// radius of 0.9997 and its basis function has a gain in the thousands, while
// the direct path's column is a vector of ones - so a ridge scaled to the
// matrix trace is set by the largest column and annihilates the smallest.
// Measured on the acceptance fixtures, that put the direct path at 0.004
// instead of 1.0 and cost 28 dB of fit at the top of the band.
// `ridgeTarget`, when non-empty, is the point the penalty pulls toward instead
// of the origin.  A solver that only shrinks toward zero cannot express "prefer
// the answer we already had unless the data says otherwise", which is what
// breaks a degenerate direction in favour of something meaningful rather than
// something merely small.
LeastSquaresResult solveRidge(const DenseMatrix& a,
                              const std::vector<double>& b,
                              const std::vector<double>& weight,
                              double ridge,
                              const std::vector<double>& ridgeTarget = {});

// The same, subject to lower[i] <= x[i] <= upper[i].
//
// Solved by active set: hold the violating variables on their bounds, re-solve
// on the rest, and release a bound variable whenever the gradient says the
// objective would fall by moving it back into the interior.  That release step
// is what makes the answer the true constrained minimizer rather than merely a
// feasible point, and it is the part a naive clamp-and-resolve omits.
//
// Use a non-finite bound (std::numeric_limits<double>::infinity()) for a free
// coordinate; the offset column the designers append is exactly that.
LeastSquaresResult solveBounded(const DenseMatrix& a,
                                const std::vector<double>& b,
                                const std::vector<double>& weight,
                                const std::vector<double>& lower,
                                const std::vector<double>& upper,
                                double ridge,
                                const std::vector<double>& ridgeTarget = {});

}  // namespace dspi_rc
