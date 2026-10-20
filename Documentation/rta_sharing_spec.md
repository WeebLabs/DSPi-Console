# Spectrum analyser sharing

How the DSPi Console shares the device's one spectrum analyser with other
consoles (remote DSPi Link sessions, the Windows Console, a UART bridge) and
with itself across its own views. The protocol-level rules live in the
firmware's `spectrum_analyser_spec.md` section 7 (host rules) and
`notification_protocol_v2_spec.md` section 3.9 (the `RTA_CONFIG` event), and
in `dspi_link_protocol_spec.md` section 7.10 (hub rules). This document is
the Console-side design that implements them.

## 1. The problem

The device holds one analyser configuration: tap, channel mask, FFT order,
averaging and peak decay. Every console's `RtaEngine` used to behave as the
only user. It read the configuration back every 500 ms and re-pushed its own
whenever the readback differed, so two consoles on different channels
overwrote each other and every overwrite discarded the frame in flight and
cleared the averages. Because the give-up counter resets whenever a readback
happens to agree, two alternating consoles never gave up. Closing the last
view sent `RTA_CTL_STOP` for everyone, which the next reader's band read
repaired within a poll tick at the cost of a restart.

## 2. Ownership model

There is no reservation. **The last console to push a configuration drives
the analyser, and every other console follows.** This is the same
"last writer wins" rule every other shared parameter already has; the only
thing the analyser lacked was a way to tell the other consoles that the value
changed. The firmware now announces every applied configuration with
`NOTIFY_EVT_RTA_CONFIG`, attributed to the writing session, and the hub stops
forwarding one session's STOP while another is watching.

## 3. RtaEngine

`RtaEngine` (`SpectrumAnalyser.swift`) gains an ownership state, published for
the views:

```swift
enum RtaOwnership: Equatable {
    case driving                       // the device holds what we asked for
    case following(origin: LinkSessionID)   // someone else's configuration; 0 = unknown
}
```

### 3.1 Inputs

- **Own echo.** An `RTA_CONFIG` notification whose `origin` is this
  transport's session (`DeviceTransport.isOwnWrite`) confirms the push: the
  engine records the device's configuration as applied, adopts the clamped
  `avgMs` and `peakDecayDBs`, zeroes the push counter and clears
  `configRejected`. The engine stays `.driving`.
- **Someone else's configuration.** An `RTA_CONFIG` notification with any
  other origin (including 0) whose tap, mask or FFT order differ from what the
  engine wants moves it to `.following(origin:)`. The comparison is exact: a
  configuration with more channels than ours is someone else's choice too,
  not a success, because the device would rotate through the extra channels
  and our fine curve would lose its bins half the time. Because the hub resolves an
  origin only for the session that wrote, a remote console sees the real
  session id and a USB-only console sees 0 for a UART or I2C writer.
- **Readback fallback.** The engine keeps the 500 ms `REQ_RTA_GET_CONFIG`
  read until it has received one `RTA_CONFIG` event on the current
  connection. After that it reads the configuration back only while a push
  is unconfirmed, because a push the device STALLs produces no echo and the
  readback is what turns it into "rejected". On firmware without the event, a
  readback that disagrees in tap, mask or order *after an earlier readback
  agreed* means another host changed it: the engine follows with origin 0.
  A readback that never agreed keeps today's three-push "rejected" path.

### 3.2 Following

While following, the engine's effective configuration is the device's. It
polls bands for the device's mask (`GET_BANDS_ALL` returns every live channel
in one read anyway) and publishes the device's tap and channels as the
`effectiveSelection` the views draw, so the user sees what the analyser is
actually doing rather than an empty graph. When that configuration is a
single channel and one of the console's displays draws the fine curve
(`RtaRequest.drawsBins`, set by the response-graph overlay), the engine reads
the bins too, so a follower shows exactly the curve the driver shows. The
bins are read whenever the analysed configuration is one channel, whether
this console chose it or follows it, and never while the device rotates
through several. The engine does not push, and it
does not count the mismatch as a rejection. A further change by someone else
updates the followed configuration in place.

### 3.3 Taking control

Any of these pushes the engine's own configuration again and returns it to
`.driving`:

- the configuration the console's views ask for changes (the user picked a
  channel or a tap). Showing or hiding a display of the same selection (the
  response-graph overlay, the bar strip, the analyser window) is not a
  change, so toggling one never takes control from another console;
- `setOptions` changes a device-side option (FFT order, averaging, decay);
- the user presses **Take control** in the graph options popover.

The engine pushes only its own configuration. There is no merging with the
channels another console asked for: that console follows ours instead, the
same way this one followed it. A merged mask would make the device rotate
through both consoles' channels, and since it keeps bins only for the channel
it transformed last, both consoles' fine curves would flicker. A readback or
echo counts as success only when the tap, mask and order match exactly, and
in that case the engine returns to `.driving` by itself, with no user action,
since the device holds what it wants.

