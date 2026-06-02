# BoatTools — Metric Store Design

Central store (`BoatMetricStore`) that aggregates, deduplicates and exposes **all** live marine data to SwiftUI apps and widgets. Covers every data type produced by BoatToolsKit: numeric metrics, AIS targets, satellite reports, and time-series histories for trending metrics.

---

## Architecture overview

```
NMEATransport / SignalKClient
        │
        │  NMEAFrame stream  (metric, aisTarget, gsvReport, nmea0183, nmea2000, …)
        ▼
  FrameCollector          ← accumulates all frames for one 1-second window
        │
        │  flush() every 1 s
        ▼
  PriorityResolver        ← applies per-metric priority rules (see tables below)
        │
        │  FlushResult { metrics, aisTargets, satelliteReports }
        ▼
  BoatMetricStore                   ← @Observable, one instance per app
    ├── metrics: [String: BoatMetric]       ← all numeric values, always best known
    ├── aisTargets: [Int: AISTarget]         ← keyed by MMSI, updated on every report
    ├── satellites: [String: [SatelliteInfo]] ← keyed by constellation name
    ├── WindHistory                          ← two-tier ring buffer (5 s / 1 min samples)
    ├── NavHistory (SOG, COG, depth, temp.water)  ← same two-tier scheme
    └── PressureHistory                      ← single ring buffer (30 min samples, 48 h)
```

### Why a 1-second window?

- A single GPS update often triggers a burst: `RMC`, `GGA`, `VTG`, `GSA`, sometimes `GNS` — all within the same second.
- Some older instruments transmit both `APA` and `APB` for compatibility; we want to see both before deciding.
- Multi-talker conflicts (two GPS sources) need to be resolved on the same data window.

Within the window every received `BoatMetric` is tagged with its **source sentence / PGN / Signal K path**. At flush time the priority resolver picks one value per canonical metric name.

---

## Priority tables

### Principle

Each metric has an ordered list of **source ranks** (1 = highest priority). When multiple sources provide the same canonical metric in the same window, the one with the lowest rank wins. Sources absent from the window are simply skipped; the resolver falls through to the next rank.

Tie-breaking within the same rank (same sentence type, different talkers) is handled by a **secondary rule** specific to the metric group (see below).

---

### 1 — Position (`lat`, `lon`, `altitude`)

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `129029` GNSS Position Data | Full quality metadata (HDOP, PDOP, fix type, geoid separation) |
| 2 | NMEA 0183 `GGA` | Has HDOP + fix quality; widely supported |
| 3 | NMEA 0183 `GNS` | Multi-constellation variant of GGA |
| 4 | PGN `129025` Position Rapid Update | High-frequency but carries no quality data |
| 5 | NMEA 0183 `RMC` | Standard but no quality field |
| 6 | NMEA 0183 `GLL` | Lat/lon only, no quality |
| 7 | Signal K `navigation.position` | Already resolved upstream |

**Tie-break (same rank, multiple talkers):** lowest HDOP wins. Equal HDOP → talker priority `GP > GN > GA > GL > GB > GQ > GI`.

---

### 2 — Speed and course over ground (`SOG`, `COG`)

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `129026` COG & SOG Rapid Update | Dedicated, high rate |
| 2 | NMEA 0183 `VTG` | Dedicated sentence |
| 3 | NMEA 0183 `RMC` | Combined with position, lower confidence |
| 4 | Signal K `navigation.speedOverGround` / `courseOverGroundTrue` | |

**Tie-break:** same talker priority as position.

---

### 3 — Speed through water (`STW`)

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `128259` Speed | Dedicated |
| 2 | NMEA 0183 `VHW` | Dedicated |
| 3 | Signal K `navigation.speedThroughWater` | |

---

### 4 — Heading (`HDG.true`, `HDG.magnetic`)

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `127250` Vessel Heading | Most complete: true + magnetic + deviation + variation |
| 2 | NMEA 0183 `HDT` | True heading, explicit |
| 3 | NMEA 0183 `HDG` | Magnetic + optional deviation/variation |
| 4 | NMEA 0183 `HDM` | Magnetic only |
| 5 | Signal K `navigation.headingTrue` / `headingMagnetic` | |

