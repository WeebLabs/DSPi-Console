# DSPi Console Automated Room Correction

Status: proposed product and technical specification

Branch: `room-correction`

Last updated: 2026-07-28

## 1. Product decision

DSPi Console should add a separate **Room Correction** window that guides a user through microphone setup, channel selection, repeatable multi-position measurements, target-curve design, filter calculation, review, saving, optional application, and verification.

The result should be described as **high-quality magnitude room correction** or **automated room EQ**, not as a Dirac Live replacement. Dirac Live uses proprietary mixed-phase processing and impulse-response correction. DSPi can nevertheless aim for similarly careful tonal results within its IIR/PEQ limits by making conservative decisions from several measurement positions and optimizing against the actual DSPi filter implementation.

The implementation should not be a direct Swift port of a Python algorithm. Measurement analysis and correction should live in a platform-neutral C++17 core with a small C ABI, while macOS and a future Windows application provide audio capture, UI, file dialogs, and device control.

## 2. Goals

- Let the user select any available input device and input channel.
- Accept an optional REW-compatible microphone calibration file, including UMIK-1/UMIK-2 files.
- Let the user choose a **measurement domain**: input channels, for surround layouts where bass management lives on the outputs, or output channels, for per-driver work. This determines both what is measured and where the filters go; the two cannot be chosen independently. See section 4.3.
- Play a host-generated logarithmic sweep through the DSPi as a CoreAudio output device, one channel at a time.
- Support an intended measurement count selected up front while allowing **Finish Measurements** after any complete position.
- Keep every individual channel/position measurement and show measurement quality immediately.
- Derive a robust correction from all accepted positions, with extra importance given to the main listening position.
- Offer a simple Dirac-style target editor: overall tilt, bass adjustment, treble adjustment, and low/high correction curtains.
- Generate only filters that the connected DSPi can reproduce.
- Save a portable, versioned room-correction project before hardware application is required.
- Let the user choose which measured channels to apply at the end.
- Never save to DSPi flash without a separate explicit action.
- Make cancellation, device loss, and partial USB writes recoverable.

## 3. Non-goals for version 1

- Mixed-phase or linear-phase correction.
- FIR generation or convolution.
- Automatic speaker/subwoofer time alignment.
- Automatic crossover design or bass management.
- Automatic room-treatment advice.
- Simultaneous multi-microphone capture.
- Correcting several seats independently with different filters.
- Claiming numerical or audible equivalence to a proprietary product.

Delay, polarity, channel-level diagnostics, and decay plots may be measured and retained for later features, but version 1 must not silently alter them.

The one deliberate exception is output trim. Version 1 does adjust it, but only by the amount needed to *preserve* the inter-channel balance the user already had, which a cut-only correction would otherwise disturb. That is a correction to an unintended side effect, not a calibration change, and it is disclosed in the results. See section 7.5.

## 4. Current DSPi Console baseline

The existing application already supplies much of the device-facing work:

- The current unified channel model allocates ten PEQ bands to every input and output channel, plus four separate crossover bands on outputs (wire band indices 20-23). The implementation must still query/use live device capabilities rather than bake this number into the correction core. Note that several checked-in documents (`CLAUDE.md`, `AGENTS.md`, `README.md`, `automated_room_eq.md`) still describe a stale pre-V16 model claiming two bands per output; they are wrong and should be corrected as part of this branch.
- `DSPMath` contains the DSPi biquad response and coefficient formulas, but **hardcodes `sampleRate = 48000.0`** (`DSPMath.swift:427`). See section 4.2.
- `DSPViewModel.setFilter` can apply a complete PEQ bank, input or output, over USB.
- `DSPViewModel.sampleRateHz` already exposes the live device sample rate (`REQ_GET_STATUS`, `wValue = 15`).
- `HostAudioFormatMonitor` already resolves the DSPi's CoreAudio device by serial and tracks its configured channel count, feeding `effectiveInputChannels`. Room Correction consumes that resolution rather than duplicating device discovery.
- `Commands.identifyOutput(_:)` fires a `CHANNEL_ID` ident at one output without disturbing unrelated user state. It is a useful Setup primitive for confirming physical speaker mapping, and the pattern to follow for any transient device action.
- The app has no microphone-capture layer, no audio playback layer, no microphone permission text, no room-correction document model, and no multi-write transaction. There is also no FFT and no CI workflow.

### 4.1 The firmware signal generator is not used

Room Correction does **not** use the firmware signal generator, in any role, including as a fallback. The reason is structural rather than a matter of preference: the generator injects **after the matrix mix, per matrix output**, so its signal never traverses the input preamp, input EQ, leveller, or upmixer. That has two fatal consequences for this feature:

1. It cannot exercise an input-side correction at all, so it can neither measure nor verify one. A verification sweep run through the generator after applying filters to an input bank would report *no change*, which is indistinguishable from a failed apply. Reporting a false negative precisely in the surround case is worse than offering no verification.
2. It would force two divergent measurement paths, one per destination, with different bypass requirements and different validity conditions.

Host playback traverses the same signal path the user's music does, which is the only path worth measuring. Section 4.3 defines it.

The generator remains a fine tool for its actual purpose and is untouched by this work. `identifyOutput` is still used in Setup, because identification is a transient cue rather than a measurement.

The Milestone 0 bit-exact model of the firmware sweep recurrence (`Research/RoomCorrection/room_correction/sweep.py`, verified against `siggen.c` on `release/v1.1.5`) is consequently **off the product critical path**. Retain it as research material and as a cross-check for the loopback fixture in section 12.2; do not port it to the production core.

### 4.2 Sample rate is a first-class correctness concern

Two facts interact badly and must be handled explicitly:

1. **Firmware designs biquads at the live sample rate.** `dsp_pipeline.c:248` computes `omega = 2*pi*freq/sample_rate` from the running rate, in **`float`** precision.
2. **`DSPMath` assumes 48 kHz in `Double`.** For the existing response graph this is a cosmetic inaccuracy. For room correction it is a modelling error the optimizer would bake into the result, because the optimizer's predicted response would not be the response the hardware produces. Bilinear frequency warping means the divergence is negligible at low frequencies and grows toward Nyquist, so it lands exactly where correction is already least trustworthy.

A third concern applied to an earlier design that used the firmware signal generator: it silently falls back to its 48 kHz coefficient row at any rate that is not exactly 44.1, 48, or 96 kHz, corrupting the sweep trajectory. Host playback authors the reference waveform on the host, so that constraint no longer applies and **the hard measurement-rate gate is withdrawn**. Rate still matters for filter prediction, which is what remains below.

Required behavior:

- The correction core takes sample rate as a parameter. No hardcoded 48 kHz anywhere in the measurement, prediction, or optimization path.
- Read `sampleRateHz` and the configured CoreAudio mode at session start, record both in the project, and re-check before applying. A rate or mode change mid-session invalidates the affected measurements.
- Biquad golden tests must run at every supported rate against each target's actual arithmetic: RP2350 float/SVF behavior and RP2040 Q28 behavior. High-Q low-frequency filters are where the paths diverge first. Do not impose RP2040/RP2350 response parity; identify the connected platform from the device capability fingerprint and predict, quantize, and verify for that platform.
- Either parameterize `DSPMath.sampleRate` or treat the portable core as the single source of truth and hold `DSPMath` to it with a parity test. Two independent implementations of the same RBJ math will otherwise drift.
- Author the sweep at the device's configured rate and never let CoreAudio resample it, or the reference no longer matches what is deconvolved. See section 4.3.

### 4.3 Measurement path and correction destination

**Host playback can only drive inputs.** The DSPi presents itself to CoreAudio as an output device whose channels are the DSPi's USB *inputs*, so a sweep always enters at an input and emerges wherever the matrix, crossovers and bass management send it. Everything below follows from that.

What is measured and where the filters go are **one decision, not two**. The full design, including the reasoning behind each choice, is in `room_correction_measurement_modes.md`; that file is authoritative if the two disagree. In summary:

**Input mode** drives one input channel and measures the complete acoustic result of that program channel, across however many drivers reproduce it, then corrects that input. This is what 3.1, 5.1 and 7.1 need, and what a multi-way speaker needs. Bass-management fan-out is the point rather than an obstacle. Only the driven input's PEQ is bypassed; the matrix, output PEQ, crossovers, trim and delay are left exactly as the user has them, because the correction lands upstream of all of them and they will still be there when the user listens.

**Output mode** forces a known path from one input to one target output at unity gain, non-inverted, with nothing else routed, and measures that speaker alone. It bypasses the driven input's PEQ and the target output's PEQ, and steps through outputs one at a time. This is for individual speakers, and for systems where outputs feed different things, such as speakers on one pair and headphones on another.

The two modes treat output PEQ differently for a reason worth stating: **we replace the output PEQ, we do not replace the crossover.** Bypassing the PEQ bank in output mode is consistent because the correction overwrites that bank. A crossover is restored untouched afterwards, so measuring without one would describe a response the speaker never produces.

Crossovers are therefore **never bypassed automatically**. An automatic bypass would be inert exactly when it is justified, since a user measuring genuinely full-range speakers has no crossovers to bypass, and consequential exactly when it is not: it can destroy a tweeter behind an eighth-order high-pass, or produce a correction that demands output in a band the crossover removes. Where a selected output has an active crossover, Setup names it and offers the choice, defaulting to keeping it.

Two constraints apply to both modes. Outputs disabled in the matrix render silence. And only channels the configured CoreAudio mode can address are drivable, so a device configured for stereo cannot be measured as 7.1 however the matrix is wired.

