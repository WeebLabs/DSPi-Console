// Exponential swept-sine synthesis, its Farina inverse filter, and
// deconvolution to an impulse response.
//
// The reference is authored here rather than modelled from firmware.  That is
// the whole point of moving measurement to host playback (spec §4.1): the
// emitted waveform is exactly the waveform the analysis holds, so there is no
// device phase law to mirror, no fixed-point increment to model, and no
// platform-specific oscillator kernel.  The sweep and its inverse are two
// functions, testable in isolation on any platform.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace dspi_rc {

// ---------------------------------------------------------------------------
// Sweep definition
//
// Every field is exposed rather than derived, because measurement conditions
// vary more than a fixed recipe can anticipate: a subwoofer wants a long slow
// sweep over a narrow band, a tweeter check wants a short one, a noisy room
// wants more energy, and an impatient user with nine speakers and twenty-one
// positions wants none of the above.
// ---------------------------------------------------------------------------
struct SweepSpec {
    double sampleRateHz = 48000.0;
    double startHz = 10.0;
    double endHz = 22000.0;
    double durationSeconds = 8.0;

    // Raised-cosine edges.  Long enough to suppress spectral splatter, short
    // enough not to erode the usable band at either end.
    double fadeInSeconds = 0.05;
    double fadeOutSeconds = 0.02;

    // Peak amplitude, linear (not dBFS).  The level check owns the dB-facing
    // control; this is what actually gets written into the buffer.
    double amplitude = 0.5;

    // Silence around the sweep.  Pre-roll gives the capture time to settle and
    // provides the noise-floor estimate; post-roll must outlast the room's
    // decay or the tail of the impulse response is truncated.
    double preRollSeconds = 0.25;
    double postRollSeconds = 1.5;

    std::size_t sweepSamples() const;
    std::size_t preRollSamples() const;
    std::size_t postRollSamples() const;
    std::size_t totalSamples() const;

    // Rejects a spec that cannot produce a usable measurement, rather than
    // silently generating something degenerate.  Returns empty if valid.
    std::string validate() const;
};

// The sweep itself, without padding: `sweepSamples()` long.
std::vector<double> generateSweep(const SweepSpec& spec);

// The full playback buffer including pre-roll and post-roll silence.
std::vector<double> generatePlaybackBuffer(const SweepSpec& spec);

// Farina inverse filter: the time-reversed sweep with an amplitude envelope
// that falls 6 dB per octave, normalized so that convolving it with the sweep
// yields unit magnitude across the swept band.  Without that normalization a
// recovered response is offset by an arbitrary constant that depends on sweep
// length and range, which is exactly the kind of error that survives testing
// because it looks like a level difference.
std::vector<double> generateInverseFilter(const SweepSpec& spec);

// ---------------------------------------------------------------------------
// Deconvolution
// ---------------------------------------------------------------------------

struct ImpulseResponse {
    std::vector<double> samples;
    double sampleRateHz = 48000.0;

    // Index of the linear response peak within `samples`.  Harmonic
    // distortion products land *before* this point in an exponential sweep
    // deconvolution, which is the property that lets them be separated.
    std::size_t peakIndex = 0;

    // Peak position relative to the start of the recording, in seconds.  This
    // is total loop latency: USB, device buffering, acoustic flight time, and
    // capture buffering combined.  Magnitude correction does not need it, but
    // per-channel distance and delay diagnostics do.
    double latencySeconds = 0.0;
};

// Deconvolve a capture against the sweep's inverse filter.
//
// `recording` is the raw captured signal including whatever silence preceded
// the sweep; the peak search locates the response, so the caller does not have
// to know when playback actually started.
ImpulseResponse deconvolve(const std::vector<double>& recording, const SweepSpec& spec);

// ---------------------------------------------------------------------------
// Windowing
// ---------------------------------------------------------------------------

// Minimum pre-peak window needed to preserve a given lowest frequency.
//
// A deconvolved sweep produces a *symmetric* band-limited impulse, not a
// causal one: the inverse filter compensates the sweep's phase, so energy sits
// on both sides of the peak.  Cutting too close silently attenuates the low
// end, and the result looks like a genuine low-frequency rolloff rather than
// an artifact.  Truncating at 5 ms costs about 1.2 dB at 50 Hz.
//
// Two constraints set the width, and the second is the one that catches people
// out:
//
//  1. The band-limited impulse skirt, which spans roughly one to two cycles of
//     the lowest frequency of interest.
//  2. Resonant ringing.  A high-Q feature rings for about Q/(pi*f) seconds,
//     and convolved with the symmetric skirt that energy spreads *before* the
//     peak as well as after it.  Room modes are exactly this case.  Measured
//     against a Q=8 notch at 80 Hz, a two-cycle window recovers it 0.8 dB too
//     deep; four cycles brings the error under 0.1 dB.
//
// Four cycles therefore satisfies both for typical room work, and is the
// default.  The competing constraint is that the exponential sweep pushes
// harmonic distortion products into negative time, so an unboundedly wide
// pre-window eventually pulls them in; in practice those sit far further back
// than anything discussed here.
double recommendedPreWindowSeconds(double lowestFrequencyHz, double cycles = 4.0);

// Extract a window around the impulse peak.
//
// Derive `preSeconds` from `recommendedPreWindowSeconds` rather than picking a
// small number: see above.  `postSeconds` must outlast the decay of the
// narrowest resonance of interest, or high-Q features come back shallower than
// they are and the correction under-corrects them.
std::vector<double> windowAroundPeak(const ImpulseResponse& ir,
                                     double preSeconds,
                                     double postSeconds);

}  // namespace dspi_rc
