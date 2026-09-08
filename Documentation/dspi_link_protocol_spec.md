# DSPi Link Protocol Specification

*Version: 1.0 (draft)*
*Status: design, not yet implemented*
*Last updated: 2026-09-08*

DSPi Link is the local-network protocol through which a **hub** (DSPi Console
in gateway mode, or a standalone bridge such as an ESP32 wired to a DSPi over
UART) shares one or more DSPi devices with **clients** (DSPi Console on another
machine, a web page served by the hub, or a mobile app). This document is
self-contained: a hub or client can be implemented from it plus the firmware's
vendor command catalogue (`Documentation/commands.md` in the firmware repo)
and the notification spec (`notification_protocol_v2_spec.md`). No DSPi Console
source is required.

Writing style note: this document avoids em-dashes per project convention.

---

## 1. Design principles

1. **Tunnel the vendor surface; do not re-model it.** Every DSPi feature is
   already reachable as `(bRequest, wValue, wIndex, wLength, payload)` over
   USB, UART and I2C with full parity. Link carries that same shape byte for
   byte. When the firmware adds a command, every hub and client can use it
   with no change to this protocol. The hub never interprets command payloads.
2. **Firmware payloads travel verbatim.** Notification packets, meter frames,
   RTA frames and bulk blobs are relayed exactly as the device produced them.
   Clients decode them with the same code they would use over USB, and the
   firmware's own wire-format version and capability commands remain the
   only gates a client needs.
3. **A small JSON control plane for what the firmware does not know about:**
   discovery, authentication, the device inventory, subscriptions and locks.
   JSON is additive by construction; unknown fields are ignored.
4. **Thin hubs.** An ESP32 must be able to implement a hub. Nothing in the
   mandatory core needs more than a WebSocket server, a few kilobytes of
   state, and a UART.
5. **One protocol, several hub kinds.** A client cannot tell a Console hub
   from a bridge except through the capability list in `hello`.
6. **Compatible evolution.** Major version lives in the URL path. Minor
   versions add message types, fields, frame types and capability names;
   they never change the meaning of existing ones.

---

## 2. Terminology

| Term | Meaning |
|------|---------|
| Hub | The process that owns the physical link to one or more DSPi devices and serves them over the network. Kinds: `console` (Console in gateway mode, USB) and `bridge` (standalone microcontroller, UART). |
| Device | One DSPi board, identified by its 16-character serial (`REQ_GET_SERIAL`, 0x7E), which is also the USB `iSerialNumber`. |
| Client | Anything that connects to a hub: Console in client mode, the web UI, a mobile app, a script. |
| Session | One authenticated WebSocket connection. Has a session id, a role, and a client name. |
| Handle | A small integer (0..254) the hub assigns to a device for the lifetime of its attachment. Used in binary frames instead of the serial. 255 is reserved. |
| Command | One tunnelled vendor request and its response. |

---

## 3. Discovery

### 3.1 DNS-SD

Hubs advertise one DNS-SD (Bonjour / mDNS) service instance per hub:

```
Service type:   _dspi._tcp.local.
Instance name:  the hub's user-visible name (UTF-8, e.g. "Studio Mac" or "DSPi Bridge 3F2A")
Port:           the WebSocket/HTTP port (default 11915, decimal of the USB VID 0x2E8B)
```

TXT record keys (all values are ASCII; unknown keys must be ignored):

| Key | Required | Value |
|-----|----------|-------|
| `v` | yes | Highest protocol major version served, currently `1`. |
| `hid` | yes | Hub id: a lowercase UUID string, stable for the life of the installation. |
| `kind` | yes | `console` or `bridge`. |
| `auth` | yes | `none` or `pin`. See section 6. |
| `n` | yes | Number of devices currently shared, decimal. |
| `d` | no | Comma-separated serials of shared devices, so a client can show devices before connecting. Omit if it would push the TXT record past 400 bytes. |
| `tls` | no | `1` if the port speaks TLS (clients use `wss://` and `https://`). Absent means plaintext. |
| `path` | no | WebSocket path if not the default `/dspi/v1`. |
| `web` | no | `1` if `GET /` serves a browser UI. |

Clients that want to present *devices* rather than hubs union the `d` lists
(or the `device.list` results) across every hub they can see and key the
result on serial. A device that moves from one hub to another is the same
device; hubs are only the way to reach it.

### 3.2 HTTP info endpoint

Every hub also answers a plain HTTP request so manual-IP entry and scripts
work without DNS-SD:

```
GET /dspi/v1/info
200 OK, Content-Type: application/json
{
  "proto": {"major": 1, "minor": 0},
  "hub":   {"id": "<uuid>", "name": "Studio Mac", "kind": "console", "version": "1.1.7"},
  "auth":  "pin",
  "tls":   false,
  "ws":    "/dspi/v1",
  "devices": [ {"serial": "E46058388B1A2E2C", "name": "Living room"} ]
}
```

