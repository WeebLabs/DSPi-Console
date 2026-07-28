// Tests for the FFT, sweep synthesis, and deconvolution chain.
//
// The centrepiece is the round-trip test: synthesize a sweep, push it through
// a known filter, deconvolve the result, and check that the recovered
// magnitude response is the filter we started with.  That exercises the sweep
// definition, the Farina inverse, the normalization, the FFT and the peak
// search together, and it fails loudly if any one of them is wrong.  Testing
// those pieces only in isolation would let a scale error or an envelope
// mistake pass, because each part looks correct on its own.
#include <cmath>
#include <complex>
#include <vector>

#include "dspi_rc/fft.hpp"
#include "dspi_rc/sweep.hpp"
#include "testing.hpp"

using namespace dspi_rc;

namespace {

// Direct-form-II transposed RBJ peaking filter, written here independently of
// the production filter model so the round-trip test is not checking the
// filter code against itself.
struct TestBiquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;

    static TestBiquad peaking(double fc, double q, double gainDb, double fs) {
        const double A = std::pow(10.0, gainDb / 40.0);
        const double w = 2.0 * M_PI * fc / fs;
        const double sn = std::sin(w), cs = std::cos(w);
        const double alpha = sn / (2.0 * q);
        const double a0 = 1 + alpha / A;
        TestBiquad f;
        f.b0 = (1 + alpha * A) / a0;
        f.b1 = (-2 * cs) / a0;
        f.b2 = (1 - alpha * A) / a0;
        f.a1 = (-2 * cs) / a0;
        f.a2 = (1 - alpha / A) / a0;
        return f;
    }

    double process(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }

    double magnitudeDbAt(double f, double fs) const {
        const double w = 2.0 * M_PI * f / fs;
        const std::complex<double> z1c = std::polar(1.0, -w);
        const std::complex<double> z2c = z1c * z1c;
        return 20.0 * std::log10(std::abs((b0 + b1 * z1c + b2 * z2c) /
                                          (1.0 + a1 * z1c + a2 * z2c)));
    }
};

std::vector<double> applyFilter(const std::vector<double>& input, TestBiquad filter) {
    std::vector<double> out;
    out.reserve(input.size());
    for (double x : input) out.push_back(filter.process(x));
    return out;
}

// Magnitude in dB of a signal's spectrum at a given frequency, via the FFT
// bin nearest that frequency.
double spectrumDbAt(const std::vector<double>& signal, double freqHz, double fs,
                    std::size_t fftSize) {
    const std::vector<Complex> spectrum = forwardReal(signal, fftSize);
    const double binHz = fs / static_cast<double>(fftSize);
    const auto bin = static_cast<std::size_t>(std::llround(freqHz / binHz));
    if (bin >= fftSize / 2) return 0.0;
    return 20.0 * std::log10(std::abs(spectrum[bin]) + 1e-30);
}

SweepSpec defaultSpec() {
    SweepSpec spec;
    spec.sampleRateHz = 48000.0;
    spec.startHz = 20.0;
    spec.endHz = 20000.0;
    spec.durationSeconds = 4.0;
    spec.amplitude = 0.5;
    spec.preRollSeconds = 0.1;
    spec.postRollSeconds = 0.5;
    return spec;
}

}  // namespace

// ---------------------------------------------------------------------------
// FFT
// ---------------------------------------------------------------------------

TEST_CASE(fft_matches_naive_dft) {
    const std::size_t n = 64;
    std::vector<Complex> input(n);
    for (std::size_t i = 0; i < n; ++i) {
        input[i] = Complex(std::sin(0.3 * static_cast<double>(i)),
                           std::cos(0.11 * static_cast<double>(i)));
    }

    std::vector<Complex> reference(n, Complex(0.0, 0.0));
    for (std::size_t k = 0; k < n; ++k) {
        for (std::size_t j = 0; j < n; ++j) {
            const double angle = -2.0 * M_PI * static_cast<double>(k * j) / static_cast<double>(n);
            reference[k] += input[j] * Complex(std::cos(angle), std::sin(angle));
        }
    }

    std::vector<Complex> actual = input;
    fftInPlace(actual, false);
    for (std::size_t k = 0; k < n; ++k) {
        CHECK_NEAR(actual[k].real(), reference[k].real(), 1e-9);
        CHECK_NEAR(actual[k].imag(), reference[k].imag(), 1e-9);
    }
}