The upmixer is a warning rather than a refusal in either mode. It derives channels downstream of the input EQ, so a correction on one input also changes what is derived from it.

Crossovers, output routing, speaker amplifiers, and the room remain part of the measured system in both modes.

## 5. User experience

### 5.0 Design intent

Room Correction is the most visible feature DSPi Console will ship, and it is the one users will judge the product by. It has to satisfy two audiences that are usually treated as opposed: someone running their first measurement, who needs to be led without being condescended to, and someone who already owns REW and Dirac, who will abandon the tool the moment it hides something they need. The resolution is not a "simple mode" toggle. It is **progressive disclosure with nothing amputated**.

Three tiers, applied consistently:

1. **The primary path is always visible.** One clear action per screen, a large live graph, and honest status. A first-time user can complete a correct measurement without opening anything.
2. **Expert controls are one interaction away**, in an inspector panel or a disclosure group on the same screen. Sweep range and duration, per-position weights, smoothing policy, curtains, Q and boost limits, band budget, target anchor points. Visible on demand, never buried behind a preference window, never requiring a restart.
3. **Deep diagnostics live in the menu bar.** Impulse response and step response, spectrogram, harmonic distortion products, group delay, decay/waterfall, raw capture export, optimizer objective history, per-band contribution breakdown. These belong to the small group who want them and should not compete for space with anything else.

The tone should be confident and calm rather than playful. "Fun" here comes from responsiveness and craft, not decoration: a sweep that draws itself as it plays, a response curve that animates into place instead of snapping, a position card that settles into the list with its quality badge already resolved. The existing `AnimatableVector`/`BodeLineShape` work in `GraphView.swift` already establishes this vocabulary and should be extended rather than replaced.

**The graph is the hero.** It is not an illustration beside the controls; it is the workspace, and it should take the majority of every screen from Measurements onward. Requirements:

- log frequency axis, adjustable dB range, pinch and scroll zoom, and a persistent cursor readout showing frequency, level, and which trace is under the pointer;
- an overlay manager: every position individually toggleable, the spatial average emphasized, the spread rendered as a translucent band rather than a thicket of lines;
- a smoothing selector that re-renders live, defaulting to the variable policy in section 6.3 but exposing fixed fractional-octave options for users who think in those terms;
- before, after, target, and correction-only traces, each independently toggleable, with a difference view;
- direct manipulation of the target curve with draggable handles, **and** numeric entry for every value the handles control. Professional users type numbers; new users drag. Neither should be a second-class path.

**Platform-native, not a reskin.** Use the macOS inspector pattern, standard toolbars, SF Symbols, system materials and vibrancy, and full light/dark support. Do not build custom window chrome. Respect the conventions already established in `Components.swift` (`ValueField`, `CustomSlider`, `BorderlessPopUpButton`) so the window feels like part of Console rather than a visiting application, and follow the project rule that stacked rows align on fixed-width columns regardless of content length.

**Interaction requirements that are easy to skip and expensive to retrofit:** full keyboard navigation including a shortcut to trigger the next measurement without reaching for the mouse; VoiceOver labels on every control and a textual summary of each graph; Dynamic Type; reduced-motion honored for every animation described above; and every destructive or device-mutating action reversible or confirmed.

**Anti-patterns, stated so they are not rediscovered:** no modal wizard that traps the user with no way back to a previous step; no single green check standing in for measurement quality (section 5.6); no progress bar without a cancel; no silent failure or silently degraded measurement; no expert control that exists only in a config file; and no gauge, dial, or skeuomorphic meter that consumes space a real graph could use.

### 5.1 Entry and window behavior

Add **Tools > Room Correction…**. Opening it creates or focuses one independent resizable window. A single active measurement session owns the DSPi's audio playback path and its temporary DSP state. Starting Test Signals, or anything else that would drive or reconfigure the device, while a measurement is active should offer to stop Room Correction first.

The window uses a persistent left-side step list and one primary action per screen:

1. Setup
2. Level Check
3. Measurements
4. Target
5. Results
6. Apply & Verify

Closing during an active measurement asks whether to stop and retain the draft. Closing at any other time autosaves the draft.

### 5.2 Setup

The Setup screen contains:

- Connected DSPi device and firmware/capability status, including the live sample rate and the configured CoreAudio mode and channel count as reported by `HostAudioFormatMonitor`. Present the configured mode as fact, not as something to change here.
- Microphone/input device picker using stable device UID, not display name alone.
- Input-channel picker when the device has multiple inputs.
- Live input meter and clipping indicator.
- Calibration-file field with **Choose…**, **Clear**, file summary, and validation status.
- Calibration orientation note. For a UMIK-1, show whether the loaded filename appears to be a 0-degree or 90-degree file, but do not infer correctness solely from the filename.
- Speaker checklist, one entry per matrix output, populated from DSPi channel names. Outputs disabled in the matrix, or not addressable in the configured CoreAudio mode, must be shown as unavailable with the specific reason.
- An **Identify** control per listed speaker, reusing `Commands.identifyOutput(_:)`, so the user can confirm which physical speaker each channel drives before measuring. Mapping a correction to the wrong speaker is a common and completely silent failure in automated room correction, and this is a cheap defence against it.
- **Correction destination** picker: input banks or output banks (section 4.3). Show the resolved input-to-output mapping the app derived from the matrix. Disable the input option, with the disqualifying routing named, when the mapping is not one-to-one.
- Per-channel role: Full range, Bass limited, or Subwoofer. Infer an initial role from active crossovers and name, but let the user change it.
- Measurement plan: Quick (3), Recommended (5), Wide (9), or Custom (1–21).
- Listening-area choice: Single seat, Sofa, or Wide area. This changes position guidance and weights, not the DSP algorithm contract.
- PEQ ownership warning, **naming the destination bank actually being consumed**. Version 1 room correction owns and replaces the complete ordinary PEQ bank of each destination channel; this is fixed behavior, not a policy choice. The Milestone 0 corpus saturated all ten bands in five of eight scenarios, so sharing the bank with pre-existing manual EQ is not viable in the general case. This warning matters more for the input destination, since input banks are where users typically keep tone controls and house EQ. The screen must say plainly which channels lose their ten PEQ slots, that crossovers are preserved, and that the original banks are restored unless Apply succeeds.

The primary button is **Continue to Level Check**. It remains disabled until a DSPi, a microphone input, at least one measurable speaker, and a valid correction destination are available.

### 5.3 Microphone calibration

Accept plain-text `.cal`, `.txt`, and `.csv` files in the format REW documents:

- frequency in Hz;
- gain in dB;
- optional phase in degrees;
- whitespace, tab, or comma separators;
- comments or other lines ignored unless they begin with a number;
- at least two strictly increasing frequency rows;
- optional `Sens Factor =...dB` or `Sensitivity ... dBFS` header.

Interpolate gain on log frequency and subtract the microphone's measured response from the acoustic measurement. Phase values may be stored but are not used for version 1 correction. Do not extrapolate an increasingly large correction outside the calibration file: hold the first/last value and warn when the correction range exceeds the file range.

A calibration file is recommended, not mandatory. An uncalibrated mic gets a persistent warning: relative low-frequency correction may still be useful, but full-range tonal accuracy is unknown. Absolute SPL is shown only when sensitivity information is present and the selected input's gain relationship is known; otherwise use dBFS and relative dB.

Remember calibration-file selection per stable microphone UID. Do not copy the user's calibration file into the application bundle.

### 5.4 Level check

Level Check prevents most invalid and unsafe sessions:

1. Capture two seconds of room noise.
2. With an explicit **Play Level Check** action, play host-generated band-limited pink noise through one representative selected speaker, using the same playback path the sweeps will use.
3. Start at a conservative playback level, default `-40 dBFS`, and let the user increase it up to the session sweep level.
4. Default sweep peak level is `-20 dBFS`; expose a range of `-30…-12 dBFS` in the normal UI. An Advanced control may permit a wider range with a warning.
5. Show microphone peak, RMS, estimated signal-to-noise ratio, and DSPi clip flags.
6. Require no clipping and recommend at least 30 dB broadband SNR. Permit continuation below the recommendation with a warning, not below a hard validity floor of 15 dB.

The app must not automatically raise master volume or output gain. It may tell the user to set their normal listening volume. Stop output immediately if the microphone input or DSPi reports clipping.

### 5.5 Measurements

Position 1 is always the **Main Listening Position** and has the largest default optimization weight. Later cards guide the mic around the listening area. The mic must remain at ear height and keep the calibration file's intended orientation.

Each position is a transaction:

1. User places the mic and presses **Measure Position**.
2. Capture begins before playback starts.
3. Measure the room-noise floor.
4. For each selected speaker, render one logarithmic sweep into that speaker's channel slot and play it once through the DSPi, with all other slots silent.
5. Keep a silent pre-roll and post-roll around the sweep.
6. Stop capture after the last response tail.
7. Analyze every channel and show pass/warn/fail results.
8. Accept the position only when every selected channel has a valid measurement; alternatively let the user retry just a failed channel.

Because playback is now a host responsibility, a stalled or glitching output stream is a measurement failure mode rather than a device concern. Underruns, dropped buffers, App Nap, and a mid-session format change must all be detected and must invalidate the affected sweep rather than quietly degrading it. Suppress App Nap for the duration of a session.

Default sweep plan:

| Role | Analysis range | Sweep range | Duration |
|---|---:|---:|---:|
| Full range | 20 Hz–20 kHz | 10 Hz–22 kHz | 8 s |
| Bass limited | 20 Hz–20 kHz | 10 Hz–22 kHz | 8 s |
| Subwoofer | 10 Hz–500 Hz | 5 Hz–1 kHz | 12 s |

The actual upper limit must remain below the Nyquist limit of the configured CoreAudio mode. Sweep ranges are advanced settings. Crossovers remain active during every sweep. Sweeps are played once each; repeated sweeps at one position are separate captures and are never coherently averaged without explicit alignment.

The sweep is authored at the device's configured rate so CoreAudio performs no rate conversion on the way out. Verify that before the first sweep and abort with a clear explanation if it cannot be satisfied, rather than measuring against a reference the device did not actually emit.

**Session duration should be shown before the user commits to a plan.** Elapsed time scales as positions times channels times sweep length plus per-position mic movement. A five-position, two-channel session is a few minutes and unremarkable. A nine-output RP2350 system at twenty-one positions is roughly 189 sweeps and over half an hour of continuous work, which is a very different proposition and one the user should not discover partway through. Display the estimate on the Setup and Measurements screens, and let the plan and sweep duration be adjusted in response to it. This is also the argument for allowing shorter sweeps on large plans: the low-frequency signal-to-noise cost of a shorter sweep is often a better trade than a session the user abandons.

After the first accepted position, show both **Measure Next Position** and **Finish Measurements**. Finishing before the selected plan count is always allowed. With only one position, explain that correction will be optimized for a small listening area and will be less protected against local nulls.

Accepted positions can be renamed, disabled, deleted, remeasured, or assigned a weight before calculation. Default weights are 2.0 for the main position and 1.0 for other positions. A disabled position is retained in the project but excluded from calculation.

### 5.6 Measurement quality feedback

Do not reduce validity to a single green check. Retain and display:

- input peak and clipping count;
- DSPi clip state during the sweep;
- broadband and per-band SNR;
- detected sweep start/end and capture completeness;
- estimated sample-rate mismatch/time stretch;
- dropouts or discontinuities;
- harmonic energy/distortion estimate when the sweep analysis can separate it;
- response repeatability when a retry exists;
- calibration-file coverage.

Hard failures include clipping, a missing or truncated sweep, device change, playback-stream interruption (underrun, dropped buffer, format change), or a response too close to the noise floor. A high-noise band may be excluded from correction while the rest of the measurement remains usable.

### 5.7 Target editor

The Target screen shows one tab per channel group and can overlay:

- each position in a faint trace;
- robust spatial average in a strong trace;
- spatial spread as a shaded band;
- target curve;
- proposed correction range;
- predicted corrected response after calculation.

Use a simple default editor inspired by mature room-correction tools:

- **Overall tilt** in dB/octave, centered at 1 kHz;
- **Bass** in dB with an adjustable transition frequency;
- **Treble** in dB with an adjustable transition frequency;
- **Low curtain** and **High curtain** defining the correction range;
- vertical target level, with an **Auto** button.

All four tonal controls may be positive or negative. Defaults should favor a gentle downward in-room trend rather than forcing a visually flat line. Provide presets such as Natural, Flat, Studio, and Bass Warm, but define them as ordinary editable control values, not special algorithm modes.

Every one of these controls is manipulable **both** as a handle dragged directly on the target curve and as a typed numeric value, per section 5.0. Dragging the tilt rotates the curve about its 1 kHz pivot; dragging a curtain slides a shaded exclusion region across the graph so the correction range is a visible thing rather than a pair of numbers. The predicted result updates live during the drag, because the entire point of a curve designer is seeing the consequence while deciding.

Expert affordances, in the inspector rather than the primary column:

- **Free-form target points.** Beyond tilt/bass/treble, allow arbitrary anchor points with adjustable interpolation, so a user with a specific house curve in mind is not forced through three macro controls. This is what separates a curve designer from a tone control.
- **Import and export target curves** as REW-compatible text, so an existing house curve can be brought in and a chosen target can be shared.
- **Per-channel curtain and target overrides** when a channel is unlinked from its group.
- **Band budget** for this channel, so a user can deliberately reserve slots.
- **Boost policy and Q limits**, surfaced read-only in the primary view and editable here, with the safety consequences stated inline rather than in a manual.

Show the required headroom and the resulting broadband level change continuously as the target is edited, not only after calculation. A target that will cost 8 dB of headroom should reveal that while the user is dragging toward it.

Channels with similar roles share a target shape by default but receive separately optimized filters. Users can unlink a channel from its group. Do not force a subwoofer and a full-range speaker to share curtains.

Auto target generation should:

- fit the broad trend of the robust response;
- keep the target inside the channel's reliable measured bandwidth;
- avoid demanding boost below the speaker's natural low-frequency roll-off or above its useful high-frequency extension;
- choose a vertical target level that minimizes required boost;
- preserve the user's requested bass/treble/tilt offsets.

### 5.8 Results

Calculation is explicit and cancelable. Results show, per channel:

- uncorrected spatial response and spread;
- target;
- predicted response at every position;
- robust predicted average;
- correction-only response;
- generated filter table;
- used/available band count;
- maximum combined boost and required headroom;
- before/after error metrics for the full range and low-frequency range;
- warnings for uncorrectable regions.

The user can adjust the target and recalculate without remeasuring.

The filter table is an editable, professional-grade surface, not a read-only report:

- every generated band shows type, frequency, gain, Q, and its individual contribution, and can be **locked** so recalculation optimizes only the remaining bands;
- any band can be hand-edited, with the predicted response updating live and a clear indicator that the result is no longer purely automatic;
- bands can be disabled individually to audition their contribution;
- hovering a band highlights its curve on the graph, and hovering a graph feature highlights the responsible bands;
- the table exports to the existing DSPi Console filter text format directly from this screen.

Also show, per channel: which destination bank the filters will be written to, the band budget consumed against what is available, and the balance-preserving compensation that will be applied (section 7.5). A user should never reach the Apply screen unsure of what is about to change.

### 5.9 Save, apply, and verify

Offer these separate actions:

- **Save Project…** saves measurements, settings, target, and calculated result.
- **Export Filters…** writes the existing DSPi Console text format for interoperability.
- **Apply to DSPi…** opens a final checklist of measured channels. All are selected by default; any subset may be applied.
- **Save to Current Preset…** appears only after a verified live apply and remains a separate confirmation.

Applying is a best-effort transaction:

1. Capture a fresh snapshot of every destination PEQ bank.
2. Confirm the connected device identity and capability fingerprint still match the calculation.
3. Write every band of each destination channel, clearing unused bands to Off, and write the destination gain for each applied channel: the correction's trim, its balance-preserving compensation, and the level match, as one value (section 7.5). Write whichever of the two is the quieter first. The bands carry the untrimmed cascade and the gain carries the trim, so writing the bands ahead of a falling gain puts the whole of that boost on the output in between.
4. Read back every band and every compensation value.
5. On any mismatch, restore all affected banks and compensation values and report exactly what failed.
6. Mark normal preset state as unsaved; do not write flash.

Confirm before writing that the matrix routing still matches the mapping recorded at calculation time. A routing change between measurement and apply invalidates an input-destination result even though every band would write successfully.

After application, offer **Verify Correction**. It repeats a sweep at the main position with the new filters active and overlays measured-after, predicted-after, and target. Because playback now traverses the whole chain, verification works identically for both destinations; this is the specific capability that device-side generation could not provide (section 4.1). Verification is the strongest way to catch routing mistakes, gain changes, or a poor model, and should be considered part of the recommended flow.

Provide a level-matched **Correction Bypass** audition control after application. Level matching is essential; a louder result must not win merely because it is louder.

It must move both halves together. The destination gain sits outside the PEQ bank, so clearing the bands alone leaves the level where the correction put it and the comparison becomes a loudness test. Bypassed is a flat bank at `datum + levelMatch`, which is the level the corrected channel averages to (section 7.5); engaged is the plan's bands at its own gain. The two therefore match by construction rather than by measurement. Per-band bypass is the wrong mechanism: it cannot carry the gain, and it needs firmware 1.1.4.

The control changes the live device and is not the rollback path, which restores the user's own EQ rather than the correction. Leaving the screen leaves the device in whichever state the control is in, and the screen must say so.

## 6. Measurement processing

### 6.1 Latency and clock handling

Variable acoustic/audio latency is not a blocker for magnitude correction. It shifts the captured sweep in time but does not alter the transfer magnitude.

**Host playback does not reduce the number of clock domains, and must not be assumed to.** Two USB audio devices attached to the same Mac remain two independent clock domains: the microphone free-runs on its own crystal, and the DSPi clocks its DAC from its own. Playing the sweep from the host changes where the samples originate, not which oscillator emits them, so the DSPi DAC clock and the microphone ADC clock are exactly as independent as they were with device-side generation. CoreAudio does not merge those domains; at most it resamples between them.

The practical magnitude is small. At a plausible worst case of about 100 ppm relative offset, a 10 s sweep drifts roughly 1 ms. For an exponential sweep that maps to a frequency error near 0.07%, which is irrelevant to magnitude correction. The consequence that does matter is impulse-response smear: 1 ms is comparable to a 6-cycle frequency-dependent window at 10 kHz (0.6 ms), so uncompensated drift degrades the high-frequency windowing in section 6.3 well before it affects frequency accuracy.

The analysis therefore uses this policy:

1. Start capture before playback.
2. Detect the recorded sweep rather than assuming a host timestamp is the acoustic start.
3. Fit its observed start, end, and logarithmic frequency trajectory.
4. Estimate the small time stretch between the emitted and recorded sweep.
5. Resample/time-warp when the estimated mismatch is large enough to affect the impulse response or the magnitude bins, using the windowing threshold above rather than a magnitude-only one.
6. Treat the estimate as a measurement-quality metric, not a shared-clock requirement.

A CoreAudio aggregate device with drift correction is a reasonable additional mitigation, since it resamples one device onto the other's clock before the data reaches us. It is not a substitute for the stretch estimate, which still serves as the quality metric.

### 6.2 Sweep extraction

Use an exponential/logarithmic swept-sine analysis based on the established Farina method:

- render the reference sweep on the host in double precision, from an explicit analytic definition owned by the portable core;
- locate it in the capture by matched correlation or sweep-ridge detection;
- compensate any fitted time stretch;
- deconvolve against the analytic inverse filter to obtain the linear room impulse response and, where reliable, separated harmonic components;
- discard absolute phase for correction;
- derive magnitude from the calibrated linear response.

Host authorship removes an entire class of problem that device-side generation carried. The emitted waveform is exactly the waveform the analysis holds, so there is no firmware phase law to mirror, no fixed-point increment quantization to model, no platform-specific oscillator kernel, and no rate-row fallback to guard against. The reference and its inverse filter are two functions in the portable core, testable in isolation on any platform.

Sweep definition requirements:

- exponential frequency trajectory `f(t) = f1 * (f2/f1)^(t/T)`, evaluated in double precision;
- raised-cosine fade in and out, long enough to suppress edge splatter and short enough not to erode the usable band, applied identically to the reference and to the inverse filter;
- the analytic Farina inverse: the time-reversed sweep with a -6 dB/octave amplitude envelope, so that sweep convolved with inverse yields an impulse;
- rendered at the device's configured sample rate, with no resampling anywhere in the output path.

Use one longer sweep rather than synchronous repetitions, since playback and capture remain on separate clocks. A failed or noisy measurement is retried as a new capture and is never coherently averaged without alignment.

### 6.3 Response preprocessing

For each channel and position:

1. Remove DC and obvious capture discontinuities.
2. Estimate the pre-sweep noise spectrum.
3. Extract the linear impulse response.
4. Apply **frequency-dependent windowing** to the impulse response.
5. Apply microphone magnitude calibration.
6. Convert to a 96-points-per-octave log-frequency grid.
7. Mark bins whose SNR is below threshold.
8. Retain the original high-resolution unwindowed response for export and diagnostics.
9. Create a correction response with variable fractional-octave smoothing.

**Frequency-dependent windowing (step 4).** Windowing and smoothing are not interchangeable and the pipeline needs both. A fixed gate applied across the whole band either truncates the modal decay that dominates the low frequencies or leaves the full reflection pattern in the high frequencies. Frequency-dependent windowing resolves this by making the effective window length a constant number of periods: long in absolute time at low frequencies, short at high frequencies. A window of roughly 6 to 15 cycles is the conventional range; start at the wider end, because an over-tight window discards real speaker behavior along with the reflections.

Below the transition frequency (section 6.5) the window should approach the full measured response, so that room gain and modal behavior are represented as the listener actually experiences them at steady state. Above it, the window tightens toward the cycle-based rule.

Doing this before smoothing matters: windowing removes seat-specific reflection structure in the time domain, where it actually lives, whereas smoothing merely averages it away in the frequency domain and blurs genuine narrow speaker features at the same time. Applying windowing first means the subsequent smoothing has less work to do and destroys less real information.

**Smoothing (step 9).** The initial variable smoothing should be approximately 1/48 octave below 100 Hz, transition toward 1/6 octave around 1 kHz, and approach 1/3 octave above 10 kHz. The high-frequency treatment intentionally follows broad tonal balance rather than seat-specific comb filtering. Prefer to express these breakpoints relative to the estimated transition frequency rather than as fixed absolutes, so the policy adapts to the room rather than assuming a typical one. Keep the smoothing policy versioned and test it perceptually; it is a tuning parameter, not a wire-format promise.

### 6.4 Multi-position model

Do not collapse measurements to a simple arithmetic average and discard the rest.

For each channel and frequency bin, compute:

- a weighted robust location in log magnitude (Huber estimator);
- weighted median;
- weighted median absolute deviation/spatial spread;
- fraction of positions whose error has the same sign;
- SNR/reliability weight.

The robust curve is used for filter seeding and display. Final filters are optimized against **all enabled positions jointly**. This retains the information needed to avoid fixing one seat at the expense of the others.

**The averaging domain must be stated explicitly, because it changes the answer.** Averaging in log magnitude (dB) lets a single deep null dominate the result: a position sitting in a -30 dB cancellation pulls the mean down far harder than the physically meaningful loss of energy justifies, and the correction then tries to compensate for a hole that exists at one seat. Averaging in the power domain weights positions by energy, so nulls contribute little and the average reflects what the listening area actually receives. Power averaging is the acoustically defensible default for spatial averages and is standard practice in the loudspeaker literature.

The recommendation is therefore:

- compute the primary location estimate as a **weighted power (RMS) average**;
- compute the robust dB-domain statistics (Huber location, median, MAD, sign agreement) alongside it, and use them for spread visualization, outlier and bad-position detection, and reliability weighting;
- never let a single position's null drive a boost, which the sign-agreement and spread terms already guard against.

A Huber estimator in the dB domain is itself fairly null-resistant, so this is a refinement rather than a correction of the existing design, but the choice should be recorded in the algorithm version because it is not neutral.

### 6.5 Transition frequency

The single most consequential structural decision in room correction is where the modal region ends and the statistical region begins. Below that transition, room behavior is dominated by discrete, high-Q, position-stable modes that are minimum-phase and genuinely correctable with a biquad. Above it, behavior is dense, position-dependent interference that must not be corrected literally at any seat. Products that sound natural treat these two regions differently; products that sound over-processed apply one policy across the whole band.

The classical estimate is the Schroeder frequency, `f = 2000 * sqrt(T60 / V)` with volume in cubic metres, which for a typical domestic room lands somewhere around 100 to 250 Hz. Requiring the user to enter room dimensions and a reverberation time to evaluate it is both a poor experience and unreliable.

Prefer to **estimate the transition empirically from the measurements themselves**, which the multi-position data already supports. The spatial spread computed in section 6.4 is the natural discriminant: below the transition, positions largely agree and spread is low and slowly varying; above it, spread rises sharply and position-to-position correlation falls away. Fitting the frequency at which that behavior changes yields a per-room, per-channel transition estimate with no user input, no room measurements, and no assumed reverberation time.

This estimate should then drive, rather than be reported alongside, the following:

- the frequency-dependent window transition (section 6.3);
- the smoothing breakpoints (section 6.3);
- the Q and boost limits (section 7.3), which should tighten above the transition;
- the confidence with which any boost at all is permitted.

Fall back to a fixed default near 200 Hz when only one position exists, and say so in the UI, because a single position cannot distinguish a room mode from a seat-specific cancellation at all. This is the strongest technical argument for measuring more than one position and should be presented to the user in those terms.

## 7. Correction algorithm

### 7.1 Design principles

The quality target is a conservative, spatially robust correction:

- cut resonances that are common across positions;
- boost only broad, consistent deficiencies;
- do not fill narrow cancellation nulls;
- do not extend a speaker beyond its measured passband by default;
- use less narrow correction as frequency rises;
- prefer fewer, lower-Q filters when two solutions measure similarly;
- optimize the exact cascade the DSPi will run;
- maintain digital headroom.

This differs materially from applying AutoEq unchanged. AutoEq is an excellent MIT-licensed reference for PEQ initialization, constrained optimization, shelf support, and sharpness penalties, but its primary problem is fitting one headphone response. DSPi's core should adapt those ideas to a multi-position room objective.

### 7.2 Target error

For channel `c`, position `p`, log-frequency bin `k`, let:

- `M(c,p,k)` be calibrated measured magnitude;
- `T(c,k)` be the target magnitude including its automatically selected vertical level;
- `F(theta,k)` be the exact magnitude response of the candidate DSPi filter cascade;
- `R(c,p,k) = M(c,p,k) + F(theta,k) - T(c,k)` be residual error.

Minimize a deterministic objective of the form:

```text
J(theta) = sum(wPosition * wFrequency * wReliability * Huber(R))
         + overshoot penalty at every position
         + positive-correction/headroom penalty
         + unused-headroom penalty
         + filter sharpness and high-Q penalties
         + small per-filter complexity penalty
```

The **unused-headroom** term exists because the rest of the objective is
level-invariant. A shared offset is subtracted before the error is scored -
correctly, since one trim applies to the whole channel and the balance
compensation restores level afterwards - and the consequence is that the
correction's absolute level is a free variable. Without a term charging for it,
a correction sitting 7 dB below the combined ceiling scores exactly the same as
one sitting on it, so nothing stops the fit spending a band on a broad cut that
does nothing for shape and simply turns the channel down.

No metric in section 9 could detect this, because they all level-normalise for
the same reason. It surfaced only as a predicted response drawn lower than it
needed to be, with `maxCombinedCorrectionDb` measured 6.59 dB under
`combinedCeilingDb` on the cancellation fixture. That difference is now
reported by the corpus harness and gated.

