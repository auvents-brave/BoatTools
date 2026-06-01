# BoatTools — Decoder Coverage

Inventory of the NMEA 0183 sentences, NMEA 2000 PGNs, and Signal K paths recognised by BoatTools, together with the canonical metric name that each one emits.

---

## NMEA 0183

### Position and navigation

| Sentence | Description | Metrics emitted |
|---|---|---|
| `RMC` | Recommended Minimum Navigation Data | `lat`, `lon`, `SOG`, `COG` |
| `GLL` | Geographic Position — Lat/Lon | `lat`, `lon` |
| `GGA` | GPS Fix Data | `lat`, `lon`, `altitude`, `gps.quality`, `gps.satellites`, `gps.hdop` |
| `GNS` | Multi-constellation Fix Data | `lat`, `lon`, `altitude`, `<prefix>.mode`, `<prefix>.satellites`, `<prefix>.hdop` (prefix per talker: `gps`, `glonass`, `galileo`, `beidou`, `qzss`, `navic`, `gnss`) |
| `VTG` | Track Made Good and Ground Speed | `COG`, `SOG` |

### GNSS fix quality

| Sentence | Description | Metrics emitted |
|---|---|---|
| `GSA` | GPS DOP and Active Satellites | `gps.fix`, `gps.satellites`, `gps.pdop`, `gps.hdop`, `gps.vdop` |
| `GST` | GPS Pseudorange Noise Statistics | `gps.rms`, `gps.error.lat`, `gps.error.lon`, `gps.error.alt` |
| `GSV` | Satellites in View (multi-message) | `<prefix>.satellites.inView`, `<prefix>.snr.avg`, `<prefix>.snr.max`, `<prefix>.snr.min` — emitted on the last message of the series |

### Heading and attitude

| Sentence | Description | Metrics emitted |
|---|---|---|
| `HDT` | Heading True | `HDG.true` |
| `HDG` | Heading — Deviation and Variation | `HDG` |
| `HDM` | Heading Magnetic | `HDG.magnetic` |
| `ROT` | Rate of Turn | `ROT` (kept only when status is `A`) |

### Wind

| Sentence | Description | Metrics emitted |
|---|---|---|
| `MWV` | Wind Speed and Angle | `AWA`/`TWA`, `AWS`/`TWS` (true or apparent according to the reference flag) |
| `MWD` | Wind Direction and Speed | `TWD`, `TWS` |
| `VWR` | Relative Wind Speed and Angle | `AWA` (signed by L/R), `AWS` |

### Water

| Sentence | Description | Metrics emitted |
|---|---|---|
| `DPT` | Depth | `depth` |
| `DBT` | Depth Below Transducer | `depth` |
| `VHW` | Water Speed and Heading | `STW` |
| `MTW` | Water Temperature | `temperature.water` (Fahrenheit values are converted to Celsius) |
| `VLW` | Distance Through Water | `log.total`, `log.trip` |

### Weather / atmosphere

| Sentence | Description | Metrics emitted |
|---|---|---|
| `MDA` | Meteorological Composite | `pressure.atmospheric`, `temperature.air`, `temperature.water`, `humidity`, `temperature.dewPoint`, `TWD`, `TWS` |

### Autopilot / routing

| Sentence | Description | Metrics emitted |
|---|---|---|
| `XTE` | Cross-Track Error, Measured | `navigation.xte` (signed L/R) |
| `APA` | Autopilot Sentence A (older form of APB) | `navigation.xte`, `navigation.bearingOriginToDest` |
| `APB` | Autopilot Sentence B | `navigation.xte`, `navigation.bearingOriginToDest`, `navigation.bearingToDest`, `navigation.headingToSteer` |
| `RMB` | Recommended Minimum Navigation Information | `navigation.xte`, `waypoint.lat`, `waypoint.lon`, `navigation.distanceToWaypoint`, `navigation.bearingToDest`, `navigation.vmg` |
| `RSA` | Rudder Sensor Angle | `rudder`, `rudder.port` (dual-rudder vessels) |
| `BWC` | Bearing & Distance to Waypoint, Great Circle | `waypoint.lat`, `waypoint.lon`, `navigation.bearingToDest`, `navigation.bearingToDest.magnetic`, `navigation.distanceToWaypoint` |
| `BWR` | Bearing & Distance to Waypoint, Rhumb Line | same fields as `BWC` (rhumb-line calculation) |
| `BWW` | Bearing, Waypoint to Waypoint | `navigation.bearingNextLeg`, `navigation.bearingNextLeg.magnetic` |
| `BOD` | Bearing, Origin to Destination | `navigation.bearingOriginToDest`, `navigation.bearingOriginToDest.magnetic` |
| `WPL` | Waypoint Location | `waypoint.lat`, `waypoint.lon` |
| `RTE` | Routes (multi-message; waypoint IDs are strings) | `route.id` (when numeric), `route.waypointsInMessage` |

