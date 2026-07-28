"""DSPi room-correction Milestone 0 research harness."""

from .fixtures import Corpus, Scenario, load_corpus
from .model import ParametricEQ, log_frequency_grid
from .optimizer import (
    FitConfig,
    FitResult,
    benchmark_scenario,
    evaluate_fixed_filters,
    fit_baseline,
    fit_robust,
    fit_variant,
    uncorrected_neutral_metrics,
)
from .sweep import FirmwareSweep, generate_firmware_log_sweep

__all__ = [
    "Corpus",
    "Scenario",
    "load_corpus",
    "ParametricEQ",
    "log_frequency_grid",
    "FitConfig",
    "FitResult",
    "benchmark_scenario",
    "evaluate_fixed_filters",
    "fit_baseline",
    "fit_robust",
    "fit_variant",
    "uncorrected_neutral_metrics",
    "FirmwareSweep",
    "generate_firmware_log_sweep",
]
