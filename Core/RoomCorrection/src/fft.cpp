#include "dspi_rc/fft.hpp"

#include <algorithm>
#include <cmath>

// For kPi.  fft.hpp stays free of the core value types so it can be lifted
// out on its own, but the implementation may use them.
#include "dspi_rc/types.hpp"

namespace dspi_rc {

std::size_t nextPowerOfTwo(std::size_t n) {
    if (n <= 1) return 1;
    std::size_t power = 1;
    while (power < n) power <<= 1;
    return power;
}

void fftInPlace(std::vector<Complex>& data, bool inverse) {
    const std::size_t n = data.size();
    if (n < 2) return;
    if ((n & (n - 1)) != 0) return;  // not a power of two; caller error

    // Bit-reversal permutation.
    for (std::size_t i = 1, j = 0; i < n; ++i) {
        std::size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(data[i], data[j]);
    }

    const double sign = inverse ? 1.0 : -1.0;
    for (std::size_t len = 2; len <= n; len <<= 1) {
        const double theta = sign * 2.0 * kPi / static_cast<double>(len);
        const Complex step(std::cos(theta), std::sin(theta));
        for (std::size_t i = 0; i < n; i += len) {
            Complex w(1.0, 0.0);
            for (std::size_t k = 0; k < len / 2; ++k) {
                const Complex u = data[i + k];
                const Complex v = data[i + k + len / 2] * w;
                data[i + k] = u + v;
                data[i + k + len / 2] = u - v;
                w *= step;
            }
        }
    }

    if (inverse) {
        const double scale = 1.0 / static_cast<double>(n);
        for (Complex& c : data) c *= scale;
    }
}

std::vector<Complex> forwardReal(const std::vector<double>& samples, std::size_t fftSize) {
    std::vector<Complex> buffer(fftSize, Complex(0.0, 0.0));
    const std::size_t count = std::min(samples.size(), fftSize);
    for (std::size_t i = 0; i < count; ++i) buffer[i] = Complex(samples[i], 0.0);
    fftInPlace(buffer, false);
    return buffer;
}

std::vector<double> inverseToReal(std::vector<Complex> spectrum) {
    fftInPlace(spectrum, true);
    std::vector<double> out;
    out.reserve(spectrum.size());
    for (const Complex& c : spectrum) out.push_back(c.real());
    return out;
}

std::vector<double> convolve(const std::vector<double>& a, const std::vector<double>& b) {
    if (a.empty() || b.empty()) return {};
    const std::size_t resultLength = a.size() + b.size() - 1;
    const std::size_t fftSize = nextPowerOfTwo(resultLength);

    std::vector<Complex> fa = forwardReal(a, fftSize);
    const std::vector<Complex> fb = forwardReal(b, fftSize);
    for (std::size_t i = 0; i < fftSize; ++i) fa[i] *= fb[i];

    std::vector<double> full = inverseToReal(std::move(fa));
    full.resize(resultLength);
    return full;
}

std::vector<double> crossCorrelate(const std::vector<double>& a,
                                   const std::vector<double>& b) {
    if (a.empty() || b.empty()) return {};
    // Correlation is convolution with the reversed kernel.
    std::vector<double> reversed(b.rbegin(), b.rend());
    return convolve(a, reversed);
}

}  // namespace dspi_rc
