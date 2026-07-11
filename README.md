# BoatTools

Swift CLI tools to explore sailboat data sources, in **strict concurrency mode**.

The package ships two products:

- **`BoatToolsKit`** — library, multiplatform. All the business logic: NMEA / Signal K / Victron VRM clients, parsers, Bonjour discovery, on-device sensors (Apple CoreLocation/CoreMotion directly, or host-pushed on Android / Windows).
- **`boattools`** — executable, ArgumentParser-based CLI on top of the library. Nine subcommands: `connect`, `devices`, `pilot`, `windlass`, `file`, `vrm`, `discover`, `gmdss`, `simulate`. The device-sensor fallback is a `BoatToolsKit` feature only — it is not exposed by the CLI.

A third piece lives in the nested [`Bridge/`](Bridge) package:
**libBoatToolsBridge**, a dynamic library exposing `BoatToolsKit` through a
plain C ABI (`boattools_bridge_*`) — NMEA parsing, streaming connections
(TCP / UDP / simulator, polled), a host-pushed device-sensor feed (position,
heading, barometric pressure — for Android / Windows hosts that read their
own hardware and push it in), AIS target details, GMDSS forecasts, the NMEA
2000 device inventory with an ISO Request roll call, and autopilot /
windlass commands — so non-Swift hosts (C# via P/Invoke, Python via
ctypes…) reuse the same decoding, transports and commands instead of
reimplementing them. Build it with `swift build -c release` from `Bridge/`
(on Windows, pass the CCurl include/lib flags as for the CLI); every
returned string is a caller-owned UTF-8 buffer released with
`boattools_bridge_string_free`.

## Install

