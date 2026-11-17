# Plan: port DSPi Console to the 1.1.7 paged vendor protocol

*Drafted 2026-11-17 on `release/v1.1.7` at `5ec256c`. Revision 2 adds the findings of an independent review by Fable. Revision 3 adds its two follow-up clarifications. Fable and Claude agree on this revision.*

## Sources

- `~/DSPi/Documentation/Features/vendor_protocol_client_update.md` is the short client guide: the request format, the probe, the rules, the errors and the old-to-new map.
- `~/DSPi/Documentation/Features/vendor_protocol_migration_guide.md` section 13.2 is a DSPi Console appendix that was audited at this exact commit. Section 13.3 covers DSPi Link, which the Console's embedded hub has to follow.
- `~/DSPi/Documentation/protocol/dspi_commands.json` and `legacy_map.json` are the machine-readable registry and map.

## What has to be true at the end

1. Every request is addressed as `PAGE.NAME`. The page goes in the `wIndex` high byte, with the interface number 2 in the low byte, and the command number goes in `bRequest`.
2. The first request a newly opened device ever sees is the `SYS.PROTOCOL_INFO` probe.
3. A device is classified **legacy** (1.1.6 or older) only when the probe STALLs and the old `GET_PLATFORM` (0x7F) then returns a valid reply. Two requests may reach a legacy device, both on the old 1.1.6 numbering: 0x7F, and the old `ENTER_BOOTLOADER` (0xF0). Nothing else may reach it, because an unprobed paged request can run an old opcode with the same number, such as factory reset or a preset overwrite.
4. On a legacy device, the app shows the "device is older" banner and can update the device to the bundled 1.1.7 image without BOOTSEL.
5. Features are gated on `SYS.PAGE_COMMANDS`, not on version numbers or probe-by-STALL.

## Where the safety gate lives

The gate lives in `USBDevice` itself, because the hub is not the only way to the device.

- **The Stats window.** It is opened with the raw `USBDevice` (`DSPi_ConsoleApp.swift:11729`), and it polls for the rest of the session.
- **Board switching.** A switch from one board to another publishes no disconnect, so the old router stays live during the new board's probe (`LinkHub.swift:186-190`).

`USBDevice` keeps a protocol state for each connection generation: **unprobed**, **legacy** or **paged**.

- **Unprobed:** the device accepts only the probe and 0x7F.
- **Legacy:** the device accepts only 0x7F and 0xF0.
- **Paged:** the device accepts any paged request.

The state resets on every new generation, so a switch starts unprobed. Every refused request returns `.noDevice`, without touching the bus. The gate, its classifier and the switch fix land before any call site sends paged requests. No hardware run with a 1.1.6 board happens before phase 3 is complete.

---

## Phase 1: Registry, generated constants and dead code

This phase changes no behaviour.

- Copy `dspi_commands.json` and `legacy_map.json` from the firmware's `release/v1.1.7` into `Protocol/` in this repository. Phase 8 re-copies them from the published tag.
- Add a generator script, `Tools/VendorProtocol/`, that emits `DSPi Console/VendorCommands.swift`. The file gets one constant per command, holding its 16-bit ID, its GET length, its SET payload bounds and its flags, named after `PAGE.NAME`.
- Add a unit test that re-runs the generator and fails when the output differs from the checked-in file.
- Delete the 49 uncalled functions in `Commands.swift` and `resetAveraging` in `SpectrumAnalyser.swift`, as listed in 13.2.5. Move the `saveParams` use in `LinkLockUsageTests` to `STORE.PRESET_SAVE`.

**Done when** the build and tests are green and nothing on the wire has changed.

## Phase 2: New transport API, gate and classifier, added alongside the old API

The new API lands next to the old one, so this phase builds green without touching the 286 call sites.