`Access-Control-Allow-Origin: *` is set on this endpoint only, so a page
served from another hub (or from a file) can probe it.

### 3.3 Manual entry

A client must accept a bare host or `host:port` typed by the user and derive
`http://host:port/dspi/v1/info`, then the WebSocket URL from the response.

---

## 4. Transport

- **WebSocket** (RFC 6455) at `ws://host:port/dspi/v1` (or `wss://` when TLS
  is advertised). Sub-protocol name `dspi-link-1` must be requested by the
  client and echoed by the hub. Hubs may refuse connections that do not
  request it.
- **Text frames carry JSON control messages** (section 7).
- **Binary frames carry data-plane frames** (section 8).
- WebSocket ping/pong is the keepalive. The hub pings every 10 s and closes a
  session that has not answered within 30 s. Clients may ping too.
- A single WebSocket frame carries exactly one message. Message size limit is
  advertised by the hub in `hello` (`limits.max_frame`, at least 16384 bytes).
- Connections are multiplexed: one session may address every device the hub
  shares. There is no per-device connection.

### 4.1 Why WebSocket

It is the one transport every intended client has natively: browsers, iOS
(`URLSessionWebSocketTask`, `Network.framework`), Android (OkHttp), .NET
(`ClientWebSocket`, for the Windows console), Python, and ESP-IDF's
`esp_http_server`. It gives framing, keepalive, and the HTTP upgrade path that
lets one port serve the API, the info endpoint and the web UI.

### 4.2 HTTP surface on the same port

| Path | Method | Purpose |
|------|--------|---------|
| `/dspi/v1` | WebSocket upgrade | The protocol. |
| `/dspi/v1/info` | GET | Discovery info, section 3.2. |
| `/` and static assets | GET | Optional browser UI (`web=1`). |

Nothing else is defined. There is deliberately no REST API for device
control; the WebSocket is the single place commands go, which keeps
serialisation, locking and attribution in one path.

---

## 5. Session lifecycle

```
client                                  hub
  |---- WebSocket upgrade --------------->|
  |<--- 101 Switching Protocols ----------|
  |---- {"t":"hello", ...} -------------->|
  |<--- {"t":"hello", ...} ---------------|      (includes auth requirement)
  |---- {"t":"auth.token"|"auth.pair"} -->|      (skipped when auth is "none")
  |<--- {"t":"ok", role, session} --------|
  |---- {"t":"device.list"} ------------->|
  |<--- {"t":"ok", devices:[...]} --------|
  |     ... commands, events, polls ...   |
```

Until `auth` succeeds (or the hub reports `auth: "none"` in its hello), the
hub answers every other message with `err` code `unauthenticated` and
discards binary frames. A hub closes the socket with WebSocket close code
4001 after 30 s without a successful auth.

Close codes used by hubs:

| Code | Meaning |
|------|---------|
| 1000 | Normal close. |
| 4000 | Protocol error (malformed message, unknown sub-protocol). |
| 4001 | Authentication timeout or failure limit reached. |
| 4002 | Token revoked. |
| 4003 | Hub shutting down. Clients reconnect with backoff (1 s, 2 s, 4 s, ... capped at 30 s). |

---

## 6. Authentication and authorization

### 6.1 Modes

| `auth` | Behaviour |
|--------|-----------|
| `none` | Every connection is an `admin` session: the hub opens the session as soon as it answers `hello`, and the client sends no auth message. A client that wants its session id (for echo suppression) may still send `auth.pair` with any PIN and receives the usual `ok`. For trusted networks and bench use only. Hubs must default to `pin`. |
| `pin` | A new client pairs once with a short-lived PIN shown by the hub and receives a long-lived token. Afterwards it presents the token. |

### 6.2 Pairing

1. The user opens the hub's pairing window (Console: "Allow new client" in
   the Networking settings; a bridge: a button press or its setup page). The
   hub generates a 6-digit PIN, displays it, and accepts pairing attempts for
   2 minutes.
2. The client sends `auth.pair` with the PIN, a client name, and the role it
   requests. The hub returns a token: 32 random bytes, base64url, plus the
   granted role.
3. The client stores the token against the hub id `hid` (not the address,
   which may change). Console and the mobile apps keep it in the platform
   keychain; the web UI keeps it in `localStorage` for the hub's origin.

The hub records `{token hash, client name, role, created, last seen}` and
lists these in its UI so the user can rename, change the role of, or revoke
any client. A hub stores only a SHA-256 of the token. Revocation and role
changes apply to the client's live sessions at once: a revoked client's
connections are closed with code 4002, and a re-roled client's next command
is judged by the new role.

