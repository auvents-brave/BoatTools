public import Foundation

// MARK: - Geographic point

/// A latitude/longitude pair, in degrees, used to describe a simulated passage.
///
/// Kept deliberately minimal (no CoreLocation dependency) so the simulator can
/// run on every platform BoatToolsKit supports.
public struct GeoPoint: Sendable, Equatable, Hashable {
    /// Latitude in degrees, positive north.
    public var latitude: Double
    /// Longitude in degrees, positive east.
    public var longitude: Double

    /// Creates a geographic point.
    /// - Parameters:
    ///   - latitude: Latitude in degrees, positive north.
    ///   - longitude: Longitude in degrees, positive east.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Simulator route

/// A named passage the simulator can sail: an ordered list of waypoints.
///
/// Routes are identified by a stable ``id`` so a host app can persist a choice
/// and resolve it back to a route via ``preset(id:)``.
public struct SimulatorRoute: Sendable, Equatable, Hashable, Identifiable {
    /// Stable identifier, safe to persist.
    public let id: String
    /// User-facing name, e.g. "Monaco → La Maddalena".
    public let name: String
    /// Waypoints in passage order. At least two are needed to make way.
    public let waypoints: [GeoPoint]

    /// Creates a route.
    /// - Parameters:
    ///   - id: Stable identifier, safe to persist.
    ///   - name: User-facing name.
    ///   - waypoints: Waypoints in passage order.
    public init(id: String, name: String, waypoints: [GeoPoint]) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
    }

    /// A Riviera-to-Sardinia passage heading south-east: just outside Monaco, out
    /// into the Ligurian Sea, down the west of Corsica, then through the Strait of
    /// Bonifacio to La Maddalena off northern Sardinia. The start sits just clear
    /// of Monaco's breakwater and every leg stays in open water, so the track
    /// leaves harbour cleanly without crossing land.
    public static let monacoToMaddalena = SimulatorRoute(
        id: "monaco-maddalena",
        name: "Monaco → La Maddalena",
        waypoints: [
            GeoPoint(latitude: 43.7280, longitude: 7.4320),   // just outside Monaco
            GeoPoint(latitude: 43.1000, longitude: 8.0000),   // open Ligurian Sea
            GeoPoint(latitude: 42.3000, longitude: 8.2500),   // west of Corsica
            GeoPoint(latitude: 41.5500, longitude: 8.5500),   // SW of Corsica
            GeoPoint(latitude: 41.3300, longitude: 9.0500),   // Strait of Bonifacio
            GeoPoint(latitude: 41.2400, longitude: 9.3800),   // off La Maddalena
        ]
    )

    /// Every route the simulator ships with.
    public static let presets: [SimulatorRoute] = [.monacoToMaddalena]

    /// Resolves a preset route by its identifier.
    /// - Parameter id: The route's ``id``.
    /// - Returns: The matching preset, or `nil` if none has that identifier.
    public static func preset(id: String) -> SimulatorRoute? {
        presets.first { $0.id == id }
    }
}

// MARK: - Simulator

/// Generates a live feed of synthetic NMEA 2000 GPS frames for a vessel sailing
/// a ``SimulatorRoute``.
///
/// Each tick the simulator advances the vessel along the route at the configured
/// speed, then **encodes real NMEA 2000 PGN payloads** (129025 Position Rapid
/// Update and 129026 COG & SOG Rapid Update) and decodes them back through the
/// same path the network transports use. The stream therefore yields, per PGN,
/// the raw ``NMEAFrame/nmea2000(pgn:source:priority:data:)`` frame followed by
/// the decoded ``NMEAFrame/metric(_:)`` frames — exactly as a real gateway would,
/// so the metric store tags and prioritises the values identically.
public enum NMEASimulator {

    /// Source address the synthetic frames claim to come from (an arbitrary,
    /// unused NMEA 2000 node address).
    private static let sourceAddress: UInt8 = 0x16
    /// Earth's mean radius, in metres.
    private static let earthRadius = 6_371_000.0
    /// Knots to metres per second.
    private static let knotsToMetresPerSecond = 0.514_444

    /// Builds a live frame stream for a simulated passage.
    ///
    /// - Parameters:
    ///   - route: The passage to sail.
    ///   - speedKnots: Speed over ground, in knots — the realistic value reported
    ///     on the instruments.
    ///   - timeMultiplier: Fast-forward factor for the *movement* only. At `1` the
    ///     vessel advances at its true speed in real time; at `10` it covers ten
    ///     times the ground per second, while the reported SOG stays realistic —
    ///     the same idea as speeding up a replay.
    ///   - updateInterval: Delay between position updates. Defaults to one second.
    ///   - loop: When `true`, the passage restarts from the first waypoint on
    ///     arrival; when `false`, the stream finishes at the last waypoint.
    /// - Returns: An async stream of frames, ready to pipe into a
    ///   ``BoatMetricStore`` with `store.pipe(_:)`.
    public static func frameStream(
        route: SimulatorRoute,
        speedKnots: Double,
        timeMultiplier: Double = 1,
        updateInterval: Duration = .seconds(1),
        loop: Bool = true
    ) -> AsyncThrowingStream<NMEAFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let waypoints = route.waypoints
                let speed = max(0, speedKnots)
                let dt = seconds(of: updateInterval)
                let stepMetres = speed * knotsToMetresPerSecond * dt * max(1, timeMultiplier)
                var tick = 0

                // A degenerate route (or zero speed) just holds the first fix so
                // the connection still reads as "live" rather than erroring.
                guard waypoints.count >= 2, stepMetres > 0 else {
                    let hold = waypoints.first ?? GeoPoint(latitude: 0, longitude: 0)
                    while !Task.isCancelled {
                        emit(position: hold, courseDegrees: 0, speedKnots: speed,
                             tick: tick, into: continuation)
                        tick += 1
                        try await Task.sleep(for: updateInterval)
                    }
                    continuation.finish()
                    return
                }

                var position = waypoints[0]
                var legIndex = 0   // sailing from waypoints[legIndex] to waypoints[legIndex + 1]
                var passageSeconds = 0.0   // simulated time sailed (scales with the multiplier)