- **The new API.** Add to `DeviceTransport` a GET and a SET that take a 16-bit command and no `index:`. `USBDevice` builds `wIndex = (page << 8) | 2` itself. Implement the new API in `USBDevice`, `HubTransport`, `NetworkTransport`, `CompositeTransport` and every fake.
- **The outcome SET.** The SET is asynchronous with a completion that reports the outcome, so slider drags never block the main thread.
  - After a STALL, `USBDevice` reads `SYS.LAST_RESULT` in the same `serialQueue` block, and trusts it only when the command ID, direction and `wValue` match the request.
  - A fire-and-forget form stays for live drags.
- **Error classes.** Switch to `DeviceRequestTO`, with a timeout of about 1.5 s.
  - STALL gets its own case, separate from timeout and from other errors.
  - Both `kIOReturnTimeout` and the USB transaction timeout map to timeout. The exact `IOReturn` that `DeviceRequestTO` produces is checked against the SDK headers and a real run before relying on it.
  - Today every unlisted code falls to `.error`, the same result a STALL gets (`USBDevice.swift:675,717`).
- **The gate.** Add the per-generation protocol state described above, and enforce it on the new API. The old 8-bit API stays unrestricted during this phase. It still sends correct 1.1.6 opcodes with page 0, which a 1.1.7 board refuses harmlessly, so today's behaviour on a 1.1.6 board is kept until phase 3 deletes the old API. For the same reason, the hub still attaches a router to a board classified legacy during this phase.
- **The classifier.** It runs the probe first.
  - A `DSPi` reply with major 1 makes the device **paged**.
  - Any other major is published as "needs a newer Console".
  - A probe STALL followed by a valid 0x7F reply makes the device **legacy**.
  - A probe STALL followed by a failed 0x7F returns no result, so the existing retry runs again from the probe. A board that is still booting may STALL its first request (`LinkHub.swift:199-201`).
  - A timeout also returns no result.
  - The "legacy" state is never cached across retries, and it is bound to the generation that was classified.
- **Board switch.** `LinkHub.usbConnectionChanged` calls `detachDevice()` synchronously when the generation changes, before probing.
- **Stats window.** It is opened with `AppState.shared.transport` instead of the raw `USBDevice`.
- **Protocol state for the UI.** `DeviceTransport` gains a published property for the device's protocol state and its version, so the UI can see a legacy device that has no router. `CompositeTransport` and the fakes implement it.
- **Tests.**
  - Unit tests with fakes cover the classifier: STALL then valid 0x7F, STALL then failed 0x7F, timeout, wrong major and a short 0x7F reply.
  - A unit test through `usbDeviceFactory` covers the switch detach.
  - A unit test checks that the gate refuses each forbidden request in each state.

**Done when** the build and tests are green, and the app still behaves exactly as before on a 1.1.6 board.

**Result (committed 2026-11-17).**

- **Where the state lives.** The protocol state is kept in `USBDevice` for each connection, not in `HubDeviceInfo`. Phase 7 adds it to the Link device object.
- **Hardware check on 1.1.7.** A board running 1.1.7 beta 1 (RP2350) passed these checks:
  - The probe classified it as paged.
  - The hub attached it.
  - `SYS.PLATFORM` and `SYS.SERIAL` read correctly.
  - A deliberately bad request came back as `VC_ERR_ADDRESS` through `SYS.LAST_RESULT`.
- **Bug found and fixed.** The run exposed a wrong STALL constant. IOKit reports a STALL as `0xE000404F` (`kIOUSBPipeStalled`), but the code expected `0xE000402F`. The old code hid this by sending every unknown failure to `.error`. Without the fix, a 1.1.6 board's STALL would have read as a timeout, and the board would never have been classified as legacy.
- **Not yet checked.** No 1.1.6 board was connected, so the legacy path has unit tests but no hardware check yet.

## Phase 3: Move every call site to the new API