Rate limit: after 5 failed `auth.pair` or `auth.token` attempts from one
address within a minute, the hub answers `rate_limited` for 60 s. The PIN is
invalidated after any 5 failures.

### 6.3 Roles

| Role | May |
|------|-----|
| `viewer` | Issue `GET`-direction commands classed *read*, subscribe to polls, receive notifications. |
| `control` | Everything `viewer` can, plus `SET` commands classed *control* (EQ, routing, volumes, presets, DSP features, test signals, RTA). |
| `admin` | Everything, including *config* (pins, input sources, control interfaces, control surfaces, flash writes of device-level config, factory reset, bootloader entry, firmware install, hub settings, client management). |

The hub classifies each `bRequest` into *read*, *control* or *config* with
a table it owns and maintains. Because the table is hub policy, the hub
publishes the session's effective denial list in `hello` (`policy.denied`,
an array of `[bRequest, dir]` pairs) so clients can grey out controls without
guessing. A command outside the role gets status `0x81 DENIED`.

Write-as-read commands (a `GET` transfer that mutates, see `commands.md`
section 1.1) are classified by what they do, not by their direction. The
table must list them explicitly.

### 6.4 Transport security

Version 1.0 hubs serve plaintext by default because browsers cannot be made
to trust a self-signed certificate on a LAN without user friction, and the
threat model is "devices on my own network". Hubs may offer TLS (`tls=1`);
native clients pin the certificate on first use (trust on first use, keyed by
`hid`) and warn if it changes. Tokens are only ever sent inside the WebSocket
after `hello`, never in URLs.

Hubs must bind to LAN interfaces only and must never be exposed through
router port forwarding. Remote access is out of scope; a VPN such as
Tailscale or WireGuard is the recommended route and needs no protocol
support.

---

## 7. Control plane (JSON, text frames)

### 7.1 Envelope

Every text frame is one JSON object with a string `t` (type). Requests carry
an integer `id` chosen by the sender (unique per session while outstanding).
Replies echo `id` and have `t` equal to `ok` or `err`. Events have no `id`.

```json
{"t": "device.list", "id": 7}
{"t": "ok", "id": 7, "devices": [ ... ]}
{"t": "err", "id": 7, "code": "denied", "msg": "admin role required"}
```

JSON keys are `snake_case` throughout (`max_frame`, `wire_version`,
`locked_by`). Implementations must not depend on key order. Timestamps are
ISO-8601 UTC with a `Z` suffix. Binary blobs inside JSON are standard base64
with padding, in fields whose names end in `_b64`.

Error codes: `unauthenticated`, `denied`, `bad_request`, `unknown_type`,
`no_device`, `locked`, `busy`, `rate_limited`, `unsupported`, `internal`.
A hub answers an unknown request type with `err` `unknown_type`; a client
ignores unknown event types. Both ignore unknown fields.

### 7.2 hello

Client to hub, first message:

```json
{"t": "hello", "proto": {"major": 1, "minor": 0},
 "client": {"name": "Troy's iPhone", "app": "DSPi Mobile", "version": "0.1"}}
```

Hub to client, in reply (no `id`):

```json
{"t": "hello",
 "proto": {"major": 1, "minor": 0},
 "hub": {"id": "<uuid>", "name": "Studio Mac", "kind": "console", "version": "1.1.7"},
 "auth": "pin",
 "caps": ["cmd", "notify", "poll", "snapshot", "lock", "fw_install", "web", "rename"],
 "limits": {"max_frame": 65536, "max_payload": 8192, "max_inflight": 8,
            "poll_max_hz": 20, "poll_budget_bps": 200000}}
```

`caps` lists what the hub implements beyond the mandatory core:

| Capability | Meaning |
|------------|---------|
| `cmd` | Command tunnel (mandatory). |
| `notify` | Notification relay (mandatory when the link to the device can deliver notifications; a bridge whose UART has `notify_enable` off omits it and clients fall back to polling). |
| `poll` | Poll subscriptions (mandatory). |
| `snapshot` | `device.snapshot` served from the hub's cache. |
| `lock` | Exclusive device locks. |
| `fw_install` | Firmware installation through the hub (Console hubs only; a bridge cannot reach the UF2 bootloader). |
| `web` | Browser UI on `/`. |
| `rename` | Hub-stored device names (`device.rename`). |

`limits.max_payload` is the largest command payload (either direction) the
hub accepts, at least 8192 so the bulk blob fits. `poll_budget_bps` is the
total poll bandwidth the hub grants a session; a bridge on a 115200-baud UART
advertises a small one.

### 7.3 Authentication messages

