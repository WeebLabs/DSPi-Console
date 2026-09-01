# Onboarding Plan

Status: implemented in 1.1.7. Phases 1 to 4 are all in the tree; this
document is now the record of what was built and why, not a proposal.

Two things changed during implementation and are corrected in place below:
the wizard's goal was cut back (section 3), and the tour's coach marks had to
bend around what the interface actually offers (section 5).

## 1. The core idea

Do not build "an onboarding". Build three separate things that share one
persistence model:

| Layer | What it is | When it runs | Blocking? |
|---|---|---|---|
| **Getting Started** | Linear setup wizard: flash a board and verify it | First launch on a machine with no prior state, or on demand from Help | Takes over the main window for a first-time user; skippable in one click |
| **Basics tour** | ~10 coach marks over the real UI, including a visit to the Matrix Mixer | Once, after setup succeeds | Non-blocking overlay, Esc dismisses |
| **Just-in-time hints** | One card the first time a specialist window opens | Whenever the user first opens that feature | Small, inline, dismisses itself |

The third layer is the important one and the part most apps skip. DSPi Console
has roughly a dozen specialist subsystems (Matrix Mixer, Control Surfaces,
Control Interfaces, macros, groups, ADAT, I2S, S/PDIF input, Linkwitz
Transform, AutoEQ, siggen, room correction). Touring those up front teaches
nothing, because the user has no context to hang them on, and it makes the tour
long enough that everyone skips it. The Matrix Mixer turned out to be the one
exception, for the reason given in section 5: it is not a feature you might
want later, it is the routing every other feature depends on, and the tour
opens its window and teaches it there rather than describing it from outside. Explaining each one at the moment it is
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

Goal, **revised**: get the user to a Pico running **verified DSPi firmware**,
and stop. The original goal was USB audio playing through the DSPi, taking in
output types, clock mastering, GPIO assignment and macOS sound routing on the
way. Built out, that was four screens of hardware interrogation in front of
someone who had owned the device for ninety seconds, and every one of those
screens asks a question the app can ask better later, in Settings, where it can
be revisited. Firmware is the one thing that genuinely cannot wait and the one
thing nothing else in the app can do.

Three steps:

1. **Welcome.** What DSPi is, and what this wizard will and will not do.
2. **Board setup.** Detect a board in BOOTSEL mode, identify the chip, write
   the bundled matching firmware, verify by re-enumeration. Details in
   section 6. Skippable in one click.
3. **Hand off.** Confirms the firmware is running and points at where the rest
   lives: outputs and wiring in Settings > Hardware, the DSPi as the macOS
   output device, filters in the sidebar, Help for everything else.

Setup assumes a blank Pico rather than inspecting a connected device. Someone
who already has a working DSPi can skip in one click, and guessing wrong the
other way strands a user on a step that never arrives.

What the removed steps taught, and where it went instead: output types and
wiring are a Settings page (reachable, revisable, and already better than a
wizard screen); the "signal detected" beat became the tour's meter step; the
macOS output-device instruction is the last card of the wizard's hand-off.

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

Coach marks anchored to the real UI, one action required. A view opts in with
`.onboardingAnchor("basics.graph")` and learns nothing else about onboarding;
the overlay at the window root resolves the anchors and draws the spotlight.

1. **Sidebar.** Inputs and outputs, and the two gestures a row carries: the
   name or meter opens that channel's page, while the coloured tag at the end
   shows or hides its curve on the graph. Anchored to the channel list, above
   the bottom inset.
2. **The Matrix Mixer, in three steps, two of them inside the window.**
   **Added during implementation, and the reason the tour is ten steps rather
   than seven.** Routing is not optional knowledge: the firmware's default
   connects left and right to the first output pair and nothing else, so a user
   with a subwoofer, a second pair of speakers or a crossover cannot make the
   device do its job without finding this window. Explaining it only on first
   open was a bet that people would go looking, which is exactly the bet not to
   make on the one screen that stands between them and working audio.

   The first attempt pointed at the button in the sidebar's icon strip and
   described the grid in a paragraph. That was still a failure: it named a row,
   a column and a crosspoint to a user who had never seen any of them, and left
   them to go and find the window afterwards. So the tour now **opens the
   Matrix Mixer itself** and continues inside it - the grid, with an invitation
   to click a crosspoint through the spotlight, and then the per-output ENABLE,
   GAIN, DELAY and MUTE rows - before closing it again and returning to the
   console.

   Mechanically: a step names the `OnboardingHost` it belongs to, every window
   the tour visits carries its own copy of the overlay, and only the host of
   the current step lights anything up. The console stays dimmed and inert
   meanwhile, and the Matrix Mixer floats while it holds a step, because a
   click on a dimmed window still raises it in AppKit and would bury the grid
   being described.

   **The card for a step in a tool window goes in a panel beside it, not in
   it.** The mixer's window is sized to exactly its grid, so a card drawn
   inside lands on top of the thing being described, and the first attempt at
   fixing that - reserving space inside the window - grew the window by a third
   of its height for the duration of two steps, which is worse. A borderless
   child panel travels with the window, costs it nothing, and leaves the
   spotlight where it is (`CoachMarkPanel.swift`). It never takes key from the
   window being explained, so a crosspoint can be clicked without clicking past
   the card first; its content view accepts the first mouse so Next needs no
   focusing click; and Esc still leaves the tour, through a local key monitor
   rather than the card's own shortcut, which would only fire while its own
   window was key.

   Opening and closing the window is driven from `ContentView`, where the
   window controllers already live, so the coordinator stays free of AppKit and
   testable. Closing the mixer mid-step is read as "enough of this" and steps
   the tour past everything hosted there, rather than stranding it with no Next
   button on screen. A window the tour walks through spends its own first-open
   card at the start of the run, so the hint never lands on top of the coach
   mark saying the same thing; a user who skips or defers the tour still meets
   that card on first open, and it still covers per-connection level and
   polarity.