- **Mechanical renumbers.** Renumber the 130 mechanical opcodes and move the `wIndex` building out of the call sites. Widen the helpers that keep an 8-bit opcode: `sendFloatParamToDevice` (whose `wIndex: 0` default is removed), `sendLimiterParam`, `sendTubeParam` and `sendUpmixParam`.
- **The 45 per-site opcodes.** Each one is either ported now or stubbed so that it sends nothing. None is sent with a guessed ID. A renumbered `SET_EQ_PARAM` would otherwise be accepted on channel 0 band 0 with garbage fields, because its old 16-byte packet matches the new 16-byte length.
  - Ported now: `MEAS.LEVELS`, which the meters need, and `SYS.SYSTEM_STATUS` for the sample rate.
  - Stubbed: the rest, each marked with the phase that ports it.
- **Local router path.** The router is on the local path, so its 8-bit keys are fixed now rather than in phase 7.
  - `CommandRouter` gets the bulk timeout from the registry's `BULK` flag, so `STORE.ALL_PARAMS` keeps its 5 s timeout.
  - `parameterKey` and the RTA arbitration move to command IDs.
  - `PollSpec.req` and `CommandRouter.WriterEntry.code` widen to 16 bits.
  - The snapshot shortcut in the client keys on `STORE.ALL_PARAMS`.
- **Remote paths fail closed until phase 7.**
  - As a client, `NetworkTransport` refuses a remote device that does not advertise the paged protocol. An older Console hub would forward paged requests to a 1.1.6 board.
  - As a hub, the Console rejects commands from non-local sessions. Its policy table is still keyed on the old 8-bit numbers, so `SYS.ENTER_BOOTLOADER` (`0x0130`) would pass under the `SET_PSYBASS` row.
  - The same rule covers polls. Polls bypass `LinkHub.submit` (`LinkHub.swift:489-495`, then `PollScheduler.swift:260`), so `subscribePolls` grants 0 Hz to non-local sessions.
  - Local use is unaffected.
- **Legacy boards stop attaching.** `usbDidConnect` no longer attaches a router to a board classified legacy. It only publishes the protocol state and version. Otherwise `isDeviceConnected` would go true and start `fetchAll` and the meter timer against a gated board, and phase 4's banner assumes the board is not "connected". A unit test through `usbDeviceFactory` covers this.
- **Test helpers.** Port `HardwareTest.requireDevice` and `settle()` (`HardwareTestSupport.swift:43,65`) so the live suites run on 1.1.7 and skip cleanly on a legacy board.
- **Old API.** Delete the old API and `Constants.swift`.

**Done when** all of these hold:

- On a 1.1.7 board, the main window connects, and volume, meters, EQ reads and the bulk read work.
- On a 1.1.6 board, a request log shows only the probe and 0x7F. That covers a cold attach, a switch from a 1.1.7 board to a 1.1.6 board, and a 1.1.6 board with the Stats window already open.

**Result (committed 2026-11-17).** Phase 3 went further than planned, so phases 5 and 6 are smaller.

- **Ported early.** Every per-site opcode was ported instead of stubbed, except the `BandWriter` busy retry, which stays in phase 6. That brought forward these items from phases 5 and 6:
  - the 17 pin-family setters, through `legacyAction`, which maps result codes back to `PIN_CONFIG_*`;
  - the preset and flash actions;
  - the splits;
  - the `FILTER.BAND` encoder;
  - the matrix route;
  - the statistics struct reads;
  - the ADAT `0xFF` default.
- **Remote shutout, narrowed.** The hub refuses only *paged* commands and polls from remote sessions, controlled by `allowsRemotePagedCommands`. The network client refuses paged requests, controlled by `allowsPagedRequests`. Page-0 traffic keeps its 1.1.6 handling. A remote rename, which the hub builds itself, is checked against the old `SET_DEVICE_NAME` row.
- **Probe on open.** `USBDevice` now probes a newly opened board before it publishes `isConnected`, so nothing sees a connected board whose protocol is unknown.
- **Existing bug fixed.** `fetchAll` and `fetchAllParams` used to mark the link dead when a newer connection replaced the one they were reading. They now only do so for the same connection.
- **Tests.** The full suite, live tests included, passed against a 1.1.7 beta 1 RP2350 board: 995 tests, 8 skips (the environment-dependent and phase 7 ones), and only the known tube-rendering flake failing.
- **Not yet checked.** The 1.1.6 path has had no hardware check yet.