                while !Task.isCancelled {
                    let target = waypoints[legIndex + 1]
                    let course = bearingDegrees(from: position, to: target)
                    let remainingMetres = distanceMetres(from: position, to: target)
                    emit(position: position, courseDegrees: course, speedKnots: speed,
                         tick: tick, into: continuation)
                    emitNavigation(position: position, target: target, course: course,
                                   speedKnots: speed, remainingMetres: remainingMetres,
                                   tick: tick, into: continuation)
                    emitAIS(passageSeconds: passageSeconds, tick: tick, into: continuation)
                    tick += 1
                    passageSeconds += dt * max(1, timeMultiplier)

                    // Advance towards the target; step onto the next leg when this
                    // tick would reach or overshoot the waypoint.
                    let remaining = remainingMetres
                    if stepMetres >= remaining {
                        position = target
                        legIndex += 1
                        if legIndex + 1 >= waypoints.count {
                            guard loop else {
                                emit(position: position, courseDegrees: course,
                                     speedKnots: 0, tick: tick, into: continuation)
                                continuation.finish()
                                return
                            }
                            position = waypoints[0]
                            legIndex = 0
                        }
                    } else {
                        position = destination(from: position, distanceMetres: stepMetres,
                                               bearingDegrees: course)
                    }
                    try await Task.sleep(for: updateInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: History backfill

    /// One past sample for seeding a curve: a value at a point in time.
    public struct HistorySample: Sendable {
        public let at: Date
        public let value: Double
        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    /// Builds synthetic past samples for the wind and pressure curves, so a fresh
    /// simulated session shows full graphs from the first second instead of empty
    /// axes that fill in slowly.
    ///
    /// The samples extend the same deterministic environmental model backwards in
    /// time, so they join the live feed seamlessly. Wind covers the last hour at
    /// 5-second spacing (the store's recent tier); pressure covers the last 48
    /// hours at 30-minute spacing (its single tier).
    ///
    /// - Parameters:
    ///   - speedKnots: Cruising speed, used to derive the apparent wind.
    ///   - endingAt: The present moment the history runs up to.
    /// - Returns: Samples keyed by metric name (`TWS`, `TWD`, `AWS`, `AWA`,
    ///   `pressure.atmospheric`), oldest first.
    public static func historyBackfill(
        speedKnots: Double, endingAt now: Date
    ) -> [String: [HistorySample]] {
        let v = max(0, speedKnots)
        // A steady representative heading is enough for a natural-looking past
        // wind curve — we do not replay the actual past track.
        let heading = 115.0

        var tws: [HistorySample] = [], twd: [HistorySample] = []
        var aws: [HistorySample] = [], awa: [HistorySample] = []
        let windStep = 5.0
        for k in stride(from: 720, through: 0, by: -1) {
            let n = Double(-k) * windStep
            let t = now.addingTimeInterval(Double(-k) * windStep)
            let direction = trueWindDirection(n)
            let speed = trueWindSpeed(n)
            let apparent = apparentWind(trueSpeed: speed, trueDirection: direction,
                                        heading: heading, boatSpeed: v)
            twd.append(HistorySample(at: t, value: direction))
            tws.append(HistorySample(at: t, value: speed))
            aws.append(HistorySample(at: t, value: apparent.speed))
            awa.append(HistorySample(at: t, value: apparent.angle))
        }

        var pressure: [HistorySample] = []
        let pressureStep = 1800.0
        for k in stride(from: 96, through: 0, by: -1) {
            let n = Double(-k) * pressureStep
            let t = now.addingTimeInterval(Double(-k) * pressureStep)
            pressure.append(HistorySample(at: t, value: pressureHPa(n)))
        }

        return [
            "TWS": tws, "TWD": twd, "AWS": aws, "AWA": awa,
            "pressure.atmospheric": pressure,
        ]
    }

    // MARK: Frame emission

    /// Emits one position fix as a burst of NMEA 2000 frames — position, course &
    /// speed, heading, speed through water, true and apparent wind, and barometric
    /// pressure — each raw frame immediately followed by its decoded metrics so
    /// the store tags every metric with the originating PGN.
    ///
    /// The reported course and speed carry a gentle wander (≤ ~3° on COG, ≤ ~0.3 kn
    /// on SOG); the heading sits a few degrees off the course made good (leeway);
    /// speed through water oscillates around the cruising speed; and the wind is a
    /// slowly-shifting true breeze with the apparent wind derived from the boat's
    /// own motion. Everything is deterministic in `tick` and continuous with the
    /// history backfill, so the curves join seamlessly at the start of a session.
    private static func emit(
        position: GeoPoint,
        courseDegrees: Double,
        speedKnots: Double,
        tick: Int,
        into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        let n = Double(tick)
        let cogWander = 2.5 * sin(n * 0.11) + 0.5 * sin(n * 0.37)   // |·| ≤ 3°
        let sogWander = 0.22 * sin(n * 0.07) + 0.07 * sin(n * 0.31) // |·| ≤ 0.3 kn
        let reportedCourse = courseDegrees + cogWander
        let reportedSpeed = speedKnots > 0 ? max(0, speedKnots + sogWander) : 0

        let heading = courseDegrees + leewayDegrees(n)
        let throughWater = speedKnots > 0 ? max(0, speedKnots + stwOffset(n)) : 0
        let trueWindDir = trueWindDirection(n)
        let trueWindSpd = trueWindSpeed(n)
        let apparent = apparentWind(trueSpeed: trueWindSpd, trueDirection: trueWindDir,
                                    heading: heading, boatSpeed: throughWater)

        yieldFrame(pgn: 129025, data: positionRapidPayload(position), into: continuation)
        yieldFrame(pgn: 129026, data: cogSogPayload(courseDegrees: reportedCourse,
                                                    speedKnots: reportedSpeed), into: continuation)
        yieldFrame(pgn: 127250, data: headingPayload(degrees: heading), into: continuation)
        yieldFrame(pgn: 128259, data: speedPayload(stwKnots: throughWater), into: continuation)
        yieldFrame(pgn: 130306, data: windPayload(speedKnots: trueWindSpd,
                                                  angleDegrees: trueWindDir, reference: 0),
                   into: continuation)
        yieldFrame(pgn: 130306, data: windPayload(speedKnots: apparent.speed,
                                                  angleDegrees: apparent.angle, reference: 2),
                   into: continuation)
        yieldFrame(pgn: 130314, data: pressurePayload(hPa: pressureHPa(n)), into: continuation)
        yieldFrame(pgn: 127258, data: variationPayload(degrees: magneticVariationDegrees(at: position)),
                   into: continuation)
        yieldFrame(pgn: 127488, data: engineRapidPayload(instance: 0, rpm: engineRPM(instance: 0, n)),
                   into: continuation)
        yieldFrame(pgn: 127488, data: engineRapidPayload(instance: 1, rpm: engineRPM(instance: 1, n)),
                   into: continuation)

        // Magnetic heading alongside the true one (compass = true − variation).
        let variation = magneticVariationDegrees(at: position)
        yieldFrame(pgn: 127250, data: headingPayload(degrees: heading - variation, magnetic: true),
                   into: continuation)

        // Attitude — a gentle pitch & roll as the boat works in a seaway.
        yieldFrame(pgn: 127257, data: attitudePayload(
            yaw: heading, pitch: 2.5 * sin(n * 0.21), roll: 4 * sin(n * 0.17 + 0.5)), into: continuation)

        // Steering & turn.
        yieldFrame(pgn: 127245, data: rudderPayload(degrees: 3 * sin(n * 0.09)), into: continuation)
        yieldFrame(pgn: 127251, data: rateOfTurnPayload(degPerMin: cogWander * 2), into: continuation)

        // Engine dynamic parameters for both engines.
        yieldFrame(pgn: 127489, data: engineDynamicPayload(instance: 0, n: n), into: continuation)
        yieldFrame(pgn: 127489, data: engineDynamicPayload(instance: 1, n: n + 40), into: continuation)

        // Full GNSS: position with quality, DOPs, UTC, satellites in view.
        yieldFrame(pgn: 129029, data: gnssPositionPayload(position, n: n), into: continuation)
        yieldFrame(pgn: 129539, data: gnssDopsPayload(n: n), into: continuation)
        yieldFrame(pgn: 126992, data: systemTimePayload(), into: continuation)
        for frame in satellitesInView(n: n) { continuation.yield(frame) }

        // Tanks: fuel & fresh water draining, black & grey water filling.
        yieldFrame(pgn: 127505, data: fluidLevelPayload(instance: 0, type: 0,
            level: tankFuel(n), capacityL: 400), into: continuation)
        yieldFrame(pgn: 127505, data: fluidLevelPayload(instance: 0, type: 1,
            level: tankFreshWater(n), capacityL: 200), into: continuation)
        yieldFrame(pgn: 127505, data: fluidLevelPayload(instance: 0, type: 5,
            level: tankBlackWater(n), capacityL: 80), into: continuation)
        yieldFrame(pgn: 127505, data: fluidLevelPayload(instance: 1, type: 2,
            level: tankGreyWater(n), capacityL: 100), into: continuation)

        // Batteries: engine 12 V (full), service 24 V (draining), solar bank.
        emitBattery(instance: 0, voltage: engineBatteryVoltage(n), current: 8 + 2 * sin(n * 0.05),
                    soc: 100, into: continuation)
        emitBattery(instance: 1, voltage: serviceVoltage(n), current: -12 - 4 * sin(n * 0.03),
                    soc: serviceSOC(n), into: continuation)
        emitBattery(instance: 2, voltage: 13.4 + 0.2 * sin(n * 0.02), current: solarCurrent(n),
                    soc: solarSOC(n), into: continuation)

        // Temperatures: sea, outside air, refrigerator, freezer.
        yieldFrame(pgn: 130312, data: temperaturePayload(instance: 0, source: 0,
            celsius: seaTemperature(n)), into: continuation)
        yieldFrame(pgn: 130312, data: temperaturePayload(instance: 1, source: 1,
            celsius: airTemperature(n)), into: continuation)
        yieldFrame(pgn: 130312, data: temperaturePayload(instance: 2, source: 7,
            celsius: 5 + 1.5 * sin(n * 0.03)), into: continuation)
        yieldFrame(pgn: 130312, data: temperaturePayload(instance: 3, source: 13,
            celsius: -18 + 2 * sin(n * 0.025)), into: continuation)

        // Windlass: anchor stowed (up) while under way.
        yieldFrame(pgn: 128777, data: windlassOperatingPayload(anchorUp: true),
                   into: continuation)
        yieldFrame(pgn: 128778, data: windlassMonitoringPayload(), into: continuation)

        // Distance log (total + trip).
        yieldFrame(pgn: 128275, data: distanceLogPayload(
            totalNM: 12_840 + n * 0.0017, tripNM: n * 0.0017), into: continuation)

        // Depth (over a shelving bottom), relative humidity, and wind gusts.
        yieldFrame(pgn: 128267, data: depthPayload(metres: 45 + 18 * sin(n * 0.004)),
                   into: continuation)
        yieldFrame(pgn: 130311, data: humidityPayload(percent: 62 + 8 * sin(n * 0.0009)),
                   into: continuation)
        yieldFrame(pgn: 130323, data: gustPayload(gustKnots: trueWindSpd + 3 + 2 * sin(n * 0.05)),
                   into: continuation)
    }

    // MARK: Environmental model

    /// True wind direction (degrees, where it blows *from*), shifting slowly — a
    /// touch more restless than a steady breeze, but still gentle.
    static func trueWindDirection(_ n: Double) -> Double {
        305 + 16 * sin(n * 0.0015) + 6 * sin(n * 0.006) + 3 * sin(n * 0.011)
    }

    /// Engine speed (rpm) for an engine instance, idling near 3000 with a slow,
    /// smooth wander of roughly ±25 rpm. The two engines use different periods and
    /// phases so they never breathe quite in step.
    static func engineRPM(instance: Int, _ n: Double) -> Double {
        if instance == 0 {
            return 3000 + 18 * sin(n * 0.017) + 5 * sin(n * 0.051)
        } else {
            return 3000 + 16 * sin(n * 0.013 + 1.7) + 6 * sin(n * 0.041 + 0.6)
        }
    }

    /// Approximate magnetic variation (declination, degrees, positive = East) for
    /// a position, from WMM-2025: ≈ +3.4°E off Monaco rising to ≈ +4.0°E off La
    /// Maddalena. Interpolated by longitude across the passage; very stable, it
    /// just edges up as the vessel works east.
    static func magneticVariationDegrees(at p: GeoPoint) -> Double {
        let lon0 = 7.43, var0 = 3.4
        let lon1 = 9.38, var1 = 4.0
        let t = min(1, max(0, (p.longitude - lon0) / (lon1 - lon0)))
        return var0 + (var1 - var0) * t
    }

    /// True wind speed (knots), easing up and down over tens of minutes.
    static func trueWindSpeed(_ n: Double) -> Double {
        max(0, 13 + 3 * sin(n * 0.0013) + 1.2 * sin(n * 0.008))
    }

    /// Barometric pressure (hPa), drifting gently over many hours.
    static func pressureHPa(_ n: Double) -> Double {
        1014 + 6 * sin(n * 0.000025) + 1.5 * sin(n * 0.0003)
    }

    /// Leeway: how many degrees the heading sits off the course made good.
    static func leewayDegrees(_ n: Double) -> Double {
        -6 + 2.5 * sin(n * 0.003)
    }

    /// Speed-through-water oscillation around the cruising speed (knots).
    static func stwOffset(_ n: Double) -> Double {
        0.4 * sin(n * 0.05) + 0.15 * sin(n * 0.013)
    }

    /// Derives apparent wind (speed in knots, angle in degrees off the bow, 0–360)
    /// from the true wind and the vessel's own motion.
    static func apparentWind(
        trueSpeed tws: Double, trueDirection twd: Double, heading: Double, boatSpeed v: Double
    ) -> (speed: Double, angle: Double) {
        // True wind angle off the bow, wind-from convention, in [-180, 180].
        var twa = (twd - heading).truncatingRemainder(dividingBy: 360)
        if twa > 180 { twa -= 360 } else if twa < -180 { twa += 360 }
        let twaRad = twa * .pi / 180
        let aws = (tws * tws + v * v + 2 * tws * v * cos(twaRad)).squareRoot()
        var awa = atan2(tws * sin(twaRad), tws * cos(twaRad) + v) * 180 / .pi
        if awa < 0 { awa += 360 }
        return (aws, awa)
    }

    /// Yields a raw NMEA 2000 frame and, when it decodes, its resulting metrics.
    private static func yieldFrame(
        pgn: UInt32,
        data: [UInt8],
        into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        continuation.yield(.nmea2000(pgn: pgn, source: sourceAddress, priority: 2, data: data))
        if let metrics = NMEA2000Decoder.decode(pgn: pgn, data: data) {
            for metric in metrics { continuation.yield(.metric(metric)) }
        }
    }

    // MARK: PGN encoders (mirrors of the decoders in NMEAParsers)

    /// PGN 129025 — Position, Rapid Update: latitude then longitude as int32 in
    /// units of 1e-7°, little-endian.
    private static func positionRapidPayload(_ p: GeoPoint) -> [UInt8] {
        littleEndian(Int32((p.latitude * 1e7).rounded()))
            + littleEndian(Int32((p.longitude * 1e7).rounded()))
    }

    /// PGN 129026 — COG & SOG, Rapid Update.
    ///   byte 0: SID
    ///   byte 1: COG reference (0 = true) in the low two bits, reserved bits set
    ///   bytes 2-3: COG (uint16, 1e-4 rad per LSB)
    ///   bytes 4-5: SOG (uint16, 0.01 m/s per LSB)
    ///   bytes 6-7: reserved
    private static func cogSogPayload(courseDegrees: Double, speedKnots: Double) -> [UInt8] {
        let normalisedCog = (courseDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let cogRaw = UInt16((normalisedCog * .pi / 180 * 1e4).rounded())
        let sogRaw = UInt16((speedKnots * knotsToMetresPerSecond * 100).rounded())
        return [0x00, 0xFC] + littleEndian(cogRaw) + littleEndian(sogRaw) + [0xFF, 0xFF]
    }

    /// PGN 127250 — Vessel Heading.
    ///   byte 0: SID
    ///   bytes 1-2: heading (uint16, 1e-4 rad), bytes 3-4: deviation (NA),
    ///   bytes 5-6: variation (NA), byte 7: reference (0 = true, 1 = magnetic).
    private static func headingPayload(degrees: Double, magnetic: Bool = false) -> [UInt8] {
        let headingRaw = UInt16((normalise(degrees) * .pi / 180 * 1e4).rounded())
        let naI16 = littleEndian(UInt16(bitPattern: Int16.max))   // NA for a signed field
        return [0x00] + littleEndian(headingRaw) + naI16 + naI16 + [magnetic ? 0x01 : 0x00]
    }

    /// PGN 128259 — Speed, Water Referenced. Reports STW only (the ground-speed
    /// field is left NA, so SOG keeps coming from 129026).
    ///   byte 0: SID, bytes 1-2: STW (uint16, 0.01 m/s), bytes 3-4: SOG (NA),
    ///   byte 5: reference type, bytes 6-7: reserved.
    private static func speedPayload(stwKnots: Double) -> [UInt8] {
        let stwRaw = UInt16((stwKnots * knotsToMetresPerSecond * 100).rounded())
        return [0x00] + littleEndian(stwRaw) + [0xFF, 0xFF] + [0x00, 0xFF, 0xFF]
    }

    /// PGN 130306 — Wind Data.
    ///   byte 0: SID, bytes 1-2: speed (uint16, 0.01 m/s), bytes 3-4: angle
    ///   (uint16, 1e-4 rad), byte 5: reference, bytes 6-7: reserved.
    /// Reference 0 = true (north-referenced: speed = TWS, angle = TWD); 2 = apparent.
    private static func windPayload(speedKnots: Double, angleDegrees: Double, reference: UInt8) -> [UInt8] {
        let speedRaw = UInt16((speedKnots * knotsToMetresPerSecond * 100).rounded())
        let angleRaw = UInt16((normalise(angleDegrees) * .pi / 180 * 1e4).rounded())
        return [0x00] + littleEndian(speedRaw) + littleEndian(angleRaw) + [reference, 0xFF, 0xFF]
    }

    /// PGN 130314 — Actual Pressure (atmospheric source).
    ///   byte 0: SID, byte 1: instance, byte 2: source (0 = atmospheric),
    ///   bytes 3-6: pressure (int32, 0.1 Pa per LSB), byte 7: reserved.
    private static func pressurePayload(hPa: Double) -> [UInt8] {
        let raw = Int32((hPa * 1000).rounded())   // hPa → 0.1 Pa units
        return [0x00, 0x00, 0x00] + littleEndian(raw) + [0xFF]
    }

    /// PGN 127258 — Magnetic Variation.
    ///   byte 0: SID, byte 1: source (4 = WMM), bytes 2-3: age of service (NA),
    ///   bytes 4-5: variation (int16, 1e-4 rad), bytes 6-7: reserved.
    private static func variationPayload(degrees: Double) -> [UInt8] {
        let raw = Int16((degrees * .pi / 180 * 1e4).rounded())
        return [0x00, 0x04, 0xFF, 0xFF] + littleEndian(UInt16(bitPattern: raw)) + [0xFF, 0xFF]
    }

    /// PGN 127488 — Engine Parameters, Rapid Update (engine speed only).
    ///   byte 0: instance, bytes 1-2: speed (uint16, 0.25 rpm per LSB),
    ///   bytes 3-4: boost (NA), byte 5: tilt/trim (NA), bytes 6-7: reserved.
    private static func engineRapidPayload(instance: UInt8, rpm: Double) -> [UInt8] {
        let raw = UInt16(max(0, (rpm / 0.25).rounded()))
        return [instance] + littleEndian(raw) + [0xFF, 0xFF, 0x7F, 0xFF, 0xFF]
    }

    /// Normalises an angle in degrees to [0, 360).
    private static func normalise(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func littleEndian(_ value: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: value)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 24) & 0xFF)]
    }

    private static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func littleEndian(_ value: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: value)
        return (0..<8).map { UInt8(truncatingIfNeeded: u >> (8 * $0)) }
    }

