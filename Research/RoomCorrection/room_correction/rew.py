"""Small REW-compatible magnitude text reader/writer for the research corpus."""

from __future__ import annotations

from pathlib import Path
import re

import numpy as np


_SPLIT = re.compile(r"[\s,;]+")


def read_rew_magnitude(path: str | Path) -> tuple[np.ndarray, np.ndarray]:
    frequencies: list[float] = []
    magnitudes: list[float] = []
    text = Path(path).read_text(encoding="utf-8-sig")
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith(("*", "#", ";")):
            continue
        fields = [item for item in _SPLIT.split(line) if item]
        if len(fields) < 2:
            continue
        try:
            frequency = float(fields[0])
            magnitude = float(fields[1])
        except ValueError:
            # REW exports can contain un-commented column headings.
            continue
        if (
            not np.isfinite(frequency)
            or not np.isfinite(magnitude)
            or frequency <= 0.0
        ):
            raise ValueError(f"invalid REW row at {path}:{line_number}")
        frequencies.append(frequency)
        magnitudes.append(magnitude)
    if len(frequencies) < 2:
        raise ValueError(f"no usable magnitude data in {path}")
    order = np.argsort(frequencies)
    return np.asarray(frequencies)[order], np.asarray(magnitudes)[order]


def write_rew_magnitude(
    path: str | Path,
    frequencies_hz: np.ndarray,
    magnitude_db: np.ndarray,
    title: str,
) -> None:
    if frequencies_hz.shape != magnitude_db.shape:
        raise ValueError("frequency and magnitude arrays must have the same shape")
    lines = [
        f"* Measurement exported by DSPi Milestone 0: {title}",
        "* Freq(Hz) SPL(dB)",
    ]
    lines.extend(
        f"{frequency:.6f}\t{magnitude:.6f}"
        for frequency, magnitude in zip(frequencies_hz, magnitude_db)
    )
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
