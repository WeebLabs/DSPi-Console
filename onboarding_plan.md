# Onboarding Plan

Status: proposal, not yet implemented. Target: 1.1.7.

## 1. The core idea

Do not build "an onboarding". Build three separate things that share one
persistence model:

| Layer | What it is | When it runs | Blocking? |
|---|---|---|---|
| **Getting Started** | Linear setup wizard: flash a board, define the hardware, hear USB audio | First launch on a machine with no prior state, or on demand from Help | Takes over the main window for a first-time user; skippable in one click |
| **Basics tour** | ~7 coach marks over the real UI | Once, after setup succeeds | Non-blocking overlay, Esc dismisses |
| **Just-in-time hints** | One card the first time a specialist window opens | Whenever the user first opens that feature | Small, inline, dismisses itself |

The third layer is the important one and the part most apps skip. DSPi Console
has roughly a dozen specialist subsystems (Matrix Mixer, Control Surfaces,
Control Interfaces, macros, groups, ADAT, I2S, S/PDIF input, Linkwitz
Transform, AutoEQ, siggen, room correction). Touring those up front teaches
nothing, because the user has no context to hang them on, and it makes the tour
long enough that everyone skips it. Explaining each one at the moment it is
first opened is both more effective and solves the version problem for free: a
new feature ships with its own first-open hint, and new users and updaters both
see it exactly once, when it becomes relevant.

## 2. Version gating

One mechanism covers new users, updaters, and per-feature hints.

Persist a **set of completed step IDs**, not a boolean:

```
onboarding.completedStepIDs   [String]   stable IDs, never reused
onboarding.lastSeenVersion    String
onboarding.tourDeclined       Bool       "never show me tours"
onboarding.firstLaunchDate    Date
```

Every step declares:

```swift
struct OnboardingStep {
    let id: String              // "basics.save-vs-commit"
    let introducedIn: String    // "1.1.7" - a published point release
    let phase: Phase            // .setup, .basics, .justInTime(window:)
    let applies: (DSPViewModel) -> Bool   // capability / platform gate
}
```

At launch: `pending = catalogue.filter { !completed.contains($0.id) && $0.applies(vm) }`.

- A brand-new user has an empty completed set, so they get everything.
- An updater already carries the old IDs, so only the new steps are pending.
- Skipping marks the steps completed, so nothing reappears.
- With beta suffixes dropped in favour of point releases (see `CLAUDE.md` >
  Releases), `introducedIn` is just a version. Every published build has its
  own number, so there is no "same version, different build" ambiguity to
  reason about.

**Presentation differs by cohort, mechanism does not.** With an empty completed
set, run the full sequence framed as setup. With a non-empty set, show one
unobtrusive banner ("3 new things in 1.1.7 - Show me / Later / Never") that
then runs only the pending steps.

**Existing beta users are opt-in.** (Decided.) On first launch of the first
onboarding-capable build, detect prior use - no `onboarding.*` keys present but
other app defaults are, e.g. `graphMinFreq` - and seed every existing step ID
as completed. Then offer the tour once as a dismissible banner rather than
running it. Everything stays reachable from the Help menu afterwards.

## 3. Getting Started wizard: what it covers

Goal, decided: get the user to a basic working state where **their computer's
USB audio comes out of the DSPi**. Not a full configuration, not crossovers,
not room correction. Sound out of the box, then hand over.

Ordering follows the path to that first audible success:

1. **Welcome.** Two sentences on what DSPi is. Buttons: *Set up a board* /
   *I already have one connected* / *Skip setup*.
2. **Board setup.** Detect a board in BOOTSEL mode, identify the chip, write
   the bundled matching firmware, verify by re-enumeration. Details in
   section 5. Fully skippable; a board already running DSPi jumps past it.
3. **Describe the hardware.** How many S/PDIF outputs, which GPIOs, is there a
   PDM sub. This is the one piece of configuration that genuinely belongs in a
   wizard, because it is not guessable and the app does nothing useful until it
   is right.
