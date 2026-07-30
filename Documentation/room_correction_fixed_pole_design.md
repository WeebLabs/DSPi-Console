# Fixed-pole correction design

Status: implemented, with measured results

Branch: `room_correction_poles`

Last updated: 2026-07-30

Supersedes section 7.4 of `automated_room_correction_spec.md` (filter
allocation and optimization). Everything else in that document, including the
safety policy in 7.3 and the balance preservation in 7.5, is unchanged and
still authoritative.

## 1. What this changes, and what it found

The correction designer stops being a search over filter frequency, Q and gain,
and becomes **a considered starting point plus a bounded Gauss-Newton descent,
solved as a sequence of constrained linear least-squares problems**. That is
Balázs Bank's fixed-pole idea adapted to the two things DSPi actually is: a
cascade, and a device that accepts filter recipes rather than coefficients.

Two results came out of building it, and the second was not the expected one.

**The production designer reaches parity with the search it replaces, about
ninety-five times faster.** Reliability-weighted worst-position RMSE across the
acceptance corpus is 2.326 dB against the search's 2.311 dB, with slightly
better headroom and every safety gate passing, in 0.41 s against 39 s. It needs
one deterministic start rather than three, no iteration cap, no stall
heuristic, and no soft penalty weights.

**A parallel filter bank is worth hundredths of a decibel and costs headroom
that ranges from 4 dB to 58 dB depending on the measurement, as implemented.** The first version of this
document concluded it does not pay at any section count; that was wrong, because
the reference had four defects that all flattered the cascade (section 8.3).
Corrected, the accuracy question is genuinely close - Bank's method needs
sixteen sections to draw level with the ten-band cascade and twenty-four before
the advantage is worth naming - but the reference forces 11 to 17 dB of preamp
attenuation against the cascade's 0.1 dB, because its sections carry no
per-section limits. **A constrained parallel designer is the gate before any
firmware work**, and it is a much smaller piece of work than the firmware.

## 2. Why the parallel structure cannot reach the device

Bank's structure is a *sum* of second-order sections. DSPi cannot run one, and
the reason is worth stating precisely, because it decides what is buildable now
and what needs firmware.

**The DSP is a cascade.** `dsp_pipeline.c:396-425` (RP2350) and
`dsp_process_rp2040.S` (RP2040) run up to `channel_band_counts[ch]` sections in
series, feeding each section's output into the next. There is no accumulator to
sum sections into and no direct path to add them to.

**The wire carries recipes, not coefficients.** `EqParamPacket` is
`{type, freq, Q, gain}` as three float32 and a type byte, and the firmware
*designs* the biquad on-device in `dsp_compute_coefficients`. `FilterType` is a
closed enum of parametric shapes. A fixed-pole section's numerator is an
arbitrary quadratic, and no recipe in that enum expresses one.

The second blocker is the binding one, and it is worth being clear about why.
A parallel bank of K sections is algebraically a single order-2K transfer
function whose denominator is the product of the K fixed denominators, so it
factors into K cascaded biquads sharing exactly those poles. The cascade is
therefore not, by itself, an obstacle to the *response*. What it costs is the
reason the parallel form was attractive: the numerical properties Bank's
structure has, and a cascade does not, are properties of the runtime structure
rather than of the transfer function. Realizing the same response as a cascade
gives up the per-section accumulation at full width, the absence of inter-stage
noise growth, and the low coefficient sensitivity, all of which matter most on
exactly the platform with the least headroom to lose them, the RP2040 at Q28.

So the shape of the branch was: build the real thing where it can be measured,
build the realizable projection of it where it can ship, and let the measured
gap between them decide whether the firmware work is justified. It did.

## 3. Two designers

### 3.1 `ParallelDesign` - the reference

A faithful fixed-pole parallel filter: K pole pairs placed in advance,
numerator weights and a direct path solved by linear least squares against a
complex minimum-phase target. Not realizable on the device, never written to
hardware, never offered in the UI. Lives in `parallel.cpp`, has its own tests,
and is reachable only from `dspi_rc_cli poles`.

It is an **optimistic bound on accuracy and a pessimistic one on safety**. Its
numerator weights carry no per-section limit, because a bound on a numerator
coefficient has no acoustic meaning, so the constraint the cascade carries in
section 5.5 has no counterpart. The correction mask still removes disputed
regions from its objective and the trim still enforces its ceiling, so it is
not unconstrained; it is simply freer than anything shippable would be.