    /// Encodes an angle (degrees) as a signed int16 in 1e-4 rad units, mapping to
    /// [-180, 180] so it fits the signed field.
    private static func signedRadRaw(_ degrees: Double) -> [UInt8] {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return littleEndian(UInt16(bitPattern: Int16((d * .pi / 180 * 1e4).rounded())))
    }

    // MARK: Auxiliary instrument encoders

    /// PGN 127257 — Attitude (yaw/pitch/roll, each int16 1e-4 rad).
    private static func attitudePayload(yaw: Double, pitch: Double, roll: Double) -> [UInt8] {
        [0x00] + signedRadRaw(yaw) + signedRadRaw(pitch) + signedRadRaw(roll) + [0xFF]
    }

    /// PGN 127245 — Rudder (position only; commanded angle left NA).
    private static func rudderPayload(degrees: Double) -> [UInt8] {
        let na = littleEndian(UInt16(bitPattern: Int16.max))
        return [0x00, 0xF8] + na + signedRadRaw(degrees) + [0xFF, 0xFF]
    }

    /// PGN 127251 — Rate of Turn (int32, 1/(32×10⁶) rad/s per LSB).
    private static func rateOfTurnPayload(degPerMin: Double) -> [UInt8] {
        let raw = Int32((degPerMin / 60 * .pi / 180 * 32_000_000).rounded())
        return [0x00] + littleEndian(raw) + [0xFF, 0xFF, 0xFF]
    }

