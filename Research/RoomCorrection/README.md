# Room Correction Milestone 0 — closed

This directory is the reproducible research gate for
`Documentation/automated_room_correction_spec.md`. The Python code is a test
harness, not application code; the production implementation remains a
portable C++17 core.

## What the harness covers

`room_correction/sweep.py` freezes the current firmware logarithmic-sweep
trajectory at DSPi firmware commit
`9776c2f9feb5a1f8487180a351f8fbb1ec67e4ff`:

- Q48 phase and increment accumulators and the Q31 logarithmic recurrence;
- the RP2350 folded seventh-order sine polynomial;
- the 5 ms overlay/cycle edge windows at the normal 192-sample block size;
- strict 44.1, 48, and 96 kHz measurement gating.

An analog microphone does not need a shared clock or fixed latency. Capture
alignment is estimated from the recorded sweep. A small time-scale fit or
resampling step can compensate independent ADC/DAC clock-rate error before
deconvolution. The RP2040 sweep uses the same phase law but a fixed-point sine,
amplitude, and envelope path; its exact output samples are not modeled here and
remain a loopback/parity test for the portable-core phase.

`fixtures/corpus.json` contains eight deterministic scenarios at 96 points per
octave. It covers 1, 3, 5, 9, and 21 positions; 44.1, 48, and 96 kHz; flat and
tilted house-curve targets; speaker roll-off/correction curtains; broad shelves;
and non-minimum-phase delayed two-path cancellations. The measurements use
analytic log-Gaussian, roll-off, delay, tilt, and noise models rather than the
RBJ filters used by the fitter, avoiding the previous inverse crime.

`room_correction/model.py` implements peaking, low-shelf, and high-shelf RBJ
responses plus the current DSPi write-path model:

- frequency, Q, and gain are IEEE-754 float32 in `EqParamPacket`;
- DSPi Console currently rounds gain to 0.1 dB before transmission, although
  the wire carries float32; removing that host policy is the first Milestone 1
  implementation task;
- firmware clamps frequency to 10 Hz–0.45 Fs and Q to 0.1–20;
- RP2350 coefficient arithmetic/storage is float32, with the low-frequency SVF
  evaluated by its RBJ-equivalent magnitude in this harness;
- RP2040 stores the float-designed coefficients in Q28. Its fixed-point
  per-sample rounding is not represented by a transfer-function calculation.

The fitter currently re-optimizes gains on the Console's 0.1 dB grid after
recipe quantization and scores the exact selected-platform response. It derives
one continuous solution, then independently performs the discrete gain search,
trim, and neutral scoring for RP2350 and RP2040. Cross-platform response parity
is not required. Production-hygiene variants enforce the boost-Q,
disputed-region, correction-curtain, and combined-response limits as hard
output contracts.

## Fair ablation and neutral scoring

The benchmark is a 2×2 ablation, with every cell receiving the same start count
and deterministic perturbation policy and none borrowing another fit's
optimized solution:

| Variant | Curve/statistic | Safety hygiene |
|---|---|---|
| `arithmetic_plain` | arithmetic dB average | no |
| `arithmetic_hygiene` | arithmetic dB average | yes, without spatial disagreement |
| `spatial_plain` | power average plus per-position reliability | no |
| `spatial_hygiene` | power average plus per-position reliability | full |

Variants are compared only on neutral metrics: raw and reliability-weighted
worst-position RMSE, median absolute error, a fixed-delta reliability-weighted
Huber loss, positive overshoot, disputed/out-of-band boost, boost Q, and local
probe correction. A variant's private optimization objective is reported for
diagnostics but never used as a cross-variant headline.

The objective uses pseudo-Huber loss, softplus hinges, and smooth maxima. The
primary gate uses all ten hardware bands, a 400-iteration cap, and three equal
starts. SLSQP is the current behavioral oracle; the portable implementation
should prototype NLopt/SLSQP before reconsidering an L-BFGS-B dependency. The
default soft hygiene weights use 0.25× of the original preset. The one-start
sweep was insensitive from 0.125× through 1.0× and had different convergence
counts by row; 0.25× was selected because it was the only tested row to
converge in all eight scenarios, not because the data established a performance
knee. Hard safety limits are not part of that sweep.

## Run

From this directory:

```sh
python3 -m unittest discover -s tests -v
python3 benchmark.py
python3 weight_sweep.py
python3 export_rew.py /tmp/dspi-room-correction-rew
```

`benchmark.py` writes a schema-versioned JSON report to standard output and
returns nonzero if the full ten-band candidate fails either platform. The
report separates closure prerequisites, discriminating quality gates, and
hard-constraint enforcement checks; a constraint readback is not presented as
evidence of safety margin. `--summary` emits the compact evidence report; `--progress` reports long
run progress on standard error; `--include-lbfgsb` performs the now-optional
optimizer comparison. The full run also checks a representative fixture at
every allocation from 1 through 10. A non-quick run below ten filters or 400
iterations is labeled `research_nonclosure` and cannot pass the closure
requirements. `--quick` is explicitly labeled `smoke` and is never closure
evidence.

`weight_sweep.py` reproduces the 0/0.125/0.25/0.5/1.0 joint soft-penalty sweep
at ten bands and 400 iterations. It uses one start to keep the research run
tractable, identifies the converged scenarios in every row, and marks its
returned-candidate means as diagnostic rather than strictly comparable with
one another or with the production three-start run.

## Explicitly not claimed

- REW text import/export is covered, but an actual REW automatic-EQ comparison
  still needs a human-run matched measurement and target.
- The corpus begins with magnitude responses; deconvolution, FDW, smoothing,
  and raw-capture quality analysis belong to Milestone 1.
- RP2350 SVF time-domain rounding, RP2040 fixed-point filter processing, and
  RP2040 generator samples require golden traces or loopback tests.
- Synthetic success is not evidence of parity with Dirac Live or ARC. Those
  products remain behavioral/listening references, not golden implementations.

See `RESULTS.md` for the neutral-metric result and remaining decision.