```json
{"t": "auth.token", "id": 1, "token": "<base64url>"}
{"t": "ok", "id": 1, "session": 12, "role": "control", "policy": {"denied": [[240,1],[83,1]]}}

{"t": "auth.pair", "id": 1, "pin": "482913", "name": "Troy's iPhone", "role": "control"}
{"t": "ok", "id": 1, "session": 12, "role": "control", "token": "<base64url>", "policy": {...}}

{"t": "auth.list", "id": 2}                         (admin)
{"t": "ok", "id": 2, "clients": [{"cid": 3, "name": "Troy's iPhone", "role": "control",
                                  "created": "2026-09-08T10:12:00Z", "last_seen": "...", "online": true}]}
{"t": "auth.revoke", "id": 3, "cid": 3}             (admin)
{"t": "auth.set_role", "id": 4, "cid": 3, "role": "viewer"}   (admin)
```

`session` is the session id the hub stamps into notification frames as
`origin` (section 9.2). A client must remember it.

### 7.4 Device inventory

```json
{"t": "device.list", "id": 5}
{"t": "ok", "id": 5, "devices": [
  {"handle": 0, "serial": "E46058388B1A2E2C", "name": "Living room",
   "platform": 1, "fw": "1.1.7", "outputs": 9, "inputs": 8,
   "wire_version": 30, "state": "online", "link": "usb",
   "locked_by": null}
]}
```

| Field | Source |
|-------|--------|
| `handle` | Hub-assigned, section 2. Stable until `device.removed`. |
| `serial` | `REQ_GET_SERIAL` (0x7E). |
| `name` | Hub-stored friendly name, or a default derived from the serial. |
| `platform`, `fw`, `outputs` | `REQ_GET_PLATFORM` (0x7F), 6-byte read. |
| `inputs` | Compile-time input count if the hub knows it; else omitted. |
| `wire_version` | From the bulk header, if the hub has read it; else omitted. Clients must still read it themselves. |
| `state` | `online`, `offline` (known device currently unplugged; handle retained for 60 s), `updating` (firmware install in progress). |
| `link` | `usb` or `uart`. Tells a client what to expect for latency and bulk timing. |
| `locked_by` | Session id holding an exclusive lock, or `null`. |

Events, sent to every session:

```json
{"t": "device.added",   "device": { ...same object... }}
{"t": "device.removed", "handle": 0, "serial": "..."}
{"t": "device.changed", "device": { ...same object... }}
```

`device.rename {handle, name}` (control or admin) changes the hub-stored name
and emits `device.changed`. If the firmware later gains a device-name
command, hubs should prefer it so the name travels with the board.

### 7.5 Snapshot

```json
{"t": "device.snapshot", "id": 6, "handle": 0}
{"t": "ok", "id": 6, "handle": 0, "wire_version": 30, "age_ms": 120,
 "bulk_b64": "<REQ_GET_ALL_PARAMS blob, base64>", "status_b64": "<REQ_GET_STATUS wValue=9 response>"}
```

The hub keeps one cached bulk blob per device, refreshed on
`BULK_INVALIDATED` and patched in place from every `PARAM_CHANGED` it
relays, so a client's first screen costs one round trip instead of a
bulk transfer plus dozens of GETs. `age_ms` says how stale the cache is. A
hub that does not implement the cache omits the `snapshot` capability and
clients read the device directly.

### 7.6 Poll subscriptions

Meters, RTA frames and any other transient state are not notified by the
firmware; they must be polled. Rather than defining a meter format that would
need updating every time the firmware adds one, a session tells the hub which
`GET` commands to poll and how often, and the hub pushes the verbatim
responses as binary `POLL` frames (section 8.4). Identical polls requested by
several sessions are executed once and fanned out.

```json
{"t": "poll.subscribe", "id": 8, "handle": 0, "polls": [
  {"slot": 0, "req": 80,  "val": 9, "idx": 2, "len": 27, "hz": 10},
  {"slot": 1, "req": 11,  "val": 3, "idx": 2, "len": 80, "hz": 15}
]}
{"t": "ok", "id": 8, "granted": [{"slot": 0, "hz": 10}, {"slot": 1, "hz": 12}]}

{"t": "poll.unsubscribe", "id": 9, "handle": 0, "slots": [1]}
```

`slot` is a session-chosen number 0..15 that comes back in each `POLL` frame.
The hub may grant a lower rate than requested to stay inside
`poll_budget_bps`; it reports the granted rates. Poll commands must be
classed *read*. A subscription ends when the session closes, when the device
goes offline, or on `poll.unsubscribe`. Hubs must stop polling a device the
moment no session subscribes, since RTA and some meters switch themselves off
when unread and keeping them alive costs device CPU.

### 7.7 Locks

Long operations that must not be interleaved with other clients' commands
(firmware install, `REQ_SET_ALL_PARAMS`, preset save with its flash blackout)
take an exclusive lock:

```json
{"t": "lock.acquire", "id": 10, "handle": 0, "reason": "Applying configuration", "timeout_ms": 10000}
{"t": "ok", "id": 10}
{"t": "lock.release", "id": 11, "handle": 0}
```

While locked, commands from other sessions get status `0x85 LOCKED` and
`device.changed` carries `locked_by`. The hub releases a lock when its
session closes or the timeout elapses. A hub without the `lock` capability
serialises commands as usual and clients skip the lock step.

### 7.8 Firmware install (Console hubs)

```json
{"t": "fw.install", "id": 12, "handle": 0, "size": 393216, "sha256": "<hex>", "version": "1.1.8"}
{"t": "ok", "id": 12, "xfer": 3}
   ... client sends FWDATA binary frames with xfer 3 (section 8.5) ...
{"t": "fw.progress", "handle": 0, "phase": "uploading"|"rebooting"|"copying"|"verifying", "pct": 42}
{"t": "fw.done", "handle": 0, "ok": true, "fw": "1.1.8"}
```

Requires `admin` and implicitly takes the lock. The hub validates the SHA-256
before touching the device, enters the bootloader (0xF0), copies the UF2 and
waits for the device to re-enumerate with the expected version. The device is
`updating` throughout and `device.changed` fires at each state.

### 7.9 Hub management (admin)

```json
{"t": "hub.stats", "id": 13}
{"t": "ok", "id": 13, "sessions": 3, "uptime_s": 8812,
 "devices": [{"handle": 0, "cmds": 18233, "errors": 2, "avg_rtt_ms": 1.4, "notify_dropped": 0}]}
{"t": "hub.rename", "id": 14, "name": "Studio Mac"}
```

---

## 8. Data plane (binary frames)

All binary frames begin with a 4-byte header. Multi-byte integers are
little-endian, matching the firmware.

```
Offset  Size  Field   Meaning
0       1     type    Frame type, table below
1       1     flags   Reserved, 0. Receivers ignore unknown bits.
2       2     tag     Per-type meaning: request id, sequence, or transfer id
```

| Type | Direction | Name | Section |
|------|-----------|------|---------|
| 0x01 | client to hub | CMD request | 8.2 |
| 0x81 | hub to client | CMD response | 8.2 |
| 0x02 | hub to client | NOTIFY | 8.3 |
| 0x03 | hub to client | POLL | 8.4 |
| 0x04 | client to hub | FWDATA chunk | 8.5 |
| 0x84 | hub to client | FWDATA ack | 8.5 |
| 0x05 | hub to client | RESYNC | 8.6 |

Types 0x06..0x7F are reserved for future client-to-hub or bidirectional
frames; 0x85..0xFF for future hub-to-client frames. A receiver ignores frame
types it does not know; a hub answers an unknown *request* type with a CMD
response carrying status `0x86 UNSUPPORTED` and the same `tag` when it can
tell the frame was a request (types below 0x80 from a client).

### 8.1 Status codes

Byte 0 of a CMD response. Codes 0x00..0x07 are the firmware's `CTRL_STATUS_*`
values, so a bridge forwards the UART status untouched and a Console hub maps
its USB result onto the same table. Codes from 0x80 are Link-level.

| Code | Name | Meaning / client action |
|------|------|-------------------------|
| 0x00 | OK | On GET, payload follows. On SET, dispatched (as with USB and UART, this does not certify the value was applied; read back if it matters). |
| 0x01 | BUSY | Device could not take the request now. Retry. |
| 0x02 | ERROR | Unknown command or the handler rejected it (USB STALL maps here). |
| 0x03 | BLOCKED | The device refused a USB-only command on this transport (bridge hubs: 0xF5, 0xF7, 0xA2, 0xA3). |
| 0x04 | BULK_LOCKED | Bulk buffer owned by another transport. Retry. |
| 0x05 | CRC_ERROR | UART CRC failure between bridge and device. Retry. |
| 0x06 | OVERSIZE | Payload too large for the device transport. |
| 0x07 | FRAME_ERROR | Malformed frame between bridge and device. |
| 0x80 | NO_DEVICE | No device at this handle, or it is offline. |
| 0x81 | DENIED | The session's role does not permit this command. |
| 0x82 | TIMEOUT | The hub gave up waiting for the device (default 2 s, 5 s for bulk). The command may or may not have executed. |
| 0x83 | TOO_LARGE | Payload exceeds `limits.max_payload`. |
| 0x84 | RATE_LIMITED | Too many in-flight commands; see `max_inflight`. |
| 0x85 | LOCKED | Another session holds the device lock. |
| 0x86 | UNSUPPORTED | Frame type or feature this hub does not implement. |
| 0x87 | BAD_FRAME | Malformed Link frame. |

### 8.2 CMD

Request (type 0x01, `tag` = request id chosen by the client):

