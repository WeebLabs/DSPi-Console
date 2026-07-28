"""Neutral scoring, ablations, and spatially robust PEQ fitting experiments."""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import math
import time
from typing import Callable, Literal

import numpy as np
from scipy.optimize import minimize

from .fixtures import Scenario
from .model import (
    FilterKind,
    FirmwarePlatform,
    ParametricEQ,
    cascade_response_db,
    firmware_cascade_response_db,
    pseudo_huber_loss,
    smooth_maximum,
    softplus,
)


FitVariant = Literal[
    "arithmetic_plain",
    "arithmetic_hygiene",
    "spatial_plain",
    "spatial_hygiene",
]


@dataclass(frozen=True)
class FitConfig:
    filter_count: int = 10
    minimum_frequency_hz: float = 20.0
    maximum_frequency_hz: float = 20_000.0
    cut_limit_db: float = -12.0
    boost_limit_db: float = 3.0
    combined_correction_ceiling_db: float = -0.5
    outside_native_boost_ceiling_db: float = 0.0
    disputed_boost_ceiling_db: float = 0.5
    huber_delta_db: float = 2.0
    overshoot_tolerance_db: float = 0.5
    max_iterations: int = 400
    deterministic_starts: int = 3
    # The ten-band sweep was insensitive from 0.125x through 1.0x; 0.25x was
    # selected because it was the only tested row that converged in all 8
    # scenarios. Hard safety contracts above are deliberately unscaled.
    complexity_weight: float = 0.0005
    positive_correction_weight: float = 0.0375
    unreliable_boost_weight: float = 2.5
    overshoot_weight: float = 0.625
    sharpness_weight: float = 0.125
    smooth_temperature_db: float = 0.04
    allow_shelves: bool = True
    firmware_platform: FirmwarePlatform = "rp2350"


@dataclass(frozen=True)
class SpatialStatistics:
    power_average_db: np.ndarray
    median_db: np.ndarray
    mad_db: np.ndarray
    sign_agreement: np.ndarray
    reliability: np.ndarray
    transition_frequency_hz: float
    estimated_native_minimum_hz: float
    estimated_native_maximum_hz: float


@dataclass(frozen=True)
class FitResult:
    variant: str
    method: str
    firmware_platform: FirmwarePlatform
    filters: tuple[ParametricEQ, ...]
    quantized_filters: tuple[ParametricEQ, ...]
    success: bool
    message: str
    starts: int
    iterations: int
    evaluations: int
    elapsed_seconds: float
    trim_db: float
    unquantized_trim_db: float
    continuous_objective: float
    optimization_objective: float
    neutral_metrics: dict[str, float]

    def json_dict(self) -> dict[str, object]:
        result = asdict(self)
        result["filters"] = [asdict(item) for item in self.filters]
        result["quantized_filters"] = [
            asdict(item) for item in self.quantized_filters
        ]
        return result


def _weighted_median(values: np.ndarray, weights: np.ndarray) -> np.ndarray:
    order = np.argsort(values, axis=0)
    sorted_values = np.take_along_axis(values, order, axis=0)
    broadcast_weights = np.broadcast_to(weights[:, None], values.shape)
    sorted_weights = np.take_along_axis(broadcast_weights, order, axis=0)
    cumulative = np.cumsum(sorted_weights, axis=0)
    index = np.argmax(cumulative >= 0.5 * np.sum(weights), axis=0)
    return np.take_along_axis(sorted_values, index[None, :], axis=0)[0]


def _estimate_transition_frequency(
    frequencies_hz: np.ndarray,
    measurements_db: np.ndarray,
    weights: np.ndarray,
) -> float:
    if measurements_db.shape[0] < 2:
        return 200.0
    mean = np.sum(weights[:, None] * measurements_db, axis=0)
    spread = np.sqrt(
        np.sum(weights[:, None] * (measurements_db - mean) ** 2, axis=0)
    )
    indices = np.flatnonzero(
        (frequencies_hz >= 80.0) & (frequencies_hz <= 500.0)
    )
    if indices.size < 7:
        return 200.0

    points_per_octave = 1.0 / float(np.median(np.diff(np.log2(frequencies_hz))))
    radius = max(3, int(round(points_per_octave / 4.0)))
    correlation = np.ones(frequencies_hz.size)
    for frequency_index in indices:
        start = max(0, frequency_index - radius)
        stop = min(frequencies_hz.size, frequency_index + radius + 1)
        pair_values: list[float] = []
        pair_weights: list[float] = []
        for left in range(measurements_db.shape[0]):
            for right in range(left + 1, measurements_db.shape[0]):
                a = measurements_db[left, start:stop]
                b = measurements_db[right, start:stop]
                a = a - np.mean(a)
                b = b - np.mean(b)
                denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
                pair_values.append(
                    float(np.dot(a, b) / denominator)
                    if denominator > 1.0e-9
                    else 1.0
                )
                pair_weights.append(float(weights[left] * weights[right]))
        correlation[frequency_index] = float(
            np.average(pair_values, weights=pair_weights)
        )

    width = max(5, int(round(points_per_octave / 6.0)))
    smooth_spread = np.convolve(spread, np.ones(width) / width, mode="same")
    decorrelation = 1.0 - correlation
    candidate_spread = smooth_spread[indices]
    candidate_decorrelation = decorrelation[indices]
    spread_range = float(np.ptp(candidate_spread))
    decorrelation_range = float(np.ptp(candidate_decorrelation))
    if spread_range < 0.75 and decorrelation_range < 0.15:
        return 200.0

    score = np.zeros_like(frequencies_hz)
    if spread_range >= 0.75:
        score += (smooth_spread - float(np.min(candidate_spread))) / spread_range
    if decorrelation_range >= 0.15:
        score += (
            decorrelation - float(np.min(candidate_decorrelation))
        ) / decorrelation_range
    gradient = np.gradient(score, np.log2(frequencies_hz))
    inner = indices[2:-2]
    transition_index = inner[int(np.argmax(gradient[inner]))]
    return float(np.clip(frequencies_hz[transition_index], 100.0, 400.0))