**Last-resort fallback (COG):** when *no* heading source is available — no
NMEA / NMEA 2000 heading **and** no device compass (the sensor is absent or
denied) — the store derives `HDG.true` from **`COG`** (course over ground).
This keeps a heading available for consumers (e.g. orienting the vessel marker)
when under way. The derived value is refreshed on every flush and is
automatically discarded the moment any real heading source appears, so it never
masks a genuine `HDG.true` / `HDG.magnetic`. It is suppressed while `COG` is
invalid (e.g. stationary), so no spurious heading is published.

**Magnetic variation from the compass:** when the device compass reports both
headings, `DeviceSensors` also publishes `magneticVariation` (declination) as the
signed difference `HDG.true − HDG.magnetic`, normalised to ±180° (positive =
East). A NMEA / NMEA 2000 source carrying variation directly still wins on
priority.

---

### 5 — Rate of turn (`ROT`)

| Rank | Source |
|------|--------|
| 1 | PGN `127251` |
| 2 | NMEA 0183 `ROT` |
| 3 | Signal K `navigation.rateOfTurn` |

---

### 6 — Wind (apparent and true)

Two independent priorities: **apparent** (`AWA`, `AWS`) and **true** (`TWA`/`TWD`, `TWS`).

#### Apparent wind

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `130306` Wind Data (apparent reference) | Dedicated, fast |
| 2 | NMEA 0183 `MWV` (reference = `R`) | Standard apparent |
| 3 | NMEA 0183 `VWR` | Older relative wind |
| 4 | Signal K `environment.wind.angleApparent` / `speedApparent` | |

#### True wind

| Rank | Source | Why |
|------|--------|-----|
| 1 | PGN `130306` Wind Data (true/ground reference) | Dedicated |
| 2 | NMEA 0183 `MWD` | Dedicated true wind direction + speed |
| 3 | NMEA 0183 `MWV` (reference = `T`) | True reference |
| 4 | NMEA 0183 `MDA` | Composite; wind is secondary data here |
| 5 | Signal K `environment.wind.directionTrue` / `speedTrue` | |

---

### 7 — Depth (`depth`)

| Rank | Source |
|------|--------|
| 1 | PGN `128267` Water Depth |
| 2 | NMEA 0183 `DPT` |
| 3 | NMEA 0183 `DBT` |
| 4 | Signal K `environment.depth.*` |

---

### 8 — Autopilot / cross-track error

| Rank | Source | Why |
|------|--------|-----|
| 1 | NMEA 0183 `APB` | Most complete autopilot sentence (XTE + bearings + heading to steer) |
| 2 | NMEA 0183 `APA` | Older form of APB; used only if APB absent |
| 3 | NMEA 0183 `XTE` | XTE only |
| 4 | PGN `129283` Cross Track Error | |
| 5 | Signal K `navigation.courseRhumbline.crossTrackError` | |

This is the clearest example of the **backwards-compatibility pattern**: instruments that support `APB` also emit `APA` for legacy receivers. We always prefer `APB`; `APA` is the silent fallback.

---

### 9 — Navigation / routing

| Rank | Source |
|------|--------|
| 1 | PGN `129284` Navigation Data |
| 2 | NMEA 0183 `APB` |
| 3 | NMEA 0183 `RMB` |
| 4 | NMEA 0183 `BWC` / `BWR` |
| 5 | Signal K `navigation.courseRhumbline.*` |

---

### 10 — Atmosphere / environment

