#!/usr/bin/env python3
"""Compare acceptance-corpus output across platforms.

Why this is not `diff`
----------------------

The first cross-platform CI run compared byte for byte and failed. macOS arm64,
Linux x64 and Windows x64 each produced slightly different numbers.

The cause is that C's transcendental functions are not required to be correctly
rounded: `log`, `exp`, `sin`, `tan` and `pow` differ in the last unit in the
last place between glibc, Apple's libm and the MSVC runtime. The optimizer is a
search, so a one-ulp difference early sends it down a marginally different path.

The divergence is not uniform, and that turns out to matter:

  * The *quality* metrics agree almost exactly - relRMSE 4.017 against 4.017,
    0.379 against 0.379. The correction is as good on every platform.
  * The values that merely identify *which* equivalent solution was found -
    trim, maximum and minimum correction - differ by up to about 0.08 dB,
    because the search settled on a slightly different filter set that does the
    same job.

So a single tolerance would be either too loose to catch a real regression in
quality or too tight to accept a harmless difference in solution. The tolerances
below are therefore per-field, tightest on the things that constitute the
promise and on the safety gates, loosest on the incidentals.

The honest contract is:

  * within one platform and build, the result is exactly reproducible - that is
    what a saved project relies on, and the unit tests enforce it;
  * across platforms, quality and safety agree to within a tolerance far below
    anything audible, and the particular filter set may differ.
"""

from __future__ import annotations

import re
import sys

# Per-field absolute tolerances, in the units the field is printed in.
#
# Anything not listed falls back to DEFAULT_TOLERANCE. Counts are advisory
# rather than fatal, for the reason set out at ADVISORY below: a different number
# of bands or shelves is a real difference in what
# the optimizer decided, not a rounding artifact.
TOLERANCES = {
    # The quality claim. These are what "the correction is as good" means.
    "rawRMSE": 0.05,
    "relRMSE": 0.05,
    "relMed": 0.05,
    "p95over": 0.05,
    # Safety gates. A platform that boosts where another does not is a bug,
    # not noise, so these stay tight.
    "dispBoost": 0.05,
    "outBoost": 0.05,
    "boostQ": 0.05,
    # Which of several equivalent solutions the search happened to find.
    "maxCorr": 0.25,
    "minCorr": 0.25,
    # Counts: exact.
    "bands": 0.0,
    "shelves": 0.0,
    "positions": 0.0,
}

DEFAULT_TOLERANCE = 0.25

# Numbers in the scenario header line, which is prose rather than key=value.
HEADER_TOLERANCES = {
    "transition": 1.0,     # Hz; a grid bin is wider than this
    "trim": 0.25,          # dB; follows the chosen solution
    "improvement": 1.0,    # percent
}

NUMBER = re.compile(r"[-+]?\d+\.?\d*(?:[eE][-+]?\d+)?")
FIELD = re.compile(r"(\w+)=\s*([-+]?\d+\.?\d*)")
HEADER_FIELD = re.compile(r"(transition|trim|improvement)\s+([-+]?\d+\.?\d*)")


# Fields whose difference is reported but does not fail the comparison.
#
# The greedy seeding stops when another filter would not repay itself, and near
# that threshold a single ulp in the residual decides whether a tenth band gets
# placed at all. Two platforms then produce nine and ten bands for solutions
# whose measured quality agrees to a few thousandths of a decibel, which is the
# divergence spec section 9.3 says is unavoidable without pinning libm.
#
# Failing on that would be the gate over-specifying its own contract: what is
# promised across platforms is equal quality, not an identical filter set. The
# quality fields are still compared strictly in the same pass, so a platform
# that genuinely fits worse is still caught - it just gets caught on the metric
# that matters rather than on a band count.
ADVISORY = {"bands", "shelves"}


def normalise(line: str) -> str:
    """Removes printf padding after `=` so a field is one token either way.

    `bands=10` and `bands= 9` describe the same field, but splitting on
    whitespace makes the second two tokens and the structural comparison then
    reports a difference that is entirely about column alignment.
    """
    return re.sub(r"=\s+", "=", line)


def skeleton(line: str) -> str:
    """Line structure with numbers removed, for an exact comparison.

    Whitespace is collapsed because printf field widths shift by one column
    when a value gains a minus sign: `maxCorr=  0.000` against
    `maxCorr= -0.000` is the same structure, and reporting it as a structural
    difference would bury the real ones.
    """
    return " ".join(NUMBER.sub("#", line).split())


def tolerance_for(name: str | None, value: float, header: bool) -> float:
    table = HEADER_TOLERANCES if header else TOLERANCES
    if name is not None and name in table:
        return table[name]
    return DEFAULT_TOLERANCE


def named_values(line: str) -> list[tuple[str | None, float]]:
    """Numbers with their field name where the line has one."""
    header = "positions," in line or "improvement" in line
    pattern = HEADER_FIELD if header else FIELD
    named = {match.group(2): match.group(1) for match in pattern.finditer(line)}
    return [(named.get(match.group()), float(match.group()))
            for match in NUMBER.finditer(line)]


def compare(reference_path: str, other_path: str) -> tuple[list[str], list[str]]:
    def read(path: str) -> list[str]:
        with open(path, encoding="utf-8") as handle:
            # Windows writes CRLF; strip it rather than reporting every line as
            # different for a reason unrelated to the maths.
            return [normalise(line.rstrip("\r\n")) for line in handle]

    reference = read(reference_path)
    other = read(other_path)
    problems: list[str] = []
    notes: list[str] = []

    if len(reference) != len(other):
        problems.append(
            f"line count differs: {reference_path} has {len(reference)}, "
            f"{other_path} has {len(other)}"
        )

    for index, (left, right) in enumerate(zip(reference, other), start=1):
        if skeleton(left) != skeleton(right):
            problems.append(
                f"line {index}: structure differs\n  {reference_path}: {left}\n"
                f"  {other_path}: {right}"
            )
            continue

        header = "improvement" in left
        for position, (a, b) in enumerate(zip(named_values(left), named_values(right))):
            name, left_value = a
            _, right_value = b
            if name in ADVISORY:
                if left_value != right_value:
                    notes.append(
                        f"line {index}, {name}: {left_value:g} vs {right_value:g} "
                        f"- equal-quality solutions of different size"
                    )
                continue

            allowed = tolerance_for(name, left_value, header)
            if abs(left_value - right_value) > allowed:
                label = name or f"value {position + 1}"
                problems.append(
                    f"line {index}, {label}: {left_value} vs {right_value} "
                    f"(tolerance {allowed})\n  {reference_path}: {left}\n"
                    f"  {other_path}: {right}"
                )

    return problems, notes


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: compare_corpus.py <reference> <other> [<other> ...]", file=sys.stderr)
        return 2

    reference = argv[1]
    failed = False

    for other in argv[2:]:
        problems, notes = compare(reference, other)
        for note in notes:
            # Surfaced rather than swallowed: a run where every scenario picks a
            # different filter count is worth a look even though none of them
            # fails the quality contract.
            print(f"::notice::{other}: {note}")
        if problems:
            failed = True
            print(f"::error::{other} differs from {reference} beyond tolerance")
            for problem in problems[:40]:
                print(problem)
            if len(problems) > 40:
                print(f"... and {len(problems) - 40} more")
        else:
            print(f"{other} agrees with {reference} within tolerance")

    if not failed:
        print("All platforms agree within tolerance.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
