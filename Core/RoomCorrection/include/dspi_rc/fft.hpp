// Minimal portable FFT.
//
// Deliberately a small in-tree implementation rather than a dependency.  The
// sizes involved here are measurement-sized (a few hundred thousand points,
// once per sweep), not real-time, so a clean radix-2 Stockham-style iterative
// transform is fast enough and costs nothing in build complexity or licensing.
//
// Spec §9.1 requires FFT to sit behind an interface so a platform adapter
// (Accelerate on macOS) can be substituted later.  `Fft` is that seam: swap
// the implementation, keep the signature, and the golden tests decide whether
// the substitution was legitimate.
#pragma once

#include <complex>
#include <cstddef>
#include <vector>

namespace dspi_rc {

using Complex = std::complex<double>;

// Smallest power of two >= n.  Exposed because callers sizing padding for
// linear (non-circular) convolution need the same rule.
std::size_t nextPowerOfTwo(std::size_t n);

// In-place complex FFT.  `data.size()` must be a power of two.
// `inverse == true` applies the 1/N scaling, so forward-then-inverse is
// identity.
void fftInPlace(std::vector<Complex>& data, bool inverse);

// Real input -> full complex spectrum, zero-padded up to `fftSize`.
// Returns `fftSize` bins (the redundant upper half included, so callers can
// index symmetrically without special-casing Nyquist).
std::vector<Complex> forwardReal(const std::vector<double>& samples, std::size_t fftSize);

// Complex spectrum -> real signal, discarding the imaginary residue.
std::vector<double> inverseToReal(std::vector<Complex> spectrum);

// Linear convolution via FFT.  Result length is a.size() + b.size() - 1.
// Zero-pads to avoid the circular wraparound that would otherwise fold a
// sweep's tail onto its head and quietly corrupt the impulse response.
std::vector<double> convolve(const std::vector<double>& a, const std::vector<double>& b);

// Cross-correlation of `a` against `b`, returned at lags
// [-(b.size()-1) .. a.size()-1] with index 0 corresponding to the most
// negative lag.  Used to locate a sweep inside a capture.
std::vector<double> crossCorrelate(const std::vector<double>& a,
                                   const std::vector<double>& b);

}  // namespace dspi_rc
