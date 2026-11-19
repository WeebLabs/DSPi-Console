# Console update: device-reported pin availability

Final (agreed by Opus and Fable; open questions decided 2026-11-18). Spec:
`~/DSPi/Documentation/Features/pin_availability_query_spec.md` (firmware
commit `103ba37` on `release/v1.1.7`).

## Goal

The Console stops computing which GPIOs a function may use. It asks the
device through the `*_PIN_AVAIL` GETs, names owners from `SYS.PIN_CLAIMS`,
and refreshes when the pin generation changes. It also adapts to the new
rule that a function holds its pins only while in use. That rule brings
stored pins, refusals at start sites, and a new required order for applying
many pin settings at once.

## Today (summary of the survey)

- One local rule engine, `DSPViewModel.pinAssignment(_:excluding:)` with
  `enum PinConsumer` (`DSPViewModel.swift:2418`), plus
  `HardwareSettingsTab.validPins` (GPIO 0-22 and 26-28, without 29 on RP2350).
- Further copies of firmware rules at call sites: UART `pin % 4`, I2C
  even/odd, the CS display's I2C instance, `CS_ADC_PINS`, `mckValidPins`,
  button sharing, ADAT loopback and `i2sRaiseConflicts`.
- About 20 picker sites. All of them hide taken pins.
- The local rules encode pre-`103ba37` behaviour that is now wrong: MCK held
  while disabled, the BCK pair held with no clock running, the dormant SPLIT
  pair held, PDM always holding its pin, and I2S RX pairs held when I2S is
  not the source.
- Start-site refusals show generic text or the generic refusal banner.
- `InterruptMonitor` has no case for event 0x11. The Link hub already
  forwards every event verbatim (`LinkHub.swift:322`).
- The Console's registry copy predates the new commands, and DSPi-Link's
  policy does not list them.

## Phases

### 1. Registry, address kind, Link policy

- Copy `dspi_commands.json` and `legacy_map.json` from firmware `103ba37`,
  update `Protocol/README.md`.
- Add the `CS_SLOT_TYPE` address kind to `VendorAddressKind`
  (`VendorCommand.swift:28`), the generator's map
  (`gen-vendor-commands.swift`) and the switches in `LiveCommandSweepTests`.
  The generator fails on an unknown kind otherwise. Then regenerate.
- DSPi-Link: add the 13 GETs as class `read` to `policy/commands.json`,
  `policy/firmware/dspi_commands.json`, `js/packages/dspi-link/src/commands.ts`
  and the ESP32 bridge's generated `link_policy_table.c`
  (`bridge/esp32/tools/gen_policy.py`), then copy the policy into
  `Link/policy/commands.json`. Separate repository; needs your go-ahead.

### 2. Wire decoding (pure, unit tested)

New file `PinAvailability.swift`:

- `PinFunction` with the wire IDs 1 to 12, and one table from function ID
  and index to the display name and `PinRole` the UI already uses.
- `PinAvailability`: status, flags, G, R, generation and `[[MaskPair]]`
  group-major, as `UInt64` masks. Length is validated as
  `count >= 8 + 16*G*R` from the header, not against fixed sizes: XPORT
  replies are 40 bytes on `DSPI_PLATFORM_PINS` builds (G = 1). CS replies are
  a fixed 80 bytes with stride 2 plus the shareable mask.
- Status is typed per family: `VC_ERR_*` for most, `CS_STATUS_*` for CS.
  Flags are documented per family; on CS, bit 2 means "the slot's current
  type differs from the queried type".
- `PinStateReply` (24 bytes, including GPIO mask and substitution mask) and
  `PinClaimsReply` (variable length: request 256, accept a short reply).
- `PinAvailabilityWireTests` with fixtures for 24, 40, 72 and 80 bytes and a
  claims list.

### 3. `PinMap` store

An `ObservableObject` on the view model (`vm.pinMap`), refreshed on its own
serial queue so meters and the RTA on `pollQueue` are not stalled.

- **At connect** (tier 2 of the connect fetch): `SYS.PIN_STATE` and
  `SYS.PIN_CLAIMS` only.
