#include "dspi_rc/sweep.hpp"

#include <algorithm>
#include <cmath>
#include <string>

#include "dspi_rc/fft.hpp"
#include "dspi_rc/types.hpp"   // kPi

namespace dspi_rc {
namespace {

std::size_t secondsToSamples(double seconds, double sampleRateHz) {
    if (seconds <= 0.0) return 0;
    return static_cast<std::size_t>(std::llround(seconds * sampleRateHz));
}

// Raised-cosine rise from 0 to 1 over `length` samples.
double raisedCosineRise(std::size_t index, std::size_t length) {
    if (length == 0) return 1.0;
    const double x = static_cast<double>(index) / static_cast<double>(length);
    return 0.5 * (1.0 - std::cos(kPi * std::min(1.0, x)));
}

}  // namespace

// ---------------------------------------------------------------------------

std::size_t SweepSpec::sweepSamples() const {
    return secondsToSamples(durationSeconds, sampleRateHz);
}
std::size_t SweepSpec::preRollSamples() const {
    return secondsToSamples(preRollSeconds, sampleRateHz);
}
std::size_t SweepSpec::postRollSamples() const {
    return secondsToSamples(postRollSeconds, sampleRateHz);
}
std::size_t SweepSpec::totalSamples() const {
    return preRollSamples() + sweepSamples() + postRollSamples();
}

std::string SweepSpec::validate() const {
    if (sampleRateHz <= 0.0) return "sample rate must be positive";
    if (startHz <= 0.0) return "start frequency must be positive";
    if (endHz <= startHz) return "end frequency must be above start frequency";
    if (endHz >= sampleRateHz * 0.5) return "end frequency must be below Nyquist";
    if (durationSeconds <= 0.0) return "duration must be positive";
    if (amplitude <= 0.0 || amplitude > 1.0) return "amplitude must be in (0, 1]";
    if (fadeInSeconds < 0.0 || fadeOutSeconds < 0.0) return "fades must not be negative";
    if (fadeInSeconds + fadeOutSeconds >= durationSeconds) {
        return "fades must be shorter than the sweep";
    }
    if (preRollSeconds < 0.0 || postRollSeconds < 0.0) return "padding must not be negative";
    // A sweep too short to resolve its own low end produces a measurement that
    // looks plausible and is not.  One cycle at the start frequency is the
    // absolute floor; in practice the low end wants far more.
    if (durationSeconds < 1.0 / startHz) return "duration is too short for the start frequency";
    return {};
}

// ---------------------------------------------------------------------------

std::vector<double> generateSweep(const SweepSpec& spec) {
    const std::size_t n = spec.sweepSamples();
    std::vector<double> out(n, 0.0);
    if (n == 0) return out;

    const double T = static_cast<double>(n) / spec.sampleRateHz;
    const double logRatio = std::log(spec.endHz / spec.startHz);

    // Farina exponential sweep:
    //   phi(t) = 2*pi*f1*T/ln(f2/f1) * (exp(t/T * ln(f2/f1)) - 1)
    // Instantaneous frequency is f1*(f2/f1)^(t/T), by construction.
    const double k = 2.0 * kPi * spec.startHz * T / logRatio;

    const std::size_t fadeIn = secondsToSamples(spec.fadeInSeconds, spec.sampleRateHz);
    const std::size_t fadeOut = secondsToSamples(spec.fadeOutSeconds, spec.sampleRateHz);

    for (std::size_t i = 0; i < n; ++i) {
        const double t = static_cast<double>(i) / spec.sampleRateHz;
        const double phase = k * (std::exp(t / T * logRatio) - 1.0);

        double envelope = 1.0;
        if (i < fadeIn) {
            envelope = raisedCosineRise(i, fadeIn);
        }
        if (fadeOut > 0 && i >= n - fadeOut) {
            envelope *= raisedCosineRise(n - 1 - i, fadeOut);
        }

        out[i] = spec.amplitude * envelope * std::sin(phase);
    }
    return out;
}

std::vector<double> generatePlaybackBuffer(const SweepSpec& spec) {
    const std::vector<double> sweep = generateSweep(spec);
    std::vector<double> out(spec.totalSamples(), 0.0);
    const std::size_t offset = spec.preRollSamples();
    for (std::size_t i = 0; i < sweep.size() && offset + i < out.size(); ++i) {
        out[offset + i] = sweep[i];
    }
    return out;
}

std::vector<double> generateInverseFilter(const SweepSpec& spec) {
    const std::vector<double> sweep = generateSweep(spec);
    const std::size_t n = sweep.size();
    std::vector<double> inverse(n, 0.0);
    if (n == 0) return inverse;

    const double T = static_cast<double>(n) / spec.sampleRateHz;
    const double logRatio = std::log(spec.endHz / spec.startHz);

    // Time-reverse, then apply the -6 dB/octave envelope.  In the reversed
    // signal the instantaneous frequency runs from f2 down to f1, and the
    // envelope must track it: amplitude proportional to frequency, i.e.
    // exp(-t/T * ln(f2/f1)), falling from 1 to f1/f2.
    for (std::size_t i = 0; i < n; ++i) {
        const double t = static_cast<double>(i) / spec.sampleRateHz;
        inverse[i] = sweep[n - 1 - i] * std::exp(-t / T * logRatio);
    }

    // Normalize so sweep * inverse has unit magnitude across the swept band.
    // Measuring it rather than deriving a closed form keeps the normalization
    // honest when fades, amplitude or band limits change.
    const std::vector<double> product = convolve(sweep, inverse);
    const std::size_t fftSize = nextPowerOfTwo(product.size());
    const std::vector<Complex> spectrum = forwardReal(product, fftSize);

    const double binHz = spec.sampleRateHz / static_cast<double>(fftSize);
    // Sample the interior of the swept band; the edges are shaped by the fades
    // and are not representative.
    const double lowHz = spec.startHz * 2.0;
    const double highHz = std::min(spec.endHz * 0.5, spec.sampleRateHz * 0.45);
    double sum = 0.0;
    std::size_t count = 0;
    if (highHz > lowHz) {
        const auto firstBin = static_cast<std::size_t>(std::ceil(lowHz / binHz));
        const auto lastBin = static_cast<std::size_t>(std::floor(highHz / binHz));
        for (std::size_t bin = firstBin; bin <= lastBin && bin < fftSize / 2; ++bin) {
            sum += std::abs(spectrum[bin]);
            ++count;
        }
    }

    if (count > 0) {
        const double mean = sum / static_cast<double>(count);
        if (mean > 1e-30) {
            for (double& v : inverse) v /= mean;
        }
    }
    return inverse;
}

// ---------------------------------------------------------------------------

ImpulseResponse deconvolve(const std::vector<double>& recording, const SweepSpec& spec) {
    ImpulseResponse ir;
    ir.sampleRateHz = spec.sampleRateHz;
    if (recording.empty()) return ir;

    const std::vector<double> inverse = generateInverseFilter(spec);
    if (inverse.empty()) return ir;

    ir.samples = convolve(recording, inverse);

    // The linear impulse lands at (sweep length - 1) plus the loop latency.
    // Harmonic products precede it, so the peak search must not simply take
    // the global maximum of the whole convolution: a strongly distorting
    // system can put a harmonic peak above the linear one.  Search from the
    // point where the linear response can first appear.
    const std::size_t linearFloor = inverse.size() > 0 ? inverse.size() - 1 : 0;
    std::size_t peak = linearFloor;
    double best = -1.0;
    for (std::size_t i = linearFloor; i < ir.samples.size(); ++i) {
        const double magnitude = std::fabs(ir.samples[i]);
        if (magnitude > best) {
            best = magnitude;
            peak = i;
        }
    }
    ir.peakIndex = peak;
    ir.latencySeconds =
        static_cast<double>(peak - linearFloor) / spec.sampleRateHz;
    return ir;
}

double recommendedPreWindowSeconds(double lowestFrequencyHz, double cycles) {
    if (lowestFrequencyHz <= 0.0 || cycles <= 0.0) return 0.0;
    return cycles / lowestFrequencyHz;
}

std::vector<double> windowAroundPeak(const ImpulseResponse& ir,
                                     double preSeconds,
                                     double postSeconds) {
    if (ir.samples.empty()) return {};
    const auto pre = secondsToSamples(preSeconds, ir.sampleRateHz);
    const auto post = secondsToSamples(postSeconds, ir.sampleRateHz);

    const std::size_t start = ir.peakIndex > pre ? ir.peakIndex - pre : 0;
    const std::size_t end = std::min(ir.samples.size(), ir.peakIndex + post);
    if (end <= start) return {};

    return std::vector<double>(ir.samples.begin() + static_cast<std::ptrdiff_t>(start),
                               ir.samples.begin() + static_cast<std::ptrdiff_t>(end));
}

}  // namespace dspi_rc