That asymmetry mattered little when the reference was losing and matters a
great deal now that it wins, so section 8.2 states plainly what part of its
margin it might buy. Two departures from Bank's method are also deliberate and
must be read with the result: pole frequencies are refined between numerator
solves, and the rows are weighted by the inverse square of the target magnitude.
The first is not Bank's method at all, and exists only so the reference gets the
same freedom the production cascade has. The second is not in Bank's reference
implementations either, and exists because the scoreboard is in dB.

### 3.2 `fitCorrection` - the production designer

The same idea projected onto what the wire carries. Centre frequencies and Qs
are allocated in advance, each section is an ordinary peaking filter or shelf
the firmware already knows how to build, and the fit refines gain, width and
centre within bounds around that allocation. This replaces the search entirely.

The projection rests on one exact fact: **cascaded magnitudes add in dB.** The
cascade's dB response is the sum of its sections' dB responses with no
approximation, which is what makes a dB-domain design matrix meaningful at all.

## 4. Placement

Placement decides quality, and at ten sections it decides most of it. Both
designers share one allocator so the two cannot disagree about the question
that matters most.

### 4.1 Greedy on features, then coverage

The allocator splits the budget by `placementBias`, which is the *coverage
share*: 0 spends everything on measured features, 1 spends everything on even
coverage of the band. Feature slots are placed first, greedily, strongest
first, each one suppressing a neighbourhood the width of the feature it claimed
so the next pick goes to a different problem rather than to the same one's
shoulder. Remaining slots are placed by repeatedly bisecting the widest gap,
which covers whatever the features did not claim without any slot landing on
one that did.

This started as equal-cumulative-energy quantiles, which is the natural reading
of "denser where the modes are" and is wrong at this section count. An isolated
narrow mode makes the cumulative curve jump, so quantile boundaries land on the
*edges* of the feature rather than on it: on the modal fixture that put
sections at 58 and 124 Hz for modes at 48 and 118 Hz, each about a full
feature-width off centre.

Neither endpoint of the bias is usable. All-coverage spends a tenth of the
budget on each decade whether or not anything is wrong there. All-feature keeps
picking after the real features are claimed and puts the surplus on whatever
noise the suppression left behind, which measures worse than the even coverage
it displaced. The corpus sweep is flat-bottomed between 0.5 and 1.0 and rises
sharply below 0.25; **0.5** is the default.

### 4.2 Q from feature width, not from spacing

Each section's Q is taken from the width of the error feature under it,
measured at half its depth and bounded by the nearest sign change, falling back
to the neighbour spacing where there is no feature to measure.

Bank's rule sets Q from the spacing, and that is right when there are thirty to
a hundred sections: adjacent sections then meet near their half-power points
and the bank can represent any smooth curve. At ten sections over three decades
the same rule yields Q near 1.3, which is broader than every room mode worth
correcting, and the fit can then only offer a gentle wide cut where the
measurement wants a narrow deep one. The reference designer keeps Bank's rule,
because at thirty-two sections it is correct and it is what the comparison is
about.

Q is then clamped by the frequency-dependent limits from spec 7.3.

## 5. The solve

### 5.1 Collapsing the positions

The objective is evaluated at every enabled position, and that requirement is
not relaxed. It does simplify, exactly rather than as a convenience.

The correction `D` is common to all positions. Expanding the weighted sum of
squares over positions, the cross terms separate: it equals the total weight
times `(D - ebar)^2` plus a term in the weighted variance of the measurements
across positions, and the second does not contain `D`. Minimizing over the
positions is therefore identical to minimizing against the single weighted mean
error curve, with per-bin weight equal to the summed position weights times the
mask. The dropped variance term is constant in the unknowns.

### 5.2 The design matrix

Three columns per section - gain, width as log Q, centre as log f - built as
central differences of the section's realized response through `realize()` and
`magnitudeDb()`. The columns are therefore derivatives of what the **exact
hardware model** produces at the live sample rate for the connected platform,
including the RP2350 SVF path below Fs/7.5 and the RP2040 Q28 truncation.

Width and centre have to be solved and not merely placed. A parallel section
carries two free numerator coefficients and can change its own shape; a
cascaded peaking section in the dB domain carries one, its gain, and can only
scale a shape decided in advance. Placement alone left the modal fixture at
1.11 dB where the search reached 0.21, and no allocator rule closed it: a
quarter-octave mode needs its centre within a few percent, which is finer than
any rule can place from a smoothed error curve.

