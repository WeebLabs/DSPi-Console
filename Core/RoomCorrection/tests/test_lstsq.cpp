// The solver under the correction designer.
//
// Tested against analytic landmarks and against brute force on problems small
// enough to solve by exhaustive search, rather than by re-deriving Householder
// QR: re-deriving the algorithm only proves the test and the implementation
// share a typo.
#include "dspi_rc/lstsq.hpp"

#include <cmath>
#include <limits>
#include <vector>

#include "testing.hpp"

using namespace dspi_rc;

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();

// Objective the solvers minimize, computed independently for cross-checking.
double objective(const DenseMatrix& a, const std::vector<double>& b,
                 const std::vector<double>& weight, const std::vector<double>& x,
                 double ridge) {
    double total = 0.0;
    for (std::size_t r = 0; r < a.rows; ++r) {
        double predicted = 0.0;
        for (std::size_t c = 0; c < a.cols; ++c) predicted += a.at(r, c) * x[c];
        const double residual = predicted - b[r];
        const double w = weight.empty() ? 1.0 : weight[r];
        total += w * residual * residual;
    }
    for (double v : x) total += ridge * v * v;
    return total;
}

}  // namespace

TEST_CASE(exactly_determined_system_is_solved_exactly) {
    // x0 + x1 = 3, x0 - x1 = 1  =>  x = (2, 1)
    DenseMatrix a(2, 2);
    a.at(0, 0) = 1.0; a.at(0, 1) = 1.0;
    a.at(1, 0) = 1.0; a.at(1, 1) = -1.0;
    const std::vector<double> b{3.0, 1.0};

    const LeastSquaresResult result = solveRidge(a, b, {}, 0.0);
    CHECK(result.ok);
    CHECK(result.rank == 2);
    CHECK_NEAR(result.x[0], 2.0, 1e-12);
    CHECK_NEAR(result.x[1], 1.0, 1e-12);
    CHECK_NEAR(result.residualNorm, 0.0, 1e-12);
}

TEST_CASE(overdetermined_fit_recovers_the_generating_line) {
    // Fit c + m*t to samples of 2 + 3t, which has an exact solution despite
    // being overdetermined.
    DenseMatrix a(6, 2);
    std::vector<double> b(6, 0.0);
    for (std::size_t i = 0; i < 6; ++i) {
        const double t = static_cast<double>(i);
        a.at(i, 0) = 1.0;
        a.at(i, 1) = t;
        b[i] = 2.0 + 3.0 * t;
    }

    const LeastSquaresResult result = solveRidge(a, b, {}, 0.0);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0], 2.0, 1e-10);
    CHECK_NEAR(result.x[1], 3.0, 1e-10);
}

TEST_CASE(a_zero_weight_row_is_ignored_rather_than_skewing_the_fit) {
    DenseMatrix a(3, 1);
    a.at(0, 0) = 1.0;
    a.at(1, 0) = 1.0;
    a.at(2, 0) = 1.0;
    // The third observation is wild, and carries no weight.
    const std::vector<double> b{5.0, 5.0, 1000.0};
    const std::vector<double> weight{1.0, 1.0, 0.0};

    const LeastSquaresResult result = solveRidge(a, b, weight, 0.0);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0], 5.0, 1e-10);
}

TEST_CASE(the_residual_norm_excludes_the_ridge_rows) {
    // A ridge that visibly moves the solution must not also be reported as fit
    // error, or a better-conditioned solve would look worse than a worse one.
    DenseMatrix a(1, 1);
    a.at(0, 0) = 1.0;
    const std::vector<double> b{10.0};

    const LeastSquaresResult result = solveRidge(a, b, {}, 1.0);
    CHECK(result.ok);
    // Minimizing (x-10)^2 + x^2 gives x = 5.
    CHECK_NEAR(result.x[0], 5.0, 1e-12);
    CHECK_NEAR(result.residualNorm, 5.0, 1e-12);
}