Download pre-built binaries for **macOS, Windows and Linux** from the
**[GitHub releases page](https://github.com/auvents-brave/BoatTools/releases)** —
it carries both the latest stable release and a rolling pre-release.

The macOS package is signed and **notarised by Apple**, so it installs without
any Gatekeeper warning, dropping `boattools` into `/usr/local/bin`. It is fully
self-contained — no extra runtime to install.

## Requirements

### 1. Swift Runtime

#### Linux (Ubuntu / Debian)

Install a Swift toolchain with `swiftly`, the official installer:

```bash
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
```

#### Windows

```powershell
winget install --id Swift.Toolchain -e
```

### 2. Additional Requirements

#### Linux (Ubuntu / Debian)

The `discover` feature relies on the **Avahi compatibility library** for Bonjour/mDNS. It is not required if you do not plan to use the `discover` feature.

```bash
sudo apt-get install -y libavahi-compat-libdnssd1
```

#### Windows

The Windows application relies on the `Microsoft.VCRedist` package. It is generally already installed on most PCs. Running the command below is harmless if it is already present.

```powershell
winget install --id Microsoft.VCRedist.2015+.x64 -e
```

The pre-built **Linux** and **Windows** binaries link the Swift runtime (they are not self-contained), so the target machine installs the Swift runtime, macOS has no such requirement.

### Build from source

```
make build      # debug build
make release    # optimised build
make run        # build and run boattools
make test       # run the test suite
```

Build through `make` rather than `swift build` directly: the `version` target
regenerates the embedded version string (`Sources/BoatTools/Version.generated.swift`,
git-ignored) from `git describe`, so `boattools --version` stays accurate. A bare
`swift build` still works, but the version is only refreshed when you run `make`.

## Platform networking

All socket-level code lives behind four
platform-neutral protocols (`TCPTransport`, `UDPTransport`, `HTTPTransport`,
`WebSocketTransport`) selected at compile time through `NetworkStack`:

| | Apple / Linux | Windows |
|---|---|---|
| TCP | SwiftNIO (`ClientBootstrap`) | libcurl (`CONNECT_ONLY=1`, `curl_easy_send`/`recv`) |
| UDP (broadcast + multicast) | SwiftNIO (`DatagramBootstrap`) | Winsock (`recvfrom`, `IP_ADD_MEMBERSHIP`) |
| HTTP(S) | AsyncHTTPClient | libcurl easy interface (Schannel TLS) |
| WebSocket | WebSocketKit | libcurl (`CONNECT_ONLY=2`, `curl_ws_send`/`recv`) |

### Building on Windows

The Windows build links libcurl **statically** through the `CCurl`
system-library target, so `boattools.exe` ships no libcurl/zlib DLLs (the Swift
runtime DLLs remain a separate dependency — see [Runtime
requirements](#runtime-requirements)). Install libcurl with [vcpkg](https://vcpkg.io)
using the static triplet (`-md` = dynamic C runtime, matching the Swift
runtime); the **`websockets` feature is required** (WebSocket support is
enabled by default in curl ≥ 8.11 but vcpkg still gates it behind a feature
flag):

```
vcpkg install curl[websockets]:x64-windows-static-md
```

Then point the compiler and linker at the vcpkg tree, e.g.:

```
swift build -Xcc -I%VCPKG_ROOT%\installed\x64-windows-static-md\include ^
            -Xlinker /LIBPATH:%VCPKG_ROOT%\installed\x64-windows-static-md\lib
```

(That is exactly what the Windows CI workflow does — see
[`.github/workflows/windows.yml`](.github/workflows/windows.yml), which also
verifies that the produced executable imports no curl/zlib DLL.)

## Swift 6 strict concurrency highlights

- All public types are **Sendable** (`BoatMetric`, `NMEAFrame`, `JSONValue`, configs, errors).
- Signal K snapshots are typed `JSONValue` (a `Sendable` enum) rather than `[String: Any]`.
- `SignalKClient`: `final class Sendable`, mutable token managed by an internal `actor TokenStore`. Authentication via bearer token or username / password.
- `VictronVRMClient`: `final class Sendable`, no mutable state.
- `NMEATransport`: `struct Sendable`. State (LineAggregator, FrameDispatcher, the assemblers) is **confined to the single task that consumes the byte stream** — no manual lock and no `@unchecked Sendable`.
- `NMEASession`: `final class @unchecked Sendable` — the outbound path (the device directory, the resolved wire format, the fast-packet sequence counter) is reachable from both the consuming task and any caller of `send(_:)`, so every mutable member is confined behind an `NSLock` instead of task confinement; justified in a comment at the declaration site, per the project's `@unchecked Sendable` convention.
- Explicit lifecycle: async `shutdown()`, no magic deinit.
- Upcoming features enabled: `ExistentialAny`, `InternalImportsByDefault`.
- Diagnostic frames: every transport emits `.invalidChecksum(rawLine:)` for bad-XOR NMEA sentences and `.unknown(rawLine:)` for unparseable lines / non-conforming Signal K JSON. The CLI prints them in red / orange when stdout is a TTY.


## Library API

The reusable surface of `BoatToolsKit`, grouped logically. Decoders, fast-packet
assemblers and other parsing internals are kept internal — consumers feed raw
frames to the clients and the metric store and let them dispatch.

**Models** — value types emitted by clients and the metric store.
- `BoatMetric` — canonical numeric metric (name, value, unit, timestamp).
- `NMEAFrame` — tagged-union of decoded frame variants (`.nmea0183`, `.nmea2000`, `.metric`, `.aisTarget`, `.gsvReport`, `.invalidChecksum`, `.unknown`).
- `AISTarget` — decoded AIS position / static report.
- `SatelliteInfo` — single satellite from a GSV / sats-in-view report.
- `Country` — MID-derived flag for an AIS MMSI.
- `JSONValue` — `Sendable` JSON tree returned by Signal K REST snapshots.
- `FileFrame` — frame + optional embedded timestamp, emitted by file replay.
- `ReplayPacing` — how a recorded log is replayed: honour the file's own timestamps, or emit at a fixed number of lines per second.
- `BoatCloudError` — transport / parsing failure.
- `CommandError` — an autopilot / windlass order could not be sent: `.noAutopilot`, `.unsupportedAutopilot(_:)` (an identified brand with no implemented dialect), `.unsupportedCommand(_:dialect:)` (a dialect gap, e.g. no absolute locked heading).
- NMEA enums: `TalkerId`, `MessageId`, `AisMessageType`, `NavigationStatus`, `ManeuverIndicator`, `ShipType`, `NavigationalAidType`.

**Metric store** — observable aggregation of resolved metrics. See [`METRIC_STORE.md`](METRIC_STORE.md).
- `BoatMetricStore` — `@Observable @MainActor` store; feed it `NMEAFrame` or `BoatMetric` values via `feed(_:)`, `feedSignalK(_:)`, `feedMetric(_:)`, `feedMetrics(_:)`, or the async-stream piping helpers `pipe(_:)` / `pipeSignalK(_:)` / `pipeMetrics(_:)`. AIS exposes `aisTargets`, `ownShip` (own MMSI excluded from targets) and `isStale(_:)`. `labels` / `setLabels(_:)` carry human display names for metric prefixes (e.g. `battery.0` → "Lynx 24"). `clear()` / `clearAIS()` reset published state when switching source or disconnecting — `clear()` also resets the pending one-second window so stale frames cannot resurface on the next tick.
- `ConnectionMultiplexer` — `@Observable @MainActor`; feeds several live sources into one `BoatMetricStore` at once for a "listen to everything" mode, owning one task per source, tracking each source's liveness (`SourceState`: `.connecting` / `.ended` / `.failed`) and tearing them all down together.
- `TimedSample`, `RingBuffer<T>`, `TieredHistory`, `PressureHistory` — history primitives backing the store's `windTWS`, `sog`, `pressure`, etc.

**Clients** — talk to live data sources.
- `SignalKClient` — REST snapshots (`snapshot(...)`), WebSocket live stream (`liveStream(...)`), and raw NDJSON delta streams over TCP / UDP (`tcpStream(...)`, `udpStream(...)`), with token- or password-based auth (`login(...)`).
- `VictronVRMClient` — VRM Portal HTTP API: `installations()`, `diagnostics(siteId:)`, and `metrics(siteId:)` mapped onto canonical metric names nested under per-device prefixes (`battery.0.`, `solar.1.`, `tank.`, `vebus.`, `system.`). `labels(...)` fetches the installation's custom device names; `frameStream(...)` polls continuously, or takes a single snapshot when the interval is zero. `DiagnosticRecord` exposes `device`, `instance` and a `unit` stripped of its printf format.
- `GMDSSForecastService` — official GMDSS high-seas text forecasts from the WMO WWMIWS service: `forecast(metarea:)` for a whole METAREA (1–21), or `forecast(latitude:longitude:)` which resolves the position to its METAREA and keeps the matching directional sub-bulletin. The transport is injectable (`URLSession` by default); `GMDSSForecast` / `GMDSSBulletin` carry the title, issue time, sub-area label and body text. The position resolution and sub-bulletin split are also exposed standalone — `metarea(latitude:longitude:)` and `bulletins(_:coveringLatitude:longitude:in:)` — for callers holding an already-fetched (e.g. logged) bulletin set.
- `NMEASimulator` — generates a synthetic NMEA 2000 passage as an `NMEAFrame` stream (`frameStream(route:speedKnots:timeMultiplier:loop:)`): position, COG/SOG, heading, wind, depth and AIS, along a `SimulatorRoute` (`SimulatorRoute.presets`, e.g. `.monacoToMaddalena`). `historyBackfill(...)` seeds the store with a plausible past so charts are not empty on connect. `session(route:speedKnots:timeMultiplier:updateInterval:loop:)` returns a full `NMEASession` instead: the same passage plus a simulated NMEA 2000 network — a Raymarine Evolution autopilot and two windlasses — that answers the ISO Request roll call, broadcasts its status and obeys the commands sent back on the session, so a pilot/windlass remote control can be exercised with no boat attached.
- Each client also offers `static` stream factories (`SignalKClient.liveStream(config:)` / `.tcpStream(...)` / `.udpStream(...)`, `VictronVRMClient.frameStream(accessToken:siteId:...)`) that manage the underlying transport internally, so callers can pipe them straight into the store without touching the networking stack.

**Transport** — NMEA over TCP / UDP / file.
- `NMEATransport` — opens a TCP or UDP socket, demultiplexes lines, runs the multipart / fast-packet / GSV assemblers, emits `NMEAFrame` values. `session(config:)` returns an `NMEASession` instead of a bare stream when the outbound path is wanted too.
- `NMEASession` — a live connection: the inbound `frames` stream plus, on TCP, transmission onto the network. `send(_:)` encodes an `OutboundMessage` in the connection's wire format; `isTransmitCapable` tells whether the connection can speak at all; `devices()` / `device(at:)` expose the connection's own device directory; `interrogateDevices(destination:)` broadcasts the ISO Request roll call.
- `OutboundMessage` — a protocol-neutral message to transmit (an autopilot command, a windlass order, an ISO request): `.nmea0183(body:)` gains its `$` and checksum, `.nmea2000(pgn:destination:priority:data:)` is encoded per gateway envelope — RAW frames with fast-packet fragmentation, iKonvert `!PDGY`, SeaSmart `$PCDIN`. Receive-only formats (Signal K, Canboat PLAIN, UDP listeners) refuse to transmit.
- `ConnectionMultiplexer.send(_:toDeviceAt:)` — routes an outbound message in "listen to everything" mode: to the session(s) that heard the target source address when known, otherwise to every transmit-capable session.
- `NMEA2000Commands` — command builders for the devices a sailor drives. `autopilot(in:)` identifies the pilot (ISO class 40 / function 150) and selects its dialect from the manufacturer code (`AutopilotBrand`); `messages(for:brand:destination:)` encodes an `AutopilotCommand` (standby / engage / wind-vane / track / ±N° / locked heading). Implemented dialects: **Raymarine Evolution** (126208 writes of 65379 and 65360, SeaTalk 126720 keystrokes), **Navico** — Simrad NAC-2/NAC-3, B&G — (Simnet AP command, PGN 130850, canboat layout) and **Garmin Reactor** (proprietary 126720, community reverse-engineering, alpha); Furuno and unknown brands are named but refused. `seatalkSentences(for:)` carries the same orders as Seatalk 1 keystrokes (`$STALK,86,11,…`) for Raymarine pilots behind an NMEA 0183 converter — `NMEASession.send(_: AutopilotCommand)` picks them automatically on an 0183 connection. `message(for:windlassID:destination:)` builds the **standard** windlass order (a 126208 command of PGN 128776) — `WindlassCommand`: up / down / off; NMEA 2000 only (0183 has no windlass sentence, Signal K no standard control path).
- `SignalKClient.put(path:value:)` / `.autopilot(_:)` — commands through a Signal K server: the `steering.autopilot` PUT paths of the server's autopilot API (state, target heading, adjust), relayed to the pilot by the server's own plugin.
- `NMEATransportMode`, `NMEAInputFormat` — configuration enums.
- `NMEA2000DeviceDirectory` / `NMEA2000Device` — inventory of the devices on the NMEA 2000 network, accumulated from the device-information PGNs (60928 address claims, 126996 product information, 126998 configuration information, 126464 PGN lists, 126993 heartbeats): manufacturer, model, serial, versions, class / function, instances, load equivalency, PGN lists, last seen. `interrogationLines(destination:)` yields the ISO Requests (YD RAW transmit format) that make every device announce itself.
- `ConnectionOwnershipManager` — AppGroup-backed primary / secondary election so several processes (e.g. main app + widget) can share one upstream connection.

**Device sensors** — the phone/laptop's own GPS, compass and barometer, as a fallback when the boat's network has nothing.
- `DeviceSensors` — Apple-only (CoreLocation + CoreMotion), emitting `BoatMetric` for `lat`, `lon`, `SOG`, `COG`, `HDG.*`, `pressure.atmospheric`.
- `DeviceSensorsConfig` — sensor-selection and accuracy knobs (`DeviceSensors`).
- `DeviceFallback` (with `DeviceFallback.Config`) — Apple-only; watches the store and starts `DeviceSensors` only while a given metric (position, heading, pressure) is missing or stale, automatically standing down when network data returns.
- `ExternalSensorFeed` — the Android / Windows equivalent: Swift cannot read those platforms' hardware directly, so the **host** reads its own GPS/compass/barometer APIs and pushes readings in — `pushLocation(latitude:longitude:altitudeMetres:speedMetresPerSecond:courseDegrees:timestamp:)`, `pushHeading(magneticDegrees:trueDegrees:timestamp:)` (also derives `magneticVariation` when both headings are given), `pushPressure(hectopascals:timestamp:)` — turning them into the exact same canonical metrics `DeviceSensors` emits, so downstream code stays platform-blind. Thread-safe (push from any thread); `stream()` yields the canonical `BoatMetric`s. This is what the bridge's `boattools_bridge_open_device_feed` / `_push_location` / `_push_heading` / `_push_pressure` wrap for non-Swift hosts (e.g. ThoosaUno's C# `DeviceSensorsService` on Android and Windows).

**Parsing** — most parsers are internal. The one exposed type:
- `NMEA0183Parser` — stateless sentence parser used by the CLI to filter decoded vs unknown sentence types. NMEA 2000, AIS, SeaSmart, Canboat, iKonvert and YD RAW decoders are reached indirectly through `NMEATransport`. Full decoder coverage in [`DECODERS.md`](DECODERS.md).

## Metric store design

How decoded values are normalised, prioritised across talkers, deduplicated and persisted in the metric store. Full document: [`METRIC_STORE.md`](METRIC_STORE.md).

- [BoatTools — Metric Store Design](METRIC_STORE.md)
  - [Architecture overview](METRIC_STORE.md#architecture-overview)
  - [Priority tables](METRIC_STORE.md#priority-tables)
  - [Non-numeric data](METRIC_STORE.md#non-numeric-data)
  - [Complete `metrics` dictionary coverage](METRIC_STORE.md#complete-metrics-dictionary-coverage)
  - [Multi-talker conflict resolution](METRIC_STORE.md#multi-talker-conflict-resolution)
  - [Angle averaging (circular mean)](METRIC_STORE.md#angle-averaging-circular-mean)
  - [Historical data](METRIC_STORE.md#historical-data)
  - [AppGroup / widget sharing (Darwin only)](METRIC_STORE.md#appgroup--widget-sharing-darwin-only)
  - [Implementation status](METRIC_STORE.md#implementation-status)

## Decoder coverage

Which NMEA 0183 sentences, NMEA 2000 PGNs and Signal K paths `BoatToolsKit` decodes, indexed by canonical metric. Full reference: [`DECODERS.md`](DECODERS.md).

- [BoatTools — Decoder Coverage](DECODERS.md)
  - [NMEA 0183](DECODERS.md#nmea-0183)
  - [NMEA 2000](DECODERS.md#nmea-2000)
  - [Signal K](DECODERS.md#signal-k)
  - [Index by canonical metric](DECODERS.md#index-by-canonical-metric)
  - [Transmitted frames (outbound)](DECODERS.md#transmitted-frames-outbound) — the pilot / windlass / roll-call frames the library sends

## Commands

```
boattools connect    — all transports: TCP, UDP broadcast/multicast, Signal K web
boattools devices    — inventory the devices present on the NMEA 2000 network
boattools pilot      — send an order to the autopilot (brand dialect auto-selected)
boattools windlass   — drive the anchor windlass (standard NMEA 2000 order)
boattools file       — read and parse a local log file
boattools vrm        — Victron VRM cloud
boattools discover   — LAN discovery via Bonjour/mDNS
boattools gmdss      — official GMDSS high-seas forecasts (WMO WWMIWS)
boattools simulate   — replay a synthetic NMEA 2000 passage
boattools --version  — print the version string
```

## Examples
    
**`connect`**
- [NMEA over TCP — connect to a gateway / MFD](#nmea-over-tcp--connect-to-a-gateway--mfd)
- [NMEA over TCP — with explicit duration](#nmea-over-tcp--with-explicit-duration)
- [Signal K NDJSON over TCP](#signal-k-ndjson-over-tcp)
- [NMEA over UDP — broadcast](#nmea-over-udp--broadcast)
- [NMEA over UDP — multicast](#nmea-over-udp--multicast)
- [Signal K WebSocket stream — auto-detected from `ws://`](#signal-k-websocket-stream--auto-detected-from-ws)
- [Signal K WebSocket stream — forced from an `http://` URL](#signal-k-websocket-stream--forced-from-an-http-url)
- [Signal K snapshot (HTTP GET, one-shot)](#signal-k-snapshot-http-get-one-shot)
- [Signal K snapshot polled every 5s for one minute](#signal-k-snapshot-polled-every-5s-for-one-minute)
- [Signal K snapshot polled every 30s forever (Ctrl-C to stop)](#signal-k-snapshot-polled-every-30s-forever-ctrl-c-to-stop)
- [Signal K via Victron's authenticated relay](#signal-k-via-victrons-authenticated-relay)
- [Capture a live session to a log file](#capture-a-live-session-to-a-log-file)

**`devices`**
- [Inventory the NMEA 2000 network](#inventory-the-nmea-2000-network)

**`file`**
- [Read a local log file — dump as fast as possible](#read-a-local-log-file--dump-as-fast-as-possible)
- [Read a log file at a fixed rate](#read-a-log-file-at-a-fixed-rate)
- [Replay a log file at the original recorded pace](#replay-a-log-file-at-the-original-recorded-pace)

**`vrm`**
- [Victron VRM — list installations attached to my user](#victron-vrm--list-installations-attached-to-my-user)
- [Victron VRM — diagnostics of a single site (one-shot)](#victron-vrm--diagnostics-of-a-single-site-one-shot)
- [Victron VRM — monitor a site every 60s for 10 minutes](#victron-vrm--monitor-a-site-every-60s-for-10-minutes)
- [Victron VRM — monitor a site every 5 min forever](#victron-vrm--monitor-a-site-every-5-min-forever)

**`discover`**
- [LAN discovery via Bonjour — interactive menu, then connect](#lan-discovery-via-bonjour--interactive-menu-then-connect)
- [LAN discovery — list only, no prompt (scripting / piping)](#lan-discovery--list-only-no-prompt-scripting--piping)
- [LAN discovery — longer scan window](#lan-discovery--longer-scan-window)

**`gmdss`**
- [GMDSS forecast — a whole METAREA](#gmdss-forecast--a-whole-metarea)
- [GMDSS forecast — only the sub-area for a position](#gmdss-forecast--only-the-sub-area-for-a-position)

**`simulate`**
- [Simulate a synthetic NMEA 2000 passage](#simulate-a-synthetic-nmea-2000-passage)

### NMEA over TCP — connect to a gateway / MFD

```sh
# Classic syntax
./boattools connect --host 10.0.0.50 --port 10110

# URL syntax
./boattools connect --url tcp://10.0.0.50:10110
```

### NMEA over TCP — with explicit duration

```sh
./boattools connect --host 10.0.0.50 --port 10110 --duration 10
./boattools connect --url tcp://10.0.0.50:10110 --duration 10
```

### Signal K NDJSON over TCP

```sh
./boattools connect --host 10.0.0.50 --port 8375 --format signalk
./boattools connect --url tcp://10.0.0.50:8375 --format signalk
```

### NMEA over UDP — broadcast

```sh
# Classic syntax
./boattools connect --port 10110

# URL syntax
./boattools connect --url udp://:10110
```

### NMEA over UDP — multicast

```sh
# Classic syntax
./boattools connect --port 10110 --multicast 239.0.0.1

# URL syntax
./boattools connect --url udp://239.0.0.1:10110
```

### Signal K WebSocket stream — auto-detected from `ws://`

```sh
./boattools connect --url ws://10.0.0.50:3000
```

### Signal K WebSocket stream — forced from an `http://` URL

```sh
./boattools connect --url http://10.0.0.50:3000 --live
```

### Signal K snapshot (HTTP GET, one-shot)

```sh
./boattools connect --url http://10.0.0.50:3000
```

### Signal K snapshot polled every 5s for one minute

```sh
./boattools connect --url http://10.0.0.50:3000 --watch 5 --duration 60
```

### Signal K snapshot polled every 30s forever (Ctrl-C to stop)

```sh
./boattools connect --url http://10.0.0.50:3000 --watch 30
```

### Signal K via Victron's authenticated relay

```sh
./boattools connect --url https://654321-signalk.proxyrelay9.victronenergy.com/ --username test --password test
```

### Capture a live session to a log file

```sh
# Capture a WebSocket stream for 1 hour
./boattools connect --url ws://10.0.0.50:3000 --log ~/session.log --duration 3600

# Capture NMEA over TCP, no time limit (Ctrl-C to stop)
./boattools connect --host 10.0.0.50 --port 10110 --log ~/nmea.log
```

Raw lines are written as received — NMEA sentences, Signal K NDJSON deltas, YD RAW hex.
The file can be replayed immediately with `file`.

Bare YD RAW frames carry no timestamp, so on capture they are written with a
`<HH:mm:ss.SSS> R` prefix — this lets `file --realtime` replay the capture at the
original pace. Other formats already embed a timestamp (or carry their own
framing) and are written verbatim.

---

### Inventory the NMEA 2000 network

```sh
# TCP RAW gateway — broadcasts an ISO Request first, so every device answers
./boattools devices --host 10.0.0.50 --port 1457

# UDP broadcast — purely passive (devices are heard as they announce themselves)
./boattools devices --port 2000 --format ydraw --duration 30
```

Collects the device-information PGNs — 60928 address claims, 126996 product
information, 126998 configuration information, 126464 PGN lists, 126993
heartbeats — and prints one block per device: manufacturer, model, serial,
software version, class / function, instances, certification, load
equivalency, transmitted and received PGNs.

```
━━ @035  GPS 24xd — Garmin ━━
  kind           Navigation · Ownship Position (GNSS)
  instances      device 0 · system 0
  unique number  123456
  NAME           0xC27891051CA1E240 · self-addressing
  product code   9876
  software       2.60
  serial         SN-0042
  transmits      126992, 129025, 129026, 129029, 129539, 129540
  heartbeat      every 60.0 s
  last seen      14:07:12
```

On UDP (receive-only) the command stays passive; use `--no-request` to force
the same on TCP. Signal K web sources do not relay these PGNs — point the
command at the gateway itself.

---

### Drive the autopilot and the windlass

```sh
# Identify the pilot (ISO class 40 / function 150), speak its dialect
./boattools pilot auto --host 10.0.0.50 --port 1457
./boattools pilot -- -10 --host 10.0.0.50 --port 1457     # 10° to port
./boattools pilot heading 235 --host 10.0.0.50 --port 1457
./boattools pilot standby --host 10.0.0.50 --port 1457

# The standard NMEA 2000 windlass order (a command of PGN 128776)
./boattools windlass up --host 10.0.0.50 --port 1457
./boattools windlass off --host 10.0.0.50 --port 1457
```

The pilot command first broadcasts the ISO Request roll call, waits for the
autopilot's address claim, then encodes the order in the brand's dialect.

Two more transports carry the same orders:

```sh
# Raymarine behind a Seatalk 1 ⇄ NMEA 0183 converter — $STALK keystrokes
./boattools pilot standby --host 10.0.0.51 --port 10110 --format nmea0183

# Through a Signal K server's autopilot API (server-side plugin required)
./boattools pilot auto --url http://10.0.0.60:3000 --token XYZ
```

#### Autopilot support matrix

| Pilot | Protocol | Frames | standby / auto / wind | track | ±N° | heading D | Status |
|---|---|---|---|---|---|---|---|
| Raymarine Evolution (EV-1/EV-2) | NMEA 2000 | 126208 writes of 65379 / 65360, SeaTalk keystrokes on 126720 | ✓ | ✓ | ✓ | ✓ | community sequences, not yet hardware-validated |
| Raymarine Seatalk 1 (ST1000+, ST4000+, …) | NMEA 0183 via a Seatalk converter | `$STALK,86,11,…` keystrokes | ✓ | ✓ | ✓ | — | keystroke codes per the Seatalk reference |
| Navico — Simrad NAC-2/NAC-3, B&G, Lowrance | NMEA 2000 | Simnet AP command, PGN 130850 | ✓ | ✓ | ✓ | — | canboat layout, proven on NAC-3 by the Signal K plugin |
| Garmin Reactor | NMEA 2000 | proprietary 126720 | ✓ (no track) | — | ✓ (±15°/±1° steps) | — | **alpha** — community reverse-engineering |
| Any pilot behind a Signal K server | Signal K | PUT `steering.autopilot.*` | ✓ | ✓ | ✓ | ✓ | needs the server's autopilot plugin |
| **Furuno NavPilot** | — | — | — | — | — | — | **not supported** — no public dialect; identified and refused by name |
| Other / unknown brands | — | — | — | — | — | — | **not supported** — identified and refused by name |

“—” inside a supported row means the dialect itself cannot express that
order (the library refuses with the command and dialect names rather than
sending a guess).

#### Windlass support matrix

| Protocol | Frames | up / down / off | Notes |
|---|---|---|---|
| NMEA 2000 | 126208 command of PGN 128776 (direction control) | ✓ | the **standard** order — brand-independent (Lewmar, Maxwell, Quick…), addressed to the windlass heard on the bus or broadcast, `--windlass` selects the unit |
| NMEA 0183 | — | — | **not supported** — the standard defines no windlass sentence |
| Signal K | — | — | **not supported** — no standard control path in the specification |

---

### Read a local log file — dump as fast as possible

```sh
./boattools file /path/to/log.nmea
./boattools file /path/to/signalk.ndjson
```

Auto-detects the format from the content: NMEA 0183, YD RAW (bare or with a
`<timestamp> R/T` logging prefix), SeaSmart (`$PCDIN`), Signal K NDJSON,
Canboat PLAIN CSV, and Digital Yacht iKonvert (`!PDGY`, Base64 N2K).
Override with `--format nmea0183|ydraw|seasmart|signalk|canboat|ikonvert` if needed.

### Read a log file at a fixed rate

```sh
# 10 frames per second
./boattools file /path/to/log.nmea --rate 10

# 1 frame per second
./boattools file /path/to/log.nmea --rate 1
```

### Replay a log file at the original recorded pace

```sh
./boattools file /path/to/signalk.ndjson --realtime
./boattools file /path/to/log.nmea --realtime
```

Timestamps are extracted from the data itself:
- **Signal K NDJSON**: `updates[].timestamp` field (ISO 8601)
- **NMEA 0183**: date + time from `RMC` sentences (DDMMYY + HHMMSS)
- **Canboat PLAIN**: the leading ISO 8601 timestamp column
- **YD RAW**: the `<time> R/T` logging-prefix time (time of day only — replay
  uses the interval between successive lines, so a capture that does not cross
  midnight replays at the right pace)

Lines with no recognisable timestamp are emitted immediately in sequence.
`--realtime` and `--rate` are mutually exclusive.

---

### Victron VRM — list installations attached to my user

```sh
./boattools vrm --user-id 123456 --token 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff
```

### Victron VRM — diagnostics of a single site (one-shot)

```sh
./boattools vrm --user-id 123456 --token 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff --site-id 654321
```

### Victron VRM — monitor a site every 60s for 10 minutes

```sh
./boattools vrm --user-id 123456 --token 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff --site-id 654321 --watch 60 --duration 600
```

### Victron VRM — monitor a site every 5 min forever

```sh
./boattools vrm --user-id 123456 --token 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff --site-id 654321 --watch 300
```

### LAN discovery via Bonjour — interactive menu, then connect

`discover` browses several service types:

- **Standards**: `_signalk-http._tcp`, `_signalk-ws._tcp`, `_nmea-0183._tcp`
- **Vendor-specific (best-effort, unverified)**: `_garmin-marine._tcp`,
  `_navico-mfd._tcp`, `_raymarine-net._tcp`, `_furuno-navnet._tcp`

On selection, every endpoint is dispatched via `connect --url <scheme://host:port>`:
Signal K → `ws://` or `http://`, NMEA / vendor → `tcp://`. Vendor protocols are
often proprietary binary — you'll likely see orange `unknown:` lines, but at
least the TCP connection works.

```sh
./boattools discover
```

### LAN discovery — list only, no prompt (scripting / piping)

```sh
./boattools discover --no-interactive
```

### LAN discovery — longer scan window

```sh
./boattools discover --timeout 10
```

### GMDSS forecast — a whole METAREA

Prints every bulletin issued for the METAREA (1–21). METAREA 3 (the
Mediterranean & Black Sea) carries two: a `WEST` bulletin from Météo-France and
an `EAST` one from the Hellenic service.

```sh
./boattools gmdss --metarea 3
```

### GMDSS forecast — only the sub-area for a position

Resolves the position to its METAREA and prints only the matching sub-area
bulletin. Off Sicily, that is the western-Mediterranean (Météo-France) text.

```sh
./boattools gmdss --lat 37.1 --lon 14.1
```

The data is the official GMDSS high-seas text, fetched from the WMO Worldwide
Met-ocean Information and Warning Service (WWMIWS).

### Simulate a synthetic NMEA 2000 passage

Streams a realistic NMEA 2000 passage (position, COG/SOG, heading, wind, depth,
AIS…) from the built-in simulator — handy for exercising downstream tools with
no hardware. `--fast` speeds up the *movement* only; the reported SOG stays
realistic.

```sh
./boattools simulate --list                       # available routes
./boattools simulate                              # Monaco → La Maddalena at 6 kn
./boattools simulate --speed 8 --fast 50          # faster passage, fast-forwarded
```
