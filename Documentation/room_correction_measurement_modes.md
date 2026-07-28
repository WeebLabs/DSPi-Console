# Room Correction: measurement modes

Status: agreed design

Last updated: 2026-07-28

Authoritative detail for what a measurement session drives, what it bypasses,
and what it leaves alone. Section 4.3 of `automated_room_correction_spec.md`
summarizes this and points here; if the two disagree, this file is correct.

## 1. The constraint everything follows from

**Host playback can only drive inputs.** The DSPi presents itself to CoreAudio
as an output device whose channels are the DSPi's USB *inputs*. A sweep always
enters at an input and emerges wherever the matrix, crossovers and bass
management send it. There is no way to inject at an output.

An earlier draft fixed measurement to physical outputs with a separately chosen
destination. That was wrong twice: it treated an input feeding several outputs
as a disqualifier, which refused the entire bass-managed surround case, and it
could not be built as written, since a nine-output device cannot be addressed
through an eight-channel playback path.

## 2. Two modes, one decision

What is measured and where the filters go are a single choice. They cannot be
picked independently.

### Input mode: measuring a system

Drive one input channel. Measure the complete acoustic result of that program
channel, across however many drivers reproduce it. Correct that input's PEQ
bank.

This is what 3.1, 5.1 and 7.1 need, and it is the right mode for a multi-way
speaker. Bass management splits front left into a high-passed L speaker and a
low-passed subwoofer; driving input L and measuring both together is exactly
the response that channel's correction should be built from. Fan-out is the
point, not an obstacle.

An input is measurable whenever it reaches something audible.

### Output mode: measuring one speaker

Force a known path from one input to one target output, and measure that
speaker alone. Correct that output's PEQ bank.

This is for individual speakers, and for systems where outputs feed different
things: speakers on one pair and headphones on another, where an input-side
correction would leak across both.

A multi-way speaker cannot be meaningfully corrected in this mode, because it
measures individual drivers rather than their summed acoustic result. That is a
property of the mode, not a defect.

## 3. What each mode touches

| | Input mode | Output mode |
|---|---|---|
| Input PEQ of the driven channel | bypassed | bypassed |
| Other input PEQ banks | untouched | untouched |
| Matrix routing | untouched | forced: one input to one output |
| Matrix gain and invert | untouched | forced to unity, non-inverted |
| Output PEQ of the measured channel | **untouched** | bypassed |
| Crossovers | untouched | untouched by default, see section 5 |
| Output trim and delay | untouched | untouched |
| Loudness, leveller, psybass, crossfeed, upmixer | disabled | disabled |

### Why output PEQ is treated differently in the two modes

In input mode the output PEQ must stay active. The correction lands on the
input, and the output PEQ is still there when the user listens, so a
measurement taken without it would produce a correction wrong by exactly
whatever that output PEQ does.

In output mode the output PEQ is bypassed, because the correction *replaces*
that bank. What was measured without is precisely what is being substituted
for, so the two are consistent.

### Why crossovers are not bypassed automatically

The same reasoning that permits bypassing output PEQ forbids bypassing
crossovers: **we replace the PEQ, we do not replace the crossover.** A crossover
is restored untouched after the session, so a measurement taken without it
describes a response the speaker will not produce, and the correction may
demand output in a band the crossover removes.

There is a safety argument as well, and it is the more serious one. The DSPi
provides four crossover bands per output with slopes to eighth order, so active
multi-way is a first-class use case. Bypassing an eighth-order high-pass at
2 kHz and sweeping from 20 Hz at measurement level will very likely destroy the
tweeter behind it.

The decisive observation is that an automatic bypass is **inert exactly when it
is justified and consequential exactly when it is not**. A user genuinely
measuring individual full-range speakers has no crossovers on those outputs, so
bypassing them changes nothing. The setting only has an observable effect in the
two cases where its premise is false: a multi-way system, where it can destroy a
driver, and a bass-managed one, where it produces an incorrect correction.

So the choice belongs to the user, informed, rather than to the app by
assumption. See section 5.

## 4. Stepping through outputs

Output mode measures **one output at a time**, reconfiguring the single forced
path between sweeps.

The correction core never needs simultaneous excitation: a fit takes one
channel's measurements across N positions and looks at nothing else. So there is
no reason to hold several paths open, and one at a time buys three things:

- it works regardless of the configured CoreAudio channel count, so a
  stereo-configured device can still measure nine outputs;
- there is no ambiguity about which input drives what;
- there is no batching logic when outputs outnumber addressable inputs.

The cost is reprogramming one matrix cell between sweeps, which is a handful of
USB writes against a sweep of several seconds.

## 5. The crossover prompt

Shown at Setup once outputs are chosen, never mid-measurement.

- Appears only if a selected output has an active crossover.
- Names each one specifically: "Output 2 has an 8th-order high-pass at 2 kHz."
- Is per-output rather than all-or-nothing, since a user may have a full-range
  main and a crossed subwoofer.
- Defaults to keeping the crossover. The app never bypasses one by default.

If the user chooses to bypass, the prompt states both consequences plainly:

- the sweep will play full range through that driver at measurement level;
- the correction will be derived from a response that differs from what they
  will hear, unless they leave the crossover off afterwards.

## 6. Level check

In output mode the level check runs **inside the forced measurement
configuration**, not against the user's normal routing.

A level validated on a different path does not describe what will play. This is
also why trim is left alone rather than zeroed: trim at 0 dB is unity, so
"zeroing" a tweeter trimmed to -15 dB hands back 15 dB, and any gain change made
after the level check invalidates it.

## 7. Reporting

After a session, tell the user what was restored.

For output mode, also report anything that was active during the measurement and
affected the result, so they can decide whether to change it and measure again.

If a crossover was bypassed at the user's request, the Results screen says so
explicitly: that the output had a crossover, that the user chose to disable it
for the measurement, and that the corrected response will differ once that
crossover is re-enabled.

Note that native-bandwidth detection will have seen the un-crossed rolloff,
which changes where boost is permitted, so the effect is not only cosmetic.

## 8. Consequences for state handling

Output mode owns considerably more device state than input mode: matrix routing,
matrix gain, matrix invert, input PEQ bypass and output PEQ bypass, changing
between sweeps rather than once per session.

- The recovery journal (spec section 8) already captures all of it.
- Restoration must put **routing back first**, before anything that depends on
  it.
- The "Restore Pre-Measurement Settings" offer becomes prominent rather than a
  quiet option, because an interrupted output-mode session leaves the matrix
  rewired.
- `DevicePreparing` needs a per-sweep configure and restore step, not only a
  session-wide prepare and restore.

## 9. Out of scope, deliberately

Raw driver measurement, meaning measuring a driver with its protection filters
bypassed, belongs to a future driver-correction feature rather than to room
correction. That feature would need its own safeguards: an explicit declaration
that the outputs are full-range, per-output sweep band limits derived from the
existing crossover, and a refusal to sweep below an output's high-pass corner.

Room correction must not acquire that capability as a side effect.