One extra unbounded column absorbs broadband level, so gains are not spent
chasing an offset the trim removes anyway. Section 5.6 is about the conditions
under which that column is safe, which are not obvious.

### 5.3 Bounds are what replace the search

Each section starts where the allocator put it, moves by at most a sixth of an
octave in centre and a factor of 1.5 in width per pass, and may never drift
more than `maxDriftOctaves` from its allocation. That bound is the line between
a refinement and a search: within it the fit is a local descent from a
considered starting point, one start is enough, and two sections cannot swap
roles. Open it wide enough and the allocator stops meaning anything, and the
local minima that made the old fit need three starts come back with it.

The corpus prefers a full octave (mean 2.462 dB at the time it was swept,
against 2.893 dB pinned), and the improvement is monotone up to that point.
**1.0 octave** is the default.

### 5.4 Robustness and asymmetry, inside the weights

Both the robust loss and the overshoot preference are weights in the
reweighting rather than penalty terms, so each pass stays an ordinary weighted
least squares and neither can be outbid by the error term.

The Huber weight `min(1, delta/|r|)` is what stops one position's 30 dB
cancellation null from owning a fit that should be describing the twenty bins
around it. The overshoot weight multiplies residuals above
`overshootToleranceDb` by `overshootEmphasis`, because a seat left 2 dB hot is
a worse outcome than a seat left 2 dB shy. Dropping the second entirely was
measurable: P95 overshoot on the local-null fixture went from 0.16 dB to
1.94 dB, precisely the failure the per-position objective exists to prevent.

### 5.5 Constraints, all structural

No soft penalty terms survive. Every limit from spec 7.3 becomes one of three
things.

**Per-section gain and width limits become bounds on the solve**, resolved by
an active-set bounded least squares: solve on the free variables, move the
worst violator onto its bound, and release a bound variable whenever the
gradient says the objective falls by moving it back inward. The release step is
what makes the answer the true constrained minimizer rather than merely a
feasible point.

**The combined ceiling stays in the trim.** `requiredTrimDb` enforces the
ceiling, the no-boost-outside-native rule and the no-boost-in-disputed-regions
rule by attenuating the channel, deterministically, after the fact.

**The sign-dependent Q limit is re-imposed structurally at the end.** A section
may not be both narrow and boosting, but the limit depends on the sign of a
coordinate the solve is free to change, which no box constraint can express.
The widths are clamped against the final gains and the gains re-solved once
against the corrected widths.

### 5.6 The level trap, twice

The fit is scored level-invariantly: one trim applies to the whole channel and
the balance-preserving compensation restores inter-channel level afterwards, so
an absolute offset is not a tonal defect, and scoring it as one makes the fit
fight its own trim. Every metric in `FitMetrics` normalizes level for the same
reason.

The consequence is that **no metric here can see a fit that scores well by
turning the channel down**, and two separate versions of this designer did
exactly that. Both are recorded because each is locally plausible and neither
showed up in any number the corpus was already printing.

Recomputing the level offset per pass as the weighted mean residual makes the
goalpost follow the bank: the target then has the same weighted mean as the
current response, so nothing anchors the level at all. Fixing the offset at the
uncorrected level is worse in the opposite direction, since it demands a
correction with a weighted mean of zero and a cut-only correction legitimately
has a negative mean; the corpus collapses across the board.

The actual requirement is subtler: **the offset must be taken under the same
weights the loss uses.** Taken under plain weights while the loss carries Huber
and overshoot weights, a uniform downward shift no longer cancels - it still
reduces the loss, so the fit buys score by attenuating. That reached a bank
sitting 17.5 dB below unity on the cancellation fixture, which no ridge could
argue it out of, because it was not a degenerate direction at all. It was
genuinely downhill. The offset is now a two-step fixed point under the loss's
own weights, after which a uniform shift is exactly neutral.

Being neutral is not the same as being decided, which is what section 5.7 is
for.

### 5.7 The ridge decides the flat directions

A Tikhonov ridge pulls gain toward zero and width and centre toward where the
allocator put them - **toward the allocation, not toward the origin**, which is
the difference between "prefer the answer we already had unless the data says
otherwise" and "prefer something small".