- **Availability sweep** (about 23 GETs on RP2350) runs only while a pin view
  watches, using the existing watcher pattern (`rta.isWatching`,
  `limiter.watchers`). With no watcher, a change only marks the store stale.
- **CS**: when a slot's editor opens, fetch every type the caps table offers
  for that slot (about 10 GETs of 80 bytes), again on a generation change
  while open. This lets `makeBinding` seed synchronously and lets the type
  picker disable IR and Display on `CS_STATUS_IR_IN_USE` and
  `CS_STATUS_DISPLAY_IN_USE`.
- **Triggers**: connect; `PIN_MAP_CHANGED`; `BULK_INVALIDATED` and Link
  RESYNC unconditionally (a board rebooting behind a hub restarts the counter
  at 0 without a new connection); the outcome of every pin SET, start SET and
  deferred apply; the end of `csRevert`, `csSave` and `setCsBinding`; any
  reply carrying an unseen generation. Coalesced.
- **Consistency**: a sweep reads `PIN_STATE` first. If any reply carries a
  different generation, it is rerun, at most 3 times. The snapshot is
  published once on main, guarded by `transport.generation`.
- **Failures**: abort the sweep on the first `.locked`, `.noDevice` or
  `.timeout`, keep the old data, mark it stale, retry later (one lock notice,
  not 23). `.vcUnknown` marks that one command absent. `.denied` gives a
  defined "pin map unavailable" state. `implements()` is not relied on,
  because it is nil over a remote transport.
- **Busy**: a CS `CS_STATUS_BUSY` is not part of the generation hash, and
  `SYS.PIN_CLAIMS` answers `VC_ERR_BUSY` as a GET failure during a CS revert.
  Both get a bounded timed retry and must not fail the rest of the snapshot.
- **Naming**: the counter is `pinGeneration`; `generation` already means the
  connection.
- **Selection drift**: on a generation change while a tab watches, the tab's
  own pin values (`vm.outputPins` and the rest) are re-fetched too.

### 4. `InterruptMonitor`

Add `NOTIFY_EVT_PIN_MAP_CHANGED = 0x11` with a u32 payload and an
`onPinMapChanged` callback that triggers the store.

### 5. Apply order for many pin settings (live regression, do early)

The new firmware breaks the order in which `PresetDocumentTransfer.applyIO`
and Settings Revert apply pins:

- Slot types are set before the BCK pin, so `OUTPUT.TYPE` to I2S is
  start-checked against the old BCK pair, and the later BCK SET answers
  `VC_ERR_STATE`.
- The input source is sent (`applyFeatureBlocks`) before the I2S pins.
- The PDM cycle (disable, store the pin, re-enable through `send`) can store
  a held pin and then have the re-enable refused silently. After the disable
  PDM can still be fading out and answer `OUTPUT_ACTIVE`.

One shared routine replaces these paths, used by the document apply,
Settings Revert and Reset Pins. It works from device answers, not from a
precomputed plan:

1. **Release.** Switch off every function with an enable flag that is on
   now and is either off in the target or changing pin. Lower the I2S
   channel count, move slots that end as S/PDIF to S/PDIF, and leave the I2S
   source if the target does. When the BCK pin of the pair the I2S outputs
   run on changes, those slots also go to S/PDIF here, because the BCK SET
   answers `VC_ERR_STATE` while they run on it (`vc_pins.c:450`). Step 4
   switches them back.
2. **Store.** Write the pins of everything that is now off. Store mode
   cannot conflict, so order does not matter.
3. **Move the always-on functions** (output slots, S/PDIF input 1, and the
   I2S pairs if I2S stays in use). Attempt every pending move and repeat
   while any succeeds.
4. **Start.** Types to I2S, channel raise, clock mode, source to I2S, then
   the enables. Every outcome is checked and reported with the owner's name.

