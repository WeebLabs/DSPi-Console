#!/usr/bin/env python3
"""Run the neutral-metric Milestone 0 ablation and optimizer benchmark."""

from __future__ import annotations

import argparse
from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import sys

import numpy as np
import scipy

from room_correction.fixtures import load_corpus
from room_correction.optimizer import FitConfig, benchmark_scenario, fit_variant
from room_correction.sweep import SUPPORTED_SAMPLE_RATES, generate_firmware_log_sweep


ROOT = Path(__file__).resolve().parent


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus", type=Path, default=ROOT / "fixtures" / "corpus.json"
    )
    parser.add_argument("--filters", type=int, default=10)
    parser.add_argument("--max-iterations", type=int, default=400)
    parser.add_argument(
        "--platform",
        choices=("rp2040", "rp2350"),
        default="rp2350",
        help="primary platform for the ablation; the full candidate gates both",
    )
    parser.add_argument("--scenario", action="append", default=[])
    parser.add_argument(
        "--quick", action="store_true", help="use two filters and 35 iterations"
    )
    parser.add_argument(
        "--include-lbfgsb",
        action="store_true",
        help="repeat the full candidate with L-BFGS-B (not part of the gate)",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="emit compact JSON instead of every filter and metric",
    )
    parser.add_argument(
        "--progress",
        action="store_true",
        help="write scenario progress to standard error",
    )
    return parser.parse_args()


def _full_fit(result: dict[str, object]) -> dict[str, object]:
    return result["ablations"]["spatial_hygiene"]


def _baseline_fit(result: dict[str, object]) -> dict[str, object]:
    return result["ablations"]["arithmetic_plain"]


def _compact_fit(result: dict[str, object]) -> dict[str, object]:
    return {
        "firmware_platform": result["firmware_platform"],
        "success": result["success"],
        "iterations": result["iterations"],
        "evaluations": result["evaluations"],
        "elapsed_seconds": result["elapsed_seconds"],
        "trim_db": result["trim_db"],
        "neutral_metrics": result["neutral_metrics"],
    }


def _aggregate_delta(
    results: list[dict[str, object]],
    fit_key: str,
    reference_key: str,
    metric: str,
) -> float:
    return float(
        np.mean(
            [
                item["ablations"][fit_key]["neutral_metrics"][metric]
                - item["ablations"][reference_key]["neutral_metrics"][metric]
                for item in results
            ]
        )
    )