It does two jobs. It breaks the level direction left neutral by 5.6, so the fit
does not wander into spending headroom it has no use for. And it stops two
sections that ended up close together solving to a large positive and a large
negative gain that nearly cancel, which is invisible in the fitted response and
awful on hardware.

The corpus sweep is the clearest trade in the whole design. At 1e-4 the mean
error is 2.462 dB and the mean peak correction sits 3.4 dB below the ceiling -
that is 3.4 dB of headroom bought for nothing. At 1e-3 the error is 2.471 dB
and the peak is 1.7 dB below. Beyond that the error climbs steeply. **1e-3** is
the default: it halves the wasted headroom for nine thousandths of a decibel.

The solver applies the ridge **relative to each column's own weighted norm**,
having normalized the columns first. This is not a refinement either. The
parallel designer's columns span ten orders of magnitude - a pole at 24 Hz with
a 48 kHz sample rate sits at radius 0.9997 and its basis function has a gain in
the thousands, while the direct path's column is a vector of ones - so a ridge
scaled to the matrix trace is set by the largest column and annihilates the
smallest. That put the direct path at 0.004 instead of 1.0 and cost 28 dB of
fit at the top of the band.

### 5.8 The solver

Householder QR on the weighted, ridge-augmented, column-normalized system,
in-tree, no dependency. Normal equations plus Cholesky would be simpler and
would probably work at this conditioning, but the argument for this change is
numerical robustness and squaring the condition number to save eighty lines
would be an odd place to economize.

Determinism is per platform on the same terms as everything else in the core,
and for the same reason: the transcendental functions the columns are built
from are not correctly rounded.

## 6. The complex target, for the reference designer only

Fitting a parallel bank requires a target with phase, and a room measurement
gives magnitude. The reference designer builds a **minimum-phase** target from
the desired correction magnitude by the real-cepstrum method: forward transform
of the log magnitude, fold the negative quefrencies onto the positive ones,
inverse transform, exponentiate.

Minimum phase is the right choice rather than the convenient one: the
correction is being asked to invert a magnitude, the minimum-phase
reconstruction is the causal stable filter with that magnitude and the least
group delay, and a magnitude-only target fitted with arbitrary phase would
spend sections on phase behaviour nobody asked for.

The production designer needs none of this. It fits magnitude in dB directly,
because a cascade of magnitude responses adds in dB.

## 7. What was retired

From `FitConfig`: `maxIterations`, `starts`, `hygieneWeight`,
`overshootWeight`, `positiveCorrectionWeight`, `unreliableBoostWeight`,
`sharpnessWeight`, `complexityWeight`. Each either became structural or has no
meaning without a search. `overshootToleranceDb` survives, reinterpreted as the
threshold of the asymmetric weight rather than of a soft hinge.

From `optimizer.cpp`: `encode`, `decode`, `Slot`, `buildSlots`, `makeBounds`,
`Bounds`, `seedFilters`, `lineSearch`, `minimize`, `MinimizeResult`,
`softHinge`, and the `Objective` class.

From `FitResult`: `objective`, `iterations` and `evaluations` are kept and
repurposed rather than removed, since they are on the C ABI. `objective` is the
final weighted residual norm, `iterations` the solve passes, `evaluations` the
number of linear solves including active-set sub-solves. `converged` becomes a
real condition rather than a budget report: the bounded solve terminated.

`evaluateBank`, `applyStrength`, `FitProblem` and `FitMetrics` are unchanged.
That is deliberate: the comparison between the old designer and the new one is
only worth anything if both are scored by identical code that neither of them
optimizes.

In `dspi_rc_fit_config`, `hygiene_weight`, `max_iterations` and `starts` are
replaced by `placement_bias`, `ridge` and `solve_passes`. The Swift layer names
only the fields it uses, so the change is confined to the header, `capi.cpp`
and `dspi_rc_default_fit_config`.

## 8. Measured results

Corpus of six synthetic scenarios, RP2350, 48 kHz, ten bands, natural target,
cut-only. The metric is reliability-weighted worst-position RMSE in dB. Peak is
the maximum combined correction, whose distance below the -0.5 dB ceiling is
headroom spent for nothing. Baseline is the SLSQP-style coordinate search at
`fc565ea`, run on the identical fixtures through the identical metrics.

