"""Filter, smoothing, and firmware-quantization primitives for Milestone 0."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Literal

import numpy as np


FilterKind = Literal["peaking", "low_shelf", "high_shelf"]
FirmwarePlatform = Literal["rp2040", "rp2350"]


def log_frequency_grid(
    minimum_hz: float = 20.0,
    maximum_hz: float = 20_000.0,
    points_per_octave: int = 96,
) -> np.ndarray:
    """Return an inclusive, uniformly log2-spaced frequency grid."""
    if minimum_hz <= 0.0 or maximum_hz <= minimum_hz or points_per_octave <= 0:
        raise ValueError("invalid logarithmic frequency grid")
    octaves = np.log2(maximum_hz / minimum_hz)
    steps = int(np.floor(octaves * points_per_octave))
    result = minimum_hz * np.power(2.0, np.arange(steps + 1) / points_per_octave)
    if result[-1] < maximum_hz:
        result = np.append(result, maximum_hz)
    else:
        result[-1] = maximum_hz
    return result


@dataclass(frozen=True)
class ParametricEQ:
    frequency_hz: float
    q: float
    gain_db: float
    filter_type: FilterKind = "peaking"


def _normalized_coefficients(
    sample_rate_hz: float,
    item: ParametricEQ,
    scalar: type[np.float32] | type[np.float64] = np.float64,
    *,
    direct_division: bool = False,
) -> tuple[float, float, float, float, float]:
    """DSPi's RBJ coefficient equations at selectable scalar precision."""
    cast = scalar
    frequency = cast(item.frequency_hz)
    q = cast(item.q)
    gain = cast(item.gain_db)
    sample_rate = cast(sample_rate_hz)
    two = cast(2.0)
    one = cast(1.0)
    amplitude = cast(cast(10.0) ** (gain / cast(40.0)))
    omega = cast(two * cast(np.pi) * frequency / sample_rate)
    sine = cast(np.sin(omega))
    cosine = cast(np.cos(omega))
    alpha = cast(sine / (two * q))
    sqrt_amplitude = cast(np.sqrt(amplitude))

    if item.filter_type == "peaking":
        b0 = cast(one + alpha * amplitude)
        b1 = cast(-two * cosine)
        b2 = cast(one - alpha * amplitude)
        a0 = cast(one + alpha / amplitude)
        a1 = cast(-two * cosine)
        a2 = cast(one - alpha / amplitude)
    elif item.filter_type == "low_shelf":
        b0 = cast(
            amplitude
            * (
                (amplitude + one)
                - (amplitude - one) * cosine
                + two * sqrt_amplitude * alpha
            )
        )
        b1 = cast(two * amplitude * ((amplitude - one) - (amplitude + one) * cosine))
        b2 = cast(
            amplitude
            * (
                (amplitude + one)
                - (amplitude - one) * cosine
                - two * sqrt_amplitude * alpha
            )
        )
        a0 = cast(
            (amplitude + one)
            + (amplitude - one) * cosine
            + two * sqrt_amplitude * alpha
        )
        a1 = cast(-two * ((amplitude - one) + (amplitude + one) * cosine))
        a2 = cast(
            (amplitude + one)
            + (amplitude - one) * cosine
            - two * sqrt_amplitude * alpha
        )
    elif item.filter_type == "high_shelf":
        b0 = cast(
            amplitude
            * (
                (amplitude + one)
                + (amplitude - one) * cosine
                + two * sqrt_amplitude * alpha
            )
        )
        b1 = cast(-two * amplitude * ((amplitude - one) + (amplitude + one) * cosine))
        b2 = cast(
            amplitude
            * (
                (amplitude + one)
                + (amplitude - one) * cosine
                - two * sqrt_amplitude * alpha
            )
        )
        a0 = cast(
            (amplitude + one)
            - (amplitude - one) * cosine
            + two * sqrt_amplitude * alpha
        )
        a1 = cast(two * ((amplitude - one) - (amplitude + one) * cosine))
        a2 = cast(
            (amplitude + one)
            - (amplitude - one) * cosine
            - two * sqrt_amplitude * alpha
        )
    else:
        raise ValueError(f"unsupported filter type: {item.filter_type}")

    values = (b0, b1, b2, a1, a2)
    if direct_division:
        return tuple(float(cast(value / a0)) for value in values)
    inverse_a0 = cast(one / a0)
    return tuple(
        float(cast(value * inverse_a0))
        for value in values
    )


def _coefficient_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    coefficients: tuple[float, float, float, float, float],
) -> np.ndarray:
    b0, b1, b2, a1, a2 = coefficients
    omega_grid = 2.0 * np.pi * frequencies_hz / sample_rate_hz
    z1 = np.exp(-1j * omega_grid)
    z2 = z1 * z1
    numerator = b0 + b1 * z1 + b2 * z2
    denominator = 1.0 + a1 * z1 + a2 * z2
    magnitude = np.maximum(np.abs(numerator / denominator), 1.0e-15)
    return 20.0 * np.log10(magnitude)