TEST_CASE(fft_round_trips) {
    std::vector<Complex> input(256);
    for (std::size_t i = 0; i < input.size(); ++i) {
        input[i] = Complex(std::sin(0.05 * static_cast<double>(i)), 0.0);
    }
    std::vector<Complex> round = input;
    fftInPlace(round, false);
    fftInPlace(round, true);
    for (std::size_t i = 0; i < input.size(); ++i) {
        CHECK_NEAR(round[i].real(), input[i].real(), 1e-12);
    }
}

TEST_CASE(next_power_of_two) {
    CHECK(nextPowerOfTwo(0) == 1u);
    CHECK(nextPowerOfTwo(1) == 1u);
    CHECK(nextPowerOfTwo(2) == 2u);
    CHECK(nextPowerOfTwo(3) == 4u);
    CHECK(nextPowerOfTwo(1024) == 1024u);
    CHECK(nextPowerOfTwo(1025) == 2048u);
}

TEST_CASE(convolution_matches_naive) {
    const std::vector<double> a{1.0, -2.0, 3.0, 0.5};
    const std::vector<double> b{0.5, 1.5, -1.0};

    std::vector<double> reference(a.size() + b.size() - 1, 0.0);
    for (std::size_t i = 0; i < a.size(); ++i) {
        for (std::size_t j = 0; j < b.size(); ++j) reference[i + j] += a[i] * b[j];
    }

    const std::vector<double> actual = convolve(a, b);
    CHECK(actual.size() == reference.size());
    for (std::size_t i = 0; i < reference.size(); ++i) {
        CHECK_NEAR(actual[i], reference[i], 1e-9);
    }
}

TEST_CASE(convolution_does_not_wrap_around) {
    // Circular convolution would fold the tail onto the head.  A delta at the
    // very end of `a` must produce output past the end of `a`, not at index 0.
    std::vector<double> a(8, 0.0);
    a.back() = 1.0;
    const std::vector<double> b{0.0, 0.0, 1.0};
    const std::vector<double> result = convolve(a, b);
    CHECK(result.size() == 10u);
    CHECK_NEAR(result[9], 1.0, 1e-12);
    CHECK_NEAR(result[0], 0.0, 1e-12);
}

TEST_CASE(cross_correlation_finds_a_known_lag) {
    std::vector<double> pattern{1.0, 2.0, -1.0, 0.5};
    std::vector<double> signal(64, 0.0);
    const std::size_t offset = 20;
    for (std::size_t i = 0; i < pattern.size(); ++i) signal[offset + i] = pattern[i];

    const std::vector<double> correlation = crossCorrelate(signal, pattern);
    std::size_t peak = 0;
    double best = -1e30;
    for (std::size_t i = 0; i < correlation.size(); ++i) {
        if (correlation[i] > best) { best = correlation[i]; peak = i; }
    }
    // Index 0 corresponds to lag -(pattern-1).
    const std::size_t recovered = peak - (pattern.size() - 1);
    CHECK(recovered == offset);
}

// ---------------------------------------------------------------------------
// Sweep synthesis
// ---------------------------------------------------------------------------

TEST_CASE(sweep_has_the_requested_length_and_amplitude) {
    const SweepSpec spec = defaultSpec();
    const std::vector<double> sweep = generateSweep(spec);
    CHECK(sweep.size() == spec.sweepSamples());

    double peak = 0.0;
    for (double v : sweep) peak = std::max(peak, std::fabs(v));
    CHECK_NEAR(peak, spec.amplitude, 0.01);
    CHECK(peak <= spec.amplitude + 1e-9);
}

TEST_CASE(sweep_fades_start_and_end_at_silence) {
    const SweepSpec spec = defaultSpec();
    const std::vector<double> sweep = generateSweep(spec);
    CHECK_NEAR(sweep.front(), 0.0, 1e-9);
    CHECK_NEAR(sweep.back(), 0.0, 1e-3);
}