    /// PGN 127489 — Engine Parameters, Dynamic (26-byte fast packet).
    private static func engineDynamicPayload(instance: UInt8, n: Double) -> [UInt8] {
        var d = [UInt8](repeating: 0xFF, count: 26)
        d[0] = instance
        func put(_ bytes: [UInt8], at: Int) { for (k, b) in bytes.enumerated() { d[at + k] = b } }
        put(littleEndian(UInt16((2800 + 60 * sin(n * 0.04)).rounded())), at: 1)            // oil pressure (×100 Pa)
        put(littleEndian(UInt16(((95 + 3 * sin(n * 0.01) + 273.15) / 0.1).rounded())), at: 3) // oil temp (0.1 K)
        put(littleEndian(UInt16(((82 + 2 * sin(n * 0.012) + 273.15) / 0.01).rounded())), at: 5) // coolant temp (0.01 K)
        put(littleEndian(UInt16(bitPattern: Int16(((14.2 + 0.1 * sin(n * 0.05)) / 0.01).rounded()))), at: 7) // alt voltage
        put(littleEndian(UInt16(bitPattern: Int16(((11 + 2 * sin(n * 0.03)) / 0.1).rounded()))), at: 9)       // fuel rate
        put(littleEndian(UInt32(5_220_000 + (instance == 0 ? 0 : 180_000))), at: 11)        // engine hours (s)
        d[24] = UInt8(bitPattern: Int8((62 + 8 * sin(n * 0.02)).rounded()))                  // load %
        d[25] = UInt8(bitPattern: Int8((58 + 6 * sin(n * 0.018)).rounded()))                 // torque %
        return d
    }