### Engine / mechanical

| Sentence | Description | Metrics emitted |
|---|---|---|
| `RPM` | Revolutions | `engine.<id>.rpm`, `engine.<id>.pitch` (or `shaft.<id>.*` for shaft sources) |
| `XDR` | Transducer Measurements | dynamic — one metric per transducer (id and unit taken from the sentence) |

### RADAR

| Sentence | Description | Metrics emitted |
|---|---|---|
| `RSD` | RADAR System Data | `radar.rangeScale`, `radar.cursor.range`, `radar.cursor.bearing` (range units K/N/S all converted to NM) |

### Time

| Sentence | Description | Metrics emitted |
|---|---|---|
| `ZDA` | Time and Date | `utc.timestamp` (Unix seconds) |

### Alarms and DSC

| Sentence | Description | Metrics emitted |
|---|---|---|
| `ALR` | Set Alarm State | `alarm.<id>.active`, `alarm.<id>.acknowledged` |
| `DSC` | Digital Selective Calling Information | `dsc.format`, `dsc.mmsi`, `dsc.category` |
| `DSE` | Expanded DSC | `dse.mmsi` |

### AIS

Multi-message sentences are reassembled before decoding.

| Sentence | Description | Output |
|---|---|---|
| `VDM` | AIS VHF Data-Link Message | AIS target |
| `VDO` | AIS VHF Data-Link Own-Vessel Report | AIS target |

Supported AIS message types: **1/2/3** (Class A Position), **4** (Base Station Report), **5** (Class A Static and Voyage Data), **8** (Binary Broadcast — also extracts the IMO 289 IFM 11 meteorological payload as metrics), **9** (SAR Aircraft, adds `altitude`), **18** (Class B Position), **19** (Class B Extended Position), **21** (Aid to Navigation), **24A/24B** (Class B Static).

Position reports are automatically enriched with the most recent static data (name, callsign, ship type, IMO, destination, draught) seen for the same MMSI.

Every AIS target also exposes a `country` derived from its MMSI Maritime Identification Digits (MID) — the ITU MID → country table, accounting for the MMSI category prefixes (ship, coast station `00`, group `0`, SAR aircraft `111`, aid to navigation `99`). `Country` provides a locale-localised `name` and a flag emoji.

### NMEA 2000 encapsulation

Some devices forward NMEA 2000 frames wrapped inside NMEA 0183-style sentences.
The wrapped PGN is unwrapped to a raw N2K frame and decoded through the PGN
tables below.

| Sentence | Description | Output |
|---|---|---|
| `DIN` (`$PCDIN`) | SeaSmart.Net NMEA 2000 encapsulation (hex payload) | The wrapped PGN is unwrapped and decoded — see the PGN tables below |
| `PDGY` (`!PDGY`) | Digital Yacht iKonvert received-data sentence (Base64 payload; `$PDGY` status sentences are ignored) | The wrapped PGN is unwrapped and decoded — see the PGN tables below |

Both are recognised even when mixed inline with regular NMEA 0183 sentences on the same stream (e.g. a chartplotter forwarding both 0183 and N2K data over a single socket).

### Equipment info and proprietary

| Sentence | Description | Metrics / output |
|---|---|---|
| `VER` | Equipment Version Information | Text fields (device type, vendor, model, software, hardware) — supports the IEC 61162-1 multi-message form, the vendor short form, and the AIS-display micro form (`$ADVER,<model>,<sw>`) |
| `TNL` | Trimble proprietary | Sub-commands `GGK` (position + RTK quality), `AVR` (yaw/tilt/roll), `VHD` (heading dual-antenna), `PJK` (projected local coordinates) |
| `TRO` | `$PHTRO` Hemisphere/CCS pitch & roll | `pitch`, `roll` (signed by `P/M` and `L/R` flags) |
| `OUT` | `$PMAROUT` Maretron Power Management | `power.<device>.state`, `power.<device>.voltage`, `power.<device>.current`, `power.<device>.power`, `power.<device>.level` (unit suffix extracted from each value) |

