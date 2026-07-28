#!/usr/bin/env python3
"""Compare acceptance-corpus output across platforms.

Why this is not `diff`
----------------------

The first cross-platform CI run compared the corpus output byte for byte and
failed: macOS arm64, Linux x64 and Windows x64 each produced slightly different
numbers.  The differences were tiny - 0.176 versus 0.178 dB RMSE, three
thousandths of a dB on a filter gain - but real.

The cause is that C's transcendental functions are not required to be correctly
rounded.  `log`, `exp`, `sin`, `tan` and `pow` differ in the last unit in the
last place between glibc, Apple's libm and the MSVC runtime.  The optimizer is a
search, so a one-ulp difference early can send it down a marginally different
path, and the divergence surfaces at the third decimal place of the result.

Making the core bit-identical everywhere would mean shipping our own
transcendental functions.  That is a large amount of work and slower code, in
exchange for agreement in a decimal place far below anything audible,
measurable in a room, or representable on the wire.

So the honest contract is:

  * within one platform and build, the result is exactly reproducible - that is
    what a saved project relies on, and it is enforced by the unit tests;
  * across platforms, results agree within a tolerance far tighter than any
    meaningful difference.

This script checks the second.  It compares structure exactly, so a genuine
algorithmic divergence - a different band count, a failed gate, a different
scenario - still fails loudly.  Only the numbers get tolerance.
"""

from __future__ import annotations

import re
import sys

# Absolute floor, plus a relative term so large values (frequencies, percentages)
# are not held to an unreasonably tight absolute bound.  0.05 dB is roughly an
# order of magnitude below audibility and two below measurement error in a room.
ABSOLUTE_TOLERANCE = 0.05
RELATIVE_TOLERANCE = 0.005

NUMBER = re.compile(r"[-+]?\d+\.?\d*(?:[eE][-+]?\d+)?")


def skeleton(line: str) -> str:
    """The line with every number replaced, so structure can be compared exactly."""
    return NUMBER.sub("#", line)


def numbers(line: str) -> list[float]:
    return [float(match.group()) for match in NUMBER.finditer(line)]


def tolerance_for(value: float) -> float:
    return max(ABSOLUTE_TOLERANCE, RELATIVE_TOLERANCE * abs(value))


def compare(reference_path: str, other_path: str) -> list[str]:
    with open(reference_path, encoding="utf-8") as handle:
        # Windows writes CRLF; strip it rather than reporting every line as
        # different for a reason that has nothing to do with the maths.
        reference = [line.rstrip("\r\n") for line in handle]
    with open(other_path, encoding="utf-8") as handle:
        other = [line.rstrip("\r\n") for line in handle]

    problems: list[str] = []

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

        for position, (a, b) in enumerate(zip(numbers(left), numbers(right))):
            if abs(a - b) > tolerance_for(a):
                problems.append(
                    f"line {index}, value {position + 1}: {a} vs {b} "
                    f"(tolerance {tolerance_for(a):.4f})\n  {reference_path}: {left}\n"
                    f"  {other_path}: {right}"
                )

    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: compare_corpus.py <reference> <other> [<other> ...]", file=sys.stderr)
        return 2

    reference = argv[1]
    failed = False

    for other in argv[2:]:
        problems = compare(reference, other)
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
