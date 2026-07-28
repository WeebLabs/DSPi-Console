"""Deterministic in-model and out-of-model multi-position corpus."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

import numpy as np

from .model import ParametricEQ, cascade_response_db, log_frequency_grid


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    source_model: str
    sample_rate_hz: int
    frequencies_hz: np.ndarray
    measurements_db: np.ndarray
    target_db: np.ndarray
    position_weights: np.ndarray
    probe_bands_hz: tuple[tuple[float, float], ...]
    native_band_hz: tuple[float, float] | None


@dataclass(frozen=True)
class Corpus:
    scenarios: tuple[Scenario, ...]

    def named(self, name: str) -> Scenario:
        for scenario in self.scenarios:
            if scenario.name == name:
                return scenario
        raise KeyError(name)


def _parse_filters(raw_filters: list[dict[str, object]]) -> list[ParametricEQ]:
    return [
        ParametricEQ(
            frequency_hz=float(item["frequency_hz"]),
            q=float(item.get("q", 0.707)),
            gain_db=float(item["gain_db"]),
            filter_type=str(item.get("filter_type", "peaking")),
        )
        for item in raw_filters
    ]


def _analytic_response(
    frequencies_hz: np.ndarray,
    raw: dict[str, object],
) -> np.ndarray:
    """Generate structure the optimizer cannot exactly invert with RBJ PEQs."""
    response = np.zeros_like(frequencies_hz)
    for feature in raw.get("gaussian_features", []):
        center = float(feature["frequency_hz"])
        width = float(feature["width_octaves"])
        gain = float(feature["gain_db"])
        response += gain * np.exp(
            -0.5 * (np.log2(frequencies_hz / center) / width) ** 2
        )
    for rolloff in raw.get("rolloffs", []):
        corner = float(rolloff["frequency_hz"])
        order = float(rolloff.get("order", 2.0))
        if rolloff["side"] == "low":
            ratio = corner / frequencies_hz
        elif rolloff["side"] == "high":
            ratio = frequencies_hz / corner
        else:
            raise ValueError(f"unknown rolloff side: {rolloff['side']}")
        response -= 10.0 * np.log10(1.0 + np.power(ratio, 2.0 * order))
    for reflection in raw.get("delayed_reflections", []):
        delay_seconds = float(reflection["delay_milliseconds"]) / 1_000.0
        ratio = float(reflection["amplitude_ratio"])
        phase = float(reflection.get("phase_degrees", 180.0)) * np.pi / 180.0
        transfer = 1.0 + ratio * np.exp(
            -1j * (2.0 * np.pi * frequencies_hz * delay_seconds - phase)
        )
        # Normalize the two-path maximum to 0 dB so the feature is cancellation.
        response += 20.0 * np.log10(np.maximum(np.abs(transfer), 1.0e-8))
        response -= 20.0 * np.log10(1.0 + abs(ratio))
    return response


def _target_response(
    frequencies_hz: np.ndarray,
    raw_scenario: dict[str, object],
) -> np.ndarray:
    target = np.full_like(
        frequencies_hz, float(raw_scenario.get("target_level_db", 0.0))
    )
    target += float(raw_scenario.get("target_slope_db_per_octave", 0.0)) * np.log2(
        frequencies_hz / 1_000.0
    )
    low_rise = raw_scenario.get("target_low_rise")
    if low_rise:
        corner = float(low_rise["frequency_hz"])
        gain = float(low_rise["gain_db"])
        steepness = float(low_rise.get("steepness", 4.0))
        target += gain / (1.0 + np.power(frequencies_hz / corner, steepness))
    high_fall = raw_scenario.get("target_high_fall")
    if high_fall:
        corner = float(high_fall["frequency_hz"])
        slope = float(high_fall["slope_db_per_octave"])
        target += slope * np.maximum(np.log2(frequencies_hz / corner), 0.0)
    return target


def load_corpus(path: str | Path) -> Corpus:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    scenarios: list[Scenario] = []
    for raw_scenario in raw["scenarios"]:
        sample_rate = int(raw_scenario.get("sample_rate_hz", raw["sample_rate_hz"]))
        grid = raw_scenario.get("grid", raw["grid"])
        frequencies = log_frequency_grid(
            float(grid["minimum_hz"]),
            float(grid["maximum_hz"]),
            int(grid["points_per_octave"]),
        )
        common = cascade_response_db(
            frequencies,
            sample_rate,
            _parse_filters(raw_scenario.get("common_filters", [])),
        )
        common += _analytic_response(frequencies, raw_scenario)
        measurements: list[np.ndarray] = []
        weights: list[float] = []
        for position_index, position in enumerate(raw_scenario["positions"]):
            curve = common.copy()
            curve += cascade_response_db(
                frequencies,
                sample_rate,
                _parse_filters(position.get("filters", [])),
            )
            curve += _analytic_response(frequencies, position)
            curve += float(position.get("level_db", 0.0))
            curve += float(position.get("tilt_db_per_octave", 0.0)) * np.log2(
                frequencies / 1_000.0
            )
            noise_db = float(position.get("noise_db", 0.0))
            if noise_db:
                seed = int(raw_scenario.get("seed", 0)) + position_index
                rng = np.random.default_rng(seed)
                white = rng.normal(0.0, noise_db, frequencies.size)
                points_per_octave = int(grid["points_per_octave"])
                width = max(3, points_per_octave // 12)
                kernel = np.hanning(width)
                kernel /= np.sum(kernel)
                curve += np.convolve(white, kernel, mode="same")
            measurements.append(curve)
            weights.append(float(position.get("weight", 1.0)))

        normalized_weights = np.asarray(weights, dtype=float)
        normalized_weights /= np.sum(normalized_weights)
        native = raw_scenario.get("native_band_hz")
        scenarios.append(
            Scenario(
                name=str(raw_scenario["name"]),
                description=str(raw_scenario["description"]),
                source_model=str(raw_scenario.get("source_model", "rbj_biquad")),
                sample_rate_hz=sample_rate,
                frequencies_hz=frequencies,
                measurements_db=np.asarray(measurements),
                target_db=_target_response(frequencies, raw_scenario),
                position_weights=normalized_weights,
                probe_bands_hz=tuple(
                    (float(item[0]), float(item[1]))
                    for item in raw_scenario.get("probe_bands_hz", [])
                ),
                native_band_hz=(float(native[0]), float(native[1])) if native else None,
            )
        )
    return Corpus(tuple(scenarios))