## Phase 4: Firmware update for both generations

- **Version and banner.** `firmwareMatch` and the banner read the protocol state and version from phase 2, so a legacy board shows "This device runs firmware 1.1.6; DSPi Console expects 1.1.7".
- **Update window.** `FirmwareUpdateView.start()` and `enterBootloaderOnly()` may act on a legacy device, where both are guarded by `isDeviceConnected` today.
- **Bootloader request.** `enterBootloaderForInstall` sends `SYS.ENTER_BOOTLOADER` to a paged device as a zero-length SET (`41 30 00 00 02 01 00 00`). It sends the old IN request (`C1 F0 00 00 02 00 01 00`) to a legacy device, directly through `USBDevice`, bound to the classified generation. If the old request STALLs, which can happen on firmware too old to have it, the flow falls through to the existing BOOTSEL hint.
- **Local only.** Remote clients cannot install firmware on a legacy board (decision 2).
- **Verification.** `ViewModelFirmwareVerifier` stays as it is. After flashing, the board comes back paged, the probe passes and `SYS.PLATFORM` gives the version.
- **Before the hardware check.** A 1.1.6 board only counts as older, and the update only installs 1.1.7, once the app is versioned 1.1.7 and bundles the 1.1.7 images. Today `MARKETING_VERSION` is 1.1.6 in both configurations, and no 1.1.7 firmware release exists on GitHub (checked 2026-11-17). CLAUDE.md allows bundling only published images. So the code and unit tests for this phase land first, and the hardware check waits for one of two things:
  - **(a)** the firmware 1.1.7 beta 1 release is published, and the release steps for it are run; or
  - **(b)** the user approves a bench-only build with locally built 1.1.7 images, which is never committed.

**Done when** both of these work on hardware:
- A 1.1.6 board updates to 1.1.7 from the banner and from the Firmware Update window.
- A 1.1.7 board reinstalls 1.1.7.

The BOOTSEL path also still works.

## Phase 5: Refusals and the former write-as-reads

- **Pin family.** Port the 17 pin-family setters to SETs with a 1-byte payload through the outcome SET. They keep their `UInt8` `PIN_CONFIG_*` return by mapping result codes through `legacy_map.json`'s `status_families.pin`, including its per-command overrides. `assignOutputPin`'s PDM retry keys on `VC_ERR_STATE`.
- **Presets and saves.** These become zero-length SETs that ACK or are refused: preset save, load and delete, output-config save, master-volume save, factory reset, `CS.SAVE` and `CS.REVERT`, and stats reset with its 1-byte mask.
- **Other actions.** Siggen start and stop, the CS macro fire and cancel, IR learn arm, cancel and status, and `MEAS.CLIP_CLEAR` are each split into their own commands.
- **XPORT.** `setUartCtrlConfig` and `setI2cCtrlConfig` check the SET's own result before reading `XPORT.STATUS`.
- **ADAT pin.** `setAdatPin` sends `0xFF` for "default" instead of 0, which on 1.1.7 would mean GPIO 0.
- **Silent writes.** Writes that 1.1.6 accepted silently and 1.1.7 refuses are logged, and shown where the UI already has a place for an error.

**Done when** a rejected pin assignment on hardware shows the same message as in 1.1.6.

## Phase 6: Reshaped commands, the band writer, statistics and feature gates

- **`FILTER.BAND`.** One 16-byte encoder replaces `eqParamPacket` and `setCrossoverBand`, with the address in `wValue` and Qp always sent.
- **`BandWriter`.** A per-device writer keeps the latest record per (channel, band) and drains it serially. On `VC_ERR_BUSY` it resends the newest value after 1 to 2 ms, giving up after about 50 ms. All band and band-bypass writes route through it. This matters most for linked pairs, Clear All, paste, AutoEQ and preset documents.
- **Matrix and names.** `ROUTE.MATRIX_ROUTE` takes an 8-byte payload with the crosspoint in `wValue`. Preset and channel names are cut at 32 UTF-8 bytes without splitting a character.
- **Split commands.** Port the limiter, tube, upmixer, output latency, RTA caps and centres, RTA stop, CS caps, siggen caps, CS aux and CS display config.
- **Statistics and rates.**
  - The statistics window moves to the five `SYS` struct reads, with each length checked.
  - The core voltage becomes a u16 and the temperature an i16.
  - `fetchInputRate` reads 4 bytes at offset 0.
  - The retired `spdifOverruns` row is dropped.