    /// PGN 129029 — GNSS Position Data (43-byte fast packet).
    private static func gnssPositionPayload(_ p: GeoPoint, n: Double) -> [UInt8] {
        var d = [UInt8](repeating: 0xFF, count: 43)
        d[0] = 0x00
        func put(_ bytes: [UInt8], at: Int) { for (k, b) in bytes.enumerated() { d[at + k] = b } }
        put(littleEndian(Int64((p.latitude * 1e16).rounded())), at: 7)
        put(littleEndian(Int64((p.longitude * 1e16).rounded())), at: 15)
        put(littleEndian(Int64((3.0 * 1e6).rounded())), at: 23)     // antenna altitude ~3 m
        d[31] = (1 << 4)                                            // method = 1 (GNSS fix)
        d[32] = 0x00
        d[33] = 11                                                  // satellites
        put(littleEndian(UInt16(bitPattern: Int16(((0.8 + 0.2 * sin(n * 0.02)) / 0.01).rounded()))), at: 34) // HDOP
        put(littleEndian(UInt16(bitPattern: Int16(((1.5 + 0.3 * sin(n * 0.015)) / 0.01).rounded()))), at: 36) // PDOP
        put(littleEndian(Int32((47.0 / 0.01).rounded())), at: 38)   // geoidal separation
        return d
    }