4. **Route audio to it.** Select DSPi as the macOS output device. Users will
   get stuck here. Provide a button that opens Sound settings, then watch the
   existing input meters and confirm out loud: *"Signal detected - you are
   connected."* That single beat is what converts a confused user into a
   confident one, and the metering plumbing already exists.
5. **Hand off.** "You are set up. Want a two-minute tour?" leading into the
   basics tour, or straight into the app.

## 4. Blocking behaviour

Decided: a first-time user with no device connected should not be dropped into
a window full of dead controls.

Implement this as a **full-window takeover of the main window's content**, not
as a separate modal window. The wizard replaces the sidebar and detail panes
while it is active and gives them back on completion or skip. This matters:

- Nothing is technically modal, so the menu bar stays live and the user can
  reach Help, Settings and Quit. A modal window over a dead UI traps people.
- One window, not two. The app already juggles a lot of tool windows.
- *Skip setup* is always visible and lands the user in the normal interface
  (with the improved empty state from section 7), never back in the wizard.

Guard rails on when it takes over:

- Only when the completed step set is empty. A returning user with an unplugged
  device sees the empty state, never the wizard.
- Never when a device is already connected and healthy; that case goes straight
  to the tour offer.
- Never a dead end: if bootloader detection fails or hardware behaves oddly,
  there is always *Continue without a device*.
- A device appearing mid-wizard advances the flow rather than restarting it.

## 5. Basics tour: what it covers, in order

Coach marks anchored to the real UI, one action required.

1. **Sidebar.** Inputs and outputs, click a row to edit it, what the meters show.
2. **The graph.** Which curve is displayed, per-channel visibility toggles.
3. **Add a filter.** Have the user actually add one peaking filter to an input:
   type, frequency, Q, gain. A tour with one real action is remembered; a tour
   that only points at things is not.
4. **Preamp and volume.** Where master volume lives, why preamp exists
   (headroom before clipping), what the clip indicator means.
5. **Saving.** The `*` unsaved marker, Tools > Commit Parameters, Revert to
   Saved. RAM versus flash is the single highest-support-cost concept in the
   app. It belongs here, early and explicit, not buried at step twelve.
6. **Presets.** Ten slots, naming, switching, and that switching discards
   uncommitted work.
7. **Where the rest lives.** One card covering the quick-access icon strip at
   the bottom of the sidebar and the Tools menu. Not eleven cards. "You will
   find the rest here when you want it."

### Explicitly out of scope for the base tour

Matrix Mixer, Control Surfaces, Control Interfaces, macros, channel groups,
ADAT in/out, I2S input and clocking, S/PDIF input selection, Linkwitz
Transform, AutoEQ, room correction, test signals, stats, interrupt monitor.

Each is specialist, most are hardware-conditional, none are on the path to
first sound. Each gets a just-in-time hint on its first open instead.

## 6. Firmware: bundling, matching, and flashing

Decided: **bundle both `.uf2` files in the app.** Roughly 1 MB total. The real
argument is not offline install, it is that the app gates dozens of features on
firmware and wire-format versions, so shipping the matched pair eliminates an
entire class of "why can't I see the Upmixer" support traffic.

The release checklist that keeps app and firmware in lockstep now lives in
`CLAUDE.md` under **Releases**.

### Version encoding: widen the fields

Decided: **point releases only, no beta suffixes**, because the device cannot
report a suffix and two builds sharing `major.minor.patch` are indistinguishable
over USB. The policy lives in `CLAUDE.md` > Releases.

That decision runs into an encoding limit. `REQ_GET_PLATFORM` (0x7F) returns 4
bytes and the firmware packs the version as
`(major << 8) | (minor << 4) | patch` (`FW_VERSION_BCD`, `config.h:593`). The
comment calls it BCD but it is plain nibble packing with no carry handling, so
**minor and patch each cap at 15**. Major is a full byte.