def filter_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    item: ParametricEQ,
) -> np.ndarray:
    if item.q <= 0.0 or item.frequency_hz <= 0.0:
        raise ValueError("frequency and Q must be positive")
    if item.frequency_hz >= sample_rate_hz / 2.0:
        raise ValueError("filter frequency must be below Nyquist")
    return _coefficient_response_db(
        frequencies_hz,
        sample_rate_hz,
        _normalized_coefficients(sample_rate_hz, item),
    )


def peaking_eq_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    frequency_hz: float,
    q: float,
    gain_db: float,
) -> np.ndarray:
    """Compatibility wrapper retained for fixture and test callers."""
    return filter_response_db(
        frequencies_hz,
        sample_rate_hz,
        ParametricEQ(frequency_hz, q, gain_db),
    )


def cascade_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    filters: list[ParametricEQ] | tuple[ParametricEQ, ...],
) -> np.ndarray:
    response = np.zeros_like(frequencies_hz, dtype=float)
    for item in filters:
        response += filter_response_db(frequencies_hz, sample_rate_hz, item)
    return response


def _round_tenth_away_from_zero(value: float) -> float:
    return math.copysign(math.floor(abs(value) * 10.0 + 0.5) / 10.0, value)


def quantize_filter_recipe(
    item: ParametricEQ,
    sample_rate_hz: float,
    *,
    console_gain_policy: bool = True,
) -> ParametricEQ:
    """Apply the current console/wire/firmware recipe precision.

    REQ_SET_EQ_PARAM carries three float32 values. DSPViewModel.setFilter adds
    a host policy of 0.1 dB gain rounding. Firmware coefficient design then
    clamps frequency to 10 Hz..0.45 Fs and Q to 0.1..20.
    """
    gain = (
        _round_tenth_away_from_zero(item.gain_db)
        if console_gain_policy
        else item.gain_db
    )
    return ParametricEQ(
        frequency_hz=float(
            np.float32(np.clip(item.frequency_hz, 10.0, 0.45 * sample_rate_hz))
        ),
        q=float(np.float32(np.clip(item.q, 0.1, 20.0))),
        gain_db=float(np.float32(gain)),
        filter_type=item.filter_type,
    )


def firmware_filter_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    item: ParametricEQ,
    platform: FirmwarePlatform,
) -> np.ndarray:
    """Evaluate float32 (RP2350) or Q28 (RP2040) stored coefficients.

    RP2350 uses an SVF below Fs/7.5 whose intended magnitude is RBJ-equivalent;
    this frequency-domain harness evaluates the float32-equivalent biquad.
    Time-domain SVF rounding parity remains a portable-core golden test.
    """
    coefficients = _normalized_coefficients(
        sample_rate_hz,
        item,
        np.float32,
        direct_division=platform == "rp2040",
    )
    if platform == "rp2040":
        scale = np.float32(1 << 28)
        coefficients = tuple(
            int(np.float32(np.float32(value) * scale)) / (1 << 28)
            for value in coefficients
        )
    elif platform != "rp2350":
        raise ValueError(f"unsupported firmware platform: {platform}")
    return _coefficient_response_db(frequencies_hz, sample_rate_hz, coefficients)


def firmware_cascade_response_db(
    frequencies_hz: np.ndarray,
    sample_rate_hz: float,
    filters: list[ParametricEQ] | tuple[ParametricEQ, ...],
    platform: FirmwarePlatform,
    *,
    console_gain_policy: bool = True,
) -> tuple[np.ndarray, tuple[ParametricEQ, ...]]:
    quantized = tuple(
        quantize_filter_recipe(
            item,
            sample_rate_hz,
            console_gain_policy=console_gain_policy,
        )
        for item in filters
    )
    response = np.zeros_like(frequencies_hz, dtype=float)
    for item in quantized:
        response += firmware_filter_response_db(
            frequencies_hz, sample_rate_hz, item, platform
        )
    return response, quantized


def pseudo_huber_loss(residual: np.ndarray, delta: float) -> np.ndarray:
    scaled = residual / delta
    return delta * delta * (np.sqrt(1.0 + scaled * scaled) - 1.0)


def softplus(value: np.ndarray | float, temperature: float) -> np.ndarray:
    scaled = np.asarray(value, dtype=float) / temperature
    return temperature * (
        np.maximum(scaled, 0.0) + np.log1p(np.exp(-np.abs(scaled)))
    )


def smooth_maximum(values: np.ndarray, temperature: float) -> float:
    maximum = float(np.max(values))
    return maximum + temperature * float(
        np.log(np.sum(np.exp((values - maximum) / temperature)))
    )