```
Offset  Size  Field     Meaning
4       1     handle    Device handle
5       1     dir       0 = SET (host to device, bmRequestType 0x41)
                        1 = GET (device to host, bmRequestType 0xC1)
6       1     bRequest  Vendor command id
7       1     reserved  0
8       2     wValue
10      2     wIndex    Pass 2 for application commands; the hub forwards it
12      2     wLength   SET: payload length that follows.  GET: bytes requested.
14      n     payload   SET only, wLength bytes
```

Response (type 0x81, `tag` = the request id):

```
Offset  Size  Field     Meaning
4       1     status    Section 8.1
5       1     reserved  0
6       2     length    Payload bytes that follow (0 unless status OK on a GET)
8       n     payload
```

Rules:

- **Direction is the client's statement of the USB transfer type.** Write-as-read
  commands are sent with `dir = 1` exactly as over USB. The hub does not
  second-guess it; it only classifies for authorization.
- **Ordering.** The hub executes commands for one device strictly in arrival
  order across all sessions and answers a session's commands in the order it
  sent them. Commands for different devices may interleave. A client may keep
  up to `max_inflight` requests outstanding per device; the hub answers
  `RATE_LIMITED` beyond that.
- **GET length.** A GET response may be shorter than `wLength` (the firmware
  clamps, and old firmware returns short reads). Clients size by `length`.
- **Bulk.** `REQ_GET_ALL_PARAMS` (0xA0) and `REQ_SET_ALL_PARAMS` (0xA1) go
  through unchanged with `wLength` up to `max_payload`. Clients never use the
  chunked forms (0xA2/0xA3) over Link; how the hub moves the blob to the
  device is its own business (single-shot on macOS, chunked on a Windows hub
  in future, one UART frame on a bridge).
- **Timeouts.** The hub waits at least 2 s for a response, 5 s for bulk, then
  answers `TIMEOUT`. Flash-writing commands can blind the device for about
  45 ms; hubs must not treat one timeout as a device loss.
- **Bootloader entry (0xF0)** is `config` class. After it, the hub reports
  the device `offline`, then `removed` if it does not return within 60 s
  (Console hubs that were asked to install firmware handle this themselves).

### 8.3 NOTIFY

Type 0x02, `tag` = Link sequence number, incremented per notification per
session (independent of the firmware's 8-bit `seq`, which stays inside the
packet).

```
Offset  Size  Field     Meaning
4       1     handle    Device
5       1     reserved  0
6       2     origin    Session id the hub attributes this change to, or 0 if unknown
8       n     packet    Verbatim v2 notification packet, starting with version byte 0x02
```

The hub relays every non-idle packet from the device's notification channel
(USB EP 0x83, or UART type 0x40 frames) to every authenticated session.
Clients parse `packet` exactly per `notification_protocol_v2_spec.md`. v1
legacy packets are never relayed; every v1 event has a v2 twin.

`origin` is the hub's best-effort attribution. The hub keeps the sessions of
its recent writes in dispatch order and, for each packet whose `source` byte
is `HOST_SET` (1), `BULK_SET` (2) or `UART` (8), consumes the oldest one made
within a short window as `origin`. Order, not recency, so a second client's
write landing before the first client's notification is read does not take
its attribution. The firmware coalesces repeated writes to one parameter, so
the queue can run ahead of the notifications; that is why this is a hint. Clients use it to suppress their own echoes and must treat
it as a hint, not a guarantee. A client must **not** suppress by `source`
alone: over Link, `HOST_SET` means "some Link client", which may be someone
else.

A gap in the Link `tag` sequence, or a gap in the firmware `seq`, means the
session missed events; the client re-reads state (`device.snapshot` or
`REQ_GET_ALL_PARAMS`). The hub sends RESYNC (8.6) when it knows it dropped.

### 8.4 POLL

Type 0x03, `tag` = per-session poll sequence.

```
Offset  Size  Field     Meaning
4       1     handle    Device
5       1     slot      The session's slot from poll.subscribe
6       2     length    Payload bytes
8       n     payload   Verbatim response of the subscribed GET
```

If a poll fails (device busy, offline), the hub sends nothing for that
tick; three consecutive failures produce a `poll.error` JSON event and the
hub keeps trying at a reduced rate until the device recovers. The event is
`{"t": "poll.error", "handle": H, "slot": S, "code": "busy"|"no_device"|...,
"msg": "..."}`; `slot`, `code` and `msg` are optional and `code` reuses the
error-code vocabulary of section 7.1.

### 8.5 FWDATA

Type 0x04 from the client, `tag` = the `xfer` id from `fw.install`.

```
Offset  Size  Field     Meaning
4       4     offset    Byte offset into the image
8       n     data      Up to max_frame - 8 bytes
```

