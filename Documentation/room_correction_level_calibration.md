# Channel level calibration

Status: draft, not implemented.

Companion to `automated_room_correction_spec.md`. That document's section 7.5
requires *preserving* the pre-correction balance between channels and defers
*equalising* them to a later discussion. This spec is that discussion, and it
changes the intent: version 1 of the level work should leave every channel at
the same measured level, not merely at whatever balance it started with.

Nothing here changes the optimizer.

## 1. Three level quantities, deliberately separate

Confusing these is what left the current build with no channel calibration at
all, so they are named separately and kept apart.

**Target placement** (`chooseAutoLevel`, `target.cpp`). Chooses where the
target curve sits vertically for one channel, at the 20th percentile of
`measured - shape` inside the corrected band. Its only job is to make a
cut-only correction feasible without demanding boost everywhere, and to avoid
one deep null dragging the channel down to match a hole nobody sits in.

It is an optimizer mechanism. It is not a statement about how loud a channel
should be relative to any other channel, and nothing downstream may treat it as
one. It stays exactly as it is.

**Level match.** A scalar per channel that brings every channel to the same
measured level. Derived from its own measurement pass, not from the fit.

**Correction compensation.** A scalar per channel accounting for the broadband
level a cut-only correction removes. Every channel loses a different amount,
because every channel has a different room interaction, so applying correction
without this silently rebalances the system even though no level control was
touched. Section 7.5 of the main spec already requires it.

Level match and correction compensation are summed into one offset per channel
and written once. Target placement is never part of that sum.

## 2. Why relative measurement is sufficient

We standardise on the UMIK-1, which carries a sensitivity figure and could in
principle give absolute SPL. We do not use it, because absolute SPL also needs
the input chain's gain, which we do not know and cannot reliably discover.

We do not need it. Every comparison here is between channels measured with the
same microphone, at the same position, through the same input chain, inside one
session. Under those conditions the unknown gain is a common factor and cancels
exactly.

That makes the constraint load-bearing rather than advisory:

> Once the level pass begins, the microphone gain, the microphone's position for
> that pass, and the DSPi input gain must not change until the session ends.

The app states this before the pass and watches the input device's volume for
the duration. If it changes, the session stops and says why rather than
producing a confidently wrong match.

**Gain cancels; frequency response does not.** The unknown chain gain is flat,
so it cancels in any comparison. The microphone's own magnitude response is
not flat, and it only cancels when both measurements sit in the same band.
Comparing channels within one band therefore needs no calibration file at all,
while comparing a subwoofer against the midband channels (section 4) genuinely
does. Without a loaded calibration file, subwoofer matching is still performed
but reported as reduced accuracy, with the microphone's uncalibrated
low-frequency response named as the reason.

## 3. Sequence of user actions

### 3.1 Setup

Unchanged. Microphone, calibration file, channels, roles, plan.

### 3.2 Level Check, extended to every channel

Today this measures the noise floor once and plays band-limited noise through a
single channel. It should measure the noise floor once, then step through every
selected channel at the main listening position. One pass yields three things:

- the room's noise floor, as now;
- per-channel signal to noise and headroom, so the worst channel sets the sweep
  level rather than the first channel being assumed representative;
- per-channel relative level, which is the calibration input.

**This must happen before the measurement campaign.** Correcting a badly
matched channel means turning a physical gain control, and that invalidates
every sweep taken before it. Discovering the problem after a full measurement
run means repeating the run.

The digital offsets computed here are not applied yet. Level is a scalar and
commutes with EQ, so only the *physical* problems have to be resolved before
sweeping.

### 3.3 Measurements

Unchanged.

### 3.4 Target

Unchanged.

### 3.5 Results

Per channel, three figures rather than one:

- level match, from 3.2;
- correction compensation, from the fit;
- total offset, being the sum and what will actually be written.

Also the total output given up to matching downward (section 5), so a user with
one quiet channel learns why the system got quieter instead of wondering.

### 3.6 Apply

One transaction: snapshot, write each channel's filters and its total offset,
read back, compare, restore on any mismatch. Reuses `MeasurementStateSnapshot`
and `MeasurementStateJournal` rather than a parallel path.

The offset is written at the destination, as section 7.5 requires: output gain
for an output-destination correction, per-input preamp for an input-destination
one. Correction and its compensation must not end up on opposite sides of the
matrix.

### 3.7 Verify

One sweep of every channel at the main listening position, back to back.

**Channels are compared to each other, not to the earlier prediction.** Drift
that would ruin an absolute comparison - temperature, a nudged microphone, an
altered gain - is common to all channels in a single pass and cancels. This is
what makes a tight tolerance defensible; the same tolerance against a
prediction taken twenty minutes earlier would fail routinely and teach users to
ignore the check.

- Pass when the worst channel-to-channel deviation is within **0.5 dB**.
- Warn beyond that.
- If the worst deviation is under 2 dB, offer **one** residual correction and
  re-verify **once**. Above 2 dB, something physical changed; report and stop
  rather than chasing noise.

Channels measured with their crossover bypassed are excluded from the pass
criterion, with the reason shown, because verify measures the real
configuration and their prediction was made without it.

