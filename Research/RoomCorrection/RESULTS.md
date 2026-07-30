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

# Fixed-pole designer result - 2026-07-30

Branch `room_correction_poles`. Full design and reasoning in
`Documentation/room_correction_fixed_pole_design.md`; this records the numbers.

The designer was replaced. Frequencies and Qs are now allocated from the
measured error before anything is solved, and the fit is a bounded
Gauss-Newton descent over gain, width and centre, run as a sequence of
constrained linear least-squares problems. The searching fit, its three
deterministic starts, its iteration cap and all six soft hygiene weights are
gone; every limit is now structural.

Both designers were run on the same six CLI fixtures through the same
`evaluateBank` code, on RP2350 at 48 kHz with ten bands and the natural target.
Baseline is the coordinate search at `fc565ea`. The metric is
reliability-weighted worst-position RMSE.

| Scenario | Uncorrected | Baseline | Fixed-pole | Delta |
|---|---:|---:|---:|---:|
| shared_room_modes | 2.101 | 0.208 | 0.145 | -0.063 |
| single_seat_local_null | 3.754 | 2.815 | 2.812 | -0.003 |
| moving_spatial_nulls | 2.968 | 1.686 | 1.689 | +0.003 |
| single_position_rolloff | 3.682 | 0.281 | 0.403 | +0.122 |
| nine_position_cancellation | 5.179 | 4.857 | 4.805 | -0.052 |
| twentyone_position_diffuse | 7.432 | 4.016 | 4.100 | +0.084 |
| **mean** | 4.186 | 2.311 | 2.326 | +0.015 |

Parity on accuracy, marginally better on headroom (mean peak combined
correction -1.8 dB against -2.05 dB), all safety gates passing in both the
cut-only and +3 dB configurations, and 0.41 s against 39 s for the whole
corpus.

## RETRACTED: "the parallel bank does not pay"

The first version of this section concluded that a firmware parallel filter bank
would not improve DSPi's room correction at any section count. **That was wrong.**
The reference designer it rested on had four independent defects, all of which
flattered the cascade. Corrected, the result reverses.

| Scenario | Cascade (10) | K=10 | K=12 | K=16 | K=24 | K=32 | K=48 |
|---|---:|---:|---:|---:|---:|---:|---:|
| shared_room_modes | 0.208 | 0.205 | 0.145 | 0.176 | 0.152 | 0.148 | 0.146 |
| single_seat_local_null | 2.815 | 2.797 | 2.792 | 2.785 | 2.778 | 2.770 | 2.774 |
| moving_spatial_nulls | 1.686 | 1.691 | 1.699 | 1.689 | 1.683 | 1.674 | 1.683 |
| single_position_rolloff | 0.281 | 0.700 | 0.502 | 0.255 | 0.175 | 0.147 | 0.136 |
| nine_position_cancellation | 4.857 | 4.791 | 4.777 | 4.781 | 4.778 | 4.825 | 4.739 |
| twentyone_position_diffuse | 4.016 | 4.034 | 4.024 | 4.029 | 4.014 | 4.044 | 4.047 |
| **mean** | 2.310 | 2.370 | 2.323 | 2.286 | 2.263 | 2.268 | 2.254 |


