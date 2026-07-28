// Plain value types shared across the portable room-correction core.
//
// Nothing in this directory may include Foundation, CoreAudio, Accelerate,
// Win32, COM, or any UI framework.  The core is C++17 and the standard
// library only, so the same sources build on macOS today and Windows later.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace dspi_rc {

// Pi, owned rather than borrowed.
//
// `M_PI` is a POSIX extension, not standard C++.  glibc hides it under strict
// ISO mode - which is exactly what `CMAKE_CXX_EXTENSIONS OFF` selects - and
// MSVC only exposes it behind `_USE_MATH_DEFINES`.  libc++ happens to define
// it unconditionally, which is why this built on macOS and nowhere else.
// Defining it here removes the platform dance entirely.
//
// Distinct from `kFirmwarePi` in biquad.hpp, which is deliberately the
// firmware's truncated literal: that one exists to reproduce the device, this
// one to be correct.
inline constexpr double kPi = 3.14159265358979323846;

// ---------------------------------------------------------------------------
// Filter types
//
// Raw values are the firmware wire bytes (firmware `enum FilterType`,
// config.h:867).  The space is partitioned: 0..11 PEQ, 12..31 reserved,
// 32..63 crossover.  Keep these in lockstep with the firmware enum and with
// Swift's `FilterType` in DSPMath.swift.
// ---------------------------------------------------------------------------
enum class FilterType : std::uint8_t {
    Flat = 0,
    Peaking = 1,
    LowShelf = 2,
    HighShelf = 3,
    LowPass = 4,
    HighPass = 5,
    Notch = 6,
    AllPass = 7,
    AllPass1 = 8,
    LowShelf1 = 9,
    HighShelf1 = 10,
    LinkwitzTransform = 11,
};

constexpr bool isFirstOrder(FilterType t) {
    return t == FilterType::AllPass1 || t == FilterType::LowShelf1 ||
           t == FilterType::HighShelf1;
}

// Types whose `gain` field carries dB.  Linkwitz Transform reuses the field
// for fp in Hz, which is why it is excluded here.
constexpr bool usesGainDb(FilterType t) {
    return t == FilterType::Peaking || t == FilterType::LowShelf ||
           t == FilterType::HighShelf || t == FilterType::LowShelf1 ||
           t == FilterType::HighShelf1;
}

// ---------------------------------------------------------------------------
// Target platform
//
// The two platforms do not merely round differently; they run structurally
// different code.  RP2350 uses a trapezoidal state-variable filter below
// Fs/7.5 and a float TDF2 biquad above it.  RP2040 always uses a TDF2 biquad
// with coefficients truncated to Q28.  Predicting a correction therefore
// requires knowing which one is attached, and a prediction made for one is
// not valid for the other.
// ---------------------------------------------------------------------------
enum class Platform : std::uint8_t {
    RP2040,
    RP2350,
};

// ---------------------------------------------------------------------------
// A single filter band, exactly as it goes on the wire.
//
// `EqParamPacket` (firmware config.h:936-941) carries freq, Q and gain as
// IEEE-754 float32, so these are float rather than double on purpose: this
// struct is the wire contract, and storing wider than the wire would invite
// predictions the hardware cannot honor.  Everything downstream computes in
// double.
// ---------------------------------------------------------------------------
struct FilterParams {
    FilterType type = FilterType::Flat;
    float freq = 1000.0f;
    float q = 0.707f;
    float gainDb = 0.0f;   // Linkwitz Transform: fp in Hz, not dB.
    float qp = 0.707f;     // Linkwitz Transform target pole Q; unused otherwise.
    bool bypass = false;

    // Firmware stores Qp as a uint16 of Q*512, where 0 means "use 0.707".
    std::uint16_t qpEncoded() const;
};

// A cascade of bands applied to one channel.
using FilterBank = std::vector<FilterParams>;

// ---------------------------------------------------------------------------
// Firmware parameter limits (dsp_pipeline.c:101-104, :116-119).
//
// The optimizer must respect these, because the firmware clamps silently.  A
// solution that converges outside them is not the solution that will run.
// ---------------------------------------------------------------------------
struct FirmwareLimits {
    static constexpr float minQ = 0.1f;
    static constexpr float maxQ = 20.0f;
    static constexpr float minFreqHz = 10.0f;
    // Upper corner is 0.45 * Fs for ordinary types, 0.15 * Fs for Linkwitz.
    static constexpr float freqNyquistFraction = 0.45f;
    static constexpr float linkwitzNyquistFraction = 0.15f;

    static float maxFreqHz(double sampleRateHz, FilterType t) {
        const double fraction = (t == FilterType::LinkwitzTransform)
                                    ? linkwitzNyquistFraction
                                    : freqNyquistFraction;
        return static_cast<float>(sampleRateHz * fraction);
    }
};

// ---------------------------------------------------------------------------
// Frequency grid
//
// Log-spaced, expressed as points per octave so resolution is stated in the
// units the analysis actually cares about.  Section 6.3 of the spec calls for
// 96 points per octave; the default matches.
// ---------------------------------------------------------------------------
struct FrequencyGrid {
    std::vector<double> hz;

    static FrequencyGrid logSpaced(double minHz, double maxHz, int pointsPerOctave);

    std::size_t size() const { return hz.size(); }
    bool empty() const { return hz.empty(); }

    // Points per octave implied by the grid, from the median log step.  Used
    // by smoothing and windowing so they adapt to whatever grid they are given
    // rather than assuming the default.
    double pointsPerOctave() const;
};

}  // namespace dspi_rc