def _estimate_native_band(
    frequencies_hz: np.ndarray,
    power_average_db: np.ndarray,
    target_db: np.ndarray,
) -> tuple[float, float]:
    relative = power_average_db - target_db
    points_per_octave = 1.0 / float(np.median(np.diff(np.log2(frequencies_hz))))
    width = max(5, int(round(points_per_octave / 3.0)))
    smooth = np.convolve(relative, np.ones(width) / width, mode="same")
    reference_region = (frequencies_hz >= 100.0) & (frequencies_hz <= 5_000.0)
    reference = float(np.percentile(smooth[reference_region], 70.0))
    inside = smooth >= reference - 3.5
    indices = np.flatnonzero(inside)
    if indices.size == 0:
        return float(frequencies_hz[0]), float(frequencies_hz[-1])
    return float(frequencies_hz[indices[0]]), float(frequencies_hz[indices[-1]])


def spatial_statistics(scenario: Scenario) -> SpatialStatistics:
    measurements = scenario.measurements_db
    weights = scenario.position_weights
    linear_power = np.power(10.0, measurements / 10.0)
    power_average = 10.0 * np.log10(
        np.sum(weights[:, None] * linear_power, axis=0)
    )
    median = _weighted_median(measurements, weights)
    mad = _weighted_median(np.abs(measurements - median), weights)
    desired = scenario.target_db - power_average
    individual_desired = scenario.target_db[None, :] - measurements
    direction = np.sign(desired)
    agrees = (individual_desired * direction[None, :]) > 0.25
    agreement = np.sum(weights[:, None] * agrees, axis=0)
    reliability = np.clip(agreement, 0.0, 1.0) * np.exp(-mad / 6.0)
    native_minimum, native_maximum = _estimate_native_band(
        scenario.frequencies_hz, power_average, scenario.target_db
    )
    return SpatialStatistics(
        power_average_db=power_average,
        median_db=median,
        mad_db=mad,
        sign_agreement=agreement,
        reliability=np.clip(reliability, 0.05, 1.0),
        transition_frequency_hz=_estimate_transition_frequency(
            scenario.frequencies_hz, measurements, weights
        ),
        estimated_native_minimum_hz=native_minimum,
        estimated_native_maximum_hz=native_maximum,
    )


def _cut_q_limit(frequency_hz: float, transition_frequency_hz: float) -> float:
    if frequency_hz <= transition_frequency_hz:
        return 10.0
    fraction = np.clip(
        math.log(frequency_hz / transition_frequency_hz)
        / math.log(10_000.0 / transition_frequency_hz),
        0.0,
        1.0,
    )
    return float(10.0 + (3.0 - 10.0) * fraction)