def main() -> int:
    arguments = parse_arguments()
    if not 1 <= arguments.filters <= 10:
        raise SystemExit("--filters must be between 1 and the hardware maximum of 10")
    if arguments.max_iterations <= 0:
        raise SystemExit("--max-iterations must be positive")
    config = FitConfig(
        filter_count=2 if arguments.quick else arguments.filters,
        max_iterations=35 if arguments.quick else arguments.max_iterations,
        deterministic_starts=2 if arguments.quick else 3,
        # Advanced mode deliberately exposes unsafe behavior instead of making
        # every method pass trivially under the production -0.5 dB ceiling.
        combined_correction_ceiling_db=3.0,
        complexity_weight=0.0005,
        positive_correction_weight=0.0375,
        unreliable_boost_weight=2.5,
        overshoot_weight=0.625,
        sharpness_weight=0.125,
        firmware_platform=arguments.platform,
    )
    corpus = load_corpus(arguments.corpus)
    scenarios = [
        scenario
        for scenario in corpus.scenarios
        if not arguments.scenario or scenario.name in arguments.scenario
    ]
    if not scenarios:
        raise SystemExit("no matching scenarios")
    results = []
    for scenario in scenarios:
        if arguments.progress:
            print(f"starting {scenario.name}", file=sys.stderr, flush=True)
        result = benchmark_scenario(
            scenario,
            config,
            include_lbfgsb=arguments.include_lbfgsb,
        )
        results.append(result)
        if arguments.progress:
            full = _full_fit(result)
            print(
                f"finished {scenario.name}: success={full['success']} "
                f"elapsed={full['elapsed_seconds']:.2f}s",
                file=sys.stderr,
                flush=True,
            )

    # The quality corpus uses one controlled hardware-realistic budget.
    # Independently exercise the complete allocation range on a representative
    # shared-mode fixture.
    budget_scenario = corpus.named("shared_room_modes")
    budget_counts = (1, 4, 10) if arguments.quick else tuple(range(1, 11))
    budget_config = replace(
        config,
        max_iterations=max(config.max_iterations, 250),
        deterministic_starts=1,
    )
    filter_budget_sweep = []
    for filter_count in budget_counts:
        fit = fit_variant(
            budget_scenario,
            "spatial_hygiene",
            replace(budget_config, filter_count=filter_count),
            "SLSQP",
        )
        filter_budget_sweep.append(
            {
                "filter_count": filter_count,
                "success": fit.success,
                "iterations": fit.iterations,
                "elapsed_seconds": fit.elapsed_seconds,
                "reliability_weighted_huber_loss": fit.neutral_metrics[
                    "reliability_weighted_huber_loss"
                ],
            }
        )

    sweep_rows = []
    for sample_rate in SUPPORTED_SAMPLE_RATES:
        sweep = generate_firmware_log_sweep(
            sample_rate,
            duration_milliseconds=5_000,
            end_hz=min(20_000.0, 0.45 * sample_rate),
        )
        sweep_rows.append(
            {
                "sample_rate_hz": sample_rate,
                "duration_samples": sweep.duration_samples,
                "fade_samples": sweep.fade_samples,
                "increment_start_q48": sweep.increment_start_q48,
                "increment_end_q48": sweep.increment_end_q48,
                "epsilon_q31": sweep.epsilon_q31,
            }
        )

    local = next(
        (item for item in results if item["scenario"] == "single_seat_local_null"),
        None,
    )
    if local:
        local_baseline_probe = float(
            _baseline_fit(local)["neutral_metrics"]["probe_0_max_correction_db"]
        )
        local_full_probe = float(
            _full_fit(local)["neutral_metrics"]["probe_0_max_correction_db"]
        )
    else:
        local_baseline_probe = 0.0
        local_full_probe = 0.0

    neutral_summary = {
        "full_vs_arithmetic_plain_mean_delta": {
            metric: _aggregate_delta(
                results, "spatial_hygiene", "arithmetic_plain", metric
            )
            for metric in (
                "raw_worst_position_rmse_db",
                "raw_median_absolute_error_db",
                "reliable_worst_position_rmse_db",
                "reliable_median_absolute_error_db",
                "reliability_weighted_huber_loss",
                "p95_positive_overshoot_db",
                "max_disputed_boost_db",
                "max_outside_native_boost_db",
            )
        },
        "arithmetic_hygiene_vs_plain_mean_delta": {
            metric: _aggregate_delta(
                results, "arithmetic_hygiene", "arithmetic_plain", metric
            )
            for metric in (
                "raw_worst_position_rmse_db",
                "reliable_worst_position_rmse_db",
                "max_disputed_boost_db",
            )
        },
        "spatial_plain_vs_arithmetic_plain_mean_delta": {
            metric: _aggregate_delta(
                results, "spatial_plain", "arithmetic_plain", metric
            )
            for metric in (
                "raw_worst_position_rmse_db",
                "reliable_worst_position_rmse_db",
                "max_disputed_boost_db",
            )
        },
        "local_null_probe_baseline_db": local_baseline_probe,
        "local_null_probe_full_db": local_full_probe,
        "local_null_boost_reduction_db": local_baseline_probe - local_full_probe,
    }

    full_fits = [_full_fit(item) for item in results]
    alternate_full_fits = [item["alternate_platform_full"] for item in results]
    all_platform_full_fits = full_fits + alternate_full_fits
    closure_requirements = {
        "hardware_maximum_filter_count_exercised": config.filter_count == 10,
        "convergent_iteration_budget_exercised": config.max_iterations >= 400,
        "all_requested_filter_budgets_converged": all(
            bool(item["success"]) for item in filter_budget_sweep
        ),
        "all_platform_slsqp_full_runs_converged": all(
            bool(item["success"]) for item in all_platform_full_fits
        ),
    }
    discriminating_quality_gates = {
        "local_null_not_boosted": local is None or (
            local_full_probe <= 0.25
            and float(
                local["alternate_platform_full"]["neutral_metrics"][
                    "probe_0_max_correction_db"
                ]
            )
            <= 0.25
        ),
        "reliable_worst_position_improves_uncorrected": all(
            float(fit["neutral_metrics"]["reliable_worst_position_rmse_db"])
            <= float(
                result["uncorrected_neutral_metrics"][
                    "reliable_worst_position_rmse_db"
                ]
            )
            for fits, result in zip(
                zip(full_fits, alternate_full_fits), results
            )
            for fit in fits
        ),
        "reliability_weighted_huber_improves_uncorrected": all(
            float(fit["neutral_metrics"]["reliability_weighted_huber_loss"])
            < float(
                result["uncorrected_neutral_metrics"][
                    "reliability_weighted_huber_loss"
                ]
            )
            for fits, result in zip(
                zip(full_fits, alternate_full_fits), results
            )
            for fit in fits
        ),
    }
    constraint_enforcement_checks = {
        "candidate_boost_q_within_tolerance": all(
            float(item["neutral_metrics"]["maximum_boost_filter_q"]) <= 2.01
            for item in all_platform_full_fits
        ),
        "quantized_gains_are_tenth_db": all(
            all(
                abs(
                    float(filter_item["gain_db"]) * 10.0
                    - round(float(filter_item["gain_db"]) * 10.0)
                )
                <= 1.0e-5
                for filter_item in item["quantized_filters"]
            )
            for item in all_platform_full_fits
        ),
        "disputed_boost_hard_ceiling_enforced": all(
            float(item["neutral_metrics"]["max_disputed_boost_db"]) <= 0.5
            for item in all_platform_full_fits
        ),
        "outside_native_boost_hard_ceiling_enforced": all(
            float(item["neutral_metrics"]["max_outside_native_boost_db"])
            <= 1.0e-6
            for item in all_platform_full_fits
        ),
    }
    constraint_headroom = {
        "minimum_disputed_boost_headroom_db": min(
            config.disputed_boost_ceiling_db
            - float(item["neutral_metrics"]["max_disputed_boost_db"])
            for item in all_platform_full_fits
        ),
        "note": (
            "Constraint headroom is reported diagnostically. Passing a hard-"
            "ceiling enforcement check is not evidence of safety margin."
        ),
    }
    closure_passed = all(
        value
        for checks in (
            closure_requirements,
            discriminating_quality_gates,
            constraint_enforcement_checks,
        )
        for value in checks.values()
    )
    smoke_requirements = {
        key: value
        for key, value in closure_requirements.items()
        if key
        not in {
            "hardware_maximum_filter_count_exercised",
            "convergent_iteration_budget_exercised",
            "all_platform_slsqp_full_runs_converged",
        }
    }
    smoke_passed = all(
        value
        for checks in (
            smoke_requirements,
            discriminating_quality_gates,
            constraint_enforcement_checks,
        )
        for value in checks.values()
    )
    run_passed = smoke_passed if arguments.quick else closure_passed
    report = {
        "schema_version": 5,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "run_mode": (
            "smoke"
            if arguments.quick
            else (
                "closure"
                if config.filter_count == 10 and config.max_iterations >= 400
                else "research_nonclosure"
            )
        ),
        "python": platform.python_version(),
        "numpy": np.__version__,
        "scipy": scipy.__version__,
        "fit_config": config.__dict__,
        "primary_ablation_platform": config.firmware_platform,
        "full_candidate_platforms_gated": ["rp2040", "rp2350"],
        "firmware_commit": "9776c2f9feb5a1f8487180a351f8fbb1ec67e4ff",
        "wire_precision": {
            "recipe_parameters": "IEEE-754 float32",
            "console_gain_policy_db": 0.1,
            "rp2350_coefficients": "float32 (SVF below Fs/7.5)",
            "rp2040_coefficients": "Q28",
            "frequency_response_model_scope": (
                "coefficient transfer functions only; RP2350 SVF and RP2040 "
                "fixed-point sample-loop rounding require golden traces"
            ),
        },
        "reference_sweep_duration_milliseconds": 5_000,
        "firmware_sweep_reference": sweep_rows,
        "filter_budget_sweep": filter_budget_sweep,
        "neutral_summary": neutral_summary,
        "scenarios": results,
        "closure_requirements": closure_requirements,
        "discriminating_quality_gates": discriminating_quality_gates,
        "constraint_enforcement_checks": constraint_enforcement_checks,
        "constraint_headroom": constraint_headroom,
        "closure_passed": closure_passed,
        "run_passed": run_passed,
    }
    output: dict[str, object] = report
    if arguments.summary:
        output = {
            "schema_version": report["schema_version"],
            "generated_at": report["generated_at"],
            "run_mode": report["run_mode"],
            "fit_config": report["fit_config"],
            "neutral_summary": neutral_summary,
            "filter_budget_sweep": filter_budget_sweep,
            "scenarios": [
                {
                    "scenario": item["scenario"],
                    "uncorrected": item["uncorrected_neutral_metrics"],
                    "arithmetic_plain": _compact_fit(
                        item["ablations"]["arithmetic_plain"]
                    ),
                    "spatial_hygiene_primary": _compact_fit(
                        item["ablations"]["spatial_hygiene"]
                    ),
                    "spatial_hygiene_alternate": _compact_fit(
                        item["alternate_platform_full"]
                    ),
                }
                for item in results
            ],
            "closure_requirements": closure_requirements,
            "discriminating_quality_gates": discriminating_quality_gates,
            "constraint_enforcement_checks": constraint_enforcement_checks,
            "constraint_headroom": constraint_headroom,
            "closure_passed": closure_passed,
            "run_passed": run_passed,
        }
    json.dump(output, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0 if run_passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
