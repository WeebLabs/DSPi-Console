# DSPi Link - Networking Plan for DSPi Console

Goal: let DSPi devices be managed over the local network from a web browser,
from another DSPi Console, and from future iOS/Android apps, with DSPi Console
acting as the gateway for the devices plugged into it, and with the same
protocol implementable on a standalone ESP32 bridge wired to a DSPi over UART.

The protocol itself is specified in
`Documentation/dspi_link_protocol_spec.md`. This document is the plan for
building it into Console and for the sibling projects around it.

Writing style note: this document avoids em-dashes per project convention.

---

## 0. Findings (baseline)

**The firmware already has the shape a network protocol needs.** Every vendor
command is dispatched through a transport-neutral orchestrator with full parity
over USB, UART and I2C (`control_interfaces_spec.md`). The UART transport can
push the same v2 notification packets the USB endpoint delivers. The vendor
command catalogue (`Documentation/commands.md` in the firmware repo) is
written explicitly for "a remote control bridge (a TCP/WiFi gateway, an ESP32
host, or a mobile app)". The design consequence is that the network protocol
should **tunnel the vendor surface byte for byte** and add only what the
firmware cannot know about: discovery, authentication, inventory, meter
subscriptions and locks. It then never needs to change when the firmware gains
a feature, and the ESP32 bridge is a framing transcoder plus a WebSocket
server.

**What must change in Console before a second client can exist:**

1. **Direct USB coupling.** `DSPViewModel` and its extensions call
   `usb.sendControlRequest` / `usb.getControlRequest` from about 260 sites:
   222 in `Commands.swift`, 26 in `StatsView.swift`, 10 in
   `SpectrumAnalyser.swift`, and a few in `FirmwareUpdateView.swift` and
   `InterruptMonitor.swift`. `InterruptMonitor` opens EP 0x83 itself via
   IOKit. There is no transport abstraction, so Console cannot today drive a
   device it does not hold on USB.
2. **Echo suppression is by source, not by session.**
   `DSPViewModel.swift:2530` drops every `PARAM_CHANGED` whose source is
   `PARAM_SRC_HOST_SET`, on the assumption that Console is the only host.
   Once a remote client writes through the hub, its changes also arrive as
   `HOST_SET` and the local window would silently stop following. The hub must
   attribute changes to sessions, and the view model must suppress by
   session id.
3. **Initial sync is already bulk-based** (`fetchAllParams`, 0xA0), which is
   the right shape for a network client; the remaining per-parameter GETs on
   connect are the latency to watch over a link, and a hub-side snapshot cache
   removes most of them.
4. **Environment facts.** The app is not sandboxed (empty entitlements), has
   no Swift package dependencies, targets macOS 14.6, and generates its
   Info.plist from `INFOPLIST_KEY_*` build settings, so the local-network
   privacy keys are added there. Nothing currently uses `MenuBarExtra` or
   `NSStatusItem`.