3. **The graph.** What the curve is and which channel it belongs to. Note the
   per-channel visibility toggles are the sidebar's descriptor pills, not a
   legend beside the graph, so the copy does not send anyone looking for one.
4. **Add a filter.** The one step that asks for an action, and the reason the
   spotlight is a real hole rather than a drawn ring: the highlighted control
   stays clickable, so the filter can be added without leaving the tour.
   There is no "add" button - a channel has ten slots and a filter appears when
   a slot is given a type, which is what the card actually says.
5. **Volume controls.** Anchored to the volume control at the foot of the
   sidebar. Revised from the plan's "preamp and volume": the two have nothing
   to do with each other, and the control that actually needs explaining is the
   picker above the slider, which silently switches between two different
   volumes. The card explains both - User Volume tracking the computer's own
   volume keys, Master Volume as a device-level setting the computer never
   touches. **Preamp is consequently no longer covered by the tour**; if it
   wants teaching, it wants its own step next to the channel header, not a
   footnote on an unrelated one.
6. **Saving.** RAM versus flash, the `*` marker, Tools > Commit Parameters and
   Revert to Saved. **Deliberately unanchored**: the controls it describes are
   menu items, which live outside the window and cannot be spotlit, so the card
   is centred rather than pointing at half the story.
7. **Presets.** Ten slots, naming, and that switching discards uncommitted
   work. Anchored to the preset picker, which is also where the `*` from step 6
   appears - the concept card is followed by the widget it named.
8. **Where the rest lives.** The quick-access icon strip at the foot of the
   sidebar and the Tools menu. Not eleven cards. No longer names the Matrix
   Mixer, which now has a step of its own.

Step 4 describes a pane that only exists once a channel is selected, because
the console opens on its overview. It declares `needsChannelDetail`, and the
console selects an input for it, so the mark never points at empty space.
A step whose anchor is genuinely absent (a collapsed pane, a popped-out graph)
still shows its card, centred and without a spotlight, rather than stalling.

### Explicitly out of scope for the base tour

Control Surfaces, Control Interfaces, macros, channel groups,
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

- **Empty state for the main window.** Built, then reverted by decision: a
  returning user with no device keeps the ordinary console and its
  long-standing red "No Devices" indicator. The takeover-style empty state
  (and a blurred-console variant tried after it) both proved worse than the
  familiar window; the wizard remains reachable from the Help menu.
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

### Phase 1 - Firmware plumbing (done)

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

### Phase 2 - Onboarding machinery (done)

- `OnboardingCatalogue`, `OnboardingCoordinator`, `OnboardingDebug`.
- The step-selection tests from section 10.
- Settings > Advanced developer section and the launch-argument overrides.
- Help menu and the What's New sheet.

Pure logic plus two small surfaces. Everything is exercisable through the dev
flags before a single coach mark exists.

### Phase 3 - The wizard (done)

- Main-window takeover and its guard rails (section 4).
- The three setup steps (section 3).
- The improved empty state for a returning user with no device (section 8).

### Phase 4 - Tour and hints (done)

- `CoachMark` overlay and the `.onboardingAnchor` modifier.
- The eight basics steps (section 5).
- First-open hints for the specialist windows.

Phase 4 shipped alongside the rest. It is where the plan's central bet gets
tested: fifteen just-in-time cards against seven coach marks, on the theory
that a feature explains itself best at the moment it is first opened.

## 12. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Bundle the `.uf2` files or download them? | **Bundle.** Download path can come later for updates. |
| 2 | What do existing beta users see? | **Opt-in.** Seed as completed, offer the tour once. |
| 3 | How far does the wizard go? | **Revised: to verified firmware, and no further.** Originally to USB audio including output/GPIO config; cut back during implementation (section 3). |
| 4 | Does the wizard block the main window? | **Yes, for a first-time user only**, as a main-window takeover rather than a modal window. |

| 5 | Beta suffixes or point releases? | **Point releases only** for anything published; `CFBundleVersion` for private test builds. |

### Still open

- Widen `REQ_GET_PLATFORM` to carry full-width minor and patch (section 6).
  Firmware-side change, wanted before auto-update, not urgent for onboarding.