| Scenario | Uncorrected | Baseline | Fixed-pole | Delta |
|---|---:|---:|---:|---:|
| shared_room_modes | 2.101 | 0.208 | **0.145** | -0.063 |
| single_seat_local_null | 3.754 | 2.815 | **2.812** | -0.003 |
| moving_spatial_nulls | 2.968 | 1.686 | 1.689 | +0.003 |
| single_position_rolloff | 3.682 | **0.281** | 0.403 | +0.122 |
| nine_position_cancellation | 5.179 | 4.857 | **4.805** | -0.052 |
| twentyone_position_diffuse | 7.432 | **4.016** | 4.100 | +0.084 |
| **mean** | 4.186 | **2.311** | 2.326 | +0.015 |

Mean peak correction is -1.8 dB against the baseline's -2.05 dB, so the new
designer wastes slightly less headroom. Every safety gate passes in both the
cut-only and the +3 dB advanced-boost configuration. Runtime for the whole
corpus is 0.41 s against 39 s, a factor of 95, and the new figure includes two
runs per scenario.

One scenario exceeds the 0.1 dB per-scenario tolerance, by 0.022 dB.

### 8.1 The parallel bank, by section count

Bank's method as specified: logarithmically placed poles weighted toward the
modal region the way PORC's default pole set is, Q from the spacing to the
neighbours, poles fixed.  Reliability-weighted worst-position RMSE in dB.

| Scenario | Cascade (10) | K=10 | K=12 | K=16 | K=24 | K=32 | K=48 |
|---|---:|---:|---:|---:|---:|---:|---:|
| shared_room_modes | 0.208 | 0.205 | **0.145** | 0.176 | 0.152 | 0.148 | 0.146 |
| single_seat_local_null | 2.815 | 2.797 | 2.792 | 2.785 | 2.778 | **2.770** | 2.774 |
| moving_spatial_nulls | 1.686 | 1.691 | 1.699 | 1.689 | 1.683 | **1.674** | 1.683 |
| single_position_rolloff | 0.281 | 0.700 | 0.502 | 0.255 | 0.175 | 0.147 | **0.136** |
| nine_position_cancellation | 4.857 | 4.791 | 4.777 | 4.781 | 4.778 | 4.825 | **4.739** |
| twentyone_position_diffuse | **4.016** | 4.034 | 4.024 | 4.029 | 4.014 | 4.044 | 4.047 |
| **mean** | 2.310 | 2.370 | 2.323 | 2.286 | 2.263 | 2.268 | **2.254** |

Preamp attenuation each design forces, same runs, in dB:

| Scenario | Cascade (10) | K=10 | K=12 | K=16 | K=24 | K=32 | K=48 |
|---|---:|---:|---:|---:|---:|---:|---:|
| shared_room_modes | -0.2 | -5.8 | -5.9 | -6.0 | -6.2 | -6.3 | -6.5 |
| single_seat_local_null | 0.0 | -4.9 | -4.9 | -5.0 | -5.2 | -5.3 | -5.4 |
| moving_spatial_nulls | -0.3 | -4.5 | -4.6 | -4.7 | -4.8 | -4.9 | -5.0 |
| single_position_rolloff | 0.0 | **-36.5** | **-40.0** | **-45.0** | **-51.9** | **-58.2** | **-58.6** |
| nine_position_cancellation | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | -0.2 | -0.5 |
| twentyone_position_diffuse | 0.0 | -14.0 | -16.0 | -18.7 | -21.8 | -23.7 | -25.7 |

With pole refinement and feature-width Q - neither of which is Bank's method,
and both of which exist so the reference gets the freedom the cascade's centres
have - the accuracy improves and the headroom does not:

| | Cascade | K=10 | K=16 | K=24 | K=32 | K=48 |
|---|---:|---:|---:|---:|---:|---:|
| mean | 2.310 | 2.287 | 2.247 | 2.226 | 2.211 | **2.198** |
| mean preamp, dB | -0.1 | -12.7 | -14.0 | -15.0 | -15.5 | -16.2 |

**Read the preamp table, and read it per fixture rather than averaged.**  The
cost is concentrated, not spread: on four of six fixtures it is 4 to 6 dB, and
on `single_position_rolloff` it is 36 dB at ten sections and 58 dB at
thirty-two.  A mean over that distribution (-10.9 dB at K=10) is dominated
entirely by the outlier and says nothing useful; an earlier draft of this
section quoted it as though it were a typical figure, which it is not.