A host that cannot follow (a UART or I2C client reading the analyser
directly, not a Link hub, which only relays) loses its channels when a
console takes control. That is the cost of "the last to choose drives".

`appliedConfig` keeps the values the engine asked for. The device's clamped
`avgMs` is stored separately for the bin average, so a clamped value is not
read as a difference and pushed again on every echo.

The engine remembers the configuration its views last asked for, through
periods when no view watches, and compares each new request against it. A
request that re-publishes the same thing, or a display shown again after all
of them were hidden, does not take control.

### 3.4 Stopping

Releasing the last subscription still sends `RTA_CTL_STOP`, but keeps the
ownership state: the device holds its configuration through STOP and
auto-off, so a display shown again resumes driving or following without a
push. An `RTA_CONFIG` event that arrives while nothing watches is judged
against the remembered configuration, so a change made meanwhile is followed
when a display returns. On a hub the STOP is
swallowed while another session watches (section 4). Over plain USB with no
other host it stops the engine at once as before, and if a UART bridge is
reading, its next read restarts the analyser.

`resetAveraging` is unchanged and shared.

### 3.5 Notification plumbing

- `Constants.swift`: `NOTIFY_EVT_RTA_CONFIG = 0x0D`.
- `InterruptMonitor` decodes the 17-byte packet (header, 12-byte `RtaConfig`,
  source at byte 16), lists it in the diagnostics log like the other discrete
  events, and exposes `onRtaConfig(config: RtaConfig, source: UInt8, origin: LinkSessionID)`.
- `LinkNotification.isHostSourced` and
  `USBNotificationReader.attributedOrigin` learn the event's source offset
  (16), so a USB console sees its own echo as its own session and the hub
  attributes the event to the writing session.
- `DSPViewModel` wires the callback to the engine, as it does for siggen.

## 4. Hub

In `CommandRouter` (one device's command path, every session including the
local one as session 1):

- **Watcher tracking.** Per session, the time of the last `REQ_RTA_GET_BANDS`
  (0x0B), `REQ_RTA_GET_BINS` (0x0C), `REQ_RTA_GET_BANDS_ALL` (0x0F) or
  `RTA_CTL_START` submitted through the router. Poll subscriptions for those
  commands run through `PollScheduler`, not the router, so the hub also asks
  the scheduler whether any other session holds a live subscription for one
  of them.
- **STOP arbitration.** A `REQ_RTA_CONTROL` with `wValue == RTA_CTL_STOP`
  is forwarded only when no other session has watched within 5000 ms and no
  other session holds a band or bin poll subscription. Otherwise the router
  completes the request with status `OK` and payload `01`, exactly what the
  device would have answered, without touching the device. The decision is
  made on the router queue, in order with the other commands, so a band read
  queued ahead of the STOP counts.
- **Session close** forgets that session's watcher entry. Nothing is sent to
  the device.
- `policy/commands.json`: the `RTA_CONTROL` note records the STOP rule.

## 5. UI

In the graph options popover (`GraphOptionsButton` / `GraphOptionsPanel` in
`SpectrumAnalyserView.swift`) and the status strip that today shows
"Device refused this configuration":

- `.following`: a line reading "Following another console" (the hub does not
  yet expose session names to clients) with a **Take control** button, in
  both the popover and the status strip.
- `.driving`: nothing new.

The channel chips, the Inputs/Outputs picker and the response-graph overlay
reflect `effectiveSelection` while following so the user can see which
channels are being analysed. Any chip, Clear or picker action while
following also takes control, even when it leaves the page's own selection
unchanged. Every analyser display, the dashboard bar strip and the pop-out
window included, draws the followed selection with its channel names and
colours, while still registering the page's own request.

## 6. Tests

- `RtaSharingTests`: engine state transitions driven through a fake
  transport: own echo confirms; foreign event follows; user change takes
  control with its own mask only; a foreign superset is followed; a
  follower reads bins only when the followed configuration is one channel;
  readback fallback follows only after an earlier agreement; a never-agreeing
  readback still ends rejected.
- `RtaWireTests`: `RTA_CONFIG` packet decode, `isHostSourced` and
  `attributedOrigin` for event 0x0D.
- `LinkHubCoreTests` (or a new `LinkRtaArbitrationTests`): STOP forwarded
  when alone; swallowed with the `01` ack while another session read bands
  within 5 s; forwarded again after 5 s; swallowed while another session
  holds a 0x0B poll subscription; forgotten on session close.

## 7. Later

A hub-side `rta.state` event naming the driving session, with band reads
moved to poll subscriptions, would add the driver's name to the "Following" label and read the device once for N
consoles. It needs a spec change and all three hub implementations, so it is
deliberately not part of this change.
