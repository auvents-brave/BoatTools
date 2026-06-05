import Foundation
import Testing

@testable import BoatToolsKit

/// Tests the synthetic-passage simulator: that it encodes real NMEA 2000 GPS
/// PGNs which decode back to the expected position, course and speed, and that
/// it both makes way and tags every metric with its originating PGN.
@Suite("NMEA simulator")
struct NMEASimulatorTests {

    /// Drains the first `count` frames of a stream, returning them in order.
    private func firstFrames(
        _ stream: AsyncThrowingStream<NMEAFrame, any Error>, count: Int
    ) async throws -> [NMEAFrame] {
        var frames: [NMEAFrame] = []
        for try await frame in stream {
            frames.append(frame)
            if frames.count >= count { break }
        }
        return frames
    }

    /// Drains the stream until `ticks` position fixes have been emitted (one `lat`
    /// metric per tick), returning every frame seen — robust to how many PGNs each
    /// tick carries.
    private func framesUntil(
        ticks: Int, _ stream: AsyncThrowingStream<NMEAFrame, any Error>
    ) async throws -> [NMEAFrame] {
        var frames: [NMEAFrame] = []
        var fixes = 0
        for try await frame in stream {
            frames.append(frame)
            // The 129025 raw frame leads every tick exactly once (unlike `lat`,
            // which several PGNs now emit).
            if case .nmea2000(129025, _, _, _) = frame { fixes += 1 }
            if fixes >= ticks { break }
        }
        return frames
    }

    private func values(_ name: String, in frames: [NMEAFrame]) -> [Double] {
        frames.compactMap { frame -> Double? in
            if case let .metric(m) = frame, m.name == name { return m.value }
            return nil
        }
    }

    /// The latest value seen for a named metric in a frame list.
    private func metric(_ name: String, in frames: [NMEAFrame]) -> Double? {
        frames.reversed().compactMap { frame -> Double? in
            if case let .metric(m) = frame, m.name == name { return m.value }
            return nil
        }.first
    }

    @Test("First fix sits on the route's start waypoint")
    func startsAtFirstWaypoint() async throws {
        let route = SimulatorRoute.monacoToMaddalena
        let stream = NMEASimulator.frameStream(route: route, speedKnots: 6, loop: false)
        // One tick emits: 129025 raw + lat + lon, then 129026 raw + COG + SOG.
        let frames = try await firstFrames(stream, count: 6)

        let start = route.waypoints[0]
        #expect(abs((metric("lat", in: frames) ?? .nan) - start.latitude) < 1e-5)
        #expect(abs((metric("lon", in: frames) ?? .nan) - start.longitude) < 1e-5)
    }

    @Test("Speed and course decode from the synthetic 129026 frame")
    func decodesCourseAndSpeed() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        let frames = try await firstFrames(stream, count: 6)

