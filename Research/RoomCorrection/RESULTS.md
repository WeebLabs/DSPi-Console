# Milestone 0 benchmark result — closed

The corrected hardware-budget benchmark was run on 2026-07-28 with ten
filters, three equal deterministic starts, a 400-iteration limit per start,
and an intentionally permissive +3 dB global ceiling. It used Python 3.14.4,
NumPy 2.4.2, and SciPy 1.18.0.

This supersedes the earlier four-filter result. A one-scenario 1–10 allocation
smoke test is no longer presented as evidence that the complete gate works at
the hardware's ten-band capacity.

## Result

The defensible result remains: **the full method is materially safer than an
aggressive arithmetic-average fit, with an explicit worst-seat accuracy cost.
It improves every scenario relative to leaving the system uncorrected, but the
benefit is modest on the cancellation-dominated realistic fixtures.**

All figures are neutral, post-quantization RP2350 metrics. RP2040 is gated
independently below.

| Scenario | Reliable worst RMSE uncorrected | Full | Improvement | Arithmetic plain | Disputed boost plain/full |
|---|---:|---:|---:|---:|---:|
| Shared room modes | 2.761 | 0.432 | 84.3% | 0.364 | 0.254 / 0.000 |
| Single-seat local null | 3.144 | 2.297 | 26.9% | 2.064 | 2.951 / 0.161 |
| Moving spatial nulls | 3.245 | 2.118 | 34.7% | 1.753 | 2.989 / 0.252 |
| Mixed full range | 3.309 | 2.726 | 17.6% | 1.997 | 2.637 / 0.465 |
| Single-position roll-off | 1.780 | 0.713 | 59.9% | 1.040 | 0.532 / 0.203 |
| Three-position house curve | 2.804 | 1.742 | 37.9% | 1.324 | 1.262 / 0.236 |
| Nine-position delayed cancellation | 5.917 | 5.045 | 14.7% | 3.983 | 2.994 / 0.500 |
| Twenty-one-position diffuse | 4.086 | 3.659 | 10.5% | 2.638 | 2.532 / 0.477 |

The full method improved reliable worst-position RMSE versus uncorrected in all
eight scenarios by 1.039 dB on average. The per-scenario percentages—not that
mean—are the product-relevant claim. The three most cancellation-dominated
fixtures improve by only 10.5–17.6%; this is expected because their remaining
error is spatially unstable and deliberately left uncorrected.

Compared with arithmetic plain across the corpus, full minus plain averaged:

- +0.698 dB raw worst-position RMSE;
- +0.446 dB reliability-weighted worst-position RMSE;
- -0.029 dB reliable-band median absolute error;
- -0.822 dB P95 positive overshoot;
- -1.732 dB maximum disputed-region boost;
- -1.484 dB maximum out-of-curtain boost.

At the local-null probe, correction falls from +2.951 dB to +0.161 dB. The
algorithm is therefore safer rather than universally more accurate.

## Hygiene-weight sweep

The previous soft hygiene weights were jointly swept at ten filters and 400
iterations using one deterministic start. Hard Q, correction-curtain, combined
response, and disputed-region limits did not move.

| Weight multiplier | Converged | Reliable-worst cost vs plain | P95 overshoot delta | Disputed-boost delta |
|---:|---:|---:|---:|---:|
| 0 | 7/8 | +0.680 dB | -0.840 dB | -1.668 dB |
| 0.125 | 7/8 | +0.467 dB | -0.722 dB | -1.688 dB |
| **0.25** | **8/8** | **+0.424 dB** | **-0.810 dB** | **-1.713 dB** |
| 0.5 | 7/8 | +0.452 dB | -0.951 dB | -1.762 dB |
| 1.0 | 6/8 | +0.499 dB | -1.042 dB | -1.809 dB |