    /// PGN 129539 — GNSS DOPs (HDOP/VDOP/TDOP + 3D mode).
    private static func gnssDopsPayload(n: Double) -> [UInt8] {
        func dop(_ v: Double) -> [UInt8] { littleEndian(UInt16(bitPattern: Int16((v / 0.01).rounded()))) }
        return [0x00, UInt8(3 << 3)]   // operating mode = 3 (3D)
            + dop(0.8 + 0.2 * sin(n * 0.02))
            + dop(1.1 + 0.2 * sin(n * 0.018))
            + dop(0.9)
    }

    /// PGN 126992 — System Time (now, from the GPS source).
    private static func systemTimePayload() -> [UInt8] {
        let now = Date().timeIntervalSince1970
        let days = UInt16(now / 86_400)
        let timeRaw = UInt32(((now - Double(days) * 86_400) * 10_000).rounded())
        return [0x00, 0x00] + littleEndian(days) + littleEndian(timeRaw)
    }

    /// Satellites-in-view: a `gsvReport` plus the SNR summary metrics that
    /// PGN 129540 would yield, built directly (its decode path is frame-based).
    private static func satellitesInView(n: Double) -> [NMEAFrame] {
        let count = 11
        var sats: [SatelliteInfo] = []
        var snrs: [Double] = []
        for i in 0..<count {
            let snr = 40 + 6 * sin(n * 0.01 + Double(i) * 0.7)
            sats.append(SatelliteInfo(prn: i + 1, elevation: 15 + i * 6,
                                      azimuth: (i * 33) % 360, snr: Int(snr.rounded())))
            snrs.append(snr)
        }
        let avg = snrs.reduce(0, +) / Double(snrs.count)
        return [
            .gsvReport(constellation: "GPS", inView: count, satellites: sats),
            .metric(.init(name: "gps.satellites.inView", value: Double(count))),
            .metric(.init(name: "gps.snr.avg", value: avg, unit: "dB")),
            .metric(.init(name: "gps.snr.max", value: snrs.max() ?? 0, unit: "dB")),
            .metric(.init(name: "gps.snr.min", value: snrs.min() ?? 0, unit: "dB")),
        ]
    }

    /// PGN 127505 — Fluid Level (instance + tank type in the first byte).
    private static func fluidLevelPayload(instance: UInt8, type: UInt8,
                                          level: Double, capacityL: Double) -> [UInt8] {
        let head = (type << 4) | (instance & 0x0F)
        let lvl = littleEndian(UInt16(bitPattern: Int16((level / 0.004).rounded())))
        return [head] + lvl + littleEndian(UInt32((capacityL / 0.1).rounded())) + [0xFF]
    }

    /// Emits a battery's status (127508) and its state of charge (127506).
    private static func emitBattery(
        instance: UInt8, voltage: Double, current: Double, soc: Double,
        into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        let v = littleEndian(UInt16((voltage / 0.01).rounded()))
        let i = littleEndian(UInt16(bitPattern: Int16((current / 0.1).rounded())))
        let t = littleEndian(UInt16(((24.0 + 273.15) / 0.01).rounded()))
        yieldFrame(pgn: 127508, data: [instance] + v + i + t + [0xFF], into: continuation)

        let socByte = UInt8(max(0, min(100, soc.rounded())))
        yieldFrame(pgn: 127506,
                   data: [0x00, instance, 0x00, socByte, 0x64] + littleEndian(UInt16(0xFFFF)) + [0xFF],
                   into: continuation)
    }

    /// PGN 130312 — Temperature (instance + source; set-point left NA).
    private static func temperaturePayload(instance: UInt8, source: UInt8, celsius: Double) -> [UInt8] {
        let raw = littleEndian(UInt16(((celsius + 273.15) / 0.01).rounded()))
        return [0x00, instance, source] + raw + littleEndian(UInt16(0xFFFF)) + [0xFF]
    }

    /// PGN 128777 — Windlass Operating Status (anchor docked/up or deployed).
    private static func windlassOperatingPayload(anchorUp: Bool) -> [UInt8] {
        let docking: UInt8 = anchorUp ? 1 : 2          // bits 4-5
        let status = (docking << 4) | (1 << 2) | 1     // rode = chain (bits 2-3), motion = stopped
        return [0x00] + littleEndian(UInt16(0)) + [0x00, status, 0xFF]
    }

    /// PGN 128778 — Windlass Monitoring Status (motor hours/voltage/current).
    private static func windlassMonitoringPayload() -> [UInt8] {
        [0x00, 0x2A] + littleEndian(UInt16((12.4 / 0.01).rounded())) + littleEndian(UInt16(0)) + [0xFF]
    }

    /// PGN 128275 — Distance Log (total + trip, metres on the wire).
    /// PGN 128267 — Water Depth (below transducer; offset/range left NA). Reuses
    /// the existing `depth` metric.
    private static func depthPayload(metres: Double) -> [UInt8] {
        let na16 = littleEndian(UInt16(bitPattern: Int16.max))
        return [0x00] + littleEndian(UInt32((metres / 0.01).rounded())) + na16 + [0xFF]
    }

    /// PGN 130311 — Environmental w/ Humidity. Only the `humidity` field is
    /// populated (temperature and pressure left NA — they come from 130312/130314).
    private static func humidityPayload(percent: Double) -> [UInt8] {
        let na16 = littleEndian(UInt16(0xFFFF))
        let hum = littleEndian(UInt16(bitPattern: Int16((percent / 0.004).rounded())))
        return [0x00, 0x00] + na16 + hum + na16
    }

    /// PGN 130323 — Meteorological Station. Only the gust field is populated, so
    /// it reaches the existing `TWS.gust` metric without overriding live wind.
    private static func gustPayload(gustKnots: Double) -> [UInt8] {
        var d = [UInt8](repeating: 0xFF, count: 26)
        d[0] = 0x00
        let gust = littleEndian(UInt16((gustKnots * knotsToMetresPerSecond * 100).rounded()))
        d[20] = gust[0]; d[21] = gust[1]
        return d
    }