The term penalises only being *below* the ceiling. Exceeding it stays a
structural matter for the trim and must not become a penalty the error term
could outbid.

Sampling uniformly in log frequency gives roughly equal importance per octave. The main listening position's default weight is 2.0; all other positions default to 1.0.

The overshoot term should be evaluated per position, not only on the average. It prevents a boost that helps a local dip while making another seat excessive. Spatial spread and sign agreement reduce the reliability weight for disputed narrow features.

### 7.3 Constraints

Initial safe defaults:

| Parameter | Default constraint |
|---|---|
| Combined correction boost | no more than 0 dB after target-level placement, with 0.5 dB safety margin |
| Individual cut | no less than -12 dB |
| Optional individual boost | no more than +3 dB in Advanced mode |
| Boost Q | no more than 2.0 |
| Cut Q below 200 Hz | no more than 10.0 |
| Cut Q at/above 10 kHz | no more than 3.0, interpolated above 200 Hz |
| Shelf Q | normally 0.5–1.0 |
| Center frequency | inside correction curtains and reliable measured bandwidth |

No-boost is the normal mode. It is achieved by choosing target vertical level so the complete correction cascade remains at or below `-0.5 dB`, not merely by forbidding positive gain on each individual band. This gives predictable headroom while still allowing overlapping filter shapes.

**That ceiling is a property of the trimmed curve, and it is only real once the trim is applied.** The optimizer's error term is level-blind by design, so the raw cascade's absolute level is a free variable: on the corpus it lands between 0 and +18.3 dB, and `requiredTrimDb` slides it down to the ceiling before anything is scored, gated, or plotted. The filter recipes alone therefore do not describe the correction that was designed. The trim must travel with them to the destination gain, or the device runs that much hotter than every guarantee made here - including the no-boost mask, which the fit satisfies on the trimmed curve and the hardware would then violate by exactly the trim. The first implementation omitted it and would have applied corrections up to 18 dB hot; it is now pinned by tests at both the plan and the applier layer.

Advanced boost mode must show required headroom and reduce gain before the first boosting stage if the DSP signal path supports that safely. Until the firmware signal path and internal saturation behavior are verified, it must never apply an uncompensated positive combined response.

Use a no-boost mask for:

- narrow deep notches;
- bins with low SNR;
- regions where enabled positions disagree in sign;
- frequencies below/above native extension;
- regions with excessive spatial variance.

### 7.4 Filter allocation and optimization

For each measured speaker, targeting its resolved destination channel (section 4.3):

1. Determine available supported PEQ bands from the live device model for that destination channel.
2. Build the robust target-error curve.
3. Add a low or high shelf candidate only when broad error of the same sign persists for at least half an octave.
4. Seed a peaking filter at the remaining error feature with the greatest area, not merely the deepest point.
5. Estimate initial Q from feature bandwidth and clamp it by frequency/sign constraints.
6. Jointly optimize all current filter parameters against every position.
7. Add another candidate only while it materially improves cross-position error.
8. Drop filters with negligible gain or benefit and re-optimize.
9. Quantize exactly as the DSPi write path will quantize. The on-wire representation and resolution of frequency, Q, and gain in `REQ_SET_EQ_PARAM` must be established from the firmware and pinned by a test before the optimizer assumes anything about it; an optimizer that converges to a precision the wire cannot carry will produce a result that does not match the hardware.
10. Re-optimize free gains after quantization and evaluate with the exact platform-specific coefficient/storage path and the **live device sample rate** used by firmware (section 4.2). Do not assume an RP2350 result is interchangeable with RP2040 fixed point, especially for sensitive low-frequency/high-Q sections.

The Milestone 0 source audit pins that contract at DSPi firmware commit `9776c2f9feb5a1f8487180a351f8fbb1ec67e4ff`: `EqParamPacket` carries frequency, Q, and gain as IEEE-754 float32; the current Swift write path rounds gain to 0.1 dB before sending; firmware clamps frequency to 10 Hz–0.45 Fs and Q to 0.1–20. RP2350 uses float32 coefficients (and an SVF below Fs/7.5 whose intended magnitude is RBJ-equivalent); RP2040 converts the float-designed coefficients to Q28 and processes fixed-point samples. Golden tests must distinguish host gain rounding, recipe/wire precision, coefficient storage, and per-sample arithmetic rather than calling all four “quantization.” The current host gain grid costs 0.077–0.138 dB in most corpus scenarios and 0.363 dB on the shelf-bearing house-curve scenario, more than the entire hygiene-weight sweep. Removing Console's 0.1 dB rounding is therefore the first Milestone 1 implementation task: retain full precision internally, send float32 gain directly, and pin the revised write path with golden tests.

Use multiple deterministic starts around the seeded solution to reduce local-minimum sensitivity. Record the algorithm version, configuration, random seed, convergence reason, and objective history in the project.

The Milestone 0 objective uses pseudo-Huber loss, softplus hinges, and smooth maxima so finite-difference optimizers are not being compared on avoidable discontinuities. Initial four-band screening favored SLSQP over finite-difference L-BFGS-B; that historical timing is not a hardware-budget runtime claim. At the real ten-band budget, SLSQP with a 400-iteration cap converged the full candidate in 8/8 corpus scenarios with three starts. The initial portable production candidate is therefore **NLopt/SLSQP**, with the Python SLSQP result retained as the behavioral oracle. L-BFGS-B/LBFGS++ may be reconsidered only if analytic gradients or a better-conditioned parameterization demonstrate a clear runtime, convergence, or dependency advantage on the frozen ten-band corpus. Do not encode optimizer identity in the public project format.

Soft hygiene weights must be selected by a frozen neutral-metric sweep while hard safety constraints remain fixed. Milestone 0 selected 0.25× of the original penalty preset because it was the only tested 0/0.125/0.25/0.5/1.0 row to converge in all eight ten-band scenarios. The one-start rows had different convergence counts, unlike the production three-start run, and the neutral metrics barely changed from 0.125× through 1.0×; the evidence does not establish a performance knee. Weight values are algorithm-version inputs, not user-facing controls.

### 7.5 Channel symmetry and grouping

Grouped channels share target **shape**, not filters. Each channel receives filters calculated from its own measurements. This retains tonal consistency without pretending left and right speakers have identical room interactions.

**Preserving relative level is not the same as doing nothing, and the no-boost policy makes this mandatory rather than optional.** A cut-only correction lowers a channel's broadband level by roughly the average depth of its cuts. Because every channel has a different room interaction, each one loses a different amount. A channel whose correction happens to be gentle emerges louder than a channel that needed deep modal cuts, so applying correction silently re-balances the system even though no level control was touched. On a stereo pair this shifts the phantom image; on a multichannel layout it degrades the whole spatial presentation. The result is that an otherwise correct tonal correction can be judged as sounding worse, for a reason that has nothing to do with tonality.

Version 1 must therefore:

- compute, per channel, the broadband level change the correction introduces, weighted over the correction band;
- compensate it so that the pre-correction relative balance between channels is preserved, using **output trim** for an output-destination correction and the **per-input preamp** for an input-destination correction;
- report the applied compensation and the pre-existing broadband level differences, and include the compensation in the snapshot and rollback path.

**The compensation is relative, and no destination gain may be positive.** Only the differences between channels carry the balance, so the absolute level of the whole set is free. Spending that freedom on makeup gain is a mistake: a correction's peak is always above its average, so giving the average back outright pushes the peak above unity by exactly that difference, and the ceiling this section's sibling guarantees stops being true at the output. The set is therefore brought to one shared datum, chosen as the deepest channel's level change, so that

```
gain = trim - levelChange + datum + levelMatch
```

with every term at or below zero. The channel that needed the most level receives exactly its own trim; every other channel receives less. Balance is preserved exactly, the ceiling holds on every channel, and the system ends up quieter by the datum, which the user makes up on the amplifier. This is the behaviour REW and Dirac Live both have, arrived at for the same reason.

The destination gain sits outside the PEQ bank, which makes a level-matched comparison possible in a way a plugin's own bypass is not: bypassing the bank alone would leave the level where the correction put it. A flat bank at `datum + levelMatch` has the same broadband level as the corrected bank, so switching between them is a comparison of shape rather than of loudness. Since the louder side of an unmatched comparison always sounds better, an unmatched A/B is not evidence about the correction at all.

**Where the compensating gain sits relative to the filters matters, and differs by destination.** The per-input preamp is upstream of the input bank, so its attenuation lands before any boost and the block never sees more than the output does. A per-output gain is downstream of the output bank, so that block carries the untrimmed cascade on its own - up to +18 dB on the corpus. The output stays under the ceiling either way, but whether the DSP saturates in between is the open question §7.3 raises. Version 1 measures and reports it on the Apply screen; it does not block the write.

The compensation must be applied at the destination, not merely somewhere convenient. Trimming an output to offset a correction that lives on an input leaves the two on opposite sides of the matrix, so any routing that is not one-to-one would carry the correction and its compensation to different places. Since the input destination is only offered when routing is one-to-one (section 4.3), matching the compensation to the destination keeps the pair inseparable and makes rollback exact.

This is distinct from, and should not be confused with, **automatic channel level matching**, which sets the channels to equal measured level and is a change to system calibration rather than a preservation of it. Automatic level matching remains a separate, opt-in, post-version-1 discussion. Preserving what the user already had is not optional, because the alternative is changing it by accident.

The same argument applies to delay, but with the opposite conclusion for version 1: magnitude correction does not alter arrival times, so leaving delay untouched genuinely preserves the existing state. Per-channel distance and delay should be measured, retained, and displayed, but not applied.