The pattern is specific and diagnostic.  Wherever the measurement rolls off and
correction is forbidden outside the speaker's passband, the reference puts gain
there anyway - it has no per-section limits, because a bound on a numerator
coefficient has no acoustic meaning - and `requiredTrimDb` then attenuates the
whole channel to compensate.  The cascade never does this, because each of its
sections is individually barred from boosting there.  So the headroom cost is
not a property of the parallel structure; it is the absence of the constraint,
and section 8.2 is where that is owed.

**Ten sections is not enough, and neither is twelve.**  At equal order Bank's
method is slightly *behind* the ten-band cascade (2.370 against 2.310).  Twelve,
which is all the firmware has storage for today, narrows that to 2.323 and still
does not cross over.  Sixteen draws level; twenty-four is where the advantage
becomes worth naming.  The firmware question is therefore not "use the two spare
slots" but "spend twenty-four or more sections per channel", which puts the
RP2040 CPU budget in the frame.

**Where it wins, it wins clearly.**  On the fixtures where correction is
genuinely available the advantage is real and grows with section count: the
roll-off fixture reaches 0.136 dB against the cascade's 0.281, and with
refinement the modal fixture reaches 0.023 dB against 0.208.  On the
interference-dominated fixtures the two converge, because neither may invert a
cancellation that moves with the microphone.  That is why the corpus mean barely
separates: two of six fixtures are error no magnitude EQ may touch, and they
dominate the average.

### 8.2 What the margin might be buying

Three asymmetries remain, and all favour the reference.

**No per-section limits.** The cascade may not cut below -12 dB, may not boost
above the mask's ceiling, and may not be narrow and boosting at once. The
parallel bank's numerator coefficients carry none of that, because a bound on a
numerator coefficient has no acoustic meaning. On the fixtures where the safety
rules bind hardest this is worth an unknown amount, and it is the reason a
shippable parallel designer would not reproduce these numbers.

**Pole refinement.** The reference now moves its poles, which Bank's method does
not. Turning it off costs 0.196 dB at K = 10 and 0.015 dB at K = 48, so at high
section count the result stands almost unchanged without it; at low section count
a meaningful part of the K = 10 parity is refinement rather than structure.

**Phase.** The reference is fitted to a minimum-phase complex target and scored
on magnitude alone, which spends some freedom on behaviour the metric ignores.
This one runs against the reference, not for it.

### 8.3 Retraction, and what was wrong

The first version of this document concluded that a parallel bank does not pay
at any section count. That was wrong, and the reason was four independent
defects in the reference implementation, all of which flattered the cascade.
The attribution, as mean reliability-weighted RMSE with one correction removed:

