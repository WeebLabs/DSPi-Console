"""Integer-exact model of the current DSPi logarithmic sweep recurrence."""

from __future__ import annotations

from dataclasses import dataclass
import math

import numpy as np


SUPPORTED_SAMPLE_RATES = (44_100, 48_000, 96_000)
Q48_TURNS = 1 << 48
Q31_SCALE = 1 << 31
UINT64_MASK = (1 << 64) - 1
DEFAULT_BLOCK_SAMPLES = 192
FADE_MILLISECONDS = 5


@dataclass(frozen=True)
class FirmwareSweep:
    sample_rate_hz: int
    requested_start_hz: float
    requested_end_hz: float
    effective_start_hz: float
    effective_end_hz: float
    duration_samples: int
    fade_samples: int
    increment_start_q48: int
    increment_end_q48: int
    epsilon_q31: int
    phase_q48: np.ndarray
    increment_q48: np.ndarray
    envelope: np.ndarray
    samples: np.ndarray

    @property
    def instantaneous_frequency_hz(self) -> np.ndarray:
        return self.increment_q48.astype(np.float64) * self.sample_rate_hz / Q48_TURNS


def _float32(value: float) -> float:
    return float(np.float32(value))


def _rp2350_sine(phase_q32: np.ndarray) -> np.ndarray:
    """Vector form of firmware's folded seventh-order float polynomial."""
    signed = phase_q32.astype(np.uint32).view(np.int32)
    x = signed.astype(np.float32) * np.float32(1.0 / (1 << 32))
    x = np.where(x > np.float32(0.25), np.float32(0.5) - x, x).astype(np.float32)
    x = np.where(x < np.float32(-0.25), np.float32(-0.5) - x, x).astype(np.float32)
    z = (x * x).astype(np.float32)
    acc = np.float32(81.3720013363) + z * np.float32(-71.3162390433)
    acc = np.float32(-41.3379844969) + z * acc
    acc = np.float32(6.2831695157) + z * acc
    return (x * acc).astype(np.float32)


def _firmware_envelope(length: int, fade_samples: int, block_samples: int) -> np.ndarray:
    """Reproduce planner endpoint ramps for a one-shot sweep.

    The first edge combines the start overlay and the cycle window. Firmware
    interpolates their product once per render segment, so render block size is
    part of the exact edge shape. The last edge uses only the cycle window.
    """
    if block_samples <= 0:
        raise ValueError("block_samples must be positive")
    envelope = np.ones(length, dtype=np.float64)
    position = 0
    fade_level = 0
    while position < length:
        block_end = min(position + block_samples, length)
        segment_start = position
        while segment_start < block_end:
            segment_end = block_end
            if fade_level < fade_samples:
                segment_end = min(segment_end, segment_start + fade_samples - fade_level)
            if segment_start < fade_samples:
                segment_end = min(segment_end, fade_samples)
            release_start = max(length - fade_samples, 0)
            if segment_start < release_start:
                segment_end = min(segment_end, release_start)

            segment_length = max(segment_end - segment_start, 1)
            next_fade = min(fade_level + segment_length, fade_samples)

            def combined_gain(cycle_position: int, overlay_level: int) -> float:
                overlay = min(overlay_level / fade_samples, 1.0)
                if cycle_position < fade_samples:
                    window = cycle_position / fade_samples
                elif cycle_position >= length - fade_samples:
                    window = max(length - cycle_position, 0) / fade_samples
                else:
                    window = 1.0
                return overlay * window

            gain0 = combined_gain(segment_start, fade_level)
            gain1 = combined_gain(segment_end, next_fade)
            step = (gain1 - gain0) / segment_length
            envelope[segment_start:segment_end] = gain0 + step * np.arange(segment_length)
            fade_level = next_fade
            segment_start = segment_end
        position = block_end
    return envelope


def generate_firmware_log_sweep(
    sample_rate_hz: int,
    start_hz: float = 20.0,
    end_hz: float = 20_000.0,
    duration_milliseconds: int = 5_000,
    level_dbfs: float = -12.0,
    block_samples: int = DEFAULT_BLOCK_SAMPLES,
) -> FirmwareSweep:
    """Generate the one-shot log sweep used by current DSPi firmware.

    This deliberately rejects unsupported rates. Firmware falls back to its
    48 kHz derived row for an unknown rate, but room correction must never rely
    on that unsafe behavior.
    """
    if sample_rate_hz not in SUPPORTED_SAMPLE_RATES:
        raise ValueError(f"unsupported room-correction sample rate: {sample_rate_hz}")
    if duration_milliseconds <= 0:
        raise ValueError("duration must be positive")
    if not -120.0 <= level_dbfs <= 0.0:
        raise ValueError("level must be between -120 and 0 dBFS")

    # cfg.p1/p2 and nyq are float in firmware before the double calculations.
    staged_start = _float32(start_hz)
    staged_end = _float32(end_hz)
    if staged_start != 0.0:
        staged_start = float(np.clip(staged_start, 1.0, 40_000.0))
    if staged_end != 0.0:
        staged_end = float(np.clip(staged_end, 1.0, 40_000.0))
    firmware_nyquist_limit = float(
        np.float32(0.45) * np.float32(sample_rate_hz)
    )
    effective_start = max(staged_start, 1.0)
    effective_end = min(staged_end, firmware_nyquist_limit)
    if effective_end <= effective_start:
        effective_end = _float32(effective_start + 1.0)

    fade_samples = max(sample_rate_hz * FADE_MILLISECONDS // 1_000, 8)
    duration_samples = sample_rate_hz * int(duration_milliseconds) // 1_000
    duration_samples = max(duration_samples, 2 * fade_samples)
    increment = int(effective_start / sample_rate_hz * Q48_TURNS)
    epsilon = math.log(effective_end / effective_start) / duration_samples
    epsilon_q31 = int(epsilon * Q31_SCALE)

    phases = np.empty(duration_samples, dtype=np.uint64)
    increments = np.empty(duration_samples, dtype=np.uint64)
    phase = 0
    for index in range(duration_samples):
        increments[index] = increment
        phase = (phase + increment) & UINT64_MASK
        phases[index] = phase
        increment = (increment + (((increment >> 16) * epsilon_q31) >> 15)) & UINT64_MASK

    phase_q32 = (phases >> np.uint64(16)).astype(np.uint32)
    oscillator = _rp2350_sine(phase_q32).astype(np.float64)
    envelope = _firmware_envelope(duration_samples, fade_samples, block_samples)
    amplitude = 10.0 ** (level_dbfs / 20.0)
    samples = (oscillator * envelope * amplitude).astype(np.float32)
    return FirmwareSweep(
        sample_rate_hz=sample_rate_hz,
        requested_start_hz=start_hz,
        requested_end_hz=end_hz,
        effective_start_hz=effective_start,
        effective_end_hz=effective_end,
        duration_samples=duration_samples,
        fade_samples=fade_samples,
        increment_start_q48=int(increments[0]),
        increment_end_q48=int(increments[-1]),
        epsilon_q31=epsilon_q31,
        phase_q48=phases,
        increment_q48=increments,
        envelope=envelope,
        samples=samples,
    )
