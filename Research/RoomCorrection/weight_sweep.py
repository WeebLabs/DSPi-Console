#!/usr/bin/env python3
"""Sweep soft hygiene weights at the hardware-realistic filter budget."""

from __future__ import annotations

import argparse
from dataclasses import asdict, replace
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

import numpy as np

from room_correction.fixtures import load_corpus
from room_correction.optimizer import FitConfig, fit_variant


ROOT = Path(__file__).resolve().parent
REFERENCE_WEIGHTS = {
    "complexity_weight": 0.002,
    "positive_correction_weight": 0.15,
    "unreliable_boost_weight": 10.0,
    "overshoot_weight": 2.5,
    "sharpness_weight": 0.5,
}
NEUTRAL_METRICS = (
    "raw_worst_position_rmse_db",
    "reliable_worst_position_rmse_db",
    "reliable_median_absolute_error_db",
    "p95_positive_overshoot_db",
    "max_disputed_boost_db",
    "max_outside_native_boost_db",
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus",
        type=Path,
        default=ROOT / "fixtures" / "corpus.json",
    )
    parser.add_argument("--filters", type=int, default=10)
    parser.add_argument("--max-iterations", type=int, default=400)
    parser.add_argument("--starts", type=int, default=1)
    parser.add_argument(
        "--platform", choices=("rp2040", "rp2350"), default="rp2350"
    )
    parser.add_argument(
        "--multipliers", default="0,0.125,0.25,0.5,1"
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    multipliers = tuple(
        float(item) for item in arguments.multipliers.split(",")
    )
    config = FitConfig(
        filter_count=arguments.filters,
        max_iterations=arguments.max_iterations,
        deterministic_starts=arguments.starts,
        combined_correction_ceiling_db=3.0,
        firmware_platform=arguments.platform,
    )
    rows: dict[str, list[dict[str, object]]] = {
        str(value): [] for value in multipliers
    }
    for scenario in load_corpus(arguments.corpus).scenarios:
        plain = fit_variant(scenario, "arithmetic_plain", config, "SLSQP")
        for multiplier in multipliers:
            weighted = replace(
                config,
                **{
                    key: value * multiplier
                    for key, value in REFERENCE_WEIGHTS.items()
                },
            )
            candidate = fit_variant(
                scenario, "spatial_hygiene", weighted, "SLSQP"
            )
            rows[str(multiplier)].append(
                {
                    "scenario": scenario.name,
                    "success": candidate.success,
                    "iterations": candidate.iterations,
                    "evaluations": candidate.evaluations,
                    "elapsed_seconds": candidate.elapsed_seconds,
                    "neutral_delta_vs_arithmetic_plain": {
                        metric: candidate.neutral_metrics[metric]
                        - plain.neutral_metrics[metric]
                        for metric in NEUTRAL_METRICS
                    },
                    "neutral_metrics": candidate.neutral_metrics,
                }
            )

    summary = {}
    for multiplier, multiplier_rows in rows.items():
        converged_rows = [
            item for item in multiplier_rows if bool(item["success"])
        ]
        summary[multiplier] = {
            "converged_scenarios": len(converged_rows),
            "converged_scenario_names": [
                str(item["scenario"]) for item in converged_rows
            ],
            "elapsed_seconds": sum(
                float(item["elapsed_seconds"]) for item in multiplier_rows
            ),
            "diagnostic_mean_over_all_attempted_scenarios": {
                metric: float(
                    np.mean(
                        [
                            item["neutral_delta_vs_arithmetic_plain"][metric]
                            for item in multiplier_rows
                        ]
                    )
                )
                for metric in NEUTRAL_METRICS
            },
            "mean_over_converged_scenarios": (
                {
                    metric: float(
                        np.mean(
                            [
                                item["neutral_delta_vs_arithmetic_plain"][
                                    metric
                                ]
                                for item in converged_rows
                            ]
                        )
                    )
                    for metric in NEUTRAL_METRICS
                }
                if converged_rows
                else None
            ),
        }

    report = {
        "schema_version": 2,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "config": asdict(config),
        "reference_weights": REFERENCE_WEIGHTS,
        "multipliers": multipliers,
        "comparison_limits": {
            "strictly_comparable": False,
            "production_start_count": 3,
            "sweep_start_count": arguments.starts,
            "note": (
                "Convergence counts differ by row and this diagnostic sweep "
                "uses one start by default. Means include every returned "
                "candidate, including non-converged runs. Converged-only "
                "means use different scenario populations. Neither view is "
                "a strictly comparable production estimate."
            ),
        },
        "summary": summary,
        "scenarios": rows,
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