The source switch and the PDM enable move after the stores whenever
hardware IO is applied. Each enable is sent with an outcome-returning call;
a refused PDM enable is reported, and the PDM pin move waits until PDM has
stopped (bounded poll of its availability status) before storing. On the
interactive paths (the Hardware tab picker and Reset Pins) a refused
re-enable also puts the old pin back and re-enables, so one pick cannot
leave the subwoofer off on a pin it cannot start on.

A cycle left over in step 3 (in practice output slots, S/PDIF input 1 and
active I2S RX pairs) is broken through a temp pin, by this rule, on all
three paths:

1. If the cycle contains an input (S/PDIF input 1 or an I2S RX pair), that
   member takes the temp pin. Inputs drive nothing.
2. In an output-only cycle, one output moves through a temp pin that is in
   its `free` mask, is not a target of anything in this apply, and has no
   claim at all in `SYS.PIN_CLAIMS`, active or stored.
3. If no such pin exists, everything else is applied and the report says the
   swap must be done by hand.
4. The three SETs go back to back. If the second or third is refused, the
   first function is moved back to its original pin; a failure there is
   reported loudly.
5. The report says so: "Output 1 was routed through GPIO n briefly."

Each move is the usual muted, synchronized restart (`process_pin_changes`),
so a swap costs up to three short mutes. The bench check confirms the
back-to-back sequence on hardware.

Revert reports a result line instead of discarding statuses. The routine
never uses `STORE.ALL_PARAMS`.

### 6. Picker model and one-site prototype

A shared helper builds rows from a `PinAvailability`, the claim list and a
**presentation mode**:

- The mode comes from the live in-use flag (bit 0) for immediate-SET
  pickers. For draft editors it comes from the draft: DAC mute is always
  "claim" (its picker only exists while the draft is enabled), UART and I2C
  follow `draft.enabled`, and CS is always "claim" because a binding is
  active on apply.
- **Claim mode** offers `free` (plus `shareable` for a CS button). Pins in
  `valid` but not `free` are shown disabled with the owner.
- **Store mode** offers all of `valid`. Pins outside `free` carry the owner
  and a "held" marker.
- The selected pin is always present. When it is outside `free` in claim
  mode it carries the held warning rather than appearing as a normal entry.
- **Owner text** is never empty: the owners of the pin, then of pin + 1 when
  the function has an implied second pin, then a reason for blocks with no
  claim ("I2C bus in use", "PWM slice in use").
- **Function status**: `VC_ERR_STATE` disables the BCK and MCK pickers with a
  reason line. Local non-pin reasons stay (for example `i2sSlaveActive`);
  the device status adds to them. PDM is exempt: its picker stays enabled
  and offers `free`, and the move goes through the corrected cycle in
  phase 5 (pending your decision on keeping the cycle).
- **Two-pin functions** (UART, I2C, CS display): every role-valid pin is
  offered. Picking a pin in another group moves the partner to the first
  acceptable pin in that group.
- **Start warning**: flag bit 3 clear on a function that is off shows
  "GPIO n is held by X. Free it before enabling." beside its enable control.
  The CLAUDE.md alignment rule applies to these stacked warning rows.

Native menu `Picker`s are text only and sit in fixed 92 pt frames, so
whether a disabled, labelled item works there (for example
`.selectionDisabled`, macOS 14) has to be researched and proven on one site
first. The output-slot pin picker is the prototype. The other sites are
converted only after it works.

Sites: output slots and PDM, Reset Pins, I2S BCK master and slave, MCK,
S/PDIF RX 1-4, I2S RX pairs, ADAT TX and RX, DAC mute, UART and I2C
control, CS binding pins per type (the shareable mask replaces
`csPinButtonShareable`, `valid` replaces `CS_ADC_PINS`), CS display SDA/SCL,
and the CS seed helpers (`makeBinding`, `freePins`, `freeI2CPair`).

### 7. Refusal and success messages

The blocking owner comes from the claim list, fetched on demand when the
store is not watching.