One point release per published build burns patch numbers quickly: 1.1.4
shipped about six betas and 1.1.5 about six more, so at that pace 1.1.x would
exhaust patch 15 inside two release cycles. Nothing breaks when it does - the
`firmwareSupportsX` helpers compare version tuples, so `(1,2,0) >= (1,1,4)`
holds - but the version number would then be driven by an encoding limit rather
than by meaning.

**Proposal: widen the fields, backwards compatibly.** Keep bytes 0-3 exactly as
they are and append full-width `minor` and `patch` as bytes 4 and 5. The app
requests 6 bytes and prefers the wide fields when the response is at least 6
bytes long, falling back to the nibbles otherwise.

- Old Console against new firmware: asks for 4, gets the unchanged first four
  bytes, still parses correctly.
- New Console against old firmware: gets 4, falls back to the nibbles.
- Cost: three lines in `vendor_commands.c` and one conditional in
  `fetchPlatform()`.

Do this **before** auto-update ships. Afterwards, a change to the version
encoding is a change the updater itself has to negotiate across versions, which
is the one place that problem is genuinely expensive.

### Detection

- BOOTSEL enumerates as VID `0x2E8A` (Raspberry Pi), PID `0x0003` for RP2040
  and `0x000F` for RP2350. Note the app's own device is `0x2E8B:0xFEAA` - a
  *different* vendor ID - so bootloader matching must hardcode `0x2E8A` and
  cannot reuse `USBDevice.vendorID`. Verify both PIDs against real boards
  before shipping.
- Reuse the IOKit matching notification machinery already in `USBDevice.swift`
  (`IOServiceAddMatchingNotification`) with a second matching dictionary. The
  USB match tells you *which chip*.
- Separately watch `NSWorkspace.shared.notificationCenter` for
  `didMountNotification` and look for `RPI-RP2` (RP2040) or `RP2350`. The mount
  tells you *where to write*. Require exactly one; refuse to guess if two
  bootloader devices are present.

### Writing

- Copy the `.uf2` to the volume root. The board reboots itself partway through
  the final blocks, so **the volume vanishing mid-write is the success path,
  not an error**. Write in chunks with `FileHandle` so progress is reportable
  and so a trailing `EIO`/`ENXIO` on the last write can be swallowed
  deliberately. Getting this wrong is the classic failure of every UF2 flasher.
- Success is *not* "the copy returned". Success is: wait up to ~10 s for
  `0x2E8B:0xFEAA` to enumerate, then read `REQ_GET_PLATFORM` and confirm the
  platform and version match what was written. Report that version to the user.
- macOS will show a removable-volume TCC prompt the first time. The app is not
  sandboxed (empty entitlements file), so this is one Allow click, but the
  wizard should pre-warn so the prompt is not a surprise. Add
  `NSRemovableVolumesUsageDescription` to Info.plist.

### Safety rules

- Never flash automatically. Always show board type, firmware version and file
  name, and require an explicit click.
- If a working DSPi is connected, offer *Export Device Configuration* before
  rebooting to bootloader. A UF2 write does not target the preset sectors, but
  a wire-format bump can invalidate them.
- Refuse when more than one bootloader device is attached.
- Provide a manual escape hatch: "My board is running something else" with the
  physical instructions (hold BOOTSEL while plugging in USB). A board running
  unrelated firmware is indistinguishable from no board at all, and the wizard
  must not dead-end there.

### Build it as a reusable component

`FirmwareInstaller` must be usable outside the wizard, because three callers
want it: the wizard, `Tools > Firmware Update...` (which today just reboots to
bootloader and leaves the user to drag a file), and the future auto-updater.

## 7. Designing now for auto-update later

Auto-update is not in this scope, but a few choices made now decide whether it
is cheap or painful later.

- **One source of truth for the expected firmware version.** A constant in
  `Constants.swift` derived from `MARKETING_VERSION`, so every caller asks the
  same question. Add it with the onboarding work even though only one thing
  uses it at first.