These rows are not a controlled comparison of equally valid populations:
converged counts differ, and the sweep used one start where production uses
three. The reliable-worst diagnostic changes by only 0.075 dB from 0.125× to
1.0×, and the disputed-boost diagnostic by 0.120 dB. The metrics are therefore
insensitive in this range. The 0.25 multiplier is the default because it was
the only fully converged row, not because the sweep establishes a performance
knee. In the final three-start run its reliable-worst cost was +0.446 dB.
Spatial weighting alone was slightly better than plain arithmetic on mean
reliable worst-position RMSE (-0.012 dB) while removing 0.465 dB of disputed
boost; ordinary hygiene alone cost +0.216 dB while removing 0.399 dB. This
confirms that spatial weighting is the more efficient safety mechanism and that
the former hygiene preset was over-tuned.

The sweep is reproducible with `python3 weight_sweep.py`.

## Ten-band convergence and runtime

SLSQP converged in all eight ten-band full-candidate runs at the 400-iteration
limit. Across three starts per scenario it used 121,701 function evaluations
and 3,890 reported iterations. Candidate fitting took 94.68 seconds total in
this Python harness, with individual scenarios ranging from 5.29 to 21.15
seconds. This replaces the invalid 13.45-second four-band runtime claim.

The complete research command also runs the other three ablation cells, so its
wall time is intentionally longer than one production candidate calculation.
L-BFGS-B is no longer rerun by default; `--include-lbfgsb` retains that research
option, but it is not part of the exit gate or production runtime.

## Platform-specific DSP evaluation

The former 0.025 dB RP2040/RP2350 parity gate was wrong and has been removed.
Ten-band cascades in this run differed by as much as 0.143 dB between coefficient
paths, confirming that better convergence can expose platform-sensitive
filters. DSPi Console knows the connected device, so the correct contract is:

1. optimize one platform-independent continuous solution;
2. quantize and re-optimize discrete gains for the connected platform;
3. apply that platform's exact output trim;
4. score and verify that platform's response independently.

The gate now evaluates both RP2350 float/SVF-equivalent and RP2040 Q28
coefficient responses separately. Both passed convergence-derived status and
the discriminating reliable-error and local-null gates on all eight scenarios.
Q, disputed-boost, curtain, and current gain-grid readbacks are reported
separately as hard-constraint enforcement checks. Cross-platform filter
identity or response equality is neither required nor claimed.

The disputed-boost check is intentionally only an enforcement regression. The
two independently evaluated platform results for nine-position delayed
cancellation are 0.499652 dB and 0.499655 dB against the hard 0.5 dB ceiling.
The optimizer is sitting on its constraint with about 0.00035 dB headroom, so
this pass provides no independent evidence of safety margin.

The current 0.1 dB gain step remains a Console policy, not a wire limitation.
Its maximum observed correction-response cost is now larger than any other
remaining tuning effect:

| Scenario class | Maximum observed quantization cost | Shelves |
|---|---:|---:|
| Three-position house curve | 0.363 dB | 1 |
| Single-seat local null | 0.138 dB | 0 |
| Other scenarios | 0.077–0.114 dB | 0–2 |

Shelves aggravate the error because rounding their gain moves a broad plateau.
Milestone 1 should remove Console's 0.1 dB host rounding first, retain full
precision internally, send the available float32 gain, and pin the new write
path with golden tests.

## Filter-bank saturation and product policy

Five of the eight scenarios used all ten available filters. The active counts
were 7, 8, 7, 10, 10, 10, 10, and 10. Realistic difficult rooms are therefore
often band-count-limited, not optimizer-limited. Version 1 room correction must
own and replace the selected output's complete ordinary PEQ bank; sharing that
bank with pre-existing manual EQ is not a viable general policy. Setup and
Apply must state plainly that correction replaces all ten PEQ slots while
preserving crossover filters, with snapshot/rollback of the original bank.

## Remaining before product implementation

Milestone 0 is closed. The following remain real Milestone
1/2 inputs and are not fabricated by this harness:

- real electrical loopback and known-analog-EQ traces;
- an actual matched REW automatic-EQ comparison;
- raw-capture deconvolution, frequency-dependent windowing, and smoothing;
- RP2040 generator/filter and RP2350 SVF time-domain golden traces;
- macOS arm64/x86_64 and Windows x64 portable-core parity.
