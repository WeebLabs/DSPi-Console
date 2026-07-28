#!/usr/bin/env python3
"""Export the deterministic corpus as REW-compatible magnitude text files."""

from __future__ import annotations

import argparse
from pathlib import Path

from room_correction.fixtures import load_corpus
from room_correction.rew import write_rew_magnitude


ROOT = Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=Path)
    parser.add_argument(
        "--corpus",
        type=Path,
        default=ROOT / "fixtures" / "corpus.json",
    )
    arguments = parser.parse_args()
    arguments.output_directory.mkdir(parents=True, exist_ok=True)
    corpus = load_corpus(arguments.corpus)
    for scenario in corpus.scenarios:
        scenario_directory = arguments.output_directory / scenario.name
        scenario_directory.mkdir(exist_ok=True)
        write_rew_magnitude(
            scenario_directory / "target.txt",
            scenario.frequencies_hz,
            scenario.target_db,
            f"{scenario.name} target",
        )
        for index, measurement in enumerate(scenario.measurements_db, 1):
            write_rew_magnitude(
                scenario_directory / f"position_{index}.txt",
                scenario.frequencies_hz,
                measurement,
                f"{scenario.name} position {index}",
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