- **Ship the version-mismatch banner in 1.1.7**, ahead of any auto-update. When
  the connected device's version differs from the expected one, show a banner
  offering *Update firmware*, wired to `FirmwareInstaller` and the bundled
  `.uf2`. This is small, immediately useful, and it is most of the auto-update
  UI already built.
- **Order of operations is app first, firmware second.** The new firmware
  arrives inside the new app bundle, so the app must update before it can
  install the matching firmware. Any future combined flow follows that order.
- **Handle downgrades, not just upgrades.** If a user reverts to an older
  Console, its bundled `.uf2` is older than the device. That is a downgrade
  offer, not an error, and the wording must say so.
- **Widen the version fields first** (see section 6). An updater that has to
  negotiate its own version encoding across releases is a problem worth not
  having.

## 8. Quality-of-life changes in the same spirit

Each of these independently removes a reason someone would need the tour.

- **Empty state for the main window.** Today, no device means a window full of
  disabled controls. Replace it with "No DSPi connected", a *Set Up a Board*
  button, and a hint to check the cable. This is where a returning user with an
  unplugged device lands, and it is the re-entry point into the wizard.
- **A Help menu.** There is none. Add *Getting Started...*, *Replay Basics
  Tour*, *What's New*, *Documentation*. Users look in Help.
- **A What's New sheet**, version-keyed, separate from the tour. Release notes
  are not onboarding and should not be delivered as coach marks.
- **Sample presets.** Ship one or two example configurations (a 2.1 crossover
  is the obvious one) that the wizard can offer to load. Nothing explains a
  crossover faster than seeing one already wired up.
- **Tooltip sweep.** There are only ~50 `.help()` modifiers across 40k lines.
  The app uses terms a newcomer will not know (preamp, Q, PDM, S/PDIF, wire
  format, biquad). A consistent tooltip pass plus one "?" popover per settings
  section is cheaper than tour steps and permanently useful.

## 9. Implementation shape

New files, mirroring the existing tool-window pattern:

```
DSPi Console/Onboarding/
  OnboardingCatalogue.swift    step definitions, IDs, applicability
  OnboardingCoordinator.swift  ObservableObject on AppState; decides what shows
  OnboardingDebug.swift        every dev override in one place (section 10)
  GettingStartedView.swift     the wizard, hosted in the main window
  FirmwareInstaller.swift      detect / write / verify; also used by Tools menu
  CoachMark.swift              anchor-preference spotlight overlay
  WhatsNew.swift + WhatsNew.json
DSPi Console/Firmware/
  DSPi-RP2040-v<version>.uf2
  DSPi-RP2350-v<version>.uf2
```

**Coach mark anchoring:** use `.anchorPreference(key:value:)` behind a tiny
`.onboardingAnchor("sidebar.inputs")` modifier, collect anchors in one overlay
at the window root, and draw the cutout and callout from there. That avoids
hardcoded coordinates and survives layout changes. Applying the modifier to
~10 existing views is a small, low-risk diff to `ContentView.swift`.

## 10. Dev and test flags

Everything simulatable, in one place. `OnboardingDebug` reads `UserDefaults`,
which picks up `-key value` launch arguments for free, so the same overrides
work from Xcode schemes, the command line, and the UI.

Settings > Advanced gains an "Onboarding (Developer)" section, hidden behind
the existing `showDebugInfo` toggle:

| Override | Values | Simulates |
|---|---|---|
| Cohort | fresh / updater-from-X / declined / seeded-existing | Every branch of section 2 |
| Force wizard | on / off | The takeover even with a device attached |
| Bootloader board | none / RP2040 / RP2350 / two boards | Detection, including the refuse-to-guess case |
| Flash outcome | success / write fails midway / volume never mounts / verify times out | Every failure path without re-flashing hardware |
| Reported firmware version | any `major.minor.patch` | The mismatch banner and downgrade wording |
| Audio signal detected | auto / force yes / force no | Wizard step 4 without real playback |
| TCC volume prompt | assume granted / assume denied | The removable-volume denial path |

