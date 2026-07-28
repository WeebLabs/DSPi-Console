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
- Let the user select the DSPi **output channels** to measure and correct.
- Use DSPi's built-in logarithmic sweep generator, one output at a time.
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

- `TestSignalsView.swift` exposes the firmware signal generator.
- `SiggenConfig` supports logarithmic sweeps (`SIGGEN_SWEEP_LOG`, type 4), output masks, level, duration, repeat count, and gaps. `level_db` is **peak** dBFS. `repeat = 0` means *infinite*, so a one-shot sweep is `repeat = 1`; this is an easy and dangerous off-by-one.
- Signal-generator capabilities are queried from firmware rather than assumed. `REQ_SIGGEN_GET_CAPS` with `wValue = 0xFFFF` doubles as the feature probe; older firmware STALLs it.
- The generator injects **after the matrix mix, per matrix output**, so it measures physical output paths and is unaffected by any input-side processing (input preamp, input/master EQ, leveller, upmixer).
- The effective output mask is `channel_mask & matrix_output_enabled & valid_channel_mask`. A selected output that is **disabled in the matrix renders silence**, which would otherwise present as a mystifying "no signal" failure at measure time. Setup must surface and block this.
- `siggen_pump()` runs the generator with no host audio stream at all. Room Correction never needs to play audio from the Mac; it only needs to record.
- Per-cycle synth state is reset, so repeated sweeps are bit-identical at the device. Any barrier to coherent averaging is on the host capture side, not the device side.
- `SIGGEN_FLAG_RAW` bypasses both crossover and PEQ. This is unsafe for room measurement because a crossover may protect a driver, so Room Correction must not use RAW mode. RAW additionally freezes filter state while active, producing a transient when normal processing re-engages, which is a second reason to avoid it.
- The current unified channel model allocates ten PEQ bands to every input and output channel, plus four separate crossover bands on outputs (wire band indices 20-23). The implementation must still query/use live device capabilities rather than bake this number into the correction core. Note that several checked-in documents (`CLAUDE.md`, `AGENTS.md`, `README.md`, `automated_room_eq.md`) still describe a stale pre-V16 model claiming two bands per output; they are wrong and should be corrected as part of this branch.
- `DSPMath` contains the DSPi biquad response and coefficient formulas, but **hardcodes `sampleRate = 48000.0`** (`DSPMath.swift:427`). See section 4.1.
- `DSPViewModel.setFilter` can apply a complete output PEQ bank over USB.
- `DSPViewModel.sampleRateHz` already exposes the live device sample rate (`REQ_GET_STATUS`, `wValue = 15`).
- `Commands.identifyOutput(_:)` already fires a `CHANNEL_ID` ident at one output without disturbing the Test Signals editing draft. It is both a useful UX primitive for Room Correction and the pattern to follow for running a generator action without clobbering unrelated user state.
- The app has no microphone-capture layer, microphone permission text, room-correction document model, or multi-write transaction. There is also no FFT, no audio capture of any kind, and no CI workflow.

### 4.1 Sample rate is a first-class correctness concern

Three separate facts interact badly and must be handled explicitly:

1. **Firmware designs biquads at the live sample rate.** `dsp_pipeline.c:248` computes `omega = 2*pi*freq/sample_rate` from the running rate, in **`float`** precision.
2. **`DSPMath` assumes 48 kHz in `Double`.** For the existing response graph this is a cosmetic inaccuracy. For room correction it is a modelling error the optimizer would bake into the result, because the optimizer's predicted response would not be the response the hardware produces. Bilinear frequency warping means the divergence is negligible at low frequencies and grows toward Nyquist, so it lands exactly where correction is already least trustworthy.
3. **The signal generator silently falls back to the 48 kHz coefficient row for any rate that is not exactly 44.1, 48, or 96 kHz.** At any other rate the sweep's actual frequency-versus-time trajectory does not match its configured parameters, so a reconstruction built from those parameters is wrong and the deconvolution is invalid.

Required behavior:

- The correction core takes sample rate as a parameter. No hardcoded 48 kHz anywhere in the measurement, prediction, or optimization path.
- Read `sampleRateHz` at session start, record it in the project, and re-check it before applying. A rate change mid-session invalidates the affected measurements.
- **Gate the feature to 44.1, 48, and 96 kHz.** At any other rate, refuse to measure and explain why. This is a firmware limitation, not a UI preference.
- Biquad parity tests must run at all three supported rates, and must compare against `float`-precision coefficient design to match firmware rather than assuming `Double` agreement is sufficient. High-Q low-frequency filters are where single precision diverges first.
- Either parameterize `DSPMath.sampleRate` or treat the portable core as the single source of truth and hold `DSPMath` to it with a parity test. Two independent implementations of the same RBJ math will otherwise drift.

The output generator measures physical output paths. The correction destination is therefore the corresponding **output PEQ channel**, not USB/input/master EQ. Crossovers, output routing, speaker amplifiers, and the room remain part of the measured system.

## 5. User experience

### 5.1 Entry and window behavior

Add **Tools > Room Correction…**. Opening it creates or focuses one independent resizable window. A single active measurement session owns the DSPi signal generator; opening Test Signals while a measurement is active should offer to stop Room Correction first.

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

- Connected DSPi device and firmware/capability status, including the live sample rate and a block if it is not 44.1, 48, or 96 kHz (section 4.1).
- Microphone/input device picker using stable device UID, not display name alone.
- Input-channel picker when the device has multiple inputs.
- Live input meter and clipping indicator.
- Calibration-file field with **Choose…**, **Clear**, file summary, and validation status.
- Calibration orientation note. For a UMIK-1, show whether the loaded filename appears to be a 0-degree or 90-degree file, but do not infer correctness solely from the filename.
- Output channel checklist populated from live signal-generator capabilities and DSPi channel names. Outputs that are disabled in the matrix must be shown as unavailable with the reason, because the generator's effective mask would render them silent.
- An **Identify** control per listed output, reusing `Commands.identifyOutput(_:)`, so the user can confirm which physical speaker each channel drives before measuring. Mapping a correction to the wrong speaker is a common and completely silent failure in automated room correction, and this is a cheap defence against it.
- Per-channel role: Full range, Bass limited, or Subwoofer. Infer an initial role from active crossovers and name, but let the user change it.
- Measurement plan: Quick (3), Recommended (5), Wide (9), or Custom (1–21).
- Listening-area choice: Single seat, Sofa, or Wide area. This changes position guidance and weights, not the DSP algorithm contract.
- Existing PEQ policy. Version 1 supports **Replace selected outputs' PEQ**. The screen must say that crossovers are preserved and the original PEQ is restored unless the user applies the result.

The primary button is **Continue to Level Check**. It remains disabled until a DSPi, microphone input, and at least one enabled output are available.

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
2. With an explicit **Play Level Check** action, play band-limited pink noise through one representative selected output.
3. Start at a conservative generator level, default `-40 dBFS`, and let the user increase it up to the session sweep level.
4. Default sweep peak level is `-20 dBFS`; expose a range of `-30…-12 dBFS` in the normal UI. An Advanced control may permit a wider range with a warning.
5. Show microphone peak, RMS, estimated signal-to-noise ratio, and DSPi clip flags.
6. Require no clipping and recommend at least 30 dB broadband SNR. Permit continuation below the recommendation with a warning, not below a hard validity floor of 15 dB.

The app must not automatically raise master volume or output gain. It may tell the user to set their normal listening volume. Stop output immediately if the microphone input or DSPi reports clipping.

### 5.5 Measurements

Position 1 is always the **Main Listening Position** and has the largest default optimization weight. Later cards guide the mic around the listening area. The mic must remain at ear height and keep the calibration file's intended orientation.

Each position is a transaction:

1. User places the mic and presses **Measure Position**.
2. Capture begins before the generator starts.
3. Measure the room-noise floor.
4. For each selected output, configure and run one one-shot logarithmic sweep.
5. Keep a silent pre-roll and post-roll around the sweep.
6. Stop capture after the last response tail.
7. Analyze every channel and show pass/warn/fail results.
8. Accept the position only when every selected channel has a valid measurement; alternatively let the user retry just a failed channel.

Default sweep plan:

| Role | Analysis range | Sweep range | Duration |
|---|---:|---:|---:|
| Full range | 20 Hz–20 kHz | 10 Hz–22 kHz | 8 s |
| Bass limited | 20 Hz–20 kHz | 10 Hz–22 kHz | 8 s |
| Subwoofer | 10 Hz–500 Hz | 5 Hz–1 kHz | 12 s |

The actual upper limit must remain below the connected device's Nyquist limit and the signal-generator descriptor's advertised range. Sweep ranges are advanced settings. Crossovers remain active during every sweep. Each sweep is configured with `repeat = 1`; `repeat = 0` means infinite.

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

Hard failures include clipping, missing/truncated sweep, device change, generator interruption, or a response too close to the noise floor. A high-noise band may be excluded from correction while the rest of the measurement remains usable.

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

The user can adjust the target and recalculate without remeasuring. Advanced users can edit an individual generated filter, lock it, and recalculate the remaining filters, but this is not required for the first usable milestone.

### 5.9 Save, apply, and verify

Offer these separate actions:

- **Save Project…** saves measurements, settings, target, and calculated result.
- **Export Filters…** writes the existing DSPi Console text format for interoperability.
- **Apply to DSPi…** opens a final checklist of measured channels. All are selected by default; any subset may be applied.
- **Save to Current Preset…** appears only after a verified live apply and remains a separate confirmation.

Applying is a best-effort transaction:

1. Capture a fresh snapshot of every destination PEQ bank.
2. Confirm the connected device identity and capability fingerprint still match the calculation.
3. Write every band, clearing unused bands to Off, and write the balance-preserving output trim for each applied channel (section 7.5).
4. Read back every band and every trim value.
5. On any mismatch, restore all affected banks and trims and report exactly what failed.
6. Mark normal preset state as unsaved; do not write flash.

After application, offer **Verify Correction**. It repeats a sweep at the main position with the new filters active and overlays measured-after, predicted-after, and target. Verification is the strongest way to catch routing mistakes, gain changes, or a poor model, and should be considered part of the recommended flow.

Provide a level-matched **Correction Bypass** audition control after application. Level matching is essential; a louder result must not win merely because it is louder.

## 6. Measurement processing

### 6.1 Latency and clock handling

Variable acoustic/audio latency is not a blocker for magnitude correction. It shifts the captured sweep in time but does not alter the transfer magnitude.

The DSPi output DAC and microphone ADC may still have independent sample clocks, including when the acoustic signal between them is analog. Exact phase/impulse deconvolution can be smeared by their small rate difference, but version 1 does not consume measured phase. The analysis therefore uses this policy:

1. Start capture before the DSPi generator.
2. Detect the recorded sweep rather than assuming a host timestamp is the acoustic start.
3. Fit its observed start, end, and logarithmic frequency trajectory.
4. Estimate the small time stretch between the expected and recorded sweep.
5. Resample/time-warp only when the estimated mismatch is large enough to affect magnitude bins.
6. Treat the estimate as a measurement-quality metric, not a shared-clock requirement.

The current signal generator is sufficient if its logarithmic frequency-versus-sample formula, amplitude envelope, and one-shot boundaries are documented or characterized with a loopback fixture. A new firmware signal type is not a prerequisite.

### 6.2 Sweep extraction

Use an exponential/logarithmic swept-sine analysis based on the established Farina method:

- reconstruct the expected DSPi sweep by **reproducing the firmware's exact phase recurrence**, not the idealized analytic exponential sweep;
- locate it in the capture by matched correlation or sweep-ridge detection;
- compensate any fitted time stretch;
- deconvolve to obtain the linear room impulse response and, where reliable, separated harmonic components;
- discard absolute phase for correction;
- derive magnitude from the calibrated linear response.

The firmware's sweep law is already known and is cheap to mirror exactly. `siggen.c` advances a Q48 phase accumulator with a per-sample multiplicative increment, `inc += inc * eps`, where `eps = log(f2/f1) / duration_samples` is precomputed at apply time for the 44.1/48/96 kHz rate rows. Two consequences:

- The discrete recurrence gives `inc_n = inc_0 * (1 + eps)^n` rather than the analytic `inc_0 * e^(eps*n)`. For a 20 Hz to 20 kHz sweep over 8 s at 48 kHz, `eps ~= 1.8e-5` and the accumulated relative frequency error at the end of the sweep is on the order of `6e-5`, which is negligible. The discrepancy is therefore not a correctness risk, but reproducing the recurrence directly costs nothing and removes the question entirely, along with any fixed-point quantization of `inc` and `eps`.
- The 5 ms `SIGGEN_FADE_MS` start/stop fade is an **amplitude overlay, not an inserted delay**, so it does not disturb the frequency trajectory. The reconstruction must nevertheless apply the same fade, or the inverse filter will mismatch at the sweep edges and splatter energy across the spectrum.

Both properties should be pinned by a loopback fixture test rather than trusted from source reading alone, since they are firmware implementation details rather than a wire-format contract.

If exact waveform reconstruction is not available in the first firmware-compatible prototype, use a fallback swept-sine ridge estimator: follow the known log-frequency trajectory in an STFT/lock-in analysis and recover amplitude versus frequency directly. This is sufficient for magnitude EQ, but the exact-waveform deconvolution path is preferred for noise rejection and diagnostics.

Use one longer sweep rather than synchronous repetitions when input and output use different devices. A failed/noisy measurement is retried as a new capture and is never coherently averaged without alignment.

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
         + filter sharpness and high-Q penalties
         + small per-filter complexity penalty
```

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

Advanced boost mode must show required headroom and reduce gain before the first boosting stage if the DSP signal path supports that safely. Until the firmware signal path and internal saturation behavior are verified, it must never apply an uncompensated positive combined response.

Use a no-boost mask for:

- narrow deep notches;
- bins with low SNR;
- regions where enabled positions disagree in sign;
- frequencies below/above native extension;
- regions with excessive spatial variance.

### 7.4 Filter allocation and optimization

For each output channel:

1. Determine available supported PEQ bands from the live device model.
2. Build the robust target-error curve.
3. Add a low or high shelf candidate only when broad error of the same sign persists for at least half an octave.
4. Seed a peaking filter at the remaining error feature with the greatest area, not merely the deepest point.
5. Estimate initial Q from feature bandwidth and clamp it by frequency/sign constraints.
6. Jointly optimize all current filter parameters against every position.
7. Add another candidate only while it materially improves cross-position error.
8. Drop filters with negligible gain or benefit and re-optimize.
9. Quantize exactly as the DSPi write path will quantize. The on-wire representation and resolution of frequency, Q, and gain in `REQ_SET_EQ_PARAM` must be established from the firmware and pinned by a test before the optimizer assumes anything about it; an optimizer that converges to a precision the wire cannot carry will produce a result that does not match the hardware.
10. Re-optimize free gains after quantization and evaluate with the same RBJ formulas, the same `float` coefficient precision, and the **live device sample rate** used by firmware (section 4.1).

Use multiple deterministic starts around the seeded solution to reduce local-minimum sensitivity. Record the algorithm version, configuration, random seed, convergence reason, and objective history in the project.

The initial production candidate is a C++ implementation using L-BFGS-B box-constrained optimization, with AutoEq's SLSQP result used as a development oracle. `LBFGS++` is MIT licensed and cross-platform, though it brings Eigen (MPL-2.0). NLopt/SLSQP is a viable LGPL alternative in this GPL application. The dependency choice should be made in a short prototype benchmark rather than embedded in the public project format.

### 7.5 Channel symmetry and grouping

Grouped channels share target **shape**, not filters. Each channel receives filters calculated from its own measurements. This retains tonal consistency without pretending left and right speakers have identical room interactions.

**Preserving relative level is not the same as doing nothing, and the no-boost policy makes this mandatory rather than optional.** A cut-only correction lowers a channel's broadband level by roughly the average depth of its cuts. Because every channel has a different room interaction, each one loses a different amount. A channel whose correction happens to be gentle emerges louder than a channel that needed deep modal cuts, so applying correction silently re-balances the system even though no level control was touched. On a stereo pair this shifts the phantom image; on a multichannel layout it degrades the whole spatial presentation. The result is that an otherwise correct tonal correction can be judged as sounding worse, for a reason that has nothing to do with tonality.

Version 1 must therefore:

- compute, per channel, the broadband level change the correction introduces, weighted over the correction band;
- compensate it with **output trim** so that the pre-correction relative balance between channels is preserved;
- report the applied compensation and the pre-existing broadband level differences, and include the trim change in the snapshot and rollback path.

This is distinct from, and should not be confused with, **automatic channel level matching**, which sets the channels to equal measured level and is a change to system calibration rather than a preservation of it. Automatic level matching remains a separate, opt-in, post-version-1 discussion. Preserving what the user already had is not optional, because the alternative is changing it by accident.

The same argument applies to delay, but with the opposite conclusion for version 1: magnitude correction does not alter arrival times, so leaving delay untouched genuinely preserves the existing state. Per-channel distance and delay should be measured, retained, and displayed, but not applied.

## 8. Preserving DSP state and safety

Before level check, create a session snapshot containing at least:

- selected output PEQ banks and bypass state;
- crossover banks;
- output enable, mute, trim, and delay;
- master/user volume and mute state where observable;
- loudness, leveller, psychoacoustic bass, crossfeed, and other nonlinear/dynamic processing that can affect a measurement;
- active preset identity and device identity;
- generator state.

Room measurement requires a linear, stable signal path. Temporarily disable dynamic processing that is in the generator-to-output path. Temporarily bypass or clear only the selected outputs' ordinary PEQ, while always preserving crossovers and protection filters. The exact temporary-state list must be confirmed against the firmware signal-flow diagram.

On cancel, close, error, or successful save without apply, restore the snapshot and verify it. Maintain an on-disk recovery journal before changing the device. If the app or device disconnects mid-session, offer **Restore Pre-Measurement Settings** on the next connection to the same hardware.

If external controls change relevant DSP state during measurement, pause and require either restoration or restarting the affected measurements. Preset load must abort the active capture.

## 9. Portable architecture

```text
SwiftUI room-correction window
        |