TEST_CASE(sweep_instantaneous_frequency_follows_the_exponential_law) {
    SweepSpec spec = defaultSpec();
    spec.fadeInSeconds = 0.0;
    spec.fadeOutSeconds = 0.0;
    const std::vector<double> sweep = generateSweep(spec);
    const double T = spec.durationSeconds;

    // Count zero crossings in a short slice and compare with the analytic
    // instantaneous frequency at the slice centre.
    for (double fraction : {0.2, 0.5, 0.8}) {
        const double centre = fraction * T;
        const double expected = spec.startHz * std::pow(spec.endHz / spec.startHz, centre / T);
        const double slice = std::max(0.02, 20.0 / expected);  // >= 10 cycles

        const auto first = static_cast<std::size_t>((centre - slice / 2) * spec.sampleRateHz);
        const auto last = static_cast<std::size_t>((centre + slice / 2) * spec.sampleRateHz);
        int crossings = 0;
        for (std::size_t i = first + 1; i < last && i < sweep.size(); ++i) {
            if ((sweep[i - 1] < 0.0) != (sweep[i] < 0.0)) ++crossings;
        }
        const double measured = crossings / (2.0 * slice);
        // Frequency changes across the slice, so allow a few percent.
        CHECK_NEAR(measured / expected, 1.0, 0.06);
    }
}

TEST_CASE(playback_buffer_places_the_sweep_after_the_pre_roll) {
    const SweepSpec spec = defaultSpec();
    const std::vector<double> buffer = generatePlaybackBuffer(spec);
    CHECK(buffer.size() == spec.totalSamples());

    for (std::size_t i = 0; i < spec.preRollSamples(); ++i) {
        CHECK_NEAR(buffer[i], 0.0, 1e-12);
    }
    for (std::size_t i = buffer.size() - spec.postRollSamples(); i < buffer.size(); ++i) {
        CHECK_NEAR(buffer[i], 0.0, 1e-12);
    }
}

TEST_CASE(spec_validation_rejects_unusable_sweeps) {
    CHECK(defaultSpec().validate().empty());

    SweepSpec aboveNyquist = defaultSpec();
    aboveNyquist.endHz = 30000.0;
    CHECK(!aboveNyquist.validate().empty());

    SweepSpec inverted = defaultSpec();
    inverted.endHz = 10.0;
    CHECK(!inverted.validate().empty());

    SweepSpec loud = defaultSpec();
    loud.amplitude = 1.5;
    CHECK(!loud.validate().empty());

    SweepSpec fadesTooLong = defaultSpec();
    fadesTooLong.fadeInSeconds = 3.0;
    fadesTooLong.fadeOutSeconds = 3.0;
    CHECK(!fadesTooLong.validate().empty());

    SweepSpec tooShortForItsLowEnd = defaultSpec();
    tooShortForItsLowEnd.startHz = 5.0;
    tooShortForItsLowEnd.durationSeconds = 0.1;
    CHECK(!tooShortForItsLowEnd.validate().empty());
}

// ---------------------------------------------------------------------------
// Deconvolution round trip
// ---------------------------------------------------------------------------

TEST_CASE(deconvolving_an_unfiltered_sweep_gives_a_flat_response) {
    const SweepSpec spec = defaultSpec();
    const std::vector<double> playback = generatePlaybackBuffer(spec);
    const ImpulseResponse ir = deconvolve(playback, spec);
    CHECK(!ir.samples.empty());

    // Pre-window sized for the lowest frequency we intend to trust.  A short
    // pre-window would attenuate the low end and look like a real rolloff.
    const double pre = recommendedPreWindowSeconds(40.0);
    const std::vector<double> window = windowAroundPeak(ir, pre, 0.2);
    CHECK(!window.empty());

    const std::size_t fftSize = nextPowerOfTwo(window.size());
    // Unity system: the recovered magnitude should be 0 dB across the band,
    // which is what the inverse-filter normalization exists to guarantee.
    for (double f : {50.0, 200.0, 1000.0, 5000.0, 12000.0}) {
        CHECK_NEAR(spectrumDbAt(window, f, spec.sampleRateHz, fftSize), 0.0, 0.5);
    }
}