Plus buttons: *Reset onboarding* (clears every `onboarding.*` key), *Replay
basics tour*, *Clear just-in-time hints only*.

Launch arguments for scripted runs:

```
-onboarding.completedStepIDs '()'          force fresh
-onboarding.lastSeenVersion 1.1.6          force updater
-DSPiSimulateBootloader rp2350             fake board
-DSPiSimulateFlashOutcome writeFailed      fake failure
-DSPiSimulateFirmwareVersion 1.1.5.0       fake mismatch
```

### Tests

Pure-logic tests in the existing `DSPi ConsoleTests` target. Step selection is
exactly the kind of thing that regresses silently, so it is worth the coverage:

- fresh user gets every applicable step
- updater gets only steps whose `introducedIn` exceeds their last seen version
- seeded existing user gets none, and the opt-in banner fires once
- declined user gets nothing thereafter
- unknown IDs already in defaults are ignored, not crashed on
- capability gating hides RP2350-only steps on an RP2040
- version comparison does not treat `1.1.10` as older than `1.1.9`, and the
  wide-field parse in `fetchPlatform()` agrees with the nibble fallback for
  every version where both are representable (minor and patch <= 15)
- `FirmwareInstaller` behind a `BootloaderLocating` protocol seam, driven by a
  fake volume path and fake enumeration, covering each flash outcome above -
  including the "volume vanished mid-write" success case

## 11. Build order

Four phases, each independently shippable. The order is chosen so the riskiest
work lands first and the parts that depend on it come later.

### Phase 1 - Firmware plumbing (useful even if onboarding never ships)

- `fetchPlatform()` requests 6 bytes and prefers the full-width minor/patch at
  bytes 4-5, falling back to the nibbles on a short read. Matches the firmware
  change in `5fa3626`.
- Expected-firmware constant in `Constants.swift`, derived from
  `MARKETING_VERSION`.
- `FirmwareInstaller`: bootloader detection, UF2 write, re-enumeration verify,
  behind a `BootloaderLocating` seam with tests for every outcome.
- Bundle the two `.uf2` files; wire `Tools > Firmware Update...` to the
  installer so it stops being a "drag a file yourself" alert.
- Version-mismatch banner.

Nothing here is onboarding, and all of it stands on its own. It is also the
riskiest code in the whole plan, so it should not be gated behind UI work.

### Phase 2 - Onboarding machinery (no visible onboarding yet)

- `OnboardingCatalogue`, `OnboardingCoordinator`, `OnboardingDebug`.
- The step-selection tests from section 10.
- Settings > Advanced developer section and the launch-argument overrides.
- Help menu and the What's New sheet.

Pure logic plus two small surfaces. Everything is exercisable through the dev
flags before a single coach mark exists.

### Phase 3 - The wizard

- Main-window takeover and its guard rails (section 4).
- The five setup steps (section 3).
- The improved empty state for a returning user with no device (section 8).

### Phase 4 - Tour and hints

- `CoachMark` overlay and the `.onboardingAnchor` modifier.
- The seven basics steps (section 5).
- First-open hints for the specialist windows.

Phase 4 is the most deferrable. If it slips a release, phases 1 to 3 still
leave a new user better off than today.

## 12. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Bundle the `.uf2` files or download them? | **Bundle.** Download path can come later for updates. |
| 2 | What do existing beta users see? | **Opt-in.** Seed as completed, offer the tour once. |
| 3 | How far does the wizard go? | **To USB audio playing through the DSPi**, including output/GPIO config. |
| 4 | Does the wizard block the main window? | **Yes, for a first-time user only**, as a main-window takeover rather than a modal window. |

| 5 | Beta suffixes or point releases? | **Point releases only** for anything published; `CFBundleVersion` for private test builds. |

### Still open

- Widen `REQ_GET_PLATFORM` to carry full-width minor and patch (section 6).
  Firmware-side change, wanted before auto-update, not urgent for onboarding.