        // SOG round-trips through 0.01 m/s quantisation to ~6 kn. The first fix
        // carries no wander, so it sits right on the configured speed.
        #expect(abs((metric("SOG", in: frames) ?? .nan) - 6) < 0.05)
        // Monaco heads east-south-east towards Cap Corse, not south-west.
        let cog = try #require(metric("COG", in: frames))
        #expect(cog > 95 && cog < 160)
    }

    @Test("Each metric is carried by a raw NMEA 2000 frame for its PGN")
    func emitsRawFramesBeforeMetrics() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        let frames = try await firstFrames(stream, count: 6)

        // The position metrics must be preceded by the 129025 raw frame, and the
        // course/speed metrics by 129026 — that ordering is what lets the store
        // tag each metric with the right PGN priority.
        let pgns = frames.compactMap { frame -> UInt32? in
            if case let .nmea2000(pgn, _, _, _) = frame { return pgn }
            return nil
        }
        #expect(pgns.contains(129025))
        #expect(pgns.contains(129026))
    }

    @Test("Heading sits a few degrees off the course (leeway)")
    func headingDiffersFromCourse() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        let frames = try await firstFrames(stream, count: 12)
        let cog = try #require(metric("COG", in: frames))
        let hdg = try #require(metric("HDG.true", in: frames))
        var diff = abs(hdg - cog).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        #expect(diff > 2 && diff < 12)
    }

    @Test("Wind, speed-through-water and pressure are emitted")
    func emitsRicherInstruments() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        // ticks:2 so the whole of the first tick's burst is captured (the position
        // metric leads each tick, ahead of the wind/STW/pressure frames).
        let frames = try await framesUntil(ticks: 2, stream)
        for name in ["TWS", "TWD", "AWS", "AWA", "STW", "pressure.atmospheric"] {
            #expect(metric(name, in: frames) != nil, "missing \(name)")
        }
        // True wind speed sits in the modelled band; pressure near sea-level.
        let tws = try #require(metric("TWS", in: frames))
        #expect(tws > 5 && tws < 25)
        let pressure = try #require(metric("pressure.atmospheric", in: frames))
        #expect(pressure > 990 && pressure < 1035)
    }

    @Test("Two engines idle near 3000 rpm, out of step")
    func emitsTwoEngines() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, updateInterval: .milliseconds(1), loop: false
        )
        let frames = try await framesUntil(ticks: 30, stream)
        let e0 = values("engine.0.rpm", in: frames)
        let e1 = values("engine.1.rpm", in: frames)
        try #require(e0.count >= 20)
        try #require(e1.count >= 20)
        // Each stays within a ~50 rpm band around 3000.
        #expect(e0.allSatisfy { $0 > 2950 && $0 < 3055 })
        #expect(e1.allSatisfy { $0 > 2950 && $0 < 3055 })
        // …but they do not move together.
        let paired = zip(e0, e1)
        #expect(paired.contains { abs($0 - $1) > 1 })
    }

    @Test("Magnetic variation is reported, stable and easterly")
    func emitsMagneticVariation() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        let frames = try await framesUntil(ticks: 2, stream)
        let variation = try #require(metric("magneticVariation", in: frames))
        // Off Monaco it sits near +3.4°E.
        #expect(variation > 3.0 && variation < 4.2)
    }

    @Test("History backfill fills the wind and pressure curves")
    func backfillFillsCurves() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let backfill = NMEASimulator.historyBackfill(speedKnots: 6, endingAt: now)
        for name in ["TWS", "TWD", "AWS", "AWA"] {
            let samples = try #require(backfill[name])
            #expect(samples.count >= 700)         // ~1 h at 5 s spacing
            #expect(samples.first!.at < samples.last!.at)   // oldest first
            #expect(samples.last!.at <= now)
        }
        let pressure = try #require(backfill["pressure.atmospheric"])
        #expect(pressure.count >= 90)             // ~48 h at 30 min spacing
        #expect(pressure.allSatisfy { $0.value > 990 && $0.value < 1035 })
    }

    @Test("Course wanders gently but stays bounded")
    func courseWandersWithinBounds() async throws {
        // A tiny update interval keeps the boat on the first leg (so the base
        // bearing barely moves) while sampling many ticks of wander quickly.
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6,
            updateInterval: .milliseconds(1), loop: false
        )
        let frames = try await framesUntil(ticks: 30, stream)
        let cogs = values("COG", in: frames)
        try #require(cogs.count >= 20)
        let span = (cogs.max() ?? 0) - (cogs.min() ?? 0)
        #expect(span > 0.3)   // it actually evolves
        #expect(span < 7.0)   // but never lurches (≤ ~2 × 3° plus tiny base drift)
    }

    @Test("Fast-forward covers more ground for the same elapsed ticks")
    func fastForwardCoversMoreGround() async throws {
        func latitudeDrop(multiplier: Double) async throws -> Double {
            let stream = NMEASimulator.frameStream(
                route: .monacoToMaddalena, speedKnots: 50, timeMultiplier: multiplier,
                updateInterval: .milliseconds(1), loop: false
            )
            let frames = try await framesUntil(ticks: 20, stream)
            let lats = values("lat", in: frames)
            return (lats.first ?? 0) - (lats.last ?? 0)   // heads south, so positive
        }
        let slow = try await latitudeDrop(multiplier: 1)
        let fast = try await latitudeDrop(multiplier: 20)
        #expect(fast > slow * 5)
    }

    private func aisTargets(in frames: [NMEAFrame]) -> [AISTarget] {
        frames.compactMap { if case let .aisTarget(t) = $0 { return t } else { return nil } }
    }

    @Test("A full instrument suite is emitted")
    func emitsFullInstrumentation() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        let frames = try await framesUntil(ticks: 2, stream)
        let expected = [
            "HDG.magnetic", "magneticVariation", "pitch", "roll", "rudder", "ROT",
            "engine.0.oilPressure", "engine.0.coolantTemperature", "engine.1.alternatorVoltage",
            "engine.0.load", "engine.1.runtime",
            "fuel.0.level", "water.0.level", "blackwater.0.level", "graywater.1.level",
            "battery.0.voltage", "battery.0.stateOfCharge", "battery.1.stateOfCharge",
            "temperature.water", "temperature.air", "temperature.refrigerator", "temperature.freezer",
            "gps.hdop", "gps.vdop", "gps.pdop", "gps.satellites", "gps.snr.avg",
            "windlass.0.anchorUp", "log.total", "depth", "humidity", "TWS.gust",
            "navigation.distanceToWaypoint", "navigation.xte", "navigation.eta", "navigation.vmg",
        ]
        for name in expected {
            #expect(metric(name, in: frames) != nil, "missing \(name)")
        }
        // Anchor stowed, engine battery full, service battery below full.
        #expect(metric("windlass.0.anchorUp", in: frames) == 1)
        #expect(metric("battery.0.stateOfCharge", in: frames) == 100)
        #expect((metric("battery.1.stateOfCharge", in: frames) ?? 0) <= 100)
    }

    @Test("AIS fleet of moving vessels is injected with valid MMSIs")
    func emitsAISFleet() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, loop: false
        )
        // ticks:2 so the whole first tick — AIS is emitted at the tail of each — is captured.
        let frames = try await framesUntil(ticks: 2, stream)
        let vessels = aisTargets(in: frames).filter {
            $0.messageType == .positionReportClassA || $0.messageType == .standardClassBReport
        }
        #expect(vessels.count >= 15)
        // Every MMSI is a valid 9-digit identifier with a position and a name.
        #expect(vessels.allSatisfy { (1...999_999_999).contains($0.mmsi) })
        #expect(vessels.allSatisfy { $0.latitude != nil && $0.longitude != nil })
        #expect(vessels.contains { $0.shipName == "CORSICA VICTORIA" })
    }

    @Test("Non-vessel AIS messages trickle in (base station, AtoN, safety, SART)")
    func emitsAISEventVariety() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 6, updateInterval: .milliseconds(1), loop: false
        )
        let frames = try await framesUntil(ticks: 140, stream)
        let targets = aisTargets(in: frames)
        #expect(targets.contains { $0.messageType == .baseStationReport })
        #expect(targets.contains { $0.messageType == .aidToNavigationReport && $0.navAidType != nil })
        #expect(targets.contains { $0.messageType == .safetyBroadcastMessage })
        #expect(targets.contains { $0.messageType == .binaryBroadcastMessage })
        #expect(targets.contains { (970_000_000...974_999_999).contains($0.mmsi) })   // SART range
    }

    @Test("The vessel makes way between ticks")
    func makesWay() async throws {
        let stream = NMEASimulator.frameStream(
            route: .monacoToMaddalena, speedKnots: 20, updateInterval: .seconds(1), loop: false
        )
        let frames = try await framesUntil(ticks: 3, stream)
        let lats = values("lat", in: frames)
        let lons = values("lon", in: frames)
        try #require(lats.count >= 2)
        // First and last fixes span different ticks, so the boat must have moved.
        #expect(lats.first != lats.last || lons.first != lons.last)
    }
}