- **Start sites**: `OUTPUT.TYPE` to I2S, and, from the UI,
  `INPUT.SOURCE` to I2S, `CLOCK.I2S_CLOCK_MODE` and PDM
  `ROUTE.OUTPUT_ENABLE`. The last three move from `send` to the completion
  form `set(...)` when the user initiates them. They are called on main with
  an optimistic UI update, and `setAndWait` on main would spin the run loop
  for up to 10 s (`DeviceTransport.swift:381-388`). Also
  `CLOCK.I2S_CLOCK_PIN_MODE`, `MCK_ENABLE` and the S/PDIF and ADAT enables.
- **Deferred families**: DAC mute compares its readback with what was sent
  and names the owner. The XPORT message names the owner. CS keeps its
  `CS.STATUS` path. The pin map refreshes after each deferred outcome.
- **I2S unit**: flag bit 3 does not cover the clock pair colliding with a
  data pin or two pairs sharing a pin. The replacement for
  `i2sRaiseConflicts` checks duplicates among the I2S family's claims as
  well as the per-pair flags.
- **Store-mode success**: a SET on a disabled MCK, ADAT port, S/PDIF input or
  beyond-count I2S pair now succeeds on a held pin. The message says
  "Set to GPIO n. Held by X; cannot be enabled until freed."
- **Substitution notice**: `SYS.PIN_STATE` byte 6 is read at connect and
  after a preset load or bulk apply. One notice per connection names the
  functions whose pins were replaced or switched off. Boot restore sets it
  too, which covers units whose stored config 1.1.7 now disables.

### 8. Overview tab

The GPIO grid comes from the `SYS.PIN_STATE` GPIO mask, which adds GPIO 29 on
RP2350. Chips come from `SYS.PIN_CLAIMS`: active claims tinted by role,
stored claims in a muted style, and shared pins listing every owner.

### 9. Remove the local rules, no fallback

Delete `pinAssignment`, `pinInUseBy`, `PinConsumer`, `validPins`,
`mckValidPins`, the `% 4` and even/odd filters, `CS_ADC_PINS` in pickers,
`csPinButtonShareable` and `i2sRaiseConflicts`. Defaults that are written to
the device stay.

There is no fallback path. The Console ships as a matched pair with 1.1.7,
and 1.1.6 boards are update-only. When `SYS.PIN_STATE` is absent (a
pre-`103ba37` beta on the bench) the pin pickers are read-only with
"Update the firmware to change pins", through the same disabled-with-reason
path. This departs from spec 12.1, which asks for a fallback to the current
logic; the departure is recorded here.

### 10. Tests

- Wire fixtures (phase 2).
- `PinMap` with a fake transport: generation consistency and rerun, abort on
  LOCKED, busy retry, unconditional refresh on BULK_INVALIDATED.
- The phase 5 routine with a fake transport: BCK before type, BCK change
  while slots stay I2S, source after RX pins, refused PDM re-enable
  reported (and restored on the interactive path), store-then-move ordering,
  and swap cycles: with an input member, output-only, no eligible temp pin,
  and rollback after a refused second SET.
- Picker model: each presentation mode, state-blocked, owner fallbacks,
  group change.
- Rewrite `PinAssignmentTests` and `I2sClockPinModeWireTests:74-83` on the
  claim list.
- `LiveCommandSweepTests`: decode checks for the 13 replies, and
  `freePins()` from the masks.
- No Console live tests that duplicate `dspi_test paged_pins`.

### 11. Release notes

A `WhatsNew.json` entry for the user-visible changes of spec section 11.

## Order of work

1, 2, 3, 4, then 5 (a live regression independent of the UI), then 6
(prototype first), 7, 8, 9, with 10 alongside each phase and 11 last.

## Decisions

1. DSPi-Link: update its policy table and generated artefacts in that
   repository as part of this work. (You, 2026-11-18.)
2. PDM pin move while PDM runs: keep the automatic off/move/on cycle, as
   corrected in phase 5. (You.)
3. Swaps in Revert, Reset Pins and the document apply: route through a temp
   pin by the rule in phase 5. (Fable's recommendation, which you asked for;
   Opus agrees.)
4. Held pins in claim-mode menus: greyed out with the owner's name, subject
   to the one-site SwiftUI prototype. In store mode they stay selectable with
   the owner shown. (You.)