## 8. Preserving DSP state and safety

Before level check, create a session snapshot containing at least:

- **every PEQ bank in the measured signal path, input and output, with its bypass state** - not only the destination banks;
- crossover banks;
- matrix routing and gains, and the resolved input-to-output mapping;
- output enable, mute, trim, and delay;
- per-input preamp;
- master/user volume and mute state where observable;
- loudness, leveller, psychoacoustic bass, crossfeed, upmixer, and other nonlinear/dynamic or channel-deriving processing that can affect a measurement;
- active preset identity, device identity, and the configured CoreAudio mode.

Room measurement requires a linear, stable signal path. Temporarily disable dynamic processing anywhere between the host playback stream and the physical output. Always preserve crossovers and protection filters.

**Host playback traverses the input chain, so the input PEQ banks must be flattened during measurement as well as the output banks.** This is a change forced by the move away from device-side generation: the old generator injected after the matrix and could never see input EQ, so bypassing the output banks alone was sufficient. It no longer is. Measuring through a live input bank would fold the user's existing tone controls into the measured response and the correction would then fight them. Flatten both ends for the duration of the session and restore both, regardless of which end the correction will eventually land on.

The upmixer deserves specific attention: it derives Centre and surround channels from stereo and sits in the measured path, so it must be disabled during measurement or the channel under test may not be the channel being driven.

The exact temporary-state list must be confirmed against the firmware signal-flow diagram.

On cancel, close, error, or successful save without apply, restore the snapshot and verify it. Maintain an on-disk recovery journal before changing the device. If the app or device disconnects mid-session, offer **Restore Pre-Measurement Settings** on the next connection to the same hardware.

If external controls change relevant DSP state during measurement, pause and require either restoration or restarting the affected measurements. Preset load must abort the active capture.

## 9. Portable architecture

```text
SwiftUI room-correction window
        |
RoomCorrectionCoordinator (Swift)
        |------------------------ DSPViewModel / USBDevice
        |
AudioCaptureBackend protocol      AudioPlaybackBackend protocol
        |-- CoreAudio AUHAL               |-- CoreAudio AUHAL (macOS)
        `-- WASAPI capture (later)        `-- WASAPI render (later)
        |                                 |
C ABI wrapper
        |
libdspi_room_correction (portable C++17)
        |-- sweep + inverse-filter synthesis
        |-- sweep detection / deconvolution
        |-- calibration parsing and interpolation
        |-- FFT abstraction
        |-- response preprocessing and smoothing
        |-- multi-position statistics
        |-- target construction
        |-- DSPi biquad model
        `-- constrained PEQ optimizer
```

### 9.1 Core rules

- No Foundation, Accelerate, CoreAudio, Swift, Win32, or COM types in the C++ core.
- Plain value objects and spans/vectors at the C++ boundary.
- Double precision for measurement, statistics, filter fitting, and response prediction.
- Float conversion only at device/file boundaries.
- Deterministic output for identical inputs and algorithm version **on a given platform and build**. Across platforms, results agree closely but not bit-exactly; see below.
- Cancellation and progress callbacks accepted by long-running operations.
- No audio-device access inside the core.
- FFT behind an interface. A portable BSD-licensed implementation such as KissFFT is suitable; Accelerate may be used by a macOS adapter only if identical golden tests pass.
- A standalone command-line harness must be able to load a saved project, recalculate filters, and emit metrics on macOS and Windows.

Note that **the repository currently has no CI** (`.github/` contains only `FUNDING.yml`). Several of this specification's guarantees are cross-platform determinism claims, and the `DSPMath` parity requirement in section 4.2 exists specifically to stop two implementations of the same filter math from drifting apart. Neither survives without automated enforcement. Standing up CI that runs the pure-logic and core golden tests on macOS and Windows is a prerequisite of Milestone 1, not a later cleanup task.

### 9.3 What cross-platform determinism actually means

The first cross-platform CI run compared the acceptance corpus byte for byte and failed. This was a correction to the specification rather than a bug in the core, and the claim is restated here so it is not re-asserted later in the stronger form.

C's transcendental functions are not required by the standard to be correctly rounded. `log`, `exp`, `sin`, `tan` and `pow` differ in the last unit in the last place between glibc, Apple's libm and the MSVC runtime. The optimizer is a search, so a one-ulp difference early sends it down a marginally different path, and the divergence surfaces in the result.

Measured across macOS arm64, Linux x64 and Windows x64 on the same corpus, the divergence is **not uniform**, and the distinction matters:

- The **quality metrics agree almost exactly**: reliability-weighted worst-position RMSE of 4.017 against 4.017, 0.379 against 0.379. The correction is as good on every platform.
- The values that identify **which of several equivalent solutions** the search found - trim, maximum and minimum combined correction - differ by up to about 0.08 dB, because a slightly different filter set was chosen that does the same job.

Making the core bit-identical everywhere would mean shipping our own transcendental functions: substantial work and slower code, bought with agreement in a decimal place far below anything audible, measurable in a room, or representable on the wire. That trade is not worth making.

The contract is therefore:

- **Within one platform and build, the result is exactly reproducible.** This is what a saved project relies on when it is reopened on the machine that produced it, and the unit tests enforce it.
- **Across platforms, quality and safety agree within a tight tolerance, and the particular filter set may differ.** A user who measures on a Mac and recalculates on a PC gets an equally good correction, not an identical one.

The CI gate reflects this with per-field tolerances rather than one number, because a single tolerance is either too loose to catch a real regression in quality or too tight to accept a harmless difference in solution: 0.05 dB on the quality metrics and on the safety gates, where a platform boosting when another does not would be a bug rather than noise; 0.25 dB on the incidentals; exact on counts, since a different number of bands is a real difference in what the optimizer decided. Structure is compared exactly, so a failed gate or a missing scenario still fails loudly.

There is no Intel macOS runner. GitHub is retiring them and jobs targeting `macos-13` sit queued indefinitely, which would block the comparison rather than fail it. x86_64 coverage comes from the Linux and Windows runners, which are both x86_64 and use different compilers again.

The existing `DSPi ConsoleTests` target already separates pure-logic tests that run anywhere from live-device tests that self-skip without hardware. The portable core's tests belong in the first tier and should follow the same convention.

### 9.2 macOS capture and playback

Use CoreAudio's HAL/audio-unit APIs for explicit device selection, timestamps, and stable device UIDs, on both the capture and playback sides. `AVAudioEngine` may be used only if it can meet those selection and timestamp requirements without relying on the system default device.

Add `NSMicrophoneUsageDescription` and, if App Sandbox is enabled now or later, the audio-input entitlement. Handle denied permission as a Setup-screen state with a path to System Settings.

The capture backend supplies interleaved or planar Float32 frames plus host timestamps. It must survive arbitrary hardware sample rates by converting to the analysis rate outside the real-time callback. Never allocate, parse files, run FFTs, or update SwiftUI from the real-time audio callback.

The playback backend renders a pre-computed buffer to a chosen device and channel slot. Requirements:

- select the DSPi explicitly by the device Console already resolved through `HostAudioFormatMonitor`, never the system default output;
- place the sweep in one channel slot with all others silent, using the channel map implied by the configured CoreAudio mode;
- **never resample.** Author at the device's configured rate and confirm no conversion is in the path; a resampled reference invalidates the deconvolution;
- do not change the device's configured mode, rate, or channel count. The configured mode is the user's deliberate choice (section 4.3);
- report underruns, dropped buffers, and format changes to the session as measurement failures rather than absorbing them;
- provide sample-accurate render position so the emitted-versus-captured stretch estimate in section 6.1 has a reliable reference on the playback side.

The playback and capture backends are separate protocols with separate lifetimes. They must not assume a shared clock, a shared device, or a common start instant. See section 6.1.

## 10. Project and export formats

### 10.1 Room-correction project

Use a portable ZIP container with extension `.dspirc`, containing versioned, documented files such as:

```text
manifest.json
device-snapshot.json
calibration/original.cal
measurements/position-01/output-00.wav
measurements/position-01/output-00.json
responses/position-01-output-00.f32
target.json
result.json
```

The project should contain:

- schema and algorithm versions;
- app, platform, DSPi firmware, wire-format, and capability fingerprint;
- selected microphone stable ID/display name and calibration data/hash;
- raw captures or lossless Float32 WAV, unless the user disables raw-audio retention;
- extracted responses and quality metrics;
- position names, weights, enabled state, and order;
- channel IDs, names, roles, and target groups;
- target controls/curtains and sampled target curves;
- original DSP state relevant to the calculation;
- generated filters, predicted curves, warnings, and optimizer diagnostics.

Use numeric channel/output IDs as identity and names only as labels. A project can be reopened without hardware, inspected, retargeted, and recalculated. Applying requires a compatible connected device and an explicit mapping confirmation if the device identity differs.

### 10.2 Filter export

Continue to use the existing DSPi Console filter text format for lightweight exchange. Add comments identifying the room-correction project, algorithm version, measurement date, target preset, and required headroom. Do not make this text export the only saved artifact because it cannot reproduce a calculation.

## 11. State machine

```text
idle
 -> setupReady
 -> checkingLevel
 -> readyToMeasure
 -> capturing(position, channel)
 -> analyzing(position, channel)
 -> positionReview
 -> capturing... | targetEditing
 -> calculating
 -> resultsReady
 -> applying
 -> appliedUnverified
 -> verifying
 -> complete