### Identified but not yet decoded

Sentences seen in real streams but for which no decoder is implemented yet:

- `$PMAR…` sentences other than `OUT` — Maretron proprietary, format unknown
- Trimble `$PTNL` sub-commands other than `GGK`/`AVR`/`VHD`/`PJK` (e.g. `BPQ`, `REX`, `DG`, `GGK_SYNC`)
- Talker `AD` (AIS Display Unit) on sentences other than `VER`

---

## NMEA 2000

PGNs larger than 8 bytes (fast-packet) are reassembled across multiple CAN frames before being decoded.

### Position and navigation

| PGN | Name | Metrics emitted |
|---|---|---|
| `126992` | System Time | `utc.timestamp`, `utc.timeSource` |
| `129025` | Position, Rapid Update | `lat`, `lon` |
| `129026` | COG & SOG, Rapid Update | `COG` (or `COG.magnetic` per reference flag), `SOG` |
| `129029` | GNSS Position Data | `lat`, `lon`, `altitude`, `gps.quality`, `gps.satellites`, `gps.hdop`, `gps.pdop`, `gps.geoidalSeparation` |
| `129033` | Time & Date | `utc.timestamp` |
| `129283` | Cross Track Error | `navigation.xte` |
| `129284` | Navigation Data | `navigation.distanceToWaypoint`, `navigation.bearingOriginToDest`, `navigation.bearingToDest`, `waypoint.lat`, `waypoint.lon`, `navigation.vmg` |

### GNSS quality

| PGN | Name | Metrics emitted |
|---|---|---|
| `129539` | GNSS DOPs | `gps.fix`, `gps.hdop`, `gps.vdop`, `gps.tdop` |
| `129540` | GNSS Sats in View | `gps.satellites.inView`, `gps.snr.avg`, `gps.snr.max`, `gps.snr.min` |

### Heading, attitude, rudder

| PGN | Name | Metrics emitted |
|---|---|---|
| `127245` | Rudder | `rudder` (actual position), `rudder.target` (autopilot command) |
| `127250` | Vessel Heading | `HDG`/`HDG.true`/`HDG.magnetic` (according to the reference flag), `HDG.deviation`, `magneticVariation` |
| `127251` | Rate of Turn | `ROT` |
| `127257` | Attitude | `yaw`, `pitch`, `roll` |

### Water

| PGN | Name | Metrics emitted |
|---|---|---|
| `128259` | Speed | `STW`, `SOG` (when the ground-reference field is present) |
| `128267` | Water Depth | `depth`, `depth.offset` (transducer-to-keel or surface-to-transducer correction), `depth.range` (transducer max scan range) |
| `128275` | Distance Log | `log.total`, `log.trip` |

### Wind

| PGN | Name | Metrics emitted |
|---|---|---|
| `130306` | Wind Data | `AWS`/`AWA` (apparent), `TWS`/`TWA` (true, boat-referenced), `TWS`/`TWD` (true, north-referenced), `TWS`/`TWD.magnetic` (magnetic-referenced) — dispatched by the reference field |

### Environment

| PGN | Name | Metrics emitted |
|---|---|---|
| `130310` | Environmental Parameters | `temperature.water`, `temperature.air`, `pressure.atmospheric` |
| `130311` | Environmental Parameters (extended) | `temperature.<source>`, `humidity`, `pressure.atmospheric` |
| `130312` | Temperature | `temperature.<source>` (per source code: water, air, inside, engine, cabin, refrigerator, …) and `<…>.setpoint` (thermostat target) |
| `130314` | Actual Pressure | `pressure.atmospheric` / `pressure.<source>` |
| `130323` | Meteorological Station Data | `weatherStation.lat`, `weatherStation.lon`, `TWS`, `TWD`, `TWS.gust`, `pressure.atmospheric`, `temperature.air` |

### Engine / mechanical