RoomCorrectionCoordinator (Swift)
        |------------------------ DSPViewModel / USBDevice
        |
AudioCaptureBackend protocol
        |-- CoreAudio AUHAL (macOS)
        `-- WASAPI capture (Windows later)
        |
C ABI wrapper
        |
libdspi_room_correction (portable C++17)
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
- Deterministic output for identical inputs and algorithm version.
- Cancellation and progress callbacks accepted by long-running operations.
- No audio-device access inside the core.
- FFT behind an interface. A portable BSD-licensed implementation such as KissFFT is suitable; Accelerate may be used by a macOS adapter only if identical golden tests pass.
- A standalone command-line harness must be able to load a saved project, recalculate filters, and emit metrics on macOS and Windows.

Note that **the repository currently has no CI** (`.github/` contains only `FUNDING.yml`). Several of this specification's guarantees are cross-platform determinism claims, and the `DSPMath` parity requirement in section 4.1 exists specifically to stop two implementations of the same filter math from drifting apart. Neither survives without automated enforcement. Standing up CI that runs the pure-logic and core golden tests on macOS and Windows is a prerequisite of Milestone 1, not a later cleanup task.

The existing `DSPi ConsoleTests` target already separates pure-logic tests that run anywhere from live-device tests that self-skip without hardware. The portable core's tests belong in the first tier and should follow the same convention.

### 9.2 macOS capture

Use CoreAudio's HAL/audio-unit APIs for explicit input-device selection, timestamps, and stable device UIDs. `AVAudioEngine` may be used only if it can meet those selection and timestamp requirements without relying on the system default device.

Add `NSMicrophoneUsageDescription` and, if App Sandbox is enabled now or later, the audio-input entitlement. Handle denied permission as a Setup-screen state with a path to System Settings.

The capture backend supplies interleaved or planar Float32 frames plus host timestamps. It must survive arbitrary hardware sample rates by converting to the analysis rate outside the real-time callback. Never allocate, parse files, run FFTs, or update SwiftUI from the real-time audio callback.

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

From every transient state, Cancel first stops the generator, then stops capture, then restores temporary DSP state. Device or microphone loss follows the same cleanup path and leaves a resumable draft.

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

The firmware tree already provides `DSPI_LOOPBACK` builds (`build-rp2040-loopback`, `build-rp2350-loopback`) that capture output slot 0 back to the host. This gives a purely digital reference path with no microphone, no acoustics, and no independent clock, which is the correct fixture for validating sweep reconstruction and deconvolution in isolation before any acoustic variable is introduced. Characterize against this first; an analog loopback then adds the converter chain, and only then does an acoustic measurement add the room.

Repeat the characterization at 44.1, 48, and 96 kHz. Explicitly verify the claim in section 4.1 that unsupported rates produce an incorrect sweep trajectory, so the gate is justified by evidence rather than by source reading.

For an electrical flat loopback, target magnitude error should be within ±0.25 dB over the declared valid analysis range. For a known analog EQ fixture, DSPi Console and REW traces should agree within ±0.5 dB after using the same calibration and smoothing policy.

### 12.3 Optimizer quality gates

On correctable synthetic responses:

- exact predicted DSPi response after parameter quantization;
- no constraint violations;
- no positive combined response in default no-boost mode;
- lower robust weighted error than the uncorrected response;
- no material worsening of the worst enabled position;
- convergence reproducible across macOS arm64/x86_64 and Windows x64.

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

- Freeze the current DSPi sweep law through firmware documentation or loopback characterization.
- Build synthetic fixtures and a Python/REW comparison corpus.
- Prototype the multi-position objective in Python using AutoEq/SciPy ideas.
- Benchmark L-BFGS-B and SLSQP production candidates.

Exit: the proposed algorithm reliably avoids local-null boosts and outperforms a simple averaged-curve fit on the corpus.

### Milestone 1 - portable core

- C++ project model, calibration parser, FFT/deconvolution, smoothing, statistics, target generator, exact DSPi biquads, optimizer, C ABI, and CLI.

Exit: all core golden tests pass on macOS and Windows CI.

### Milestone 2 - macOS measurement

- Microphone permissions, CoreAudio device picker/capture, level check, generator orchestration, position capture, quality analysis, cancellation, and recovery journal.

Exit: repeated real-device measurements agree with REW within the measurement tolerances.

### Milestone 3 - target and results

- Target editor, channel grouping, calculation progress, plots, filter tables, project save/reopen, and text export.

Exit: an offline saved project can be retargeted and deterministically recalculated.

### Milestone 4 - safe apply and verify

- Channel checklist, write/readback/rollback, unsaved-preset integration, verification sweep, and level-matched bypass audition.

Exit: fault-injection tests prove rollback and recovery behavior.

### Milestone 5 - tuning and Windows backend

- Blind/listening comparisons, default tuning, WASAPI capture adapter, Windows UI integration, and cross-platform project compatibility.

## 14. Research conclusions and licensing

- [AutoEq](https://github.com/jaakkopasanen/AutoEq) is MIT licensed and is the best reusable reference for PEQ parameter seeding, constrained fitting, shelf filters, and filter-sharpness penalties. Its [algorithm notes](https://github.com/jaakkopasanen/AutoEq/wiki/How-Does-AutoEq-Work%3F) describe an SLSQP objective and why plain mean-square error is insufficient.
- [REW's measurement guidance](https://www.roomeqwizard.com/help/help_en-GB/html/makingmeasurements.html) supports logarithmic sweeps, pre-capture level checking, calibration files, explicit timing detection, and avoiding invalid clipped captures. Its [EQ guidance](https://www.roomeqwizard.com/help/help_en-GB/html/eqwindow.html) motivates correction curtains, target-level placement, boost/Q limits, broad shelves, variable smoothing, and avoiding boost outside native roll-off. REW is a behavioral reference; its implementation is not open source.
- [REW's calibration-file documentation](https://www.roomeqwizard.com/help/help_en-GB/html/calfiles.html) provides a practical interoperable format, including USB microphone sensitivity headers.
- [Farina's swept-sine work](https://www.angelofarina.it/Public/Papers/list_pub.htm) is the measurement basis for exponential-sweep deconvolution and harmonic separation.
- Multi-position frequency-domain work such as [Carini et al.](https://doi.org/10.1109/TASL.2011.2158420) and the [AES spatial-averaging study](https://assets.ctfassets.net/4zjnzn055a4v/6nKDWR1VsWp2WkaAqdvdDT/09402de507362053495f5f53e8a86d87/AES_141_-_Spatial_Stability_of_the_Frequency_Response_Estimate_and_the_Benefit_of_Spatial_Averaging.pdf) supports extracting response features common across a listening area rather than inverting one point literally.
- [Dirac's own technical discussion](https://www.dirac.com/wp-content/uploads/2021/09/On-equalization-filters.pdf) shows why robust correction should avoid spatially unstable behavior and why a magnitude-only minimum-phase system cannot reproduce all mixed-phase benefits. Dirac's [product description](https://www.dirac.com/products/room-correction) confirms the importance of multiple positions and editable target curves.
- [IK's ARC description](https://www.ikmultimedia.com/news/?id=IKReleasesArcStudio) highlights correction-range limits and adjustable correction resolution as important user controls. Those concepts are applicable without copying its proprietary algorithm.
- [Cavern QuickEQ](https://github.com/VoidXH/Cavern) is an interesting open-code room-correction reference, but its custom license restricts commercial/public use and is not suitable for incorporation without separate permission.
- [LBFGS++](https://github.com/yixuan/LBFGSpp) (MIT) and [KissFFT](https://github.com/mborgerding/kissfft) (BSD-3-Clause) are plausible portable building blocks. Dependency notices and exact versions must be recorded if adopted.
- **DSPi Console is GPL-3.0** (verified against the repository `LICENSE`). This resolves the licensing questions raised in section 7.4 favorably: MIT (LBFGS++, AutoEq, KissFFT's BSD-3-Clause) and MPL-2.0 (Eigen) are all GPL-3.0 compatible, and LGPL (NLopt) is usable. The genuine constraint is the other direction: any code derived from this project inherits GPL-3.0, which is worth confirming as acceptable before the portable core is factored out as a reusable library, since that is the natural point at which someone would want to link it from something else. Cavern QuickEQ remains excluded on its custom license regardless.

## 15. Decisions requested before implementation

Recommended defaults are included so work can begin without blocking, but these product decisions should be confirmed:

1. **Existing PEQ:** replace the selected output PEQ banks, preserving crossovers and restoring the original banks unless Apply succeeds. Recommended: yes.
2. **Standard measurement plan:** 5 positions with the main position weighted 2×. Recommended: yes.
3. **Boost policy:** no positive combined correction by default; Advanced mode allows up to +3 dB with explicit headroom handling. Recommended: yes.
4. **Correction range:** full-range measurement, but Auto curtains and conservative high-frequency correction. Recommended: yes.
5. **Channel level/delay:** measure, retain, and display both. Do not apply delay. Do apply the output-trim compensation needed to preserve the pre-correction relative levels between channels, because a cut-only correction otherwise changes them by accident (section 7.5). Automatic channel level *matching* stays out of version 1. Recommended: yes.
6. **Raw capture retention:** keep lossless raw captures in `.dspirc` by default, with a smaller-project option that keeps only extracted responses. Recommended: yes.
7. **Position maximum:** allow 1–21 so the same flow covers quick desktop work and a wide seating area. Recommended: yes.
8. **Sample-rate gate:** refuse to measure at any rate other than 44.1, 48, or 96 kHz, because the generator's sweep trajectory is not trustworthy elsewhere (section 4.1). This is a hard block rather than a warning, since the resulting measurement is invalid in a way the user cannot detect. Recommended: yes.
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
- A hard sample-rate gate with a clear explanation (section 4.1).
- A session-duration estimate before the user commits to a measurement plan.
- Correction curtains and automatic native-bandwidth detection.
- Spatial spread visualization, not only an averaged trace.
- No-boost default and explicit headroom accounting.
- Project save independent of hardware apply.
- Crash/disconnect recovery journal for temporary DSP changes.
- Read-back verification and rollback when applying filters.
- A post-apply verification sweep.
- Level-matched correction bypass for listening comparison.

These features will contribute more to a professional result than exposing many optimizer knobs to the user.