Verify confirms; it never discovers. A verify step that finds problems for the
first time is a second calculate step wearing the wrong name.

## 4. Comparison bands and normalisation

Channels are compared as **in-band spectral level**, being power per octave
averaged across the band, rather than as broadband RMS. This is the whole
mechanism that lets differently band-limited channels be compared: power per
octave is independent of how wide the band is, so a two-octave subwoofer and a
four-octave midband measurement are directly comparable without needing any
frequency range in common.

Per-octave rather than per-third-octave is an arbitrary choice; it only has to
be consistent across every channel in a session.

**Full-range channels** are measured over roughly **200 Hz to 4 kHz**: above the
modal region, so the reading is stable against small microphone movements, and
below where directivity and air absorption dominate. Their mutual comparison
sits in one band and needs no calibration file.

**A subwoofer** is measured with its own band-limited low-frequency stimulus,
over its detected native bandwidth, and normalised the same way. A separate
stimulus rather than the midband one because a subwoofer fed broadband noise
discards almost all of the signal's energy in its own low-pass, leaving a poor
signal to noise ratio exactly where the room is noisiest.

Its result is then expressed as an offset from the full-range datum. That
comparison crosses bands, so it requires the microphone magnitude calibration
described in section 2.

### 4.1 Rejected: matching in the crossover overlap

An earlier draft compared the subwoofer against a reference full-range channel
where the two overlap. This is recorded as rejected so it is not proposed
again. The overlap is close to the worst available place to calibrate a
subwoofer:

- both the main and the subwoofer are rolling off there, so both readings sit
  on steep slopes where small frequency errors become large level errors;
- what is measured is their acoustic sum, which depends on relative phase and
  delay rather than on either level alone;
- room modes are strongest in that region;
- in input mode with bass management, driving the reference channel drives the
  subwoofer too, so no main-alone measurement exists to reference against;
- a cancellation in the overlap makes a correctly adjusted subwoofer read as
  too quiet, and the resulting advice to raise it would leave the system worse
  than before.

The last point is the disqualifying one: the failure mode is confident, wrong,
and in the direction of damage.

### 4.2 The LFE convention

An LFE *program* channel carries a **+10 dB in-band gain** by convention. This
is a gain applied to the channel's own band, and it is not the same claim as
expecting a broadband meter to read 10 dB higher, because the LFE band is a
small fraction of a broadband signal's energy.

It is therefore applied explicitly as an in-band offset in the level
arithmetic, never inferred from a measurement. A discrete LFE input channel is
not a channel to equalise against the others, and any matching pass must know
the difference between an LFE program channel and a subwoofer output.

## 5. Direction and cost

Among **full-range channels**, matching is always **downward**, toward the
quietest. Every channel has already spent headroom on its correction, and
asking for gain on top of that risks exceeding what is available. Attenuation
always succeeds.

**The subwoofer does not participate in that search.** It sits on its own datum
with an explicit offset (section 4), so it is neither a candidate for the
quietest channel nor pulled to match one. A weak subwoofer must never attenuate
seven other channels by default; that trades a correct system for a quiet one
to satisfy an arithmetic rule.

The output given up to downward matching among the full-range channels is
reported, so a user with one quiet channel learns why the system got quieter
rather than wondering.

## 6. Guidance when a channel is out of range

A channel outside the workable window produces an instruction, not a warning.
The second sentence is the important half, because it states the cost of
ignoring the first:

> The centre channel is 6.3 dB below the other channels. Raise its gain control
> and measure again - otherwise every other channel has to be attenuated by
> 6.3 dB to match it.

For a **subwoofer**, where downward matching does not apply, the consequence is
different and so is the offer. The user may fix the gain or proceed knowingly:

> The subwoofer is 6.3 dB below its reference level. Raise its gain control and
> measure again, or continue with the subwoofer left uncalibrated.

Continuing is a supported outcome, recorded in the project and shown in
Results, not a silent failure. What is never offered is attenuating the rest of
the system to meet it.

Within the window, nothing is said and the digital trim absorbs the difference.

## 7. Open decisions

1. **The workable window.** How far a channel may sit from the median before a
   physical gain change is demanded. Suggested starting point is 3 dB, being
   roughly where the attenuation cost starts to matter.
2. **The subwoofer's reference offset.** Section 4 gives the subwoofer an
   explicit offset from the full-range datum rather than a matched level. Its
   default value is undecided. Calibrating it to equal in-band spectral level
   is the defensible starting point, but most listeners then raise it, so the
   offset should probably be exposed rather than fixed.
3. **Whether level matching can be skipped.** A user who has already calibrated
   with an SPL meter may not want their trims touched.

## 8. Relationship to the existing specification

`automated_room_correction_spec.md` section 7.5 stands, with one change: its
statement that automatic channel level matching "remains a separate, opt-in,
post-version-1 discussion" is superseded by this document. Correction
compensation remains mandatory and is not replaced by level matching; the two
are summed.

Section 7.5's treatment of delay is unaffected. Magnitude correction does not
alter arrival times, so delay is still measured, retained and displayed but not
applied.