TEST_CASE(the_ridge_shrinks_the_solution_toward_zero) {
    DenseMatrix a(4, 2);
    std::vector<double> b(4, 0.0);
    for (std::size_t i = 0; i < 4; ++i) {
        a.at(i, 0) = 1.0;
        a.at(i, 1) = static_cast<double>(i);
        b[i] = 4.0 + 2.0 * static_cast<double>(i);
    }

    const LeastSquaresResult plain = solveRidge(a, b, {}, 0.0);
    const LeastSquaresResult ridged = solveRidge(a, b, {}, 5.0);
    CHECK(plain.ok && ridged.ok);

    // The ridge penalizes the solution's norm, not each coordinate: a large
    // ridge can grow one coefficient while shrinking the vector, which is
    // exactly the trade the cancelling-pair guard relies on.
    const double plainNorm = std::hypot(plain.x[0], plain.x[1]);
    const double ridgedNorm = std::hypot(ridged.x[0], ridged.x[1]);
    CHECK(ridgedNorm < plainNorm);
}

TEST_CASE(bounds_hold_and_the_bounded_answer_beats_every_feasible_neighbour) {
    // Unconstrained the fit wants x = (2, 1); the upper bound on x0 forces it
    // somewhere else, and the whole point of the active set is that the *other*
    // coordinate then moves to compensate rather than staying put.
    DenseMatrix a(2, 2);
    a.at(0, 0) = 1.0; a.at(0, 1) = 1.0;
    a.at(1, 0) = 1.0; a.at(1, 1) = -1.0;
    const std::vector<double> b{3.0, 1.0};
    const std::vector<double> lower{-10.0, -10.0};
    const std::vector<double> upper{0.5, 10.0};

    const LeastSquaresResult result = solveBounded(a, b, {}, lower, upper, 0.0);
    CHECK(result.ok);
    CHECK(result.x[0] <= upper[0] + 1e-12);
    CHECK(result.x[0] >= lower[0] - 1e-12);

    // x0 pinned at 0.5, minimizing over x1 alone gives x1 = 1.
    CHECK_NEAR(result.x[0], 0.5, 1e-9);
    CHECK_NEAR(result.x[1], 1.0, 1e-9);

    // Brute force over the feasible box, to confirm the reported point is the
    // minimizer rather than merely feasible.
    const double best = objective(a, b, {}, result.x, 0.0);
    for (int i = 0; i <= 200; ++i) {
        for (int j = 0; j <= 200; ++j) {
            std::vector<double> probe{
                lower[0] + (upper[0] - lower[0]) * static_cast<double>(i) / 200.0,
                lower[1] + (upper[1] - lower[1]) * static_cast<double>(j) / 200.0};
            CHECK(objective(a, b, {}, probe, 0.0) >= best - 1e-6);
        }
    }
}

TEST_CASE(a_variable_is_released_when_the_optimum_moves_back_inside) {
    // Two nearly collinear columns, which is exactly the configuration where a
    // clamp-and-resolve scheme parks a variable on a bound and never revisits
    // it.  The unconstrained optimum is interior, so a correct active set must
    // end with nothing fixed.
    DenseMatrix a(3, 2);
    a.at(0, 0) = 1.0;  a.at(0, 1) = 0.99;
    a.at(1, 0) = 1.0;  a.at(1, 1) = 1.01;
    a.at(2, 0) = 1.0;  a.at(2, 1) = 1.00;
    const std::vector<double> b{2.0, 2.0, 2.0};
    const std::vector<double> lower{-50.0, -50.0};
    const std::vector<double> upper{50.0, 50.0};

    const LeastSquaresResult result = solveBounded(a, b, {}, lower, upper, 1e-6);
    CHECK(result.ok);
    for (std::size_t c = 0; c < 2; ++c) {
        CHECK(result.x[c] > lower[c] + 1e-9);
        CHECK(result.x[c] < upper[c] - 1e-9);
    }
    // The two columns are interchangeable, so only their sum is determined.
    CHECK_NEAR(result.x[0] + result.x[1], 2.0, 1e-3);
}