| PGN | Name | Metrics emitted |
|---|---|---|
| `127488` | Engine Parameters, Rapid Update | `engine.<inst>.rpm`, `engine.<inst>.boostPressure`, `engine.<inst>.tiltTrim` |
| `127489` | Engine Parameters, Dynamic | `engine.<inst>.{oilPressure, oilTemperature, coolantTemperature, alternatorVoltage, fuelRate, runtime, coolantPressure, fuelPressure, load, torque}` |
| `127505` | Fluid Level | `<type>.<inst>.level`, `<type>.<inst>.capacity` (type ∈ fuel / water / graywater / livewell / oil / blackwater) |
| `127508` | Battery Status | `battery.<inst>.voltage`, `.current`, `.temperature` |

### Anchor windlass

| PGN | Name | Metrics emitted |
|---|---|---|
| `128776` | Anchor Windlass Control Status | `windlass.<inst>.commandedDirection` (0=off · 1=deploying · 2=retrieving) |
| `128777` | Anchor Windlass Operating Status | `windlass.<inst>.chainLength` (m, 0.1 m resolution) · `windlass.<inst>.anchorUp` (1.0=docked · 0.0=deployed) · `windlass.<inst>.motion` (0=stopped · 1=deploying · 2=retrieving) · `windlass.<inst>.chainSpeed` (m/s) · `windlass.<inst>.rodeType` (1=chain · 2=rope) |
| `128778` | Anchor Windlass Monitoring Status | `windlass.<inst>.motorCurrent` (A) · `windlass.<inst>.controllerVoltage` (V) · `windlass.<inst>.motorHours` (h) |

### AIS

| PGN | Name | Equivalent AIS message type |
|---|---|---|
| `129038` | AIS Class A Position Report | 1/2/3 |
| `129039` | AIS Class B Position Report | 18 |
| `129040` | AIS Class B Extended Position Report | 19 (+ name, ship type) |
| `129041` | AIS Aids to Navigation Report | 21 |
| `129793` | AIS UTC and Date Report | 4 |
| `129794` | AIS Class A Static and Voyage Data | 5 |
| `129809` | AIS Class B "CS" Static Data, Part A | 24A |
| `129810` | AIS Class B "CS" Static Data, Part B | 24B |

---

## Signal K

Signal K's canonical SI units are systematically converted to BoatTools' nautical units (rad → °, m/s → kn, K → °C, Pa → hPa, m → NM, Hz → rpm, ratio → %).

### Literal paths

| Signal K path | Canonical metric | Conversion |
|---|---|---|
| `navigation.speedOverGround` | `SOG` | m/s × 1.94384 |
| `navigation.speedThroughWater` | `STW` | m/s × 1.94384 |
| `navigation.courseOverGroundTrue` / `…OverGround` | `COG` | rad → ° |
| `navigation.headingTrue` | `HDG.true` | rad → ° |
| `navigation.headingMagnetic` | `HDG.magnetic` | rad → ° |
| `navigation.rateOfTurn` | `ROT` | rad/s × 180/π × 60 → °/min |
| `navigation.attitude.pitch/roll/yaw` | `pitch`/`roll`/`yaw` | rad → ° |
| `navigation.log` | `log.total` | m / 1852 → NM |
| `navigation.logTrip` | `log.trip` | m / 1852 → NM |
| `navigation.gnss.satellites` | `gps.satellites` | — |
| `navigation.gnss.satellitesInView` | `gps.satellites.inView` | — |
| `navigation.gnss.horizontalDilution` | `gps.hdop` | — |
| `navigation.gnss.positionDilution` | `gps.pdop` | — |
| `navigation.gnss.verticalDilution` | `gps.vdop` | — |
| `navigation.gnss.timeDilution` | `gps.tdop` | — |
| `navigation.gnss.methodQuality` | `gps.quality` | — |
| `navigation.gnss.antennaAltitude` | `altitude` | — |
| `environment.wind.angleApparent` | `AWA` | rad → ° |
| `environment.wind.angleTrueWater` / `…TrueGround` | `TWA` | rad → ° |
| `environment.wind.directionTrue` | `TWD` | rad → ° |
| `environment.wind.speedApparent` | `AWS` | m/s × 1.94384 |
| `environment.wind.speedTrue` / `…OverGround` | `TWS` | m/s × 1.94384 |
| `environment.depth.belowKeel/belowSurface/belowTransducer` | `depth` | — |
| `environment.water.temperature` | `temperature.water` | K → °C |
| `environment.outside.temperature` | `temperature.air` | K → °C |
| `environment.inside.temperature` | `temperature.inside` | K → °C |
| `environment.outside.dewPointTemperature` | `temperature.dewPoint` | K → °C |
| `environment.outside.pressure` / `…atmosphericPressure` | `pressure.atmospheric` | Pa → hPa |
| `environment.outside.humidity` / `…relativeHumidity` | `humidity` | ratio × 100 → % |
| `steering.rudderAngle` | `rudder` | rad → ° |
| `steering.autopilot.target.rudderAngle` | `rudder.target` | rad → ° |
| `navigation.gnss.geoidalSeparation` | `gps.geoidalSeparation` | — |
| `navigation.courseRhumbline.crossTrackError` (and `courseGreatCircle…`) | `navigation.xte` | m → NM |
| `navigation.courseRhumbline.bearingTrackTrue` | `navigation.bearingOriginToDest` | rad → ° |
| `navigation.courseRhumbline.bearingToDestinationTrue` | `navigation.bearingToDest` | rad → ° |
| `navigation.courseRhumbline.nextPoint.distance` (and `courseGreatCircle…`) | `navigation.distanceToWaypoint` | m → NM |
| `navigation.courseRhumbline.nextPoint.velocityMadeGood` (and `courseGreatCircle…`) | `navigation.vmg` | m/s × 1.94384 |
| `steering.autopilot.target.headingTrue` | `navigation.headingToSteer` | rad → ° |
| `navigation.datetime` | `utc.timestamp` | — |