TEST_CASE(deconvolution_recovers_a_known_filter_response) {
    const SweepSpec spec = defaultSpec();
    const TestBiquad filter = TestBiquad::peaking(200.0, 3.0, 8.0, spec.sampleRateHz);

    const std::vector<double> playback = generatePlaybackBuffer(spec);
    const std::vector<double> recorded = applyFilter(playback, filter);

    const ImpulseResponse ir = deconvolve(recorded, spec);
    const std::vector<double> window =
        windowAroundPeak(ir, recommendedPreWindowSeconds(50.0), 0.3);
    const std::size_t fftSize = nextPowerOfTwo(window.size());

    for (double f : {60.0, 120.0, 200.0, 350.0, 800.0, 4000.0}) {
        const double recovered = spectrumDbAt(window, f, spec.sampleRateHz, fftSize);
        const double expected = filter.magnitudeDbAt(f, spec.sampleRateHz);
        CHECK_NEAR(recovered, expected, 0.6);
    }
}

TEST_CASE(deconvolution_recovers_a_deep_narrow_cut) {
    // A high-Q cut is the hard case: too short a window truncates its ringing
    // and the recovered notch comes back shallower than reality, which would
    // make the optimizer under-correct real room modes.
    const SweepSpec spec = defaultSpec();
    const TestBiquad filter = TestBiquad::peaking(80.0, 8.0, -14.0, spec.sampleRateHz);

    const std::vector<double> recorded = applyFilter(generatePlaybackBuffer(spec), filter);
    const ImpulseResponse ir = deconvolve(recorded, spec);
    const std::vector<double> window =
        windowAroundPeak(ir, recommendedPreWindowSeconds(60.0), 1.0);
    const std::size_t fftSize = nextPowerOfTwo(window.size());

    CHECK_NEAR(spectrumDbAt(window, 80.0, spec.sampleRateHz, fftSize), -14.0, 0.7);
}

TEST_CASE(deconvolution_reports_loop_latency) {
    const SweepSpec spec = defaultSpec();

    // Simulate an unknown playback/capture latency by prepending silence.
    const double extraLatencySeconds = 0.037;
    const auto extra = static_cast<std::size_t>(extraLatencySeconds * spec.sampleRateHz);
    std::vector<double> recorded(extra, 0.0);
    const std::vector<double> playback = generatePlaybackBuffer(spec);
    recorded.insert(recorded.end(), playback.begin(), playback.end());

    const ImpulseResponse ir = deconvolve(recorded, spec);
    // Reported latency includes the spec's own pre-roll, since it is measured
    // from the start of the recording.
    const double expected = extraLatencySeconds + spec.preRollSeconds;
    CHECK_NEAR(ir.latencySeconds, expected, 0.001);
}

TEST_CASE(peak_search_ignores_harmonic_products_before_the_linear_response) {
    // Exponential sweeps push harmonic distortion into negative time relative
    // to the linear impulse.  A naive global-maximum peak search would lock
    // onto a harmonic in a strongly distorting system and every subsequent
    // measurement would be misaligned.  Simulate that with a hard nonlinearity.
    const SweepSpec spec = defaultSpec();
    std::vector<double> recorded = generatePlaybackBuffer(spec);
    for (double& v : recorded) {
        v = std::tanh(v * 6.0) * 0.5;  // heavy, obviously nonlinear
    }

    const ImpulseResponse ir = deconvolve(recorded, spec);
    // The linear response must still be found at the pre-roll position.
    CHECK_NEAR(ir.latencySeconds, spec.preRollSeconds, 0.002);
}

TEST_CASE(round_trip_holds_at_every_supported_rate) {
    for (double fs : {44100.0, 48000.0, 96000.0}) {
        SweepSpec spec = defaultSpec();
        spec.sampleRateHz = fs;
        spec.durationSeconds = 3.0;
        CHECK(spec.validate().empty());

        const TestBiquad filter = TestBiquad::peaking(500.0, 2.0, -6.0, fs);
        const std::vector<double> recorded = applyFilter(generatePlaybackBuffer(spec), filter);
        const ImpulseResponse ir = deconvolve(recorded, spec);
        const std::vector<double> window =
            windowAroundPeak(ir, recommendedPreWindowSeconds(100.0), 0.3);
        const std::size_t fftSize = nextPowerOfTwo(window.size());
        CHECK_NEAR(spectrumDbAt(window, 500.0, fs, fftSize), -6.0, 0.6);
    }
}