| Variant | K=10 | K=24 | K=48 |
|---|---:|---:|---:|
| all corrections | 2.318 | 2.225 | 2.195 |
| no target normalization | 2.795 | 2.443 | 2.295 |
| no pole refinement | 2.514 | 2.305 | 2.210 |
| spacing-rule Q (Bank's) | 2.318 | 2.221 | 2.239 |
| log placement, LF-dense | 2.298 | 2.224 | 2.204 |
| log placement, even | 2.343 | 2.234 | 2.197 |

**The fit was in the wrong domain, and this was the whole story.** Rows were
weighted by mask and position only, so the least squares minimized *linear*
residuals while the scoreboard measured dB. dB error is proportional to relative
linear error, so a plain linear fit minimizes `|target|^2 * (dB error)^2`: in a
cut-only corpus, where the target sits well below unity nearly everywhere, that
instructs the fit to ignore precisely the regions the metric weights most. A bin
12 dB down counted for a sixteenth, one 24 dB down for a two-hundred-and-
fiftieth. Correcting it is worth 0.48 dB at K = 10 and is what turned a loss
into a win.

Worth recording: **PORC, the canonical Python port of Bank's method, does not
normalize either** - it runs a time-domain least squares on minimum-phase
impulse responses, which is flat linear weighting. The correction is required
here because of what the scoreboard measures, not because the reference
implementations have it.

**The poles were frozen while the cascade's were not.** The production designer
refines its centres by up to an octave and takes its Q from the measured feature
width; the reference did neither. That is not a comparison of structures, it is
a comparison of one designer's refinement against another's absence of it.
Worth 0.196 dB at K = 10.

**The pole radius was clamped at 0.9995**, a floor of about 7.6 Hz of bandwidth
at 48 kHz. At high section counts the spacing rule asks for narrower than that
below roughly 50 Hz, so the clamp broadened exactly the low-frequency sections
in the region where the structure is strongest. Now `1 - 1e-6`; the filter is
only ever evaluated, never run, so the clamp needs to keep arithmetic finite and
nothing more.

**The placement parameters had drifted apart.** `ParallelConfig` still carried
`placementBias = 0.75` after the production default moved to 0.5, while the
document claimed a shared allocator meant the two could not disagree. The shared
thing was the allocator *code*, not its settings.

Two of the four turned out not to matter much, which is worth saying as plainly
as the two that did. Bank's spacing-rule Q is within 0.004 dB of feature-width Q
at K = 24 and is actually *better* there; and log placement, LF-dense in PORC's
manner, is within 0.02 dB of the greedy feature allocator at every K. **The
poles being log-spaced, which is the thing Bank's method is usually described
by, made almost no difference on this corpus.** Only the weighting and the
refinement did.

The general lesson is the one already recorded in 5.6 about headroom: a
reference implementation is only an upper bound if it is actually extracting
what the structure can deliver, and the corpus cannot distinguish "the structure
is limited" from "the fit is broken". The tell was there to be read - a healthy
least squares does not get 74% worse on the cleanest fixture when six sections
are added, as `single_position_rolloff` did going from K = 10 to K = 16 - and it
was written down in the risks section as an oddity rather than investigated. The
canaries in `test_parallel.cpp` now close that gap: they hand the designer a
target the bank can represent exactly and require it back, in two stages so that
the basis and solver are separated from the minimum-phase reconstruction.

### 8.4 What would still change the conclusion

The corpus is six synthetic fixtures. They were built to exercise the safety
rules rather than to sample real rooms, and the two fixtures where magnitude EQ
can do least dominate the mean while the two where it can do most are where the
parallel bank's advantage lives. A real-measurement corpus is the missing input,
and it could move this in either direction.

The more actionable caveat is 8.2: the reference is not constrained the way
anything shippable would be. Before this result justifies firmware work, the
next experiment is a *constrained* parallel designer - per-section limits on
what each pole pair may contribute - to find out how much of the margin survives
the safety rules. That is a smaller piece of work than the firmware itself and
it is the honest gate.

## 9. What firmware would need, if the evaluation is ever revisited

Recorded so the decision can be re-made against a real cost. Not in scope, and
on section 8's evidence not currently justified.

- A parallel EQ mode per channel: an accumulator, K second-order sections
  summed, plus a direct path. Both platforms, including the RP2040 hand-written
  assembly.
- Raw coefficient upload. The recipe wire cannot express an arbitrary
  numerator, so this is a new filter type or vendor command carrying b0/b1/a1/a2
  per section, plus flash and bulk wire format changes.
- Storage beyond `MAX_BANDS` 12.
- A CPU budget on both platforms. Twenty-four sections per channel across eight
  input channels is well over twice today's PEQ load, and the RP2040 is the
  binding case.

The cheaper intermediate is a raw-coefficient filter type alone: the existing
cascade would run the factored parallel design with no new DSP path and no
assembly work, at the cost of the numerical properties in section 2. On these
results it would buy nothing.

## 10. Risks and known weaknesses

**The knobs were swept one at a time.** `placementBias`, `maxDriftOctaves`,
`ridge`, `overshootEmphasis` and `solvePasses` interact, and the defaults come
from coordinate-wise sweeps around a moving point rather than a joint search.
The corpus is flat near the chosen values, which is reassuring but not the same
as a demonstrated optimum.

**Gauss-Newton is not monotone here.** A pass is a bounded descent step against
a linearization, and on at least one fixture a wider drift limit produced a
slightly worse result than a narrower one. The trust regions keep this small
and the fixed pass count bounds it, but the fit carries no guarantee that pass
N+1 improves on pass N, and nothing in the code pretends otherwise.

**Shelves are allocated, not earned.** Two of the ten slots always go to a low
and a high shelf when shelves are enabled, placed at the outermost peaking
centres. Where a fixture has no broad edge trend those slots are pruned for
negligible gain and the effective budget is eight. An allocator that decided
between a shelf and a peaking section on the evidence would use the budget
better.

**The reference designer is dead code by construction.** It is not on the
product path, is confined to its own translation unit and tests, and section 8
is the decision it existed to inform. It should be deleted once that decision
is accepted.
