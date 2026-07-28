#include "dspi_rc/biquad.hpp"

#include <algorithm>
#include <cmath>

namespace dspi_rc {
namespace {

// Bilinear variable u = (1 - z^-1) / (1 + z^-1) evaluated on the unit circle.
// For z = e^{jw} this is exactly j*tan(w/2), which is why the SVF's prewarped
// g composes with it so cleanly.
std::complex<double> bilinearU(double freqHz, double sampleRateHz) {
    const double w = 2.0 * M_PI * freqHz / sampleRateHz;
    return std::complex<double>(0.0, std::tan(w / 2.0));
}

// Truncate toward zero into Q28 and back, matching the firmware's
// `(int32_t)(x * scale)` cast (dsp_pipeline.c:312-316).  A C cast truncates;
// rounding here would model a device that does not exist.
double quantizeQ28(float value) {
    const double scale = static_cast<double>(1LL << kFilterShift);
    const double scaled = static_cast<double>(value) * scale;
    // int32_t range check: the firmware relies on its own corner clamps to
    // keep normalized coefficients inside +/-8, well within Q28.  Saturate
    // rather than invoke undefined behavior if a caller escapes that.
    const double limited = std::max(-2147483648.0, std::min(2147483647.0, scaled));
    return static_cast<double>(static_cast<std::int32_t>(limited)) / scale;
}

}  // namespace

// ---------------------------------------------------------------------------

std::uint16_t FilterParams::qpEncoded() const {
    const float clamped = std::max(0.1f, std::min(20.0f, qp));
    return static_cast<std::uint16_t>(std::lround(clamped * 512.0f));
}

// ---------------------------------------------------------------------------

FilterParams clampToFirmware(FilterParams p, double sampleRateHz) {
    const float fs = static_cast<float>(sampleRateHz);

    if (p.q < FirmwareLimits::minQ) p.q = FirmwareLimits::minQ;
    if (p.q > FirmwareLimits::maxQ) p.q = FirmwareLimits::maxQ;
    if (p.freq < FirmwareLimits::minFreqHz) p.freq = FirmwareLimits::minFreqHz;
    if (p.freq > fs * FirmwareLimits::freqNyquistFraction) {
        p.freq = fs * FirmwareLimits::freqNyquistFraction;
    }

    if (p.type == FilterType::LinkwitzTransform) {
        const float ltMax = fs * FirmwareLimits::linkwitzNyquistFraction;
        if (p.freq > ltMax) p.freq = ltMax;
        // gainDb carries fp in Hz for this type.
        if (p.gainDb < FirmwareLimits::minFreqHz) p.gainDb = FirmwareLimits::minFreqHz;
        if (p.gainDb > ltMax) p.gainDb = ltMax;
        if (p.qp < FirmwareLimits::minQ) p.qp = FirmwareLimits::minQ;
        if (p.qp > FirmwareLimits::maxQ) p.qp = FirmwareLimits::maxQ;
    }

    return p;
}

// ---------------------------------------------------------------------------

std::complex<double> RealizedSection::response(double freqHz, double sampleRateHz) const {
    switch (kind) {
        case Kind::Bypass:
            return std::complex<double>(1.0, 0.0);

        case Kind::Biquad: {
            const double w = 2.0 * M_PI * freqHz / sampleRateHz;
            const std::complex<double> z1 = std::polar(1.0, -w);
            const std::complex<double> z2 = z1 * z1;
            const std::complex<double> num = b0 + b1 * z1 + b2 * z2;
            const std::complex<double> den = 1.0 + a1 * z1 + a2 * z2;
            if (std::abs(den) < 1e-30) return std::complex<double>(1.0, 0.0);
            return num / den;
        }

        case Kind::Svf: {
            // H = m0 + (m1*g*u + m2*g^2) / (u^2 + k*g*u + g^2)
            // This is the bilinear image of the analog SVF whose band-pass and
            // low-pass outputs the structure exposes as v1 and v2.
            const std::complex<double> u = bilinearU(freqHz, sampleRateHz);
            const std::complex<double> den = u * u + (k * g) * u + (g * g);
            if (std::abs(den) < 1e-30) return std::complex<double>(m0, 0.0);
            const std::complex<double> num = (m1 * g) * u + (m2 * g * g);
            return m0 + num / den;
        }

        case Kind::SvfFirst: {
            // One-pole TPT: LP = g/(u+g), HP = u/(u+g).
            // out = m0*in + m1*LP + m2*HP.
            const std::complex<double> u = bilinearU(freqHz, sampleRateHz);
            const std::complex<double> den = u + g;
            if (std::abs(den) < 1e-30) return std::complex<double>(m0, 0.0);
            return m0 + (m1 * g + m2 * u) / den;
        }
    }
    return std::complex<double>(1.0, 0.0);
}

// ---------------------------------------------------------------------------

RealizedSection realize(const FilterParams& raw, double sampleRateHz, Platform platform) {
    RealizedSection out;

    if (raw.bypass || raw.type == FilterType::Flat) {
        return out;  // Kind::Bypass
    }

    const FilterParams p = clampToFirmware(raw, sampleRateHz);
    const float fs = static_cast<float>(sampleRateHz);
    const bool isLt = (p.type == FilterType::LinkwitzTransform);

    // Firmware: gain_db holds fp for LT, so the dB conversion is skipped
    // (it would otherwise produce inf).
    const float A = isLt ? 1.0f : std::pow(10.0f, p.gainDb / 40.0f);

    const float ltFp = isLt ? p.gainDb : 0.0f;
    const float ltQp = isLt ? p.qp : 0.707f;

    // -----------------------------------------------------------------------
    // RP2350: trapezoidal SVF below Fs/7.5
    // -----------------------------------------------------------------------
    if (platform == Platform::RP2350) {
        bool useSvf = p.freq < (fs / kSvfThresholdDivisor);
        // Linkwitz has two corners; both must be below the threshold.
        if (isLt && ltFp >= (fs / kSvfThresholdDivisor)) useSvf = false;

        if (useSvf && isFirstOrder(p.type)) {
            float g = std::tan(kFirmwarePi * p.freq / fs);
            float m0 = 0.0f, m1 = 0.0f, m2 = 0.0f;
            switch (p.type) {
                case FilterType::AllPass1:
                    m0 = 0.0f; m1 = 1.0f; m2 = -1.0f;
                    break;
                case FilterType::LowShelf1:
                    g = g / A;
                    m0 = 1.0f; m1 = A * A - 1.0f; m2 = 0.0f;
                    break;
                case FilterType::HighShelf1:
                    g = g * A;
                    m0 = 1.0f; m1 = 0.0f; m2 = A * A - 1.0f;
                    break;
                default:
                    break;
            }
            out.kind = RealizedSection::Kind::SvfFirst;
            out.g = g;
            out.m0 = m0; out.m1 = m1; out.m2 = m2;
            return out;
        }

        if (useSvf) {
            float g = std::tan(kFirmwarePi * p.freq / fs);
            float k = 1.0f / p.q;

            switch (p.type) {
                case FilterType::Peaking:
                    k = 1.0f / (p.q * A);
                    break;
                case FilterType::LowShelf:
                    g = g / std::sqrt(A);
                    break;
                case FilterType::HighShelf:
                    g = g * std::sqrt(A);
                    break;
                case FilterType::LinkwitzTransform:
                    g = std::tan(kFirmwarePi * ltFp / fs);
                    k = 1.0f / ltQp;
                    break;
                default:
                    break;
            }

            float m0 = 0.0f, m1 = 0.0f, m2 = 0.0f;
            switch (p.type) {
                case FilterType::LowPass:
                    m0 = 0.0f; m1 = 0.0f; m2 = 1.0f;
                    break;
                case FilterType::HighPass:
                    m0 = 1.0f; m1 = -k; m2 = -1.0f;
                    break;
                case FilterType::Peaking:
                    m0 = 1.0f; m1 = k * (A * A - 1.0f); m2 = 0.0f;
                    break;
                case FilterType::LowShelf:
                    m0 = 1.0f; m1 = k * (A - 1.0f); m2 = A * A - 1.0f;
                    break;
                case FilterType::HighShelf:
                    m0 = A * A; m1 = k * (1.0f - A) * A; m2 = 1.0f - A * A;
                    break;
                case FilterType::Notch:
                    m0 = 1.0f; m1 = -k; m2 = 0.0f;
                    break;
                case FilterType::AllPass:
                    m0 = 1.0f; m1 = -2.0f * k; m2 = 0.0f;
                    break;
                case FilterType::LinkwitzTransform: {
                    const float g0 = std::tan(kFirmwarePi * p.freq / fs);
                    const float r = g0 / g;
                    m0 = 1.0f;
                    m1 = r / p.q - k;
                    m2 = r * r - 1.0f;
                    break;
                }
                default:
                    break;
            }

            out.kind = RealizedSection::Kind::Svf;
            out.g = g; out.k = k;
            out.m0 = m0; out.m1 = m1; out.m2 = m2;
            return out;
        }
    }

    // -----------------------------------------------------------------------
    // TDF2 biquad path (RP2040 always; RP2350 above Fs/7.5)
    //
    // Mirrors dsp_pipeline.c:248-299 in float, including the truncated pi.
    // -----------------------------------------------------------------------
    const float omega = 2.0f * kFirmwarePi * p.freq / fs;
    const float sn = std::sin(omega);
    const float cs = std::cos(omega);
    const float alpha = sn / (2.0f * p.q);

    float a0f = 1.0f, a1f = 0.0f, a2f = 0.0f;
    float b0f = 1.0f, b1f = 0.0f, b2f = 0.0f;

    switch (p.type) {
        case FilterType::LowPass:
            b0f = (1 - cs) / 2; b1f = 1 - cs; b2f = (1 - cs) / 2;
            a0f = 1 + alpha; a1f = -2 * cs; a2f = 1 - alpha;
            break;
        case FilterType::HighPass:
            b0f = (1 + cs) / 2; b1f = -(1 + cs); b2f = (1 + cs) / 2;
            a0f = 1 + alpha; a1f = -2 * cs; a2f = 1 - alpha;
            break;
        case FilterType::Peaking:
            b0f = 1 + alpha * A; b1f = -2 * cs; b2f = 1 - alpha * A;
            a0f = 1 + alpha / A; a1f = -2 * cs; a2f = 1 - alpha / A;
            break;
        case FilterType::LowShelf: {
            const float sq = std::sqrt(A);
            b0f = A * ((A + 1) - (A - 1) * cs + 2 * sq * alpha);
            b1f = 2 * A * ((A - 1) - (A + 1) * cs);
            b2f = A * ((A + 1) - (A - 1) * cs - 2 * sq * alpha);
            a0f = (A + 1) + (A - 1) * cs + 2 * sq * alpha;
            a1f = -2 * ((A - 1) + (A + 1) * cs);
            a2f = (A + 1) + (A - 1) * cs - 2 * sq * alpha;
            break;
        }
        case FilterType::HighShelf: {
            const float sq = std::sqrt(A);
            b0f = A * ((A + 1) + (A - 1) * cs + 2 * sq * alpha);
            b1f = -2 * A * ((A - 1) + (A + 1) * cs);
            b2f = A * ((A + 1) + (A - 1) * cs - 2 * sq * alpha);
            a0f = (A + 1) - (A - 1) * cs + 2 * sq * alpha;
            a1f = 2 * ((A - 1) - (A + 1) * cs);
            a2f = (A + 1) - (A - 1) * cs - 2 * sq * alpha;
            break;
        }
        case FilterType::Notch:
            b0f = 1.0f; b1f = -2 * cs; b2f = 1.0f;
            a0f = 1 + alpha; a1f = -2 * cs; a2f = 1 - alpha;
            break;
        case FilterType::AllPass:
            b0f = 1 - alpha; b1f = -2 * cs; b2f = 1 + alpha;
            a0f = 1 + alpha; a1f = -2 * cs; a2f = 1 - alpha;
            break;
        case FilterType::AllPass1: {
            const float ta = std::tan(kFirmwarePi * p.freq / fs);
            const float ap = (ta - 1.0f) / (ta + 1.0f);
            b0f = ap; b1f = 1.0f; b2f = 0.0f;
            a0f = 1.0f; a1f = ap; a2f = 0.0f;
            break;
        }
        case FilterType::LowShelf1:
            b0f = (A * sn) + 1.0f + cs; b1f = (A * sn) - 1.0f - cs; b2f = 0.0f;
            a0f = (sn / A) + 1.0f + cs; a1f = (sn / A) - 1.0f - cs; a2f = 0.0f;
            break;
        case FilterType::HighShelf1:
            b0f = sn + A + (A * cs); b1f = sn - A - (A * cs); b2f = 0.0f;
            a0f = sn + (1.0f / A) + (cs / A); a1f = sn - (1.0f / A) - (cs / A); a2f = 0.0f;
            break;
        case FilterType::LinkwitzTransform: {
            const float g0 = std::tan(kFirmwarePi * p.freq / fs);
            const float gp = std::tan(kFirmwarePi * ltFp / fs);
            b0f = 1.0f + g0 / p.q + g0 * g0;
            b1f = 2.0f * (g0 * g0 - 1.0f);
            b2f = 1.0f - g0 / p.q + g0 * g0;
            a0f = 1.0f + gp / ltQp + gp * gp;
            a1f = 2.0f * (gp * gp - 1.0f);
            a2f = 1.0f - gp / ltQp + gp * gp;
            break;
        }
        default:
            return out;  // Kind::Bypass
    }

    out.kind = RealizedSection::Kind::Biquad;

    if (platform == Platform::RP2350) {
        // Float storage, normalized by a0 via a reciprocal-and-multiply,
        // matching dsp_pipeline.c:303-308.
        const float invA0 = 1.0f / a0f;
        out.b0 = static_cast<double>(b0f * invA0);
        out.b1 = static_cast<double>(b1f * invA0);
        out.b2 = static_cast<double>(b2f * invA0);
        out.a1 = static_cast<double>(a1f * invA0);
        out.a2 = static_cast<double>(a2f * invA0);
    } else {
        // Q28 storage, direct division then truncation
        // (dsp_pipeline.c:311-316).  The division order differs from the
        // RP2350 reciprocal-and-multiply, which is itself a source of small
        // divergence between the two platforms.
        out.b0 = quantizeQ28(b0f / a0f);
        out.b1 = quantizeQ28(b1f / a0f);
        out.b2 = quantizeQ28(b2f / a0f);
        out.a1 = quantizeQ28(a1f / a0f);
        out.a2 = quantizeQ28(a2f / a0f);
    }

    return out;
}

// ---------------------------------------------------------------------------

std::vector<RealizedSection> realizeBank(const FilterBank& bank,
                                         double sampleRateHz,
                                         Platform platform) {
    std::vector<RealizedSection> out;
    out.reserve(bank.size());
    for (const FilterParams& p : bank) {
        if (p.bypass || p.type == FilterType::Flat) continue;
        out.push_back(realize(p, sampleRateHz, platform));
    }
    return out;
}

double magnitudeDb(const std::vector<RealizedSection>& sections,
                   double freqHz,
                   double sampleRateHz) {
    double magnitude = 1.0;
    for (const RealizedSection& s : sections) {
        magnitude *= std::abs(s.response(freqHz, sampleRateHz));
    }
    if (magnitude < 1e-30) magnitude = 1e-30;
    return 20.0 * std::log10(magnitude);
}

ResponseCache ResponseCache::forGrid(const FrequencyGrid& grid, double sampleRateHz) {
    ResponseCache cache;
    const std::size_t n = grid.size();
    cache.cosW.resize(n); cache.sinW.resize(n);
    cache.cos2W.resize(n); cache.sin2W.resize(n);
    cache.tanHalfW.resize(n);
    for (std::size_t i = 0; i < n; ++i) {
        const double w = 2.0 * M_PI * grid.hz[i] / sampleRateHz;
        cache.cosW[i] = std::cos(w);
        cache.sinW[i] = std::sin(w);
        cache.cos2W[i] = std::cos(2.0 * w);
        cache.sin2W[i] = std::sin(2.0 * w);
        cache.tanHalfW[i] = std::tan(w / 2.0);
    }
    return cache;
}

void magnitudeDbInto(const std::vector<RealizedSection>& sections,
                     const ResponseCache& cache,
                     std::vector<double>& out) {
    const std::size_t n = cache.size();
    out.assign(n, 0.0);

    for (const RealizedSection& s : sections) {
        switch (s.kind) {
            case RealizedSection::Kind::Bypass:
                break;

            case RealizedSection::Kind::Biquad:
                for (std::size_t i = 0; i < n; ++i) {
                    // z^-1 = cos(w) - j sin(w); z^-2 = cos(2w) - j sin(2w).
                    const double nr = s.b0 + s.b1 * cache.cosW[i] + s.b2 * cache.cos2W[i];
                    const double ni = -(s.b1 * cache.sinW[i] + s.b2 * cache.sin2W[i]);
                    const double dr = 1.0 + s.a1 * cache.cosW[i] + s.a2 * cache.cos2W[i];
                    const double di = -(s.a1 * cache.sinW[i] + s.a2 * cache.sin2W[i]);
                    const double den = dr * dr + di * di;
                    if (den < 1e-60) continue;
                    const double magnitudeSquared = (nr * nr + ni * ni) / den;
                    out[i] += 10.0 * std::log10(std::max(magnitudeSquared, 1e-60));
                }
                break;

            case RealizedSection::Kind::Svf:
                for (std::size_t i = 0; i < n; ++i) {
                    // u = j*t, so u^2 = -t^2 and the algebra stays real/imag split.
                    const double t = cache.tanHalfW[i];
                    const double dr = -(t * t) + s.g * s.g;
                    const double di = s.k * s.g * t;
                    const double nr = s.m2 * s.g * s.g;
                    const double ni = s.m1 * s.g * t;
                    const double den = dr * dr + di * di;
                    if (den < 1e-60) continue;
                    const double qr = (nr * dr + ni * di) / den;
                    const double qi = (ni * dr - nr * di) / den;
                    const double hr = s.m0 + qr;
                    const double magnitudeSquared = hr * hr + qi * qi;
                    out[i] += 10.0 * std::log10(std::max(magnitudeSquared, 1e-60));
                }
                break;

            case RealizedSection::Kind::SvfFirst:
                for (std::size_t i = 0; i < n; ++i) {
                    const double t = cache.tanHalfW[i];
                    const double dr = s.g;
                    const double di = t;
                    const double nr = s.m1 * s.g;
                    const double ni = s.m2 * t;
                    const double den = dr * dr + di * di;
                    if (den < 1e-60) continue;
                    const double qr = (nr * dr + ni * di) / den;
                    const double qi = (ni * dr - nr * di) / den;
                    const double hr = s.m0 + qr;
                    const double magnitudeSquared = hr * hr + qi * qi;
                    out[i] += 10.0 * std::log10(std::max(magnitudeSquared, 1e-60));
                }
                break;
        }
    }
}

std::vector<double> magnitudeDb(const std::vector<RealizedSection>& sections,
                                const FrequencyGrid& grid,
                                double sampleRateHz) {
    std::vector<double> out;
    out.reserve(grid.size());
    for (double f : grid.hz) {
        out.push_back(magnitudeDb(sections, f, sampleRateHz));
    }
    return out;
}

std::vector<double> bankMagnitudeDb(const FilterBank& bank,
                                    const FrequencyGrid& grid,
                                    double sampleRateHz,
                                    Platform platform) {
    return magnitudeDb(realizeBank(bank, sampleRateHz, platform), grid, sampleRateHz);
}

std::vector<double> phaseDegrees(const std::vector<RealizedSection>& sections,
                                 const FrequencyGrid& grid,
                                 double sampleRateHz) {
    std::vector<double> out;
    out.reserve(grid.size());
    double previous = 0.0;
    double offset = 0.0;
    for (double f : grid.hz) {
        std::complex<double> h(1.0, 0.0);
        for (const RealizedSection& s : sections) {
            h *= s.response(f, sampleRateHz);
        }
        double phase = std::arg(h) * 180.0 / M_PI;
        // Unwrap as we go so diagnostics get a continuous curve.
        double candidate = phase + offset;
        while (candidate - previous > 180.0) { offset -= 360.0; candidate -= 360.0; }
        while (candidate - previous < -180.0) { offset += 360.0; candidate += 360.0; }
        previous = candidate;
        out.push_back(candidate);
    }
    return out;
}

}  // namespace dspi_rc