The hub answers each chunk with type 0x84, same `tag`, body `[offset u32]
[status u8]` (0 = accepted). Chunks must be sequential from 0. The hub
verifies the SHA-256 when the last byte lands and only then proceeds.

### 8.6 RESYNC

Type 0x05, body `[handle u8][reason u8]`. The 2-byte header `tag` is
unused here: senders write 0 and receivers ignore it. Reasons: 0 = hub
dropped notifications for this session (slow reader), 1 = device reattached,
2 = hub cache rebuilt. A receiver treats an unknown reason as reason 0 (re-read
state) rather than an error. The client re-reads state.

---

## 9. Hub requirements by kind

### 9.1 Console hub (USB)

- Owns the vendor interface exclusively; the local UI and all remote sessions
  go through the same command router, so ordering and attribution are the
  same for everyone.
- Maps USB results to status codes: success to `OK`, `kIOUSBPipeStalled` to
  `ERROR`, timeouts to `TIMEOUT`, disconnect to `NO_DEVICE`.
- Relays EP 0x83 packets and keeps the snapshot cache.
- Implements `fw_install`, `lock`, `snapshot`, `rename`, `web`.

### 9.1.1 Windows Console hub

DSPi Console for Windows implements the same hub with these differences,
none of which are visible to clients:

- **Bulk transfers.** WinUSB caps a control transfer's data stage at 4096
  bytes, so a Windows hub cannot issue `0xA0`/`0xA1` for the 5980-byte blob.
  It serves a client's `0xA0` GET by running the chunked read (`0xA2`, 2048-byte
  chunks) and returning the concatenated blob in one CMD response, and serves
  a client's `0xA1` SET by splitting the payload across `0xA3` writes. The
  client sees exactly what a macOS hub would return. The hub must hold the
  device's per-device FIFO for the whole chunk session, because any other
  vendor request between chunks tears the session down
  (`bulk_params_chunking.md`). If a client itself sends `0xA2`/`0xA3`, the
  hub passes them through unchanged on any USB hub kind.
- **Status mapping.** WinUSB pipe stall (`ERROR_GEN_FAILURE` on the
  transfer) maps to `ERROR`; `ERROR_SEM_TIMEOUT` to `TIMEOUT`;
  `ERROR_DEVICE_NOT_CONNECTED` to `NO_DEVICE`.
- **Discovery.** Windows 10 and later resolve and advertise mDNS natively
  through `Windows.Networking.ServiceDiscovery.Dnssd` (`DnssdServiceInstance`
  to register, `DeviceWatcher` with the DNS-SD selector to browse); no
  Bonjour installation is needed. The TXT record must be written with the
  same keys as section 3.1.
- **Firewall.** An inbound listener needs a Windows Defender Firewall rule
  for the port on the Private profile. The installer adds it; the app
  detects a missing rule and offers to add it. Without the rule discovery
  works but connections time out, which users will report as "the phone
  sees it but cannot connect".
- **Firmware install** is supported: the UF2 volume appears as a drive
  letter and the existing installer path applies, so `fw_install` is
  advertised.

### 9.2 Bridge hub (UART)

- Requires the device's UART control interface enabled over USB once, with
  `notify_enable = 1` and a baud of 921600 or 1000000 (a 5980-byte bulk read
  takes about 60 ms at 1 Mbaud, 520 ms at 115200). The bridge reads
  `REQ_GET_CTRL_IFACE_STATUS` (0xF9) at boot and reports `uart_live`.
- Obeys the one-request-in-flight rule on the UART: the Link router
  serialises per device anyway, so this costs nothing.
- Forwards the UART `status` byte verbatim; wraps UART timeouts as `TIMEOUT`.
- Relays type 0x40 UART notification frames as NOTIFY. Because a busy request
  stream starves UART notifications, the bridge must leave idle gaps: a
  minimum of 2 ms between the end of one response and the start of the next
  request is enough for the firmware to emit queued notifications.
- Advertises a `poll_budget_bps` that fits the baud rate after leaving half
  the bandwidth for commands and notifications (about 40000 bps at 1 Mbaud).
- Omits `fw_install`. Firmware updates for a bridged device need physical USB
  access until the firmware gains a UART-side update path.
- Stores tokens, the hub id, the hub name and device names in non-volatile
  storage. Provides Wi-Fi provisioning outside this protocol (see the
  Console plan for the recommended path).

---

### 9.3 Shared artefacts across implementations

Several tables in this protocol are policy, not code, and every hub and
client needs the same copy. They are published alongside this spec as
machine-readable files so that no implementation hand-transcribes them:

| File | Content | Used by |
|------|---------|---------|
| `policy/commands.json` | Every `bRequest` with its direction(s), class (`read`, `control`, `config`) and a short name. | Hubs (authorization), clients (greying out controls), tests (coverage). |
| `fixtures/frames/*.bin` + `frames.json` | Byte-exact CMD, NOTIFY, POLL, FWDATA and RESYNC frames with their decoded meaning. | Codec tests in every language. |
| `fixtures/messages/*.json` | Valid and invalid control-plane messages with the expected reply or error code. | Control-plane tests. |
| `fixtures/device/bulk_v30.bin`, `status_rp2350.bin`, `notify_*.bin` | Real device captures with the decoded values in a sidecar JSON. | Decoder tests, so Swift, C#, TypeScript and Kotlin all decode the same bytes to the same numbers. |
| `conformance/` | A reference client that drives any hub through the checklist in section 12, and a reference hub (Python, on the existing `tools/dspi_test` USB layer) that any client can be tested against. | CI for every implementation. |

An implementation embeds `policy/commands.json` as a resource and records the
spec version it was taken from. A hub must treat a `bRequest` absent from
its embedded table as `config`.

## 10. Versioning and compatibility rules

1. The URL path carries the major version (`/dspi/v1`). A hub may serve
   several majors on different paths during a transition.
2. `hello.proto.minor` is additive. A client uses only what the hub's `caps`
   and minor version say exist.
3. JSON: unknown fields ignored by both sides; unknown request types get
   `unknown_type`; unknown events are dropped.
4. Binary: `flags` bits and reserved bytes are 0 when sent and ignored when
   received; unknown frame types are dropped or answered `UNSUPPORTED`.
5. Status codes 0x00..0x07 track the firmware's `CTRL_STATUS_*` table and
   never diverge from it; Link codes live at 0x80 and above.
6. Firmware compatibility is not Link's concern. A client gates features on
   the device's own reports (`REQ_GET_PLATFORM`, the bulk wire-format
   version, `REQ_GET_CAPS` and friends) exactly as it does over USB. The hub
   passes commands through even when it does not know them.
7. The hub's authorization table is the one place where a new firmware
   command needs hub attention: an unlisted `bRequest` is treated as *config*
   (admin only) until classified, which fails safe.

---

## 11. Worked examples

### 11.1 Set master volume to -20 dB (REQ_SET_MASTER_VOLUME 0xD2)

Client sends a binary frame, request id 0x0007, handle 0:

```
01 00 07 00   type=CMD, flags, tag=7
00            handle 0
00            dir = SET
D2            bRequest
00            reserved
00 00         wValue 0
02 00         wIndex 2
04 00         wLength 4
00 00 A0 C1   -20.0f little-endian
```

Hub answers:

```
81 00 07 00   type=CMD response, tag=7
00 00         status OK, reserved
00 00         length 0
```

Every other session then receives a NOTIFY frame carrying the device's
`PARAM_CHANGED` packet for `master_volume.master_volume_db` with
`origin = 12` (the sender's session id), and the sender receives the same
frame and drops it because `origin` matches its own session.

### 11.2 Read the platform (REQ_GET_PLATFORM 0x7F)

```
01 00 08 00  00 01 7F 00  00 00 02 00  06 00
81 00 08 00  00 00 06 00  01 01 17 09 01 07     -> RP2350, fw 1.1.7, 9 outputs
```

### 11.3 Subscribe to the peak meters at 10 Hz

```json
{"t": "poll.subscribe", "id": 3, "handle": 0,
 "polls": [{"slot": 0, "req": 80, "val": 9, "idx": 2, "len": 27, "hz": 10}]}
```

Then, ten times a second:

```
03 00 <seq16>  00 00 1B 00  <27 bytes of REQ_GET_STATUS>
```

---

## 12. Conformance checklist

A hub is conformant when it:

- [ ] advertises `_dspi._tcp` with the required TXT keys and answers `/dspi/v1/info`;
- [ ] negotiates sub-protocol `dspi-link-1` and sends `hello` first;
- [ ] enforces `pin` auth by default, rate-limits failures, stores token hashes only;
- [ ] implements CMD with per-device ordering, `max_inflight`, and the status table;
- [ ] relays notifications verbatim with `origin` attribution and sends RESYNC on drop;
- [ ] implements poll subscriptions with fan-out and stops polling when unsubscribed;
- [ ] classifies every command it forwards and fails safe on unknown ones;
- [ ] keeps handles stable, emits `device.added/removed/changed`;
- [ ] closes with the defined codes and survives client reconnect storms.

A client is conformant when it:

- [ ] discovers via DNS-SD and accepts manual entry;
- [ ] keys stored tokens and trust on `hid`, not on address;
- [ ] uses `caps` and `limits` instead of assuming hub kind;
- [ ] suppresses echoes by `origin`, never by `source` alone;
- [ ] re-reads state on any sequence gap or RESYNC;
- [ ] gates device features on the device's own version and capability reports.
