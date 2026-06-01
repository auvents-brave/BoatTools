# BoatTools

Swift CLI tools to explore sailboat data sources, in **strict concurrency mode**.

The package ships two products:

- **`BoatToolsKit`** — library, multiplatform. All the business logic: NMEA / Signal K / Victron VRM clients, parsers, Bonjour discovery, Apple device sensors.
- **`boattools`** — executable, ArgumentParser-based CLI on top of the library. Four subcommands: `connect`, `file`, `vrm`, `discover`. The Apple device sensors are a `BoatToolsKit` feature only — they are not exposed by the CLI.

## Install

Pre-built binaries are attached to every [release](https://github.com/auvents-brave/BoatTools/releases):

- **macOS** (Apple Silicon + Intel) — [`boattools-macos-universal.pkg`](https://github.com/auvents-brave/BoatTools/releases/latest/download/boattools-macos-universal.pkg): installs `boattools` into `/usr/local/bin`. BoatTools is signed and **notarised by Apple**, so it installs without any Gatekeeper warning. 
- **Linux** (x86_64) — [`boattools-linux-x86_64.tar.gz`](https://github.com/auvents-brave/BoatTools/releases/latest/download/boattools-linux-x86_64.tar.gz). `discover` on Linux needs the Avahi compatibility library (`libavahi-compat-libdnssd-dev`).

## Swift 6.3 strict concurrency highlights

- All public types are **Sendable** (`BoatMetric`, `NMEAFrame`, `JSONValue`, configs, errors).
- Signal K snapshots are typed `JSONValue` (a `Sendable` enum) rather than `[String: Any]`.
- `SignalKClient`: `final class @unchecked Sendable`, mutable token managed by an internal `actor TokenStore`. Authentication via bearer token or username / password.
- `VictronVRMClient`: `final class @unchecked Sendable`, no mutable state.
- `NMEATransport`: `struct Sendable`. State (LineAggregator, FrameDispatcher, NIO handlers) is **confined to the NIO event loop** — no manual lock, marked `@unchecked Sendable` because isolation is guaranteed by the NIO pipeline.
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
- `BoatCloudError` — transport / parsing failure.
- NMEA enums: `TalkerId`, `MessageId`, `AisMessageType`, `NavigationStatus`, `ManeuverIndicator`, `ShipType`, `NavigationalAidType`.

**Metric store** — observable aggregation of resolved metrics. See [`METRIC_STORE.md`](METRIC_STORE.md).
- `BoatMetricStore` — `@Observable @MainActor` store; feed it `NMEAFrame` or `BoatMetric` values via `feed(_:)`, `feedSignalK(_:)`, `feedMetric(_:)`, `feedMetrics(_:)`, or the async-stream piping helpers `pipe(_:)` / `pipeSignalK(_:)` / `pipeMetrics(_:)`.
- `TimedSample`, `RingBuffer<T>`, `TieredHistory`, `PressureHistory` — history primitives backing the store's `windTWS`, `sog`, `pressure`, etc.

**Clients** — talk to live data sources.
- `SignalKClient` — REST snapshots (`snapshot(...)`), WebSocket live stream (`liveStream(...)`), TCP / UDP delta streams (`frameStream(...)`), token-based auth (`login(...)`).
- `VictronVRMClient` — VRM Portal HTTP API: `installations()`, `diagnostics(siteId:)`, `metrics(siteId:)`.

**Transport** — NMEA over TCP / UDP / file.
- `NMEATransport` — opens a TCP or UDP socket, demultiplexes lines, runs the multipart / fast-packet / GSV assemblers, emits `NMEAFrame` values.
- `NMEATransportMode`, `NMEAInputFormat` — configuration enums.
- `ConnectionOwnershipManager` — AppGroup-backed primary / secondary election so several processes (e.g. main app + widget) can share one upstream connection.

**Device sensors** — Apple-only fallback.
- `DeviceSensors` — CoreLocation + CoreMotion bridge, emitting `BoatMetric` for `lat`, `lon`, `SOG`, `COG`, `HDG.*`, `pressure.atmospheric`.
- `DeviceSensorsConfig` — sensor-selection and accuracy knobs.

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

## Commands

```
boattools connect    — all transports: TCP, UDP broadcast/multicast, Signal K web
boattools file       — read and parse a local log file
boattools vrm        — Victron VRM cloud
boattools discover   — LAN discovery via Bonjour/mDNS
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
