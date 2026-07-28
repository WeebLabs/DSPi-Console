# libdspi_rc - portable room-correction core

Platform-neutral C++17 implementing the measurement analysis and correction
maths for DSPi Console's Room Correction feature. See
`Documentation/automated_room_correction_spec.md` section 9.

## Why this is a separate library

The feature ships on macOS first and Windows later. Everything here is
standard C++17 with no third-party dependencies, so the same sources build on
both. Anything platform-specific - audio capture, audio playback, USB, UI,
file dialogs - lives in the application and is passed in as plain data.

Hard rules, enforced by review:

- no Foundation, CoreAudio, Accelerate, Swift, Win32, COM, or UI types;
- no audio-device access inside the core;
- double precision for measurement, statistics, fitting and prediction, with
  float only where the wire or the firmware uses float;
- deterministic output for identical inputs and algorithm version.

## Build and test

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/dspi_rc_tests
```

`ctest --test-dir build` works too. The build sets
`CMAKE_EXPORT_COMPILE_COMMANDS`, and `compile_commands.json` in this directory
is a symlink into `build/` so clangd resolves headers.

## What is here

| Component | Status |
|---|---|
| `types` - filter params, platform, frequency grid | done |
| `biquad` - faithful DSPi filter model | done |
| sweep synthesis and inverse filter | done |
| FFT abstraction | done |
| deconvolution and IR windowing | done |
| calibration parsing | done |
| smoothing and spatial statistics | done |
| target construction | done |
| constrained PEQ optimizer | pending |
| C ABI and CLI harness | pending |

## The filter model is a model of *this* hardware

`biquad.cpp` is not a general biquad library and should not be tidied into
one. It reproduces what the firmware actually runs, including choices that
look like mistakes in isolation:

- the firmware's truncated pi literal `3.1415926535f` rather than `M_PI`;
- single-precision coefficient design, because the firmware designs in float
  and a double design diverges first exactly where high-Q low-frequency
  filters live;
- the RP2350 trapezoidal SVF used below Fs/7.5, whose discrete transfer
  function is not the bilinear biquad's;
- RP2040 Q28 storage with truncation toward zero, matching the firmware's C
  cast, and its direct-division normalization rather than RP2350's
  reciprocal-and-multiply.

Predicting anything less faithfully means the optimizer converges on a
response the hardware does not produce. Reference: firmware
`dsp_pipeline.c:96-318` on `release/v1.1.5` (`9776c2f`).

## Two findings worth not rediscovering

**The deconvolved impulse is symmetric, not causal.** The inverse filter
compensates the sweep's phase, so energy sits on both sides of the peak. A
pre-peak window that is too short attenuates the low end, and the result looks
like a genuine rolloff rather than an artifact: truncating at 5 ms costs about
1.2 dB at 50 Hz. Use `recommendedPreWindowSeconds` rather than a constant.

**High-Q resonances need more pre-window than the skirt alone suggests.** A
resonance rings for roughly `Q/(pi*f)` seconds, and convolved with the
symmetric skirt that energy spreads before the peak too. Measured against a
Q=8 notch at 80 Hz, a two-cycle window recovers it 0.8 dB *too deep*, which
would make the optimizer over-correct a room mode. Four cycles brings the
error under 0.1 dB and is the default. Both effects are pinned by tests.

**Sample rate and platform are always parameters.** Never assume 48 kHz, and
never assume an RP2350 result transfers to RP2040. Section 4.2 of the spec
explains why: the firmware designs coefficients at the live rate, and the two
platforms run structurally different code.

## Testing convention

Tests assert **analytic landmarks** rather than re-deriving the coefficient
formulas, matching the convention in the Swift `DSPMathTests`. Re-deriving a
formula only proves the test and the implementation share a typo. "A peaking
filter has exactly its requested gain at its centre frequency" is independent
of how the coefficients were reached, and holds across the SVF and biquad
paths even though they compute entirely different numbers.

The exception is `svf_matches_rbj_reference_across_the_whole_band`, which does
carry a duplicated RBJ implementation on purpose: the point is to compare two
*independent* derivations across the full curve, since single-point landmarks
can be satisfied by a wrong-but-plausible transfer function.
