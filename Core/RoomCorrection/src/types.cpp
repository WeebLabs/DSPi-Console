#include "dspi_rc/types.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {

FrequencyGrid FrequencyGrid::logSpaced(double minHz, double maxHz, int pointsPerOctave) {
    FrequencyGrid grid;
    if (minHz <= 0.0 || maxHz <= minHz || pointsPerOctave <= 0) return grid;

    const double octaves = std::log2(maxHz / minHz);
    // Inclusive of both endpoints, so a 10 Hz to 20 kHz grid actually contains
    // 10 and 20000 rather than stopping just short of them.
    const auto count = static_cast<std::size_t>(std::llround(octaves * pointsPerOctave)) + 1;

    grid.hz.reserve(count);
    const double step = octaves / static_cast<double>(count - 1);
    for (std::size_t i = 0; i < count; ++i) {
        grid.hz.push_back(minHz * std::pow(2.0, step * static_cast<double>(i)));
    }
    // Pin the last point exactly, so callers comparing against maxHz do not
    // trip over accumulated rounding.
    grid.hz.back() = maxHz;
    return grid;
}

double FrequencyGrid::pointsPerOctave() const {
    if (hz.size() < 2) return 0.0;
    std::vector<double> steps;
    steps.reserve(hz.size() - 1);
    for (std::size_t i = 1; i < hz.size(); ++i) {
        if (hz[i] > 0.0 && hz[i - 1] > 0.0) {
            steps.push_back(std::log2(hz[i] / hz[i - 1]));
        }
    }
    if (steps.empty()) return 0.0;
    // Median rather than mean: robust to a grid that has been trimmed or
    // concatenated and so has one irregular step.
    std::sort(steps.begin(), steps.end());
    const double median = steps[steps.size() / 2];
    return median > 0.0 ? 1.0 / median : 0.0;
}

}  // namespace dspi_rc