```

From every transient state, Cancel first stops playback, then stops capture, then restores temporary DSP state. Device or microphone loss follows the same cleanup path and leaves a resumable draft.

## 12. Validation and acceptance

### 12.1 Core automated tests

- Calibration parser fixtures for UMIK/REW variants, comments, malformed rows, duplicate frequencies, optional sensitivity, and optional phase.
- Exact log-sweep fixtures with known gain, delay, noise, harmonic distortion, and sample-rate offsets.
- Synthetic room responses containing broad tilt, shelves, modal peaks, deep cancellation notches, natural roll-offs, and spatially moving nulls.
- Multi-position tests proving a local null does not create a large boost and a shared mode does create a cut.
- Biquad response parity with `DSPMath` and captured DSPi hardware response.
- Determinism, cancellation, serialization round-trip, and old-project migration tests.
- Optimizer tests at 1, 3, 5, 9, and 21 positions and at every supported band count.
- Quantized filters must remain stable and within firmware parameter constraints.

### 12.2 Measurement validation

Use an electrical/acoustic loopback fixture to characterize the existing DSPi log sweep. Confirm reconstructed frequency trajectory, duration, amplitude envelope, fade behavior, and the response extracted at representative independent input sample rates.

The firmware tree already provides `DSPI_LOOPBACK` builds (`build-rp2040-loopback`, `build-rp2350-loopback`) that capture output slot 0 back to the host. Driven by host playback, this gives a purely digital reference path with no microphone, no acoustics, and no independent clock, exercising the real production chain end to end: host sweep synthesis, USB transport, the DSP path including input EQ, and deconvolution. It is the correct fixture for validating that chain in isolation before any acoustic variable is introduced. Characterize against this first; an analog loopback then adds the converter chain, and only then does an acoustic measurement add the room.

Repeat the characterization at every rate the device supports. Because the reference sweep is now host-authored, the relevant claim to verify is that no resampling occurs anywhere in the output path at each rate, and that the captured loopback matches the emitted reference to within the tolerance above.

For an electrical flat loopback, target magnitude error should be within ±0.25 dB over the declared valid analysis range. For a known analog EQ fixture, DSPi Console and REW traces should agree within ±0.5 dB after using the same calibration and smoothing policy.

### 12.3 Optimizer quality gates

Every method comparison must use neutral post-quantization metrics that are not private penalty terms from either method's optimization objective. Report at least raw worst-position RMSE, correctable/reliability-weighted worst-position RMSE, reliable-band median absolute error, fixed-delta reliability-weighted Huber loss, positive overshoot, disputed-region boost, out-of-curtain boost, and filter-Q distribution. Give every ablation the same number of deterministic starts; no variant may borrow another variant's optimized solution.

The primary closure gate must run the complete corpus at the maximum live hardware allocation (currently ten PEQ bands), not at a smaller convenient comparison budget. A 1–10 sweep on one easy scenario is allocation coverage only and cannot substitute for that gate. The iteration cap must be high enough for the ten-band candidate to converge; a pass produced by premature termination is invalid.

Report hard-constraint enforcement separately from discriminating quality gates. A disputed-boost result at the configured 0.5 dB ceiling demonstrates that enforcement works, but says nothing about safety margin; report the remaining headroom explicitly. The same distinction applies to Q, correction-curtain, and serialization/quantization readbacks.

On correctable synthetic and out-of-model responses:

- exact predicted DSPi response after parameter quantization;
- no constraint violations;
- no positive combined response in default no-boost mode;
- lower correctable/reliability-weighted error than the uncorrected response;
- no positive boost outside the configured or reliably estimated native bandwidth;
- no material boost in narrow, low-SNR, spatially disputed, or otherwise deliberately uncorrected regions;
- raw worst-position error reported as a diagnostic, **not** used as a hard failure when its increase is the direct consequence of refusing to invert an unreliable local null;
- RP2040 and RP2350 quantization, trim, predicted response, and all safety/quality gates evaluated independently from the same continuous solution; cross-platform recipe identity or response parity is not required;
- convergence reproducible across macOS arm64, Windows x64 and Linux x64, **within the per-field tolerances described below** rather than bit-exactly.

The required ablation is a 2×2 comparison: arithmetic-average versus spatial/reliability-aware fitting, each with and without ordinary EQ hygiene. Report benefit against uncorrected separately for every scenario; a corpus mean must not hide weak cancellation-dominated cases. The intended product claim must follow those neutral results. The closed Milestone 0 result supports “materially safer boost behavior, with an explicit accuracy tradeoff versus an aggressive average-curve fit and modest benefit on spatially unstable rooms”; it does not support the withdrawn “55% more accurate” claim.

On real rooms, compare against REW automatic EQ using the same measurement, target, band count, and constraints. Compare robust error, worst-seat error, filter headroom, Q distribution, and listening results. Dirac Live and ARC may be used as listening/response references, but their proprietary outputs cannot be treated as a golden algorithm oracle.

### 12.4 End-to-end acceptance

- The user can finish after any completed position.
- Cancelling at every step restores the initial DSP state.
- A failed multi-band apply either verifies completely or rolls back.
- Saving works before applying.
- Applying never saves flash automatically.
- Verification measurement is visually and numerically compared with prediction.
- A session created on macOS can be opened and recalculated by the Windows/core harness.

## 13. Delivery plan

### Milestone 0 - research harness

**Status: closed on 2026-07-28.**

- Freeze the current DSPi sweep law through firmware documentation or loopback characterization.
- Build synthetic fixtures and a Python/REW comparison corpus.
- Prototype the multi-position objective in Python using AutoEq/SciPy ideas.
- Benchmark L-BFGS-B and SLSQP production candidates.

Exit: the harness reports neutral metrics, a fair spatial-versus-hygiene ablation, and a frozen hygiene-weight sweep; runs the complete corpus at the maximum ten-band hardware allocation with a convergent iteration budget; covers out-of-fitting-model structure, speaker roll-off, non-minimum-phase cancellation, tilted targets, shelves, 1/3/5/9/21 positions, 1–10 allocation coverage, all supported sample rates, and the 96-point-per-octave grid; evaluates and gates the quantized DSP recipe independently for RP2040 and RP2350; reliably avoids local-null and out-of-curtain boosts; improves correctable/reliability-weighted error versus the uncorrected response in every scenario; and records per-scenario benefit plus the accuracy/safety tradeoff against a simple averaged-curve fit without requiring the robust method to win raw worst-seat RMSE.

### Milestone 1 - portable core

**Status: complete. Verified on macOS arm64, Linux x64 and Windows x64 by CI.**

- Remove Console's 0.1 dB host gain rounding, preserve gain precision through project/core/write paths, and add float32-versus-legacy-grid golden tests before further optimizer tuning. **Done.**
- C++ project model, calibration parser, FFT/deconvolution, smoothing, statistics, target generator, exact DSPi biquads, optimizer, C ABI, and CLI. **Done** (`Core/RoomCorrection`, 133 unit cases plus the acceptance corpus, no dependencies, clean under `-Wall -Wextra -Wpedantic`).

Exit: all core golden tests pass on macOS and Windows CI. **Met.** The 133 core cases and the acceptance corpus pass on macOS arm64, Linux x64 and Windows x64, and the full Swift suite runs on macOS in CI as well.

The first CI runs earned their place immediately, catching three things that local testing could not:

- **Portability breaks that macOS hid.** `M_PI` is a POSIX extension rather than standard C++; glibc hides it under the strict ISO mode that `CMAKE_CXX_EXTENSIONS OFF` selects, and MSVC only exposes it behind `_USE_MATH_DEFINES`. libc++ defines it unconditionally, which is exactly why the core built locally and nowhere else. Three headers were also relying on transitive includes that happen to work on libc++ and are guaranteed nowhere.
- **The determinism claim was too strong**, corrected in section 9.3.
- **Two CI jobs that reported success without testing anything.** One targeted a runner that is being retired and sat queued rather than failing; the other piped through a tool that is not installed on the runners and had `continue-on-error` set, so it went green in eight seconds. A check that always passes is worse than no check, because it gets trusted. Removing the mask revealed the real problem, which was that the runner's Xcode could not open a project saved in a newer format.

Findings recorded during the milestone, each caught by a failing test or the corpus rather than by review:

- The deconvolved impulse is symmetric, not causal, so a short pre-peak window attenuates the low end and looks like a genuine rolloff (1.2 dB at 50 Hz when cut at 5 ms).
- High-Q resonances need more pre-window than the band-limited skirt implies, because ringing spreads before the peak once convolved with it. A two-cycle window reads a Q=8 notch at 80 Hz 0.8 dB *too deep*, which would make the optimizer over-correct a room mode. Four cycles is the default.
- Sign agreement inverted where the response already met target: with nothing to dispute, a naive count marks a correct region maximally unreliable and de-weights it, licensing overshoot. Now deadbanded.
- MAD cannot detect a single outlier position by construction, so reliability must not be built on spread alone.
- Auto level was inverted. Correction is target minus measured, so a target at the upper envelope demands boost everywhere and a cut-only fit came out worse than no correction.
- Absolute level was coupled into the error metric, so the optimizer fought its own trim and variant comparisons measured trim rather than tonal accuracy. Both objective and metrics now remove a single shared offset.
- Soft penalties were outbid twice: once by boost outside the native band and in disputed regions, now enforced deterministically by the trim; once by boost filter Q reaching 2.25 against a ceiling of 2, now enforced structurally when the parameter vector is decoded.
- The optimizer's dominant cost was recomputing per-frequency trigonometry per section per evaluation. Caching it cut the suite from 3:15 to 47 s, and a test pins the cached path against the reference to 1e-9 so it cannot drift silently.

The production optimizer is an in-tree deterministic coordinate-descent minimizer rather than NLopt. It satisfies every corpus gate, so the NLopt/SLSQP decision in section 7.4 stays open rather than settled: revisit it only if a real-room corpus shows the in-tree minimizer falling short, since adding a dependency should be paid for by evidence.

### Milestone 2 - macOS measurement

- Microphone permissions, CoreAudio device pickers, capture and playback backends, sweep synthesis, level check, position capture, routing validation, quality analysis, cancellation, and recovery journal.

Exit: repeated real-device measurements agree with REW within the measurement tolerances.

### Milestone 3 - target and results

- Target editor with direct manipulation and numeric entry, free-form anchors, target import/export, channel grouping, calculation progress, the interactive graph and overlay manager, the editable and lockable filter table, project save/reopen, and text export.

Exit: an offline saved project can be retargeted and deterministically recalculated on the platform that produced it, and recalculated to within the stated tolerances on any other.

### Milestone 4 - safe apply and verify

- Channel checklist, write/readback/rollback, unsaved-preset integration, verification sweep, and level-matched bypass audition.

Exit: fault-injection tests prove rollback and recovery behavior.

### Milestone 5 - tuning and Windows backend

- Blind/listening comparisons, default tuning, menu-level advanced diagnostics (impulse, step, spectrogram, distortion, decay, optimizer history), WASAPI capture and render adapters, Windows UI integration, and cross-platform project compatibility.

## 14. Research conclusions and licensing

- [AutoEq](https://github.com/jaakkopasanen/AutoEq) is MIT licensed and is the best reusable reference for PEQ parameter seeding, constrained fitting, shelf filters, and filter-sharpness penalties. Its [algorithm notes](https://github.com/jaakkopasanen/AutoEq/wiki/How-Does-AutoEq-Work%3F) describe an SLSQP objective and why plain mean-square error is insufficient.
- [REW's measurement guidance](https://www.roomeqwizard.com/help/help_en-GB/html/makingmeasurements.html) supports logarithmic sweeps, pre-capture level checking, calibration files, explicit timing detection, and avoiding invalid clipped captures. Its [EQ guidance](https://www.roomeqwizard.com/help/help_en-GB/html/eqwindow.html) motivates correction curtains, target-level placement, boost/Q limits, broad shelves, variable smoothing, and avoiding boost outside native roll-off. REW is a behavioral reference; its implementation is not open source.
- [REW's calibration-file documentation](https://www.roomeqwizard.com/help/help_en-GB/html/calfiles.html) provides a practical interoperable format, including USB microphone sensitivity headers.
- [Farina's swept-sine work](https://www.angelofarina.it/Public/Papers/list_pub.htm) is the measurement basis for exponential-sweep deconvolution and harmonic separation.
- Multi-position frequency-domain work such as [Carini et al.](https://doi.org/10.1109/TASL.2011.2158420) and the [AES spatial-averaging study](https://assets.ctfassets.net/4zjnzn055a4v/6nKDWR1VsWp2WkaAqdvdDT/09402de507362053495f5f53e8a86d87/AES_141_-_Spatial_Stability_of_the_Frequency_Response_Estimate_and_the_Benefit_of_Spatial_Averaging.pdf) supports extracting response features common across a listening area rather than inverting one point literally.
- [Dirac's own technical discussion](https://www.dirac.com/wp-content/uploads/2021/09/On-equalization-filters.pdf) shows why robust correction should avoid spatially unstable behavior and why a magnitude-only minimum-phase system cannot reproduce all mixed-phase benefits. Dirac's [product description](https://www.dirac.com/products/room-correction) confirms the importance of multiple positions and editable target curves.
- [IK's ARC description](https://www.ikmultimedia.com/news/?id=IKReleasesArcStudio) highlights correction-range limits and adjustable correction resolution as important user controls. Those concepts are applicable without copying its proprietary algorithm.
- [Cavern QuickEQ](https://github.com/VoidXH/Cavern) is an interesting open-code room-correction reference, but its custom license restricts commercial/public use and is not suitable for incorporation without separate permission.
- [NLopt](https://github.com/stevengj/nlopt) (LGPL) is the current portable optimizer candidate because it supplies SLSQP. [LBFGS++](https://github.com/yixuan/LBFGSpp) (MIT) remains a fallback only if later analytic-gradient work reverses the Milestone 0 convergence result. [KissFFT](https://github.com/mborgerding/kissfft) (BSD-3-Clause) remains a plausible FFT building block. Dependency notices and exact versions must be recorded if adopted.
- **DSPi Console is GPL-3.0** (verified against the repository `LICENSE`). This resolves the licensing questions raised in section 7.4 favorably: MIT (LBFGS++, AutoEq, KissFFT's BSD-3-Clause) and MPL-2.0 (Eigen) are all GPL-3.0 compatible, and LGPL (NLopt) is usable. The genuine constraint is the other direction: any code derived from this project inherits GPL-3.0, which is worth confirming as acceptable before the portable core is factored out as a reusable library, since that is the natural point at which someone would want to link it from something else. Cavern QuickEQ remains excluded on its custom license regardless.

## 15. Decisions requested before implementation

Recommended defaults are included so work can begin without blocking, but these product decisions should be confirmed:

1. **Existing PEQ (confirmed):** room correction owns and replaces each selected output's complete ordinary PEQ bank. Applying correction replaces all ten slots, preserves crossovers, and restores the original bank unless Apply succeeds. This is fixed version 1 behavior because five of eight Milestone 0 scenarios exhausted the hardware band budget.
2. **Standard measurement plan:** 5 positions with the main position weighted 2×. Recommended: yes.
3. **Boost policy:** no positive combined correction by default; Advanced mode allows up to +3 dB with explicit headroom handling. Recommended: yes.
4. **Correction range:** full-range measurement, but Auto curtains and conservative high-frequency correction. Recommended: yes.
5. **Channel level/delay:** measure, retain, and display both. Do not apply delay. Do apply the output-trim compensation needed to preserve the pre-correction relative levels between channels, because a cut-only correction otherwise changes them by accident (section 7.5). Automatic channel level *matching* stays out of version 1. Recommended: yes.
6. **Raw capture retention:** keep lossless raw captures in `.dspirc` by default, with a smaller-project option that keeps only extracted responses. Recommended: yes.
7. **Position maximum:** allow 1–21 so the same flow covers quick desktop work and a wide seating area. Recommended: yes.
7a. **Correction destination:** user-selectable between the input and output PEQ banks, with the input option offered only when matrix routing is one-to-one for every selected channel (section 4.3). Recommended: yes.
7b. **Measurement path:** host-generated sweep played through the DSPi as a CoreAudio output device. The firmware signal generator is not used for measurement or verification in any role (section 4.1). Recommended: yes.
8. **Sample rate (superseded):** the hard 44.1/48/96 kHz measurement gate is withdrawn. It existed because the firmware generator's sweep trajectory was untrustworthy at other rates; host playback authors the reference itself, so the constraint is gone. Author at the device's configured rate, never resample, and keep rate parameterized throughout prediction (section 4.2).
9. **Spatial averaging domain:** weighted power average as the primary location estimate, with robust dB-domain statistics used for spread, outlier rejection, and reliability weighting (section 6.4). Recommended: yes.
10. **Transition frequency:** estimate it per room and per channel from the spatial spread of the measurements rather than asking the user for room volume and reverberation time, and let it drive windowing, smoothing, and the Q and boost limits (section 6.5). Recommended: yes.
11. **`DSPMath` ownership:** decide whether the portable core becomes the single source of truth for biquad math with `DSPMath` reduced to a thin caller, or whether both implementations persist under a CI-enforced parity test. The second is less disruptive now and more expensive forever. Recommended: parity test for version 1, with consolidation as an explicit follow-up rather than an assumed one.

## 16. Recommended additions beyond the initial request

The following additions materially improve trust and usability and should be included in the first public version unless schedule requires phasing:

- Level check and noise-floor measurement before the first sweep.
- Immediate quality scoring with per-channel retry.
- Per-output **Identify** in Setup, so a correction cannot be silently applied to the wrong physical speaker.
- Output-trim compensation preserving pre-correction inter-channel balance (section 7.5).
- A data-driven transition-frequency estimate driving windowing, smoothing, and correction limits (section 6.5).
- Frequency-dependent windowing ahead of smoothing (section 6.3).
- Selectable input or output correction destination with matrix-routing validation (section 4.3).
- A session-duration estimate before the user commits to a measurement plan.
- Progressive disclosure that exposes every expert control without burying it in a preferences window (section 5.0).
- A target editor with both direct manipulation and numeric entry, free-form anchor points, and target import/export.
- An editable, lockable filter table with live prediction.
- Menu-level access to impulse response, step response, spectrogram, distortion, decay, and optimizer diagnostics.
- Correction curtains and automatic native-bandwidth detection.
- Spatial spread visualization, not only an averaged trace.
- No-boost default and explicit headroom accounting.
- Project save independent of hardware apply.
- Crash/disconnect recovery journal for temporary DSP changes.
- Read-back verification and rollback when applying filters.
- A post-apply verification sweep.
- Level-matched correction bypass for listening comparison.

These features will contribute more to a professional result than exposing many optimizer knobs to the user.