### Object paths (unpacked into multiple metrics)

| Signal K path | Metrics produced |
|---|---|
| `navigation.position` | `lat`, `lon`, `altitude` (from `{latitude, longitude, altitude}`) |
| `navigation.*.nextPoint.position` | `waypoint.lat`, `waypoint.lon` |

### Pattern paths (indexed)

| Signal K pattern | Canonical metric |
|---|---|
| `electrical.batteries.<id>.voltage` | `battery.<id>.voltage` |
| `electrical.batteries.<id>.current` | `battery.<id>.current` |
| `electrical.batteries.<id>.temperature` | `battery.<id>.temperature` (K → °C) |
| `electrical.batteries.<id>.capacity.stateOfCharge` | `battery.<id>.soc` (ratio → %) |
| `electrical.generators.<id>.{voltage,current,power,acIsOn,stateOfCharge}` | `power.genset.{voltage,current,power,state,level}` |
| `electrical.inverters.<id>.{ac.voltage,dc.voltage,acIsOn,…}` | `power.inverter.{voltage,…}` |
| `electrical.chargers.<id>.{voltage,current,…}` | `power.charger.{voltage,…}` |
| `propulsion.<id>.revolutions` | `engine.<id>.rpm` (Hz × 60) |
| `propulsion.<id>.oilPressure` | `engine.<id>.oilPressure` |
| `propulsion.<id>.oilTemperature` | `engine.<id>.oilTemperature` (K → °C) |
| `propulsion.<id>.coolantTemperature` / `…temperature` | `engine.<id>.coolantTemperature` (K → °C) |
| `propulsion.<id>.alternatorVoltage` | `engine.<id>.alternatorVoltage` |
| `propulsion.<id>.fuel.rate` | `engine.<id>.fuelRate` (m³/s → L/h) |
| `propulsion.<id>.runTime` | `engine.<id>.runtime` (s) |
| `propulsion.<id>.engineLoad` | `engine.<id>.load` (ratio → %) |
| `propulsion.<id>.engineTorque` | `engine.<id>.torque` (ratio → %) |
| `propulsion.<id>.boostPressure` / `coolantPressure` / `fuelPressure` | `engine.<id>.{boostPressure,coolantPressure,fuelPressure}` |
| `tanks.fuel.<id>.currentLevel` | `fuel.<id>.level` (ratio → %) |
| `tanks.freshWater.<id>.currentLevel` | `water.<id>.level` |
| `tanks.wasteWater.<id>.currentLevel` / `…blackWater.…` | `blackwater.<id>.level` |
| `tanks.greyWater.<id>.currentLevel` | `graywater.<id>.level` |
| `tanks.liveWell.<id>.currentLevel` | `livewell.<id>.level` |