- **Feature gates.** Every probe-by-STALL flag and version gate moves to `SYS.PAGE_COMMANDS` bits read at connect.

**Done when** the 13.2.9 hardware checks pass:
- A linked-pair band drag, Clear All and paste each read back identical bands.
- The statistics window shows about 1100 mV and a plausible temperature.

## Phase 7: The embedded DSPi Link hub and client

**This phase starts only after the user confirms `~/DSPi-Link` is ready.** Until then, nothing reads or uses that repository.

- **Policy table.** Key the policy on the 16-bit ID. `Link/policy/commands.json` is regenerated from the registry plus a class column. The 15 escalation rows of 13.3.8 are checked by hand.
- **Client bulk timeout.** `LinkClient`'s `bulkOpcodes` (0xA0 to 0xA3) moves to the registry's `BULK` flag on the command ID. Today it can't be reached for paged traffic. Once remote paged traffic is allowed, `STORE.ALL_PARAMS` would miss the longer timeout and unrelated commands would get it.
- **Hub-built rename.** Drop the rename's check against the old `SET_DEVICE_NAME` row (0x56) once the policy is keyed on command IDs.
- **Status codes.** `LinkStatus` and `LinkFrames.decode` accept `0x10` to `0x1A`. The hub forwards the `SYS.LAST_RESULT` code instead of `0x02`.
- **Device protocol field.** Add a protocol field to the device object. A remote hub publishes a legacy board with its version but no command access, following the Link spec.
- **Lift the fail-closed rule.** The phase 3 rule that rejects non-local sessions is lifted.
- **Web app.** The bundled web app (`DSPi Console/Web/assets/index-*.js`) is rebuilt from the DSPi-Link web app against the new IDs.

## Phase 8: Tests, documentation and release readiness

Each phase updates its own unit tests and fakes as it goes. This phase finishes off the rest.

- **Policy tests.** Replace `testEveryFirmwareRequestCodeIsInTheTable` and `testEveryAppRequestConstantIsInTheTable` with tests against the vendored registry. Today they parse the firmware's `config.h`, which no longer has `REQ_` defines.
- **Hardware tests.** Run the full live suite with a 1.1.7 board connected.
- **Documentation.** Rewrite the "USB Protocol" section of `CLAUDE.md` and update the memory notes.
- **Release steps.** Add a step to the CLAUDE.md release process: "refresh the vendored `Protocol/` registry from the same firmware tag as the UF2s, and regenerate `VendorCommands.swift`".
- **Release notes.** Add a `WhatsNew.json` note that users on 1.1.6 must update the Console before the firmware. A 1.1.6-era Console cannot see a 1.1.7 board, and it would downgrade the board through BOOTSEL.

---

## Decisions (agreed 2026-11-17)

1. **Link scope.** `~/DSPi-Link` is being updated separately right now. Phase 7 waits for it. Nothing in this port reads or uses that repository until the user confirms it is ready.
2. **Updating legacy devices remotely.** Only a locally connected 1.1.6 board can be updated. Once phase 7 lands, a remote hub publishes the legacy state, so remote clients see the board and its version, but they cannot install firmware on it.
3. **Pin-error messages.** Keep the `PIN_CONFIG_*` codes by mapping result codes back through `legacy_map.json`. Moving Settings to the new result codes comes later.
4. **Commits.** One commit per phase, each leaving the build green. Nothing is pushed until the user says so.

## Open question for the user

- **Phase 4 hardware check.** This needs either the published 1.1.7 beta 1 firmware release, option (a), or your approval of a bench-only build with local images, option (b).