Bank's method as specified: log placement weighted toward the modal region,
spacing-rule Q, poles fixed. With pole refinement and feature-width Q (neither
is Bank's method) the mean improves to 2.198 dB at K=48 and the preamp cost is
unchanged at -16.2 dB.

**The preamp table is the finding, read per fixture.** Accuracy separates the
two designs by hundredths of a decibel. Headroom separates them by 4 to 6 dB on
four fixtures, 14 to 26 dB on the diffuse one, and 36 to 59 dB on the roll-off
one. The mean (-10.9 dB at K=10) is dominated by that last case and should not
be quoted as typical.

The pattern is diagnostic: wherever correction is forbidden outside the
speaker's passband, the reference puts gain there anyway, having no per-section
limits, and `requiredTrimDb` attenuates the whole channel to compensate.

**Ten sections is not enough, and neither is twelve.** At equal order Bank's
method is behind the cascade (2.370 against 2.310). Twelve, all the firmware has
storage for, gives 2.323 and still does not cross over. Sixteen draws level;
twenty-four is where it becomes worth naming. So the firmware question is not
"use the two spare slots" - it is "spend twenty-four or more sections per
channel", where the RP2040 CPU budget binds.

### Attribution: which defect mattered

Mean reliability-weighted RMSE with one correction removed:

| Variant | K=10 | K=24 | K=48 |
|---|---:|---:|---:|
| all corrections | 2.318 | 2.225 | 2.195 |
| no target normalization | 2.795 | 2.443 | 2.295 |
| no pole refinement | 2.514 | 2.305 | 2.210 |
| spacing-rule Q (Bank's) | 2.318 | 2.221 | 2.239 |
| log placement, LF-dense | 2.298 | 2.224 | 2.204 |
| log placement, even | 2.343 | 2.234 | 2.197 |

**The domain of the fit was the whole story.** Rows carried mask and position
weight only, so the least squares minimized *linear* residuals while the metric
measured dB. Since dB error is proportional to relative linear error, a plain
linear fit minimizes `|target|^2 * (dB error)^2` - and in a cut-only corpus the
target sits well below unity nearly everywhere, so the fit was instructed to
ignore exactly the regions the metric weights most. A bin 12 dB down counted for
a sixteenth. Fixing it is worth 0.48 dB at K = 10 and turned the loss into a win.

Worth recording: **PORC, the canonical Python port of Bank's method, does not
normalize either** - it runs a time-domain least squares on minimum-phase impulse
responses. The correction is needed because of what the scoreboard measures, not
because the reference implementations have it.

The other three: poles were frozen while the cascade's centres were refined by up
to an octave (worth 0.196 dB at K = 10); the pole radius was clamped at 0.9995, a
7.6 Hz bandwidth floor that broadened the sub-50 Hz sections at high K; and
`ParallelConfig` had drifted to `placementBias = 0.75` after the production
default moved to 0.5.

Two things turned out **not** to matter, which is worth as much as the two that
did. Bank's spacing-rule Q is within 0.004 dB of feature-width Q at K = 24 and is
better there. And log placement, weighted toward the low end as PORC's default
pole set is, is within 0.02 dB of the greedy feature allocator at every K.
**Log-spaced poles - the thing Bank's method is usually described by - made
almost no difference on this corpus.**

### The conclusion now

The firmware question is **open, and leaning toward worth doing** for
low-frequency modal resolution specifically, with one gate outstanding. The
reference carries no per-section limits, because a bound on a numerator
coefficient has no acoustic meaning, so part of its margin is freedom no
shippable design would have. The next experiment is a *constrained* parallel
designer, to find how much survives the safety rules. That is much smaller than
the firmware work and it is the honest gate before committing to it.

### How it was caught

The tell was in the original table: `single_position_rolloff` went from 1.779 dB
at K = 10 to 3.092 dB at K = 16. A healthy least squares does not get 74% worse
on the cleanest fixture in the corpus when six sections are added. It was written
into the risks section as an oddity instead of being investigated.

`test_parallel.cpp` now carries canaries that close the gap: they hand the
designer a target the bank can represent exactly and require it back. Two stages,
deliberately - a consistent linear system is recovered exactly under *any*
positive weights, so a single end-to-end canary would have passed throughout and
proved nothing about the weighting. The first stage isolates basis and solver,
the second adds the minimum-phase reconstruction, and a separate probe compares
deep-cut error with and without the normalization.

## Twelve bands buys the new designer nothing

Firmware already has storage for twelve PEQ bands (`MAX_BANDS` is 12, with
`channel_band_counts` set to 10), so raising the budget is a firmware constant
rather than a format change. Reliability-weighted worst-position RMSE at ten and
twelve bands, RP2350, 48 kHz:

| Fixture | search @10 | search @12 | fixed-pole @10 | fixed-pole @12 |
|---|---:|---:|---:|---:|
| mixed_full_range (extra) | 1.569 | 1.340 | 1.222 | 1.234 |
| shared_room_modes | 0.208 | 0.192 | 0.145 | 0.147 |
| twentyone_position_diffuse | 4.016 | 4.036 | 4.100 | 4.029 |

The search gains from the extra slots on the two correctable fixtures; the
fixed-pole designer does not move outside allocator jitter, and on the full-range
example it is marginally worse at twelve than at ten.

The reading is that **the search was partly budget-limited and the new designer
is not**. At ten bands the fixed-pole fit is already close to what these
measurements support, so what binds is the measurement rather than the slot
count. That is consistent with the section-count sweep above, where the parallel
bank needs K = 24 before it pulls clearly ahead: the gains live in resolution far
beyond twelve sections, not in one or two more.

Note this cuts against the Milestone 0 finding that five of eight scenarios
saturated the ten-band budget. That was measured with the search, and it was the
search that was saturating.

## Two defects worth not rediscovering

Both were invisible to every metric the corpus already printed, because
`FitMetrics` level-normalizes - deliberately, since one trim applies to the
whole channel and the balance compensation restores level afterwards.

**A level-invariant objective cannot see a fit that scores well by turning the
channel down.** Two versions of the designer did exactly that, one reaching a
bank sitting 17.5 dB below unity while scoring normally. The requirement is
that the level offset be taken under *the same weights the loss uses*: taken
under plain weights while the loss carries Huber and overshoot weights, a
uniform downward shift no longer cancels and is genuinely downhill. Fixing the
offset instead, at the uncorrected level, fails the opposite way - it demands a
zero-mean correction, and a cut-only correction legitimately has a negative
mean.

**A ridge scaled to the matrix trace is set by the largest column.** The
parallel designer's columns span ten orders of magnitude, since a pole at 24 Hz
at 48 kHz sits at radius 0.9997 with a basis-function gain in the thousands
while the direct path's column is a vector of ones. Trace scaling annihilated
the direct path - 0.004 instead of 1.0 - and cost 28 dB of fit at the top of
the band. The ridge must be relative to each column's own weighted norm.