    private static func distanceLogPayload(totalNM: Double, tripNM: Double) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6)
            + littleEndian(UInt32((totalNM * 1852).rounded()))
            + littleEndian(UInt32((tripNM * 1852).rounded()))
    }

    // MARK: Navigation / autopilot

    /// Emits the active-waypoint navigation data (129284) and cross-track error
    /// (129283) for the leg currently being sailed.
    private static func emitNavigation(
        position: GeoPoint, target: GeoPoint, course: Double, speedKnots: Double,
        remainingMetres: Double, tick: Int,
        into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        yieldFrame(pgn: 129284, data: navigationDataPayload(
            target: target, distanceMetres: remainingMetres, bearing: course,
            speedKnots: speedKnots), into: continuation)
        yieldFrame(pgn: 129283, data: crossTrackErrorPayload(
            metres: 40 * sin(Double(tick) * 0.03)), into: continuation)
    }

    /// PGN 129284 — Navigation Data (35-byte fast packet): distance, ETA,
    /// bearings, destination waypoint position and VMG.
    private static func navigationDataPayload(
        target: GeoPoint, distanceMetres: Double, bearing: Double, speedKnots: Double
    ) -> [UInt8] {
        var d = [UInt8](repeating: 0xFF, count: 35)
        d[0] = 0x00
        func put(_ bytes: [UInt8], at: Int) { for (k, b) in bytes.enumerated() { d[at + k] = b } }
        put(littleEndian(UInt32((distanceMetres / 0.01).rounded())), at: 1)
        d[5] = 0; d[6] = 0
        // ETA at present speed.
        let speedMps = max(0.1, speedKnots * knotsToMetresPerSecond)
        let eta = Date().timeIntervalSince1970 + distanceMetres / speedMps
        let days = UInt16(eta / 86_400)
        put(littleEndian(UInt32(((eta - Double(days) * 86_400) * 10_000).rounded())), at: 7)
        put(littleEndian(days), at: 11)
        let brg = littleEndian(UInt16((normalise(bearing) * .pi / 180 * 1e4).rounded()))
        put(brg, at: 13)
        put(brg, at: 15)
        put(littleEndian(Int32((target.latitude * 1e7).rounded())), at: 25)
        put(littleEndian(Int32((target.longitude * 1e7).rounded())), at: 29)
        put(littleEndian(UInt16(bitPattern: Int16((speedKnots / 1.94384 / 0.01).rounded()))), at: 33)
        return d
    }

    /// PGN 129283 — Cross Track Error (int32, 0.01 m per LSB).
    private static func crossTrackErrorPayload(metres: Double) -> [UInt8] {
        [0x00, 0x00] + littleEndian(Int32((metres / 0.01).rounded())) + [0xFF, 0xFF]
    }

    // MARK: AIS traffic

    /// A vessel in the synthetic AIS picture.
    private struct AISShip: Sendable {
        let mmsi: Int
        let name: String
        let type: ShipType
        let classB: Bool
        let start: GeoPoint
        let course: Double
        let speed: Double
    }

    /// A spread of traffic along the Gibraltar→Genoa corridor and around Corsica.
    /// MMSIs are fictitious — a real maritime ID (MID) flag prefix padded with 9s
    /// — so they never collide with a real vessel.
    private static let aisFleet: [AISShip] = [
        // Western corridor (Gibraltar → Ligurian Sea).
        AISShip(mmsi: 224_990_011, name: "CABO FINISTERRE", type: .cargo, classB: false,
                start: GeoPoint(latitude: 36.10, longitude: -5.20), course: 62, speed: 14.5),
        AISShip(mmsi: 256_990_021, name: "MELITA STAR", type: .cargo, classB: false,
                start: GeoPoint(latitude: 37.40, longitude: -1.80), course: 58, speed: 13.0),
        AISShip(mmsi: 247_990_031, name: "GOLFO DI NAPOLI", type: .passenger, classB: false,
                start: GeoPoint(latitude: 38.90, longitude: 2.40), course: 55, speed: 18.0),
        AISShip(mmsi: 228_990_041, name: "MARSEILLE EXPRESS", type: .cargo, classB: false,
                start: GeoPoint(latitude: 41.20, longitude: 5.10), course: 70, speed: 16.0),
        AISShip(mmsi: 636_990_051, name: "ATLANTIC PIONEER", type: .cargo, classB: false,
                start: GeoPoint(latitude: 42.60, longitude: 7.20), course: 75, speed: 15.5),
        AISShip(mmsi: 538_990_061, name: "PACIFIC ENVOY", type: .cargo, classB: false,
                start: GeoPoint(latitude: 43.50, longitude: 8.40), course: 248, speed: 14.0),
        // Around Corsica and the Ligurian / Tyrrhenian, near the passage.
        AISShip(mmsi: 247_990_071, name: "CORSICA VICTORIA", type: .passenger, classB: false,
                start: GeoPoint(latitude: 42.70, longitude: 9.45), course: 200, speed: 21.0),
        AISShip(mmsi: 228_990_081, name: "MEDITERRANEE", type: .passenger, classB: false,
                start: GeoPoint(latitude: 41.90, longitude: 8.74), course: 20, speed: 19.0),
        AISShip(mmsi: 247_990_091, name: "ALERIA", type: .cargo, classB: false,
                start: GeoPoint(latitude: 42.10, longitude: 9.65), course: 350, speed: 11.0),
        AISShip(mmsi: 247_990_101, name: "SAN ROCCO", type: .fishing, classB: true,
                start: GeoPoint(latitude: 41.60, longitude: 9.30), course: 120, speed: 6.5),
        AISShip(mmsi: 228_990_111, name: "BONIFACIO", type: .highSpeedCraft, classB: false,
                start: GeoPoint(latitude: 41.38, longitude: 9.16), course: 300, speed: 28.0),
        AISShip(mmsi: 247_990_121, name: "MAGDALENA", type: .sailing, classB: true,
                start: GeoPoint(latitude: 41.30, longitude: 9.45), course: 280, speed: 5.5),
        AISShip(mmsi: 228_990_131, name: "VENT D'EST", type: .sailing, classB: true,
                start: GeoPoint(latitude: 42.30, longitude: 8.10), course: 160, speed: 6.0),
        AISShip(mmsi: 247_990_141, name: "TIRRENO", type: .cargo, classB: false,
                start: GeoPoint(latitude: 41.00, longitude: 9.80), course: 15, speed: 13.5),
        AISShip(mmsi: 256_990_151, name: "VALLETTA PRIDE", type: .cargo, classB: false,
                start: GeoPoint(latitude: 40.50, longitude: 9.20), course: 5, speed: 14.0),
        AISShip(mmsi: 227_990_161, name: "NICE LA BELLE", type: .passenger, classB: false,
                start: GeoPoint(latitude: 43.50, longitude: 7.40), course: 130, speed: 17.5),
        AISShip(mmsi: 247_990_171, name: "LIBECCIO", type: .tug, classB: true,
                start: GeoPoint(latitude: 43.00, longitude: 9.50), course: 210, speed: 8.0),
        AISShip(mmsi: 228_990_181, name: "PILOTE CORSE", type: .pilotVessel, classB: true,
                start: GeoPoint(latitude: 41.92, longitude: 8.72), course: 250, speed: 9.0),
    ]

    /// Emits the moving AIS fleet plus the occasional non-vessel message (base
    /// station, AtoN, safety broadcast, SART, binary/weather broadcast).
    private static func emitAIS(
        passageSeconds: Double, tick: Int,
        into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        for ship in aisFleet {
            let pos = destination(from: ship.start,
                                  distanceMetres: ship.speed * knotsToMetresPerSecond * passageSeconds,
                                  bearingDegrees: ship.course)
            continuation.yield(.aisTarget(AISTarget(
                mmsi: ship.mmsi,
                messageType: ship.classB ? .standardClassBReport : .positionReportClassA,
                channel: ship.classB ? "B" : "A",
                latitude: pos.latitude, longitude: pos.longitude,
                speedOverGround: ship.speed, courseOverGround: ship.course,
                trueHeading: Int(ship.course.rounded()),
                navigationStatus: ship.classB ? nil : .underWayUsingEngine,
                shipName: ship.name, shipType: ship.type)))
        }
        emitAISEvents(tick: tick, into: continuation)
    }

    /// Periodic non-vessel AIS messages, staggered so they trickle in like a real
    /// receiver — the kinds the journal logs as Base station / Safety / SART, etc.
    private static func emitAISEvents(
        tick: Int, into continuation: AsyncThrowingStream<NMEAFrame, any Error>.Continuation
    ) {
        // Base stations (MMSI 00MIDxxxx) — coastal, fixed.
        if tick % 30 == 3 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 2_270_100, messageType: .baseStationReport, channel: "A",
                latitude: 43.74, longitude: 7.42)))                        // Monaco
        }
        if tick % 37 == 11 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 2_471_200, messageType: .baseStationReport, channel: "B",
                latitude: 41.92, longitude: 8.74)))                        // Ajaccio
        }
        // Aid to navigation (MMSI 99MIDxxxx) — a special-mark buoy.
        if tick % 40 == 7 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 992_476_010, messageType: .aidToNavigationReport, channel: "A",
                latitude: 41.39, longitude: 9.18, shipName: "BONIFACIO SW",
                navAidType: .buoySafeWater)))
        }
        // Safety broadcast — free-text securité message, like a coast station.
        if tick % 53 == 19 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 247_990_500, messageType: .safetyBroadcastMessage, channel: "A",
                text: "SECURITE NAVAL EXERCISE 4208N 00830E WIDE BERTH REQUESTED")))
        }
        // Binary / weather broadcast — carries a short meteo bulletin as text.
        if tick % 67 == 23 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 2_270_300, messageType: .binaryBroadcastMessage, channel: "A",
                latitude: 43.40, longitude: 7.90,
                text: "WX WNW 18KT GUST 24 1014HPA SEA MODERATE")))
        }
        // SART / distress (MMSI 970xxxxxx) — rare.
        if tick % 131 == 64 {
            continuation.yield(.aisTarget(AISTarget(
                mmsi: 970_010_119, messageType: .positionReportClassA, channel: "A",
                latitude: 42.40, longitude: 8.60,
                speedOverGround: 0, courseOverGround: 0)))
        }
    }

    // MARK: Tank / battery / temperature models

    static func tankFuel(_ n: Double) -> Double { max(5, 82 - n * 0.0006) }
    static func tankFreshWater(_ n: Double) -> Double { max(8, 68 - n * 0.0004) }
    static func tankBlackWater(_ n: Double) -> Double { min(95, 12 + n * 0.0005) }
    static func tankGreyWater(_ n: Double) -> Double { min(92, 20 + n * 0.00045) }

    static func engineBatteryVoltage(_ n: Double) -> Double { 13.6 + 0.15 * sin(n * 0.02) }
    static func serviceSOC(_ n: Double) -> Double { max(25, 100 - n * 0.02) }
    static func serviceVoltage(_ n: Double) -> Double { 23.4 + serviceSOC(n) / 100 * 2.6 }
    static func solarSOC(_ n: Double) -> Double { 86 + 4 * sin(n * 0.001) }
    static func solarCurrent(_ n: Double) -> Double { max(0, 9 + 6 * sin(n * 0.004)) }

    static func seaTemperature(_ n: Double) -> Double { 18 + 1.5 * sin(n * 0.0008) }
    static func airTemperature(_ n: Double) -> Double { 22 + 3 * sin(n * 0.0006) }

    // MARK: Navigation maths

    /// Converts a `Duration` to seconds as a `Double`.
    private static func seconds(of duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    /// Great-circle distance between two points, in metres (haversine).
    private static func distanceMetres(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return earthRadius * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Initial great-circle bearing from `a` to `b`, in degrees (0…360, true).
    private static func bearingDegrees(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached by travelling `distanceMetres` from `origin` on a true
    /// `bearingDegrees` great-circle course.
    private static func destination(
        from origin: GeoPoint, distanceMetres: Double, bearingDegrees: Double
    ) -> GeoPoint {
        let δ = distanceMetres / earthRadius
        let θ = bearingDegrees * .pi / 180
        let φ1 = origin.latitude * .pi / 180
        let λ1 = origin.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }
}