5. **The Windows console** (`WeebLabs/DSPi-Console-Windows`, C#) shares the
   wire formats. The protocol is language-neutral by design so it can become a
   client too; nothing in this plan depends on it.
6. **The WebUSB spec** in the firmware repo is a different route (browser
   straight to USB) that conflicts with Console holding the vendor interface.
   Link does not replace it, but for the "visit the local IP" flow the hub
   must serve the web UI itself: a page hosted on `https://` cannot open a
   plaintext `ws://` socket to a LAN address (mixed-content blocking), so a
   cloud-hosted control page cannot talk to a local hub.

---

## 1. Architecture

```
                 +----------------------------- DSPi Console (hub mode) -----------------------------+
                 |                                                                                    |
   USB           |   USBDevice  --->  LinkHub                                                         |
  DSPi #1 <------|-- (IOKit)          |  DeviceRegistry   (serial -> handle, name, state, cache)       |
  DSPi #2 <------|-- serial queue     |  CommandRouter    (per-device FIFO, attribution, timeouts)     |
                 |   EP 0x83 reader   |  NotifyRelay      (fan-out, origin, resync)                    |
                 |                    |  PollScheduler    (shared polls, budgets)                      |
                 |                    |  AuthStore        (token hashes, roles, pairing PIN)            |
                 |                    |  Policy           (bRequest -> read/control/config)             |
                 |                    +---- LinkServer (WebSocket + HTTP, DNS-SD) ----> LAN            |
                 |                    |                                                                |
                 |   DSPViewModel <-- HubTransport (in-process session, same router as remote ones)     |
                 +------------------------------------------------------------------------------------+

   DSPi Console (client mode):  DSPViewModel <-- NetworkTransport (WebSocket) --> some hub
   Web UI / mobile apps:        dspi-link client library --> some hub
   ESP32 bridge:                UART <-> LinkHub (C) <-> WebSocket server, DNS-SD
```

The one structural decision that makes everything else fall out: **the local
UI becomes a session on the hub**, exactly like a remote one. `USBDevice`
is owned by the hub only. That gives one ordering, one attribution scheme, one
lock model, and means "Console as client" is the same `DSPViewModel` with a
different transport underneath.

### 1.1 The transport abstraction

```swift
protocol DeviceTransport: AnyObject {
    var identity: DeviceIdentity { get }              // serial, platform, link kind
    var generation: UInt64 { get }                    // bumps on reconnect (existing pattern)
    var isConnected: Bool { get }
    var session: SessionID { get }                    // for echo suppression
    func send(_ req: UInt8, value: UInt16, index: UInt16, data: Data)          // fire-and-forget SET
    func get(_ req: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Data?   // blocking GET
    func getResult(...) -> Result<Data, LinkStatus>   // GET with the status code, for new code
    var notifications: AsyncStream<LinkNotification> { get }   // packet + origin
    func subscribePolls(...) / unsubscribe(...)       // meters and RTA
}
```

`send`/`get` keep the exact signatures the 260 call sites use, so the
refactor is mechanical (`usb.` becomes `transport.`). New code uses
`getResult` so it can distinguish `DENIED`, `LOCKED` and `TIMEOUT`.

Implementations: `HubTransport` (in-process session on the local hub),
`NetworkTransport` (WebSocket client). `USBDevice` stops being a transport
the view model sees; it becomes the hub's device driver.

---

## Phase 1 - Transport abstraction (no networking yet)

- Add `DeviceTransport` and the `LinkNotification` type.
- Move EP 0x83 reading out of `InterruptMonitor` into `USBDevice` (it is the
  device driver's job); `InterruptMonitor` becomes a consumer of the
  transport's notification stream, like the view model. Its log window is
  unchanged.
- Introduce `LinkHub` with a single `LocalSession`, and `HubTransport`.
  `AppState` builds `USBDevice -> LinkHub -> HubTransport -> DSPViewModel`.
- Replace the direct `usb.` calls in `Commands.swift`, `StatsView.swift`,
  `SpectrumAnalyser.swift`, `FirmwareUpdateView.swift` with the transport.
  Device selection (`selectDevice`, `availableDevices`) moves behind the hub
  registry, which the view model observes.
- Change the echo filter at `DSPViewModel.swift:2530` to compare
  `notification.origin` with `transport.session`, and stop dropping
  `HOST_SET` outright.
- Make `fetchAllParams` accept a pre-fetched blob so the snapshot path can
  feed it later.

**Deliverable:** the app behaves exactly as today over USB. All existing tests
pass. New pure-logic tests cover the router's ordering and the attribution
window using a fake device.

## Phase 2 - Hub core

Pure Swift, no sockets, fully unit-testable:

- `DeviceRegistry`: serial to handle mapping, offline grace (60 s), hub-stored
  names (in `UserDefaults` keyed by serial), `device.*` events.
- `CommandRouter`: per-device FIFO across sessions, `max_inflight` per
  session, timeouts (2 s, 5 s bulk), USB result to status mapping, the
  attribution window for `origin` (a SET from session S completed on device
  D within the last 250 ms and no other session's SET in between).
- `NotifyRelay`: fan-out with a bounded per-session queue (drop oldest and
  send RESYNC when a slow session falls 256 packets behind).
- `SnapshotCache`: one bulk blob per device, refreshed on
  `BULK_INVALIDATED`, patched from `PARAM_CHANGED` (offset/size/value maps
  straight onto the blob), plus the last status frame.
- `PollScheduler`: dedupes identical `(handle, req, val, idx, len)` polls,
  runs each at the max requested rate, grants rates within the budget,
  stops when the last subscriber leaves. `StatsView` and `RtaEngine` become
  poll subscribers rather than owning timers, which also removes their direct
  USB access.
- `AuthStore`: token hashes, roles, client names, pairing PIN with expiry and
  failure counting. Persisted in Application Support as JSON; the hub id UUID
  lives there too.
- `Policy`: the `bRequest` classification table, loaded from the shared
  `policy/commands.json` (spec section 9.3) embedded as a bundle resource,
  never hand-written in Swift. Unknown commands default to `config`. A unit
  test asserts every request code referenced in `Commands.swift` is present
  in the JSON so a new command cannot slip through unclassified; the same
  test exists on the Windows side against its own command layer.

**Deliverable:** `LinkHubTests` exercising each component with a fake device
transport, including multi-session ordering, echo attribution, lock
behaviour, and poll dedupe.

## Phase 3 - Server and discovery

- **Server stack.** Recommended: **SwiftNIO** (`NIOHTTP1` + `NIOWebSocket`)
  as the project's first package dependency. It serves the WebSocket, the
  `/dspi/v1/info` endpoint and the static web UI on one port with a
  well-trodden upgrade path. The alternative, `Network.framework`'s
  `NWListener` with `NWProtocolWebSocket`, handles the WebSocket natively
  but cannot answer plain HTTP on the same port, which the info endpoint and
  the web UI need; it would force a second port or a hand-written HTTP
  parser. NIO is the smaller total.
- **Discovery.** Advertise with the `dnssd` C API (`DNSServiceRegister`), which
  works regardless of the server stack and updates TXT records (`n`, `d`)
  as devices come and go. Bind the listener to all interfaces but drop
  connections whose peer is not on a local subnet, as a second line of
  defence behind "never port-forward this".
- **Info.plist keys** (via `INFOPLIST_KEY_*`): `NSLocalNetworkUsageDescription`
  and `NSBonjourServices = _dspi._tcp` so the client side (Phase 5) gets the
  macOS 15 local-network prompt with a sensible message.
- **Settings.** A new "Networking" settings page with: enable sharing,
  hub name, port, per-device share toggles, auth mode (`pin` default), the
  "Allow new client" button that shows the PIN for two minutes, and the
  paired-clients list with role and revoke. Status line: listening address,
  connected sessions, per-session name and role.
- **Prevent App Nap** while sessions exist (`ProcessInfo.beginActivity` with
  `.userInitiated` and a reason), otherwise a backgrounded Console throttles
  its timers and the meters on the phone stutter.

**Deliverable:** a second Console instance on the same machine (or a Python
script) can pair, list devices and set the master volume through the hub,
and the local window follows.

## Phase 4 - Menu bar mode

- `MenuBarExtra` (available from macOS 13) with a status icon that shows
  hub state (sharing on/off, session count) and a menu: Open Console, Allow
  new client, per-device quick volume, Quit.
- "Minimise to menu bar" toggles `NSApp.setActivationPolicy(.accessory)`
  and closes the main window; the hub keeps running. Reopening the window
  restores `.regular`.
- "Start at login" via `SMAppService.mainApp` and a "start minimised"
  preference, so the gateway is up after a reboot without anyone opening
  Console.
- Sleep: the hub disappears when the Mac sleeps. Document it, offer a
  "Prevent sleep while clients are connected" option
  (`IOPMAssertionCreateWithName` with the idle-sleep assertion), and let
  clients reconnect with backoff so waking the Mac is enough.

**Deliverable:** Console runs as a menu bar service through a login and a
sleep/wake cycle with a phone reconnecting on its own.

## Phase 5 - Console as a client

- `NetworkTransport`: WebSocket client (`URLSessionWebSocketTask` is enough
  on the client side), hello, token auth from the keychain keyed by `hid`,
  pairing sheet when no token exists, request id allocation, notification
  and poll streams, reconnect with backoff.
- Discovery with `NWBrowser` for `_dspi._tcp` plus a manual "Connect to
  address" field.
- The device picker merges local USB devices (from the local hub) and remote
  devices (from discovered hubs) into one list keyed by serial, badged by
  where they live. Selecting a remote device swaps the transport under the
  same `DSPViewModel`.
- Use `device.snapshot` when the hub offers it: `fetchAllParams` takes the
  cached blob and the status frame from one JSON reply instead of a bulk
  read and the trailing GETs.
- Firmware update over Link: `FirmwareInstaller` gains a path that streams
  the bundled `.uf2` through `fw.install` when the transport is remote and
  the hub advertises `fw_install`. The remote hub does the bootloader work
  it already knows how to do.
- Feature gating stays exactly as it is: it keys off what the device reports,
  which arrives through the tunnel unchanged.

**Deliverable:** Console on a second Mac discovers and fully controls a device
hosted by the first, including meters, RTA and a firmware update.

## Phase 6 - Web UI (separate repository)

- `dspi-link-js`: a TypeScript client library implementing the protocol
  (hello, auth, device list, CMD, NOTIFY, POLL, snapshot) plus the wire-format
  decoders the app already has in Swift (bulk blob, band params, status
  frame, notification packets, RTA frames). The web app is its only consumer.
- **Mobile apps are native** (Swift on iOS, Kotlin on Android), decided
  2026-09-08. Each ports the same two layers: the Link client and the
  wire-format decoders. To keep three codebases in step with the wire format,
  the protocol spec and the firmware's `bulk_params.h` are the shared source
  of truth, and each client carries a fixture test that decodes a checked-in
  bulk blob and notification packet set to known values. The Swift Link
  client from Phase 5 (`NetworkTransport`) is written so the iOS app can
  take it as a package.
- The web app is built to a single static bundle the hub serves at `/`.
  Budget it to fit an ESP32's flash too (gzipped, well under 1 MB) so a
  bridge serves the identical page.
- Scope for v1: device list, dashboard with meters, input and output EQ,
  matrix mixer, volumes, presets. Tools windows (test signals, RTA, upmixer,
  psybass, subharmonic synth, control surfaces) follow as the library gains
  their decoders.

**Deliverable:** browsing to the hub's address gives working control of every
shared device from any modern browser on the LAN.

## Phase 7 - ESP32 bridge (separate firmware repository)

- Target ESP32-S3 (PSRAM helps with several WebSocket clients and the static
  bundle). ESP-IDF, `esp_http_server` with WebSocket support, `mdns`
  component, NVS for tokens, hub id, hub name and device name.
- UART to the DSPi at 921600 or 1 Mbaud; implement the type 0x01/0x02/0x40
  framing with CRC16-CCITT-FALSE from `control_interfaces_spec.md`; obey the
  one-request rule; leave the 2 ms idle gap so notifications flow.
- Wi-Fi provisioning is not part of the Link protocol. Recommended: the
  Improv Wi-Fi standard over BLE and over USB serial, which gives two
  set-up paths for free: any phone with the Improv web page, and DSPi Console
  itself, which can provision a bridge plugged into the Mac by USB serial
  ("Set up a bridge" in Networking settings). A soft-AP captive portal is the
  fallback.
- The DSPi must have its UART control interface enabled with `notify_enable`
  set, which is done over USB from Console's existing Control Interfaces
  settings. Add a one-click "Prepare this device for a bridge" that sets the
  pins, baud and notify flag in one go and prints what to wire.
- OTA update of the bridge's own firmware via `esp_https_ota` from a GitHub
  release, triggered from its setup page.

**Deliverable:** a DSPi with no host computer appears on the network exactly
like one hosted by Console, minus `fw_install`.

## Phase 8 - Firmware additions worth considering (none blocking)

1. **Device friendly name** command and storage (device-level, survives
   factory reset like the interface configs) so the name travels with the
   board between hubs. Until then hubs store names by serial.
2. **UART-side firmware update.** Without it a bridged device needs physical
   USB access for updates. A staged image in the spare flash with a
   swap-on-boot would let the bridge do it; this is a substantial firmware
   feature and is deliberately out of this plan's scope.
3. **A `PARAM_SRC_LINK` source tag** is not needed: Link attributes by
   session, which is finer than any source byte could be.

## Tests

Pure logic (`DSPi ConsoleTests`, no device): frame codec and decoder tests
driven by the shared fixture files (spec section 9.3), so a fixture that
passes here and in the C# suite proves the two consoles agree byte for byte;
frame codec round-trips for every binary type; JSON envelope encode/decode with unknown fields; policy table
completeness; router ordering with three sessions; attribution window;
notify fan-out drop and RESYNC; poll dedupe and budget; auth store pairing,
rate limit, revocation; snapshot patching from `PARAM_CHANGED`.

Live device (`HardwareIntegrationTests`, self-skips): hub plus
`NetworkTransport` in-process over loopback, set and read back master volume,
receive the notification with the right `origin`, subscribe to status polls
and see frames at the granted rate, bulk read equals a direct USB bulk read.

---

## 2. What the original vision leaves out

Each of these is folded into the spec or the phases above.

1. **Several clients at once.** Two people (or one person with a phone and a
   laptop) will write to the same device. Ordering, attribution and echo
   suppression have to be designed in, not bolted on; the firmware's
   notification stream makes all clients converge, but only if each can tell
   its own writes from everyone else's. Today's Console cannot.
2. **Permissions.** A phone that can adjust volume should not be able to
   reassign GPIO pins, factory reset or enter the bootloader. Three roles
   and a command classification table cover it, and revocation needs a UI.
3. **Firmware updates.** They work through a Console hub because the hub can
   drive the UF2 bootloader. They cannot work through an ESP32 bridge with
   today's firmware. This needs saying to users up front.
4. **Wi-Fi provisioning for the bridge**, and the one-time USB step to enable
   the DSPi's UART interface with notifications on.
5. **Device naming that survives moving a device** between hubs or from USB
   to a bridge. Key everything on the serial.
6. **The gateway going away.** macOS sleep, App Nap, login. The menu bar mode
   needs launch-at-login, an App Nap exemption, an optional sleep assertion,
   and clients that reconnect quietly.
7. **Bandwidth on a UART bridge.** An RTA bin frame is about 1 KB and meters
   are 27 bytes at 10 Hz; at 115200 baud the RTA alone saturates the link.
   Poll budgets and hub-granted rates handle it; the bridge must run the
   UART fast.
8. **Long operations.** Bulk apply, preset save (flash blackout) and firmware
   install must not interleave with another client's writes. Exclusive locks.
9. **First-screen latency.** A phone should not need a 6 KB bulk read plus
   dozens of GETs to draw its first screen; the hub keeps a snapshot cache.
10. **Browser realities.** Mixed-content blocking means the web UI must be
    served by the hub over plain HTTP on the LAN; TLS is optional and
    trust-on-first-use for native clients only. State this rather than
    discover it late.
11. **Local-network privacy prompts** on macOS 15 and iOS require usage
    strings and the Bonjour service type in the app's Info.plist, or
    discovery silently finds nothing.
12. **Diagnostics.** Per-session and per-device counters (`hub.stats`) so
    "the phone feels laggy" can be answered with a number.
13. **Remote access beyond the LAN** is best left to a VPN; a relay service
    would add accounts, cloud infrastructure and a very different security
    model. The protocol needs nothing for it.
14. **The Windows console** can become a client with the same protocol, which
    is one more reason to keep the control plane JSON and the data plane the
    firmware's own bytes.

---

## 3. Decisions taken in this plan

| Decision | Choice | Why |
|----------|--------|-----|
| Protocol shape | Tunnel the vendor surface plus a small JSON control plane | Zero protocol churn as firmware grows; bridge stays thin |
| Transport | WebSocket, one port, sub-protocol `dspi-link-1` | Native everywhere the clients live, including browsers and ESP-IDF |
| Discovery | DNS-SD `_dspi._tcp` plus `/dspi/v1/info` | Standard on every platform; manual entry still works |
| Default port | 11915 (decimal of USB VID 0x2E8B) | Memorable, unregistered range; advertised so it is not fixed |
| Auth | Pairing PIN to long-lived token, three roles, hash-only storage | Simple for users, revocable, no accounts |
| TLS | Optional, off by default, TOFU for native clients | Browsers cannot trust LAN self-signed certs without friction |
| Meters | Client-defined poll subscriptions with verbatim responses | No meter format to maintain; new firmware meters work on day one |
| Local UI | A session on the hub, not a privileged path | One ordering and one attribution model for everyone |
| Server stack | SwiftNIO | One port for WebSocket, info and static UI |
| Web UI hosting | Served by the hub, also from the bridge's flash | Mixed-content rules leave no other option on a LAN |
| Mobile apps | Native Swift and Kotlin, porting the client and decoder layers | Native polish; alignment held by shared fixture tests |

## 4. Windows Console parity

DSPi Console for Windows (`WeebLabs/DSPi-Console-Windows`, C#) will gain the
same hub and client roles. The following keep that port mechanical rather
than a second design exercise.

**Put the cross-implementation material in its own repository.** Recommended:
`WeebLabs/DSPi-Link`, holding the protocol spec (moved from this repo once it
settles), `policy/commands.json`, the fixture sets, the Python reference
client and hub, and the `dspi-link-js` library. Both consoles, the ESP32
bridge and the mobile apps vendor a tagged version of it. The fixtures are the
contract: a decoder change that breaks one platform fails in every platform's
CI on the same bytes.

**Mirror the architecture and the names.** The Windows app gets the same five
components with the same responsibilities: `DeviceRegistry`, `CommandRouter`,
`NotifyRelay`, `PollScheduler`, `AuthStore`, behind an `IDeviceTransport`
whose two calls match the existing WinUSB wrapper's shapes, with a
`HubTransport` for the local UI and a `NetworkTransport` for client mode.
Reviewing one side against the other then works line by line, the way the
`.dspipreset` parity work was done.

**Platform equivalents, chosen so nothing in the protocol depends on them:**

| Concern | macOS | Windows |
|---------|-------|---------|
| Server | SwiftNIO (`NIOHTTP1` + `NIOWebSocket`) | Kestrel via a `FrameworkReference` to `Microsoft.AspNetCore.App`: WebSockets, static files and the info endpoint on one port without URL ACLs. Avoid `HttpListener`, which needs `netsh urlacl` for a non-admin bind. |
| Client socket | `URLSessionWebSocketTask` | `System.Net.WebSockets.ClientWebSocket` |
| Advertise / browse | `DNSServiceRegister` / `NWBrowser` | `Windows.Networking.ServiceDiscovery.Dnssd` (`DnssdServiceInstance` / `DeviceWatcher`), native on Windows 10+ |
| Bulk to the device | `0xA0` / `0xA1` single-shot | `0xA2` / `0xA3` chunked, hidden inside the hub (spec 9.1.1) |
| Notification endpoint | IOKit bulk read on EP 0x83 | The WinUSB async read the Windows console already uses |
| Token storage | Keychain | DPAPI (`ProtectedData`, current-user scope) |
| Background mode | `MenuBarExtra` + accessory activation policy | Tray `NotifyIcon`, hide the main window |
| Start at login | `SMAppService.mainApp` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry, or a Startup-folder shortcut |
| Keep running | App Nap exemption, optional sleep assertion | Nothing needed for throttling; `SetThreadExecutionState` for the optional sleep hold |
| Firewall | None by default | Inbound rule on the Private profile, added by the installer |
| Bridge provisioning | Improv over USB serial | Same, via `SerialPort` |
| Firmware install through the hub | `BootloaderLocator` + `FirmwareInstaller` | Existing UF2 drive-letter path; `fw_install` advertised |

**JSON.** Keys are `snake_case` (now stated in spec 7.1). In .NET 8 and later
`JsonNamingPolicy.SnakeCaseLower` maps them directly; on an older target,
`JsonPropertyName` attributes do. Binary frames are little-endian throughout,
which is `BinaryPrimitives.*LittleEndian` on the C# side.

**Sequencing.** Build and stabilise the macOS hub first, then run the Windows
client against it, then the Windows hub against the macOS client. The Python
reference implementations give each side something to test against before
the other exists.

## 5. Decisions confirmed by the user (2026-09-08)

1. **Name and service type stay:** the protocol is "DSPi Link", the
   sub-protocol `dspi-link-1`, the service `_dspi._tcp`, the default port
   11915.
2. **SwiftNIO is accepted** as the project's first Swift package dependency,
   for the hub server in Phase 3.
3. **Web UI in TypeScript, mobile apps native.** The `dspi-link-js` library
   serves the web app only; iOS and Android port the client and decoder
   layers, with shared fixture tests to keep them aligned (Phase 6).
4. **All three roles ship in v1:** viewer, control and admin.
5. **Windows Console gains the same functionality.** Shared artefacts and
   platform equivalents are in section 4; the protocol absorbs the WinUSB
   bulk cap on the hub side so clients never see it.