TEST_CASE(an_infinite_bound_leaves_a_coordinate_free) {
    // The designers append an unbounded offset column; it must not be dragged
    // to a bound by the active set.
    DenseMatrix a(2, 2);
    a.at(0, 0) = 1.0; a.at(0, 1) = 1.0;
    a.at(1, 0) = 0.0; a.at(1, 1) = 1.0;
    const std::vector<double> b{7.0, 4.0};
    const std::vector<double> lower{0.0, -kInfinity};
    const std::vector<double> upper{0.0, kInfinity};

    const LeastSquaresResult result = solveBounded(a, b, {}, lower, upper, 0.0);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0], 0.0, 1e-12);
    // With x0 pinned at 0 the best x1 splits the two observations.
    CHECK_NEAR(result.x[1], 5.5, 1e-9);
}

TEST_CASE(bounds_that_exclude_zero_still_produce_a_feasible_answer) {
    // The initial point is chosen as the feasible point nearest zero, which has
    // to cope with a box that does not contain zero at all.
    DenseMatrix a(2, 1);
    a.at(0, 0) = 1.0;
    a.at(1, 0) = 1.0;
    const std::vector<double> b{0.0, 0.0};
    const std::vector<double> lower{3.0};
    const std::vector<double> upper{9.0};

    const LeastSquaresResult result = solveBounded(a, b, {}, lower, upper, 0.0);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0], 3.0, 1e-9);
}

TEST_CASE(a_degenerate_problem_is_rejected_rather_than_answered) {
    DenseMatrix empty;
    const LeastSquaresResult result = solveRidge(empty, {}, {}, 0.0);
    CHECK(!result.ok);

    DenseMatrix a(2, 1);
    a.at(0, 0) = 1.0;
    a.at(1, 0) = 1.0;
    const std::vector<double> b{1.0, 1.0};
    const std::vector<double> shortBounds{0.0};
    const LeastSquaresResult mismatched = solveBounded(a, b, {}, shortBounds, {}, 0.0);
    CHECK(!mismatched.ok);
}

TEST_CASE(the_ridge_pulls_toward_its_target_rather_than_the_origin) {
    // Shrinking toward zero cannot express "prefer the answer we already had",
    // which is what decides a flat direction on the merits instead of merely
    // making it small.
    DenseMatrix a(1, 1);
    a.at(0, 0) = 1.0;
    const std::vector<double> b{10.0};
    const std::vector<double> target{6.0};

    // Minimizing (x-10)^2 + (x-6)^2 gives x = 8.
    const LeastSquaresResult result = solveRidge(a, b, {}, 1.0, target);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0], 8.0, 1e-12);

    // The residual is still measured against the data, not against the target.
    CHECK_NEAR(result.residualNorm, 2.0, 1e-12);
}

TEST_CASE(a_ridge_target_of_the_wrong_length_is_rejected) {
    DenseMatrix a(2, 2);
    a.at(0, 0) = 1.0; a.at(1, 1) = 1.0;
    const std::vector<double> b{1.0, 1.0};
    const std::vector<double> tooShort{0.0};
    CHECK(!solveRidge(a, b, {}, 1.0, tooShort).ok);

    const std::vector<double> lower{-1.0, -1.0};
    const std::vector<double> upper{1.0, 1.0};
    CHECK(!solveBounded(a, b, {}, lower, upper, 1.0, tooShort).ok);
}

TEST_CASE(a_degenerate_direction_settles_on_the_ridge_target) {
    // Two identical columns: only their sum is determined by the data, and the
    // ridge target decides how that sum is split.  This is the configuration
    // the designer relies on to stop a level walk-down.
    DenseMatrix a(2, 2);
    a.at(0, 0) = 1.0; a.at(0, 1) = 1.0;
    a.at(1, 0) = 1.0; a.at(1, 1) = 1.0;
    const std::vector<double> b{4.0, 4.0};
    const std::vector<double> target{3.0, 0.0};

    const LeastSquaresResult result = solveRidge(a, b, {}, 1e-6, target);
    CHECK(result.ok);
    CHECK_NEAR(result.x[0] + result.x[1], 4.0, 1e-3);
    // The split follows the target: the coordinate it favours takes more.
    CHECK(result.x[0] > result.x[1]);
}