Unknown Signal K paths are emitted with their raw name (no silent drops), with no unit conversion.

---

## Index by canonical metric

Reverse view: for every canonical metric emitted by BoatTools, the protocols that can produce it.

| Metric | NMEA 0183 | NMEA 2000 | Signal K |
|---|---|---|---|
| `lat` / `lon` | `RMC`, `GLL`, `GGA`, `GNS`, AIS types 1/2/3/4/5/9/18/19/21, `$PTNL,GGK` | `129025`, `129029`, AIS PGN 129038/039/040/041/793 | `navigation.position` |
| `altitude` | `GGA`, `GNS`, `$PTNL,GGK`, AIS type 9 (aircraft) | `129029`, AIS PGN | `navigation.position`, `navigation.gnss.antennaAltitude` |
| `SOG` | `RMC`, `VTG`, AIS position reports | `129026`, AIS PGN 129038/039/040 | `navigation.speedOverGround` |
| `STW` | `VHW` | `128259` | `navigation.speedThroughWater` |
| `COG` | `RMC`, `VTG`, AIS position reports | `129026`, AIS PGN | `navigation.courseOverGroundTrue` |
| `HDG` / `HDG.true` / `HDG.magnetic` | `HDT`, `HDG`, `HDM`, `$PTNL,VHD` | `127250` | `navigation.headingTrue`, `navigation.headingMagnetic` |
| `HDG.deviation` / `magneticVariation` | — | `127250` | — |
| `ROT` | `ROT`, AIS type 1/2/3 | `127251`, AIS PGN 129038 | `navigation.rateOfTurn` |
| `AWA` / `AWS` | `MWV`, `VWR` | `130306` | `environment.wind.angleApparent`, `environment.wind.speedApparent` |
| `TWA` / `TWS` / `TWD` | `MWV`, `MWD`, `MDA`, AIS meteo IFM 11 | `130306`, `130323` | `environment.wind.{angleTrueWater,speedTrue,directionTrue}` |
| `TWS.gust` / `TWD.gust` | AIS meteo IFM 11, `MDA` (gust not in MDA spec — placeholder) | `130323` | — |
| `depth` | `DPT`, `DBT` | `128267` | `environment.depth.{belowKeel,belowSurface,belowTransducer}` |
| `temperature.water` | `MTW`, `MDA` | `130310`, `130311`, `130312` | `environment.water.temperature` |
| `temperature.air` | `MDA`, AIS meteo IFM 11 | `130310`, `130311`, `130312`, `130323` | `environment.outside.temperature` |
| `temperature.dewPoint` | `MDA`, AIS meteo IFM 11 | `130311` | `environment.outside.dewPointTemperature` |
| `humidity` | `MDA`, AIS meteo IFM 11 | `130311` | `environment.outside.humidity` |
| `pressure.atmospheric` | `MDA`, AIS meteo IFM 11 | `130310`, `130311`, `130314`, `130323` | `environment.outside.pressure` |
| `gps.fix` | `GSA` | `129539` | — |
| `gps.satellites` | `GGA`, `GSA`, `GNS` | `129029` | `navigation.gnss.satellites` |
| `gps.satellites.inView` | `GSV` | `129540` | `navigation.gnss.satellitesInView` |
| `gps.hdop` / `gps.pdop` / `gps.vdop` / `gps.tdop` | `GSA`, `GGA`, `GNS`, `$PTNL,GGK` | `129029`, `129539` | `navigation.gnss.{horizontalDilution,positionDilution,verticalDilution,timeDilution}` |
| `gps.quality` | `GGA`, `$PTNL,GGK/AVR/VHD/PJK` | `129029` | `navigation.gnss.methodQuality` |
| `gps.rms` / `gps.error.lat/lon/alt` | `GST` | — | — |
| `gps.snr.{avg,max,min}` | `GSV` | `129540` | — |
| `log.total` / `log.trip` | `VLW` | `128275` | `navigation.log`, `navigation.logTrip` |
| `rudder` / `rudder.port` | `RSA` | `127245` | `steering.rudderAngle` |
| `pitch` / `roll` / `yaw` | `$PHTRO`, `$PTNL,AVR`, AIS | `127257` | `navigation.attitude.{pitch,roll,yaw}` |
| `tilt` | `$PTNL,AVR` | — | — |
| `engine.<inst>.rpm` | `RPM` | `127488` | `propulsion.<id>.revolutions` |
| `engine.<inst>.boostPressure` | — | `127488`, `127489` | `propulsion.<id>.boostPressure` |
| `engine.<inst>.tiltTrim` | — | `127488` | — |
| `engine.<inst>.{oilPressure,oilTemperature,coolantTemperature,alternatorVoltage,fuelRate,runtime,coolantPressure,fuelPressure,load,torque}` | — | `127489` | `propulsion.<id>.…` |
| `battery.<inst>.{voltage,current,temperature,soc}` | — | `127508` | `electrical.batteries.<id>.…` |
| `fuel.<inst>.level` / `water…` / `graywater…` / `blackwater…` / `livewell…` / `oil…` | — | `127505` | `tanks.<type>.<id>.currentLevel` |
| `<tank>.<inst>.capacity` | — | `127505` | — |
| `rudder.target` | — | `127245` | `steering.autopilot.target.rudderAngle` (Signal K convention) |
| `windlass.<inst>.chainLength` | — | `128777` | — |
| `windlass.<inst>.anchorUp` | — | `128777` | — |
| `windlass.<inst>.motion` | — | `128777` | — |
| `windlass.<inst>.chainSpeed` | — | `128777` | — |
| `windlass.<inst>.rodeType` | — | `128777` | — |
| `windlass.<inst>.commandedDirection` | — | `128776` | — |
| `windlass.<inst>.motorCurrent` | — | `128778` | — |
| `windlass.<inst>.controllerVoltage` | — | `128778` | — |
| `windlass.<inst>.motorHours` | — | `128778` | — |
| `depth.offset` / `depth.range` | — | `128267` | — |
| `gps.geoidalSeparation` | — | `129029` | — |
| `<…>.setpoint` (temperature) | — | `130312` | — |
| `utc.timeSource` | — | `126992` | — |
| `COG.magnetic` / `TWD.magnetic` | — | `129026` (COG), `130306` (wind) | — |
| `power.<device>.{state,voltage,current,power,level}` | `$PMAROUT` | — | `electrical.{generators,inverters,chargers}.<id>.…` |
| `navigation.xte` | `XTE`, `APA`, `APB`, `RMB` | `129283` | `navigation.courseRhumbline.crossTrackError` |
| `navigation.bearingOriginToDest` (+ `.magnetic`) | `APA`, `APB`, `BOD` | `129284` | `navigation.courseRhumbline.bearingTrackTrue` |
| `navigation.bearingToDest` (+ `.magnetic`) | `APB`, `BWC`, `BWR`, `RMB` | `129284` | `navigation.courseRhumbline.bearingToDestinationTrue` |
| `navigation.bearingNextLeg` (+ `.magnetic`) | `BWW` | — | — |
| `navigation.headingToSteer` | `APB` | — | `steering.autopilot.target.headingTrue` |
| `navigation.distanceToWaypoint` | `BWC`, `BWR`, `RMB` | `129284` | `navigation.courseRhumbline.nextPoint.distance` |
| `navigation.vmg` | `RMB` | `129284` | `navigation.courseRhumbline.nextPoint.velocityMadeGood` |
| `waypoint.lat` / `waypoint.lon` | `WPL`, `BWC`, `BWR`, `RMB` | `129284` | `navigation.*.nextPoint.position` |
| `weatherStation.lat` / `weatherStation.lon` | — | `130323` | — |
| `route.id` / `route.waypointsInMessage` | `RTE` | — | — |
| `radar.rangeScale` / `radar.cursor.range` / `radar.cursor.bearing` | `RSD` | — | — |
| `alarm.<id>.active` / `…acknowledged` | `ALR` | — | — |
| `dsc.{format,mmsi,category}` / `dse.mmsi` | `DSC`, `DSE` | — | — |
| `utc.timestamp` | `ZDA` | `126992`, `129033` | `navigation.datetime` |
| `pjk.northing` / `pjk.easting` | `$PTNL,PJK` | — | — |
| AIS target | `VDM`, `VDO` | `129038/039/040/041/793/794/798/809/810` | — |