| Metric | Rank 1 | Rank 2 | Rank 3 |
|--------|--------|--------|--------|
| `pressure.atmospheric` | PGN `130310` / `130311` / `130314` | NMEA 0183 `MDA` | Signal K `environment.outside.pressure` |
| `temperature.air` | PGN `130310` / `130311` | NMEA 0183 `MDA` | Signal K `environment.outside.temperature` |
| `temperature.water` | PGN `130310` / `130311` / `130312` | NMEA 0183 `MTW` / `MDA` | Signal K `environment.water.temperature` |
| `humidity` | PGN `130311` | NMEA 0183 `MDA` | Signal K `environment.outside.humidity` |

---

### 11 — Engine, battery, tanks

No conflicts expected (each metric is keyed by instance index). Pass through directly.

---

## Non-numeric data

In addition to `[String: BoatMetric]`, the store holds two structured collections that are updated on every flush.

### AIS targets — `aisTargets: [Int: AISTarget]`

Keyed by MMSI. Every incoming `NMEAFrame.aisTarget` is merged into the dict:
- If the MMSI already exists, static fields (name, callsign, ship type, destination, draught) are preserved when the new report omits them (position reports carry no static data).
- The `timestamp` of the last received report is tracked per target for staleness detection.
- Targets not updated for **10 minutes** are considered stale but kept; the UI can dim them. Targets not updated for **30 minutes** are removed.

### Satellite reports — `satellites: [String: [SatelliteInfo]]`

Keyed by constellation name (`"GPS"`, `"GLONASS"`, `"Galileo"`, `"BeiDou"`, `"QZSS"`, `"NavIC"`, `"GNSS"`). Replaced wholesale on each `NMEAFrame.gsvReport`. Consumers can iterate all constellations or filter to a specific one.

---

## Complete `metrics` dictionary coverage

The `metrics` dict holds **every** `BoatMetric` produced by the priority resolver, which covers:

| Category | Example keys |
|---|---|
| Position | `lat`, `lon`, `altitude` |
| Speed / course | `SOG`, `COG`, `STW`, `ROT` |
| Heading | `HDG.true`, `HDG.magnetic`, `magneticVariation` |
| Wind | `TWS`, `TWD`, `AWS`, `AWA` |
| Depth | `depth`, `depth.offset` |
| Water / atmosphere | `temperature.water`, `temperature.air`, `pressure.atmospheric`, `humidity` |
| GPS quality | `gps.satellites`, `gps.hdop`, `gps.pdop`, `gps.fix`, `gps.quality`, `gps.snr.avg` |
| Engine (per instance) | `engine.0.rpm`, `engine.0.coolantTemperature`, `engine.0.fuelRate`, … |
| Battery (per instance) | `battery.0.voltage`, `battery.0.soc`, … |
| Tanks (per instance) | `fuel.0.level`, `water.0.level`, `blackwater.0.level`, … |
| Autopilot / routing | `navigation.xte`, `navigation.bearingToDest`, `navigation.distanceToWaypoint`, `navigation.vmg` |
| Waypoint | `waypoint.lat`, `waypoint.lon` |
| Log | `log.total`, `log.trip` |
| Time | `utc.timestamp` |
| Alarms | `alarm.0.active`, `alarm.0.acknowledged` |
| DSC | `dsc.mmsi`, `dsc.format` |
| Radar | `radar.rangeScale`, `radar.cursor.range`, `radar.cursor.bearing` |
| Weather station | `weatherStation.lat`, `weatherStation.lon` |
| Power | `power.genset.voltage`, `power.inverter.state`, … |

Every key that appears in `DECODERS.md` can appear in `metrics`. No filtering.

---

## Multi-talker conflict resolution

When the same sentence type arrives from several talkers in the same window:

| Metric group | Tie-break rule |
|---|---|
| Position | Lowest HDOP; equal HDOP → talker priority `GP > GN > GA > GL > GB > GQ > GI` |
| SOG / COG | Same talker priority as position |
| Heading | Only one compass expected; first seen wins |
| Wind | Only one wind instrument expected; first seen wins |
| All others | First seen wins |

---

## Angle averaging (circular mean)

Wind direction (`TWD`, `AWA`) and course (`COG`, `HDG`) are angles; arithmetic averaging wraps incorrectly around 0°/360°. The store uses **circular mean**:

```
mean = atan2(Σ sin(θᵢ), Σ cos(θᵢ))  × 180/π   (mod 360)
```

Applied wherever an angular metric is smoothed into a history sample.

---

## Historical data

### Rationale for two-tier wind/nav history

| Need | Update rate | Retention |
|---|---|---|
| Tactical decisions (last tack, puff timing) | Every 5 s | 1 hour |
| Strategic trend (is the wind backing?) | Every 1 min | 6 hours |

Each tier is a **ring buffer**. The 5-second tier accumulates raw values and flushes a smoothed sample every 5 s. The 1-minute tier accumulates the raw values (not the already-averaged 5 s samples) and flushes every 60 s.

### Wind and navigation histories

| Tier | Sample interval | Smoothing window | Retention | Samples |
|------|----------------|-----------------|-----------|---------|
| Recent | 5 s | last 5 s (raw values) | 1 h | 720 |
| Long | 1 min | last 60 s (raw values) | 6 h | 360 |

**Tracked metrics:**

| Metric | Notes |
|--------|-------|
| `TWS` | True wind speed |
| `TWD` | True wind direction (circular mean) |
| `AWS` | Apparent wind speed |
| `AWA` | Apparent wind angle (circular mean) |
| `SOG` | Speed over ground |
| `COG` | Course over ground (circular mean) |
| `depth` | Water depth |
| `temperature.water` | Water temperature |

> `depth` and `temperature.water` are included: depth trend matters near shoaling water; water temperature matters for current boundaries.

### Pressure history

| Sample interval | Smoothing window | Retention | Samples |
|----------------|-----------------|-----------|---------|
| 30 min | last 30 min (raw values) | 48 h | 96 |

**Tracked metrics:** `pressure.atmospheric` only.

48 hours covers the typical synoptic cycle; 30-minute resolution is sufficient to detect rapid falls (storm warning threshold is ~3 hPa / 3 h = 1.5 hPa per sample).

---

## AppGroup / widget sharing (Darwin only)

Gated with `#if canImport(Darwin)` — covers macOS, iOS, watchOS, tvOS, visionOS, macCatalyst with a single condition. Not compiled on Linux or Windows.

When `BoatMetricStore` is initialised with a non-nil `appGroupID`, it additionally writes a compact JSON snapshot to `UserDefaults(suiteName: appGroupID)` after each flush. The widget reads the same defaults key.

Written keys:

| Defaults key | Content |
|---|---|
| `boattools.metrics` | Flat dict of current metric values (name → Double) |
| `boattools.wind.recent` | Recent wind history (TWS + TWD arrays) |
| `boattools.wind.long` | Long wind history |
| `boattools.pressure` | Pressure history |
| `boattools.nav.recent` | Recent SOG + COG |
| `boattools.updatedAt` | ISO 8601 timestamp of last flush |

---

## Implementation status

Everything described above is implemented in `BoatToolsKit`:

- `BoatMetricStore` (public) holds `metrics`, `aisTargets`, `satellites` and all history accessors.
- `FrameCollector` and `PriorityResolver` (internal) drive the 1-second window and produce a `FlushResult` on each tick.
- `RingBuffer<T>`, `TieredHistory`, `PressureHistory` are public history primitives.
- `BoatMetricStore.isStale(_:)` reports staleness; targets older than 10 minutes are flagged, 30 minutes removed.
- The Darwin AppGroup JSON snapshot is written from `BoatMetricStore.flushSharedDefaults()` whenever a non-nil `appGroupID` was passed to `init`.

To feed the store from a transport, use one of the async-stream piping helpers on `BoatMetricStore`:

```swift
let store = BoatMetricStore()
store.start()
store.pipe(NMEATransport(...).frames())          // tag from NMEA0183/NMEA2000 source
store.pipeSignalK(signalKClient.liveStream(...)) // tag as Signal K (lowest priority)
store.pipeMetrics(DeviceSensors().stream())      // raw BoatMetric values
```