TEST_CASE(window_around_peak_clamps_at_buffer_edges) {
    ImpulseResponse ir;
    ir.sampleRateHz = 48000.0;
    ir.samples.assign(1000, 0.0);
    ir.samples[10] = 1.0;
    ir.peakIndex = 10;

    // Asking for more pre-roll than exists must clamp rather than underflow.
    const std::vector<double> window = windowAroundPeak(ir, 1.0, 0.001);
    CHECK(!window.empty());
    CHECK(window.size() <= ir.samples.size());
}

TEST_CASE(too_short_a_pre_window_attenuates_the_low_end) {
    // Pins the behaviour that motivated recommendedPreWindowSeconds.  This is
    // not asserting that truncation is desirable; it is asserting that the
    // effect is real and sizeable, so nobody "simplifies" the pre-window back
    // to a small constant and quietly loses a dB in the bass.
    const SweepSpec spec = defaultSpec();
    const ImpulseResponse ir = deconvolve(generatePlaybackBuffer(spec), spec);

    const std::vector<double> truncated = windowAroundPeak(ir, 0.005, 0.2);
    const std::vector<double> adequate =
        windowAroundPeak(ir, recommendedPreWindowSeconds(40.0), 0.2);

    const double truncatedDb =
        spectrumDbAt(truncated, 50.0, spec.sampleRateHz, nextPowerOfTwo(truncated.size()));
    const double adequateDb =
        spectrumDbAt(adequate, 50.0, spec.sampleRateHz, nextPowerOfTwo(adequate.size()));

    CHECK(truncatedDb < -0.5);              // measurably wrong
    CHECK_NEAR(adequateDb, 0.0, 0.3);       // and fixed by sizing the window
}

TEST_CASE(recommended_pre_window_scales_with_frequency) {
    CHECK_NEAR(recommendedPreWindowSeconds(20.0), 0.2, 1e-12);
    CHECK_NEAR(recommendedPreWindowSeconds(100.0), 0.04, 1e-12);
    CHECK_NEAR(recommendedPreWindowSeconds(20.0, 2.0), 0.1, 1e-12);
    CHECK_NEAR(recommendedPreWindowSeconds(0.0), 0.0, 1e-12);
    CHECK_NEAR(recommendedPreWindowSeconds(100.0, 0.0), 0.0, 1e-12);
}

TEST_CASE(two_cycle_pre_window_mismeasures_a_high_q_resonance) {
    // The reason the default is four cycles rather than two.  A Q=8 notch
    // rings for roughly Q/(pi*f) = 32 ms, and that energy spreads before the
    // peak as well as after it once convolved with the symmetric skirt.  Two
    // cycles clips it and the notch reads too deep, which would make the
    // optimizer over-correct a room mode.
    const SweepSpec spec = defaultSpec();
    const TestBiquad filter = TestBiquad::peaking(80.0, 8.0, -14.0, spec.sampleRateHz);
    const ImpulseResponse ir = deconvolve(applyFilter(generatePlaybackBuffer(spec), filter), spec);

    const std::vector<double> tight =
        windowAroundPeak(ir, recommendedPreWindowSeconds(60.0, 2.0), 1.0);
    const std::vector<double> ample =
        windowAroundPeak(ir, recommendedPreWindowSeconds(60.0), 1.0);

    const double tightDb =
        spectrumDbAt(tight, 80.0, spec.sampleRateHz, nextPowerOfTwo(tight.size()));
    const double ampleDb =
        spectrumDbAt(ample, 80.0, spec.sampleRateHz, nextPowerOfTwo(ample.size()));

    CHECK(tightDb < -14.5);                 // measurably too deep
    CHECK_NEAR(ampleDb, -14.0, 0.2);        // and fixed by the wider default
}