def _decode_parameters(
    parameters: np.ndarray,
    filter_types: tuple[FilterKind, ...],
) -> tuple[ParametricEQ, ...]:
    return tuple(
        ParametricEQ(
            frequency_hz=10.0 ** parameters[index],
            q=math.exp(parameters[index + 1]),
            gain_db=parameters[index + 2],
            filter_type=filter_types[index // 3],
        )
        for index in range(0, parameters.size, 3)
    )


def _encode_filters(filters: tuple[ParametricEQ, ...]) -> np.ndarray:
    values: list[float] = []
    for item in filters:
        values.extend(
            (math.log10(item.frequency_hz), math.log(item.q), item.gain_db)
        )
    return np.asarray(values)


def _parameter_bounds(
    config: FitConfig,
    filter_types: tuple[FilterKind, ...],
) -> list[tuple[float, float]]:
    bounds: list[tuple[float, float]] = []
    for filter_type in filter_types:
        q_bounds = (0.5, 1.0) if filter_type != "peaking" else (0.3, 10.0)
        bounds.extend(
            (
                (
                    math.log10(config.minimum_frequency_hz),
                    math.log10(config.maximum_frequency_hz),
                ),
                (math.log(q_bounds[0]), math.log(q_bounds[1])),
                (config.cut_limit_db, config.boost_limit_db),
            )
        )
    return bounds


def _boost_confidence(
    scenario: Scenario,
    statistics: SpatialStatistics,
) -> np.ndarray:
    confidence = statistics.reliability * np.clip(
        (statistics.sign_agreement - 0.5) / 0.5, 0.0, 1.0
    )
    # An explicit user correction curtain takes precedence over automatic
    # bandwidth detection. Fixtures use native_band_hz to exercise that same
    # production rule rather than granting the optimizer hidden ground truth.
    native_band = scenario.native_band_hz or (
        statistics.estimated_native_minimum_hz,
        statistics.estimated_native_maximum_hz,
    )
    native = (
        (scenario.frequencies_hz >= native_band[0])
        & (scenario.frequencies_hz <= native_band[1])
    )
    return confidence * native


def _seed_parameters(
    guide_db: np.ndarray,
    scenario: Scenario,
    config: FitConfig,
    boost_confidence: np.ndarray | None,
    transition_frequency_hz: float,
) -> tuple[np.ndarray, tuple[FilterKind, ...]]:
    residual = guide_db.copy()
    if boost_confidence is not None:
        residual = np.where(residual > 0.0, residual * boost_confidence, residual)
    valid = (
        (scenario.frequencies_hz >= config.minimum_frequency_hz)
        & (scenario.frequencies_hz <= config.maximum_frequency_hz)
    )
    log_step = float(np.median(np.diff(np.log2(scenario.frequencies_hz))))
    area_width = max(3, int(round(0.5 / log_step)))
    if area_width % 2 == 0:
        area_width += 1
    area_radius = area_width // 2
    area_kernel = np.ones(area_width)
    filters: list[ParametricEQ] = []

    if config.allow_shelves:
        valid_indices = np.flatnonzero(valid)
        edge_count = min(area_width, valid_indices.size)
        edge_candidates: list[tuple[float, ParametricEQ]] = []
        for filter_type, indices in (
            ("low_shelf", valid_indices[:edge_count]),
            ("high_shelf", valid_indices[-edge_count:]),
        ):
            values = residual[indices]
            median = float(np.median(values))
            if abs(median) < 0.75:
                continue
            agreement = float(np.mean(np.sign(values) == np.sign(median)))
            if agreement < 0.75:
                continue
            frequency = (
                float(scenario.frequencies_hz[indices[-1]])
                if filter_type == "low_shelf"
                else float(scenario.frequencies_hz[indices[0]])
            )
            gain = float(
                np.clip(median, config.cut_limit_db, config.boost_limit_db)
            )
            edge_candidates.append(
                (
                    float(np.sum(np.abs(values))),
                    ParametricEQ(frequency, 0.707, gain, filter_type),
                )
            )
        for _, item in sorted(edge_candidates, reverse=True, key=lambda pair: pair[0]):
            if len(filters) >= config.filter_count:
                break
            filters.append(item)
            residual -= cascade_response_db(
                scenario.frequencies_hz, scenario.sample_rate_hz, [item]
            )

    while len(filters) < config.filter_count:
        weighted_residual = residual.copy()
        if boost_confidence is not None:
            weighted_residual = np.where(
                residual > 0.0, residual * boost_confidence, residual
            )
        positive_area = np.convolve(
            np.maximum(weighted_residual, 0.0), area_kernel, mode="same"
        )
        negative_area = np.convolve(
            np.maximum(-weighted_residual, 0.0), area_kernel, mode="same"
        )
        score = np.maximum(positive_area, negative_area)
        available = valid.copy()
        for existing in filters:
            available &= ~(
                np.abs(
                    np.log2(scenario.frequencies_hz / existing.frequency_hz)
                )
                < 0.3
            )
        score = np.where(available, score, -np.inf)
        area_index = int(np.argmax(score))
        positive_feature = positive_area[area_index] >= negative_area[area_index]
        start = max(0, area_index - area_radius)
        stop = min(residual.size, area_index + area_radius + 1)
        feature_indices = np.arange(start, stop)
        matching = (
            weighted_residual[feature_indices] > 0.0
            if positive_feature
            else weighted_residual[feature_indices] < 0.0
        )
        if np.any(matching):
            matching_indices = feature_indices[matching]
            index = int(
                matching_indices[
                    np.argmax(np.abs(weighted_residual[matching_indices]))
                ]
            )
        else:
            index = area_index
        gain = float(
            np.clip(residual[index], config.cut_limit_db, config.boost_limit_db)
        )
        if boost_confidence is not None and gain > 0.0:
            gain *= float(boost_confidence[index])
        if not np.isfinite(score[index]) or abs(gain) < 0.05:
            frequency = float(
                np.clip(
                    80.0 * (2.4 ** len(filters)),
                    config.minimum_frequency_hz,
                    config.maximum_frequency_hz,
                )
            )
            gain = 0.0
        else:
            frequency = float(scenario.frequencies_hz[index])
        half_height = abs(residual[index]) * 0.5
        left = index
        right = index
        sign = np.sign(residual[index])
        while (
            left > 0
            and np.sign(residual[left - 1]) == sign
            and abs(residual[left - 1]) >= half_height
        ):
            left -= 1
        while (
            right + 1 < residual.size
            and np.sign(residual[right + 1]) == sign
            and abs(residual[right + 1]) >= half_height
        ):
            right += 1
        left_frequency = scenario.frequencies_hz[max(left - 1, 0)]
        right_frequency = scenario.frequencies_hz[min(right + 1, residual.size - 1)]
        bandwidth = max(
            float(np.log2(right_frequency / left_frequency)), log_step
        )
        ratio = 2.0**bandwidth
        estimated_q = math.sqrt(ratio) / max(ratio - 1.0, 1.0e-6)
        q_limit = (
            2.0
            if gain > 0.0
            else _cut_q_limit(frequency, transition_frequency_hz)
        )
        item = ParametricEQ(
            frequency,
            float(np.clip(estimated_q, 0.3, q_limit)),
            gain,
        )
        filters.append(item)
        residual -= cascade_response_db(
            scenario.frequencies_hz, scenario.sample_rate_hz, [item]
        )

    result = tuple(filters)
    return _encode_filters(result), tuple(item.filter_type for item in result)


def _deterministic_starts(
    initial: np.ndarray,
    bounds: list[tuple[float, float]],
    count: int,
) -> list[np.ndarray]:
    starts = [initial]
    for start_index in range(1, count):
        shifted = initial.copy()
        for filter_index in range(initial.size // 3):
            base = filter_index * 3
            direction = 1.0 if (filter_index + start_index) % 2 == 0 else -1.0
            shifted[base] += direction * 0.05 * start_index
            shifted[base + 1] -= 0.10 * start_index
            shifted[base + 2] *= 1.0 - 0.10 * start_index
        shifted = np.asarray(
            [
                np.clip(value, lower, upper)
                for value, (lower, upper) in zip(shifted, bounds)
            ]
        )
        starts.append(shifted)
    return starts


def _smooth_correction(
    parameters: np.ndarray,
    filter_types: tuple[FilterKind, ...],
    variant: FitVariant,
    scenario: Scenario,
    statistics: SpatialStatistics,
    config: FitConfig,
) -> tuple[np.ndarray, tuple[ParametricEQ, ...], float]:
    filters = _decode_parameters(parameters, filter_types)
    response = cascade_response_db(
        scenario.frequencies_hz, scenario.sample_rate_hz, filters
    )
    smooth_maximum_db = smooth_maximum(
        response, config.smooth_temperature_db
    )
    required_drops = [
        float(
            softplus(
                smooth_maximum_db - config.combined_correction_ceiling_db,
                config.smooth_temperature_db,
            )
        )
    ]
    native_band = scenario.native_band_hz or (
        statistics.estimated_native_minimum_hz,
        statistics.estimated_native_maximum_hz,
    )
    outside_native = (
        (scenario.frequencies_hz < native_band[0])
        | (scenario.frequencies_hz > native_band[1])
    )
    if variant.endswith("hygiene") and np.any(outside_native):
        outside_maximum_db = smooth_maximum(
            response[outside_native], config.smooth_temperature_db
        )
        required_drops.append(
            float(
                softplus(
                    outside_maximum_db
                    - config.outside_native_boost_ceiling_db,
                    config.smooth_temperature_db,
                )
            )
        )
    disputed = (
        (statistics.sign_agreement < 0.6)
        | (statistics.reliability < 0.5)
    )
    if variant == "spatial_hygiene" and np.any(disputed):
        disputed_maximum_db = smooth_maximum(
            response[disputed], config.smooth_temperature_db
        )
        required_drops.append(
            float(
                softplus(
                    disputed_maximum_db
                    - config.disputed_boost_ceiling_db,
                    config.smooth_temperature_db,
                )
            )
        )
    trim = -smooth_maximum(
        np.asarray(required_drops), config.smooth_temperature_db
    )
    return response + trim, filters, trim


def _exact_trim(
    response_db: np.ndarray,
    ceiling_db: float,
    *,
    outside_native: np.ndarray | None,
    outside_native_ceiling_db: float,
    disputed: np.ndarray | None,
    disputed_ceiling_db: float,
    quantize_tenth_db: bool,
) -> float:
    required = min(0.0, ceiling_db - float(np.max(response_db)))
    if outside_native is not None and np.any(outside_native):
        required = min(
            required,
            outside_native_ceiling_db
            - float(np.max(response_db[outside_native])),
        )
    if disputed is not None and np.any(disputed):
        required = min(
            required,
            disputed_ceiling_db - float(np.max(response_db[disputed])),
        )
    if quantize_tenth_db:
        required = math.floor((required + 1.0e-9) * 10.0) / 10.0
    return required


def _spatial_error(
    residual: np.ndarray,
    scenario: Scenario,
    statistics: SpatialStatistics,
    config: FitConfig,
    *,
    reliability_weighted: bool,
) -> float:
    frequency_weights = (
        statistics.reliability
        if reliability_weighted
        else np.ones_like(statistics.reliability)
    )
    weights = scenario.position_weights[:, None] * frequency_weights[None, :]
    return float(
        np.sum(weights * pseudo_huber_loss(residual, config.huber_delta_db))
        / np.sum(weights)
    )


def _hygiene_penalty(
    correction_db: np.ndarray,
    filters: tuple[ParametricEQ, ...],
    residual: np.ndarray,
    scenario: Scenario,
    statistics: SpatialStatistics,
    config: FitConfig,
    *,
    use_spatial_reliability: bool,
) -> float:
    temperature = config.smooth_temperature_db
    overshoot = softplus(
        residual - config.overshoot_tolerance_db, temperature
    )
    overshoot_penalty = float(
        np.sum(scenario.position_weights[:, None] * overshoot**2)
        / residual.shape[1]
    )
    positive = softplus(correction_db, temperature)
    positive_penalty = float(np.mean(positive**2))
    if use_spatial_reliability:
        confidence = _boost_confidence(scenario, statistics)
        unreliable_boost = float(
            np.mean((positive * (1.0 - confidence)) ** 2)
        )
    else:
        unreliable_boost = 0.0

    sharpness = 0.0
    complexity = 0.0
    for item in filters:
        if item.filter_type == "peaking":
            cut_limit = _cut_q_limit(
                item.frequency_hz, statistics.transition_frequency_hz
            )
            boost_fraction = 1.0 / (
                1.0 + math.exp(-item.gain_db / max(temperature, 0.02))
            )
            q_limit = cut_limit + boost_fraction * (min(2.0, cut_limit) - cut_limit)
        else:
            q_limit = 1.0
        violation = float(softplus(item.q - q_limit, 0.03))
        sharpness += violation * violation * (0.25 + abs(item.gain_db)) ** 2
        complexity += math.sqrt(item.gain_db * item.gain_db + 0.01)
    return (
        config.overshoot_weight * overshoot_penalty
        + config.positive_correction_weight * positive_penalty
        + config.unreliable_boost_weight * unreliable_boost
        + config.sharpness_weight * sharpness
        + config.complexity_weight * complexity
    )


def _objective_value(
    variant: FitVariant,
    correction: np.ndarray,
    filters: tuple[ParametricEQ, ...],
    scenario: Scenario,
    statistics: SpatialStatistics,
    config: FitConfig,
) -> float:
    arithmetic_average = np.sum(
        scenario.position_weights[:, None] * scenario.measurements_db, axis=0
    )
    if variant.startswith("arithmetic"):
        average_residual = arithmetic_average + correction - scenario.target_db
        if variant == "arithmetic_plain":
            return float(np.mean(average_residual**2))
        residual = average_residual[None, :]
        synthetic = replace(
            scenario,
            measurements_db=arithmetic_average[None, :],
            position_weights=np.asarray([1.0]),
        )
        error = float(
            np.mean(
                pseudo_huber_loss(
                    average_residual, config.huber_delta_db
                )
            )
        )
        return error + _hygiene_penalty(
            correction,
            filters,
            residual,
            synthetic,
            statistics,
            config,
            use_spatial_reliability=False,
        )

    residual = (
        scenario.measurements_db
        + correction[None, :]
        - scenario.target_db[None, :]
    )
    error = _spatial_error(
        residual,
        scenario,
        statistics,
        config,
        reliability_weighted=True,
    )
    if variant == "spatial_plain":
        return error
    return error + _hygiene_penalty(
        correction,
        filters,
        residual,
        scenario,
        statistics,
        config,
        use_spatial_reliability=True,
    )


def _objective_for_variant(
    variant: FitVariant,
    scenario: Scenario,
    statistics: SpatialStatistics,
    config: FitConfig,
    filter_types: tuple[FilterKind, ...],
) -> Callable[[np.ndarray], float]:

    def objective(parameters: np.ndarray) -> float:
        correction, filters, _ = _smooth_correction(
            parameters, filter_types, variant, scenario, statistics, config
        )
        return _objective_value(
            variant, correction, filters, scenario, statistics, config
        )

    return objective


def _neutral_metrics(
    correction_db: np.ndarray,
    scenario: Scenario,
    statistics: SpatialStatistics,
    filters: tuple[ParametricEQ, ...],
) -> dict[str, float]:
    residual = scenario.measurements_db + correction_db[None, :] - scenario.target_db[None, :]
    rmse_by_position = np.sqrt(np.mean(residual**2, axis=1))
    reliable_weights = statistics.reliability.copy()
    native_band = scenario.native_band_hz or (
        statistics.estimated_native_minimum_hz,
        statistics.estimated_native_maximum_hz,
    )
    reliable_weights *= (
        (scenario.frequencies_hz >= native_band[0])
        & (scenario.frequencies_hz <= native_band[1])
    )
    reliable_weights = np.maximum(reliable_weights, 1.0e-6)
    reliable_rmse = np.sqrt(
        np.sum(reliable_weights[None, :] * residual**2, axis=1)
        / np.sum(reliable_weights)
    )
    reliable_mask = reliable_weights >= 0.5
    if not np.any(reliable_mask):
        reliable_mask = reliable_weights > 1.0e-6

    disputed = (
        (statistics.sign_agreement < 0.6)
        | (statistics.reliability < 0.5)
    )
    outside_native = (
        (scenario.frequencies_hz < native_band[0])
        | (scenario.frequencies_hz > native_band[1])
    )
    positive_overshoot = np.maximum(residual, 0.0)
    reliable_huber = float(
        np.sum(
            scenario.position_weights[:, None]
            * reliable_weights[None, :]
            * pseudo_huber_loss(residual, 2.0)
        )
        / np.sum(reliable_weights)
    )
    metrics = {
        "raw_worst_position_rmse_db": float(np.max(rmse_by_position)),
        "raw_median_absolute_error_db": float(np.median(np.abs(residual))),
        "reliable_worst_position_rmse_db": float(np.max(reliable_rmse)),
        "reliable_median_absolute_error_db": float(
            np.median(np.abs(residual[:, reliable_mask]))
        ),
        "reliability_weighted_huber_loss": reliable_huber,
        "p95_positive_overshoot_db": float(
            np.percentile(positive_overshoot, 95.0)
        ),
        "max_combined_correction_db": float(np.max(correction_db)),
        "minimum_combined_correction_db": float(np.min(correction_db)),
        "max_disputed_boost_db": float(
            max(np.max(correction_db[disputed]), 0.0)
            if np.any(disputed)
            else 0.0
        ),
        "max_outside_native_boost_db": float(
            max(np.max(correction_db[outside_native]), 0.0)
            if np.any(outside_native)
            else 0.0
        ),
        "maximum_boost_filter_q": float(
            max((item.q for item in filters if item.gain_db > 0.05), default=0.0)
        ),
        "active_filter_count": float(
            sum(abs(item.gain_db) >= 0.05 for item in filters)
        ),
        "shelf_filter_count": float(
            sum(
                abs(item.gain_db) >= 0.05 and item.filter_type != "peaking"
                for item in filters
            )
        ),
        "transition_frequency_hz": statistics.transition_frequency_hz,
        "estimated_native_minimum_hz": statistics.estimated_native_minimum_hz,
        "estimated_native_maximum_hz": statistics.estimated_native_maximum_hz,
    }
    for probe_index, (low, high) in enumerate(scenario.probe_bands_hz):
        mask = (scenario.frequencies_hz >= low) & (scenario.frequencies_hz <= high)
        metrics[f"probe_{probe_index}_max_correction_db"] = float(
            np.max(correction_db[mask])
        )
    return metrics


def uncorrected_neutral_metrics(scenario: Scenario) -> dict[str, float]:
    statistics = spatial_statistics(scenario)
    return _neutral_metrics(
        np.zeros_like(scenario.frequencies_hz), scenario, statistics, tuple()
    )


def _platform_correction(
    filters: tuple[ParametricEQ, ...],
    scenario: Scenario,
    config: FitConfig,
    outside_native: np.ndarray | None,
    disputed: np.ndarray | None,
) -> tuple[np.ndarray, tuple[ParametricEQ, ...], float]:
    response, quantized_filters = firmware_cascade_response_db(
        scenario.frequencies_hz,
        scenario.sample_rate_hz,
        filters,
        config.firmware_platform,
    )
    trim = _exact_trim(
        response,
        config.combined_correction_ceiling_db,
        outside_native=outside_native,
        outside_native_ceiling_db=config.outside_native_boost_ceiling_db,
        disputed=disputed,
        disputed_ceiling_db=config.disputed_boost_ceiling_db,
        quantize_tenth_db=True,
    )
    return response + trim, quantized_filters, trim


def _finalize_filters(
    variant: FitVariant,
    method: str,
    scenario: Scenario,
    config: FitConfig,
    statistics: SpatialStatistics,
    decoded_filters: tuple[ParametricEQ, ...],
    *,
    success: bool,
    message: str,
    iterations: int,
    evaluations: int,
    continuous_objective: float,
) -> FitResult:
    started = time.perf_counter()
    # Boost Q is a hard production-hygiene contract, not merely an optimizer
    # penalty. Plain ablations intentionally omit it so its contribution is
    # measurable. Shelves already have Q <= 1 from their parameter bounds.
    filters = tuple(
        replace(item, q=min(item.q, 2.0))
        if (
            variant.endswith("hygiene")
            and item.gain_db > 0.0
            and item.filter_type == "peaking"
        )
        else item
        for item in decoded_filters
    )
    native_band = scenario.native_band_hz or (
        statistics.estimated_native_minimum_hz,
        statistics.estimated_native_maximum_hz,
    )
    outside_native = None
    if variant.endswith("hygiene"):
        outside_native = (
            (scenario.frequencies_hz < native_band[0])
            | (scenario.frequencies_hz > native_band[1])
        )
    disputed = None
    if variant == "spatial_hygiene":
        disputed = (
            (statistics.sign_agreement < 0.6)
            | (statistics.reliability < 0.5)
        )
    unquantized_response = cascade_response_db(
        scenario.frequencies_hz, scenario.sample_rate_hz, filters
    )
    unquantized_trim = _exact_trim(
        unquantized_response,
        config.combined_correction_ceiling_db,
        outside_native=outside_native,
        outside_native_ceiling_db=config.outside_native_boost_ceiling_db,
        disputed=disputed,
        disputed_ceiling_db=config.disputed_boost_ceiling_db,
        quantize_tenth_db=False,
    )
    unquantized_correction = unquantized_response + unquantized_trim

    _, initially_quantized, _ = _platform_correction(
        filters,
        scenario,
        config,
        outside_native,
        disputed,
    )
    quantized_list = list(initially_quantized)
    initial_correction, _, _ = _platform_correction(
        tuple(quantized_list),
        scenario,
        config,
        outside_native,
        disputed,
    )
    quantized_objective = _objective_value(
        variant,
        initial_correction,
        tuple(quantized_list),
        scenario,
        statistics,
        config,
    )
    # Firmware consumes float32 recipes and the current console rounds gains to
    # 0.1 dB. Re-optimize the remaining discrete gains after f/Q quantization.
    for _ in range(2):
        changed = False
        for filter_index, item in enumerate(tuple(quantized_list)):
            best_item = item
            best_score = quantized_objective
            center_tenths = int(round(item.gain_db * 10.0))
            for gain_tenths in range(center_tenths - 2, center_tenths + 3):
                gain = float(
                    np.clip(
                        gain_tenths / 10.0,
                        config.cut_limit_db,
                        config.boost_limit_db,
                    )
                )
                candidate_item = replace(item, gain_db=gain)
                if (
                    variant.endswith("hygiene")
                    and candidate_item.filter_type == "peaking"
                    and candidate_item.gain_db > 0.0
                    and candidate_item.q > 2.0
                ):
                    candidate_item = replace(candidate_item, q=2.0)
                candidate_filters = quantized_list.copy()
                candidate_filters[filter_index] = candidate_item
                candidate_correction, candidate_quantized, _ = (
                    _platform_correction(
                        tuple(candidate_filters),
                        scenario,
                        config,
                        outside_native,
                        disputed,
                    )
                )
                score = _objective_value(
                    variant,
                    candidate_correction,
                    candidate_quantized,
                    scenario,
                    statistics,
                    config,
                )
                if score + 1.0e-10 < best_score:
                    best_score = score
                    best_item = candidate_item
            if best_item != item:
                quantized_list[filter_index] = best_item
                quantized_objective = best_score
                changed = True
        if not changed:
            break
    correction, quantized_filters, quantized_trim = _platform_correction(
        tuple(quantized_list),
        scenario,
        config,
        outside_native,
        disputed,
    )
    alternate_platform: FirmwarePlatform = (
        "rp2040" if config.firmware_platform == "rp2350" else "rp2350"
    )
    primary_response, _ = firmware_cascade_response_db(
        scenario.frequencies_hz,
        scenario.sample_rate_hz,
        quantized_filters,
        config.firmware_platform,
    )
    alternate_response, _ = firmware_cascade_response_db(
        scenario.frequencies_hz,
        scenario.sample_rate_hz,
        quantized_filters,
        alternate_platform,
    )
    metrics = _neutral_metrics(
        correction, scenario, statistics, quantized_filters
    )
    metrics.update(
        {
            "max_quantization_delta_db": float(
                np.max(np.abs(correction - unquantized_correction))
            ),
            "max_alternate_platform_coefficient_response_delta_db": float(
                np.max(np.abs(alternate_response - primary_response))
            ),
        }
    )
    elapsed = time.perf_counter() - started
    return FitResult(
        variant=variant,
        method=method,
        firmware_platform=config.firmware_platform,
        filters=filters,
        quantized_filters=quantized_filters,
        success=success,
        message=f"{message}; discrete gains re-optimized after quantization",
        starts=1,
        iterations=iterations,
        evaluations=evaluations,
        elapsed_seconds=elapsed,
        trim_db=quantized_trim,
        unquantized_trim_db=unquantized_trim,
        continuous_objective=continuous_objective,
        optimization_objective=float(quantized_objective),
        neutral_metrics=metrics,
    )


def _run_one_start(
    variant: FitVariant,
    method: str,
    scenario: Scenario,
    config: FitConfig,
    statistics: SpatialStatistics,
    filter_types: tuple[FilterKind, ...],
    initial: np.ndarray,
    objective: Callable[[np.ndarray], float],
) -> FitResult:
    started = time.perf_counter()
    result = minimize(
        objective,
        initial,
        method=method,
        bounds=_parameter_bounds(config, filter_types),
        options={"maxiter": config.max_iterations, "ftol": 1.0e-8},
    )
    optimization_elapsed = time.perf_counter() - started
    finalized = _finalize_filters(
        variant,
        method,
        scenario,
        config,
        statistics,
        _decode_parameters(result.x, filter_types),
        success=bool(result.success),
        message=str(result.message),
        iterations=int(getattr(result, "nit", 0)),
        evaluations=int(getattr(result, "nfev", 0)),
        continuous_objective=float(result.fun),
    )
    return replace(
        finalized,
        elapsed_seconds=optimization_elapsed + finalized.elapsed_seconds,
    )


def evaluate_fixed_filters(
    scenario: Scenario,
    variant: FitVariant,
    filters: tuple[ParametricEQ, ...],
    config: FitConfig,
    method: str = "platform post-quantization",
) -> FitResult:
    """Finalize one continuous solution for a specific DSPi platform."""
    statistics = spatial_statistics(scenario)
    filter_types = tuple(item.filter_type for item in filters)
    objective = _objective_for_variant(
        variant, scenario, statistics, config, filter_types
    )
    continuous_objective = objective(_encode_filters(filters))
    return _finalize_filters(
        variant,
        method,
        scenario,
        config,
        statistics,
        filters,
        success=True,
        message="shared continuous solution",
        iterations=0,
        evaluations=0,
        continuous_objective=continuous_objective,
    )


def fit_variant(
    scenario: Scenario,
    variant: FitVariant,
    config: FitConfig = FitConfig(),
    method: str = "SLSQP",
) -> FitResult:
    statistics = spatial_statistics(scenario)
    if variant.startswith("arithmetic"):
        average = np.sum(
            scenario.position_weights[:, None] * scenario.measurements_db,
            axis=0,
        )
        guide = scenario.target_db - average
        confidence = None
    else:
        guide = scenario.target_db - statistics.power_average_db
        confidence = _boost_confidence(scenario, statistics)
    initial, filter_types = _seed_parameters(
        guide,
        scenario,
        config,
        confidence,
        statistics.transition_frequency_hz,
    )
    bounds = _parameter_bounds(config, filter_types)
    starts = _deterministic_starts(
        initial, bounds, config.deterministic_starts
    )
    objective = _objective_for_variant(
        variant, scenario, statistics, config, filter_types
    )
    runs = [
        _run_one_start(
            variant,
            method,
            scenario,
            config,
            statistics,
            filter_types,
            start,
            objective,
        )
        for start in starts
    ]
    successful = [item for item in runs if item.success]
    pool = successful or runs
    # The continuous objective is platform-independent, so both devices start
    # from the same best continuous solution and diverge only during their
    # exact post-quantization gain search and response evaluation.
    best = min(pool, key=lambda item: item.continuous_objective)
    return replace(
        best,
        message=f"{best.message}; best of {len(runs)} equal deterministic starts",
        starts=len(runs),
        iterations=sum(item.iterations for item in runs),
        evaluations=sum(item.evaluations for item in runs),
        elapsed_seconds=sum(item.elapsed_seconds for item in runs),
    )


def fit_baseline(
    scenario: Scenario,
    config: FitConfig = FitConfig(),
    method: str = "SLSQP",
) -> FitResult:
    return fit_variant(scenario, "arithmetic_plain", config, method)


def fit_robust(
    scenario: Scenario,
    config: FitConfig = FitConfig(),
    method: str = "SLSQP",
    baseline_filters: tuple[ParametricEQ, ...] | None = None,
) -> FitResult:
    # baseline_filters is intentionally ignored: every ablation receives the
    # same start count and no method borrows another method's optimized answer.
    del baseline_filters
    return fit_variant(scenario, "spatial_hygiene", config, method)


def _metric_delta(
    candidate: FitResult,
    reference: FitResult,
) -> dict[str, float]:
    return {
        key: float(candidate.neutral_metrics[key] - value)
        for key, value in reference.neutral_metrics.items()
        if key in candidate.neutral_metrics
        and isinstance(value, (int, float))
    }


def benchmark_scenario(
    scenario: Scenario,
    config: FitConfig = FitConfig(),
    *,
    include_lbfgsb: bool = False,
) -> dict[str, object]:
    variants = {
        variant: fit_variant(scenario, variant, config, "SLSQP")
        for variant in (
            "arithmetic_plain",
            "arithmetic_hygiene",
            "spatial_plain",
            "spatial_hygiene",
        )
    }
    full_slsqp = variants["spatial_hygiene"]
    full_lbfgsb = (
        fit_variant(scenario, "spatial_hygiene", config, "L-BFGS-B")
        if include_lbfgsb
        else None
    )
    alternate_platform: FirmwarePlatform = (
        "rp2040" if config.firmware_platform == "rp2350" else "rp2350"
    )
    alternate_full_slsqp = replace(
        evaluate_fixed_filters(
            scenario,
            "spatial_hygiene",
            full_slsqp.filters,
            replace(config, firmware_platform=alternate_platform),
        ),
        success=full_slsqp.success,
        message=(
            "shared continuous solution from primary platform; "
            f"source optimizer: {full_slsqp.message}"
        ),
    )
    return {
        "scenario": scenario.name,
        "description": scenario.description,
        "source_model": scenario.source_model,
        "sample_rate_hz": scenario.sample_rate_hz,
        "positions": int(scenario.measurements_db.shape[0]),
        "frequency_points": int(scenario.frequencies_hz.size),
        "uncorrected_neutral_metrics": uncorrected_neutral_metrics(scenario),
        "ablations": {
            key: value.json_dict() for key, value in variants.items()
        },
        "full_lbfgsb": full_lbfgsb.json_dict() if full_lbfgsb else None,
        "alternate_platform_full": alternate_full_slsqp.json_dict(),
        "neutral_delta_full_vs_arithmetic_plain": _metric_delta(
            full_slsqp, variants["arithmetic_plain"]
        ),
        "neutral_delta_arithmetic_hygiene_vs_plain": _metric_delta(
            variants["arithmetic_hygiene"], variants["arithmetic_plain"]
        ),
        "neutral_delta_spatial_plain_vs_arithmetic_plain": _metric_delta(
            variants["spatial_plain"], variants["arithmetic_plain"]
        ),
    }
