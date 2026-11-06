import Testing

@testable import BoatToolsKit

/// Unit tests for ``NMEA2000Decoder`` on a representative set of PGNs.
///
/// Each test invents a byte payload, feeds it through ``NMEA2000Decoder/decode(pgn:data:)``
/// and checks the resulting ``BoatMetric`` values against the values that went in.
@Suite("NMEA 2000 decoder")
struct NMEA2000Tests {

	/// Encodes a fixed-width integer as little-endian bytes.
	private static func leBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
		withUnsafeBytes(of: value.littleEndian) { Array($0) }
	}

	/// PGN 129285 — Navigation Route / WP Information: route and waypoint names.
	@Test func `PGN 129285 — route and waypoint names`() throws {
		func varString(_ s: String) -> [UInt8] {
			[UInt8(s.utf8.count + 2), 1] + Array(s.utf8)
		}
		var data: [UInt8] = []
		data += Self.leBytes(UInt16(0))  // start RPS
		data += Self.leBytes(UInt16(2))  // 2 waypoints in this message
		data += Self.leBytes(UInt16(1))  // database id
		data += Self.leBytes(UInt16(1))  // route id
		data.append(0)  // direction + flags
		data += varString("CORSICA")
		data.append(0xFF)  // reserved
		data += Self.leBytes(UInt16(3)) + varString("NICE") + [UInt8](repeating: 0, count: 8)
		data += Self.leBytes(UInt16(4)) + varString("CALVI") + [UInt8](repeating: 0, count: 8)

		let info = try #require(NMEA2000Decoder.routeInfo(data))
		#expect(info.route == "CORSICA")
		#expect(info.waypoints[3] == "NICE")
		#expect(info.waypoints[4] == "CALVI")
	}

	/// PGN 129284 — the origin / destination waypoint numbers (bytes 16-23).
	@Test func `PGN 129284 — waypoint numbers decode and honour not-available`() {
		var data = [UInt8](repeating: 0xFF, count: 34)
		for (k, b) in Self.leBytes(UInt32(2)).enumerated() { data[16 + k] = b }
		for (k, b) in Self.leBytes(UInt32(3)).enumerated() { data[20 + k] = b }
		let numbers = NMEA2000Decoder.navigationWaypointNumbers(data)
		#expect(numbers.origin == 2)
		#expect(numbers.destination == 3)

		let unavailable = NMEA2000Decoder.navigationWaypointNumbers([UInt8](repeating: 0xFF, count: 34))
		#expect(unavailable.origin == nil)
		#expect(unavailable.destination == nil)
	}

	/// PGN 129284 laid out as the standard has it: the four flag fields share
	/// byte 5. They used to be read as two, which pushed every later field a
	/// byte along and put the closing velocity past the end of the 34-byte
	/// message, so the VMG never decoded at all.
	@Test func `PGN 129284 — bearings, destination and VMG sit where the standard puts them`()
		throws
	{
		var d = [UInt8](repeating: 0xFF, count: 34)
		d[0] = 0  // SID
		func put(_ bytes: [UInt8], at: Int) { for (k, b) in bytes.enumerated() { d[at + k] = b } }
		put(Self.leBytes(UInt32(185_200)), at: 1)  // 1852 m = 1 NM
		d[5] = 0  // the single flags byte
		put(Self.leBytes(UInt16((90.0 * .pi / 180 * 1e4).rounded())), at: 12)  // origin → dest
		put(Self.leBytes(UInt16((45.0 * .pi / 180 * 1e4).rounded())), at: 14)  // position → dest
		put(Self.leBytes(Int32(43_295_000)), at: 24)  // 4.3295° N
		put(Self.leBytes(Int32(5_365_000)), at: 28)  // 0.5365° E
		put(Self.leBytes(Int16(515)), at: 32)  // 5.15 m/s ≈ 10 kn

		let m = try #require(NMEA2000Decoder.decode(pgn: 129284, data: d))
		func value(_ name: String) throws -> Double {
			try #require(m.first { $0.name == name }?.value)
		}
		#expect(abs(try value("navigation.distanceToWaypoint") - 1.0) < 1e-6)
		#expect(abs(try value("navigation.bearingOriginToDest") - 90.0) < 0.01)
		#expect(abs(try value("navigation.bearingToDest") - 45.0) < 0.01)
		#expect(abs(try value("waypoint.lat") - 4.3295) < 1e-6)
		#expect(abs(try value("waypoint.lon") - 0.5365) < 1e-6)
		#expect(abs(try value("navigation.vmg") - 10.011) < 0.01)  // 515 × 0.01 m/s, quantised
	}

	/// PGN 129291 — the dedicated, fast-cadence current message.
	@Test func `PGN 129291 — set and drift`() throws {
		var d = [UInt8](repeating: 0xFF, count: 8)
		d[0] = 0
		d[1] = 0  // set reference: true
		for (k, b) in Self.leBytes(UInt16((225.0 * .pi / 180 * 1e4).rounded())).enumerated() {
			d[2 + k] = b
		}
		for (k, b) in Self.leBytes(UInt16(103)).enumerated() { d[4 + k] = b }  // 1.03 m/s ≈ 2 kn

		let m = try #require(NMEA2000Decoder.decode(pgn: 129291, data: d))
		let set = try #require(m.first { $0.name == "navigation.currentSet" })
		let drift = try #require(m.first { $0.name == "navigation.currentDrift" })
		#expect(abs(set.value - 225.0) < 0.01)
		#expect(set.unit == "°")
		#expect(abs(drift.value - 2.0) < 0.01)
		#expect(drift.unit == "kn")
	}

	/// PGN 129291 with a magnetic reference keeps the value out of the true slot.
	@Test func `PGN 129291 — a magnetic set is named as such`() throws {
		var d = [UInt8](repeating: 0xFF, count: 8)
		d[0] = 0
		d[1] = 1  // set reference: magnetic
		for (k, b) in Self.leBytes(UInt16((90.0 * .pi / 180 * 1e4).rounded())).enumerated() {
			d[2 + k] = b
		}
		let m = try #require(NMEA2000Decoder.decode(pgn: 129291, data: d))
		#expect(m.contains { $0.name == "navigation.currentSet.magnetic" })
		#expect(!m.contains { $0.name == "navigation.currentSet" })
	}

	/// PGN 130577 — both velocity vectors and the current between them.
	@Test func `PGN 130577 — direction data carries six quantities`() throws {
		var d = [UInt8](repeating: 0xFF, count: 14)
		d[0] = 0  // data mode + COG reference (true)
		d[1] = 0  // SID
		func put(_ bytes: [UInt8], at: Int) { for (k, b) in bytes.enumerated() { d[at + k] = b } }
		func radians(_ degrees: Double) -> [UInt8] {
			Self.leBytes(UInt16((degrees * .pi / 180 * 1e4).rounded()))
		}
		put(radians(100), at: 2)  // COG
		put(Self.leBytes(UInt16(309)), at: 4)  // SOG 3.09 m/s ≈ 6 kn
		put(radians(95), at: 6)  // heading
		put(Self.leBytes(UInt16(257)), at: 8)  // STW 2.57 m/s ≈ 5 kn
		put(radians(270), at: 10)  // set
		put(Self.leBytes(UInt16(51)), at: 12)  // drift 0.51 m/s ≈ 1 kn

		let m = try #require(NMEA2000Decoder.decode(pgn: 130577, data: d))
		func value(_ name: String) throws -> Double {
			try #require(m.first { $0.name == name }?.value)
		}
		#expect(abs(try value("COG") - 100) < 0.01)
		#expect(abs(try value("SOG") - 6.0) < 0.02)
		#expect(abs(try value("HDG.true") - 95) < 0.01)
		#expect(abs(try value("STW") - 5.0) < 0.02)
		#expect(abs(try value("navigation.currentSet") - 270) < 0.01)
		#expect(abs(try value("navigation.currentDrift") - 1.0) < 0.02)
	}

	/// PGN 128000 — leeway, signed to starboard.
	@Test func `PGN 128000 — leeway angle is signed`() throws {
		var d = [UInt8](repeating: 0xFF, count: 8)
		d[0] = 0
		for (k, b) in Self.leBytes(Int16((-5.0 * .pi / 180 * 1e4).rounded())).enumerated() {
			d[1 + k] = b
		}
		let m = try #require(NMEA2000Decoder.decode(pgn: 128000, data: d))
		let leeway = try #require(m.first { $0.name == "navigation.leeway" })
		#expect(abs(leeway.value - -5.0) < 0.01)
		#expect(leeway.unit == "°")
	}

	/// Switching source must not leave the previous feed's route lingering: the
	/// route and waypoint names (PGN 129285) and the active destination (129284)
	/// travel through the labels side channel, which ``BoatMetricStore/clear()``
	/// has to drop along with the metrics.
	@MainActor @Test func `clear() drops the previous source's route and waypoint labels`() {
		func varString(_ s: String) -> [UInt8] { [UInt8(s.utf8.count + 2), 1] + Array(s.utf8) }
		// PGN 129285 — route "Monaco - La Maddalena" carrying waypoint 2 "WP 2".
		var route: [UInt8] = []
		route += Self.leBytes(UInt16(0))  // start RPS
		route += Self.leBytes(UInt16(1))  // 1 waypoint in this message
		route += Self.leBytes(UInt16(1))  // database id
		route += Self.leBytes(UInt16(1))  // route id
		route.append(0)  // direction + flags
		route += varString("Monaco - La Maddalena")
		route.append(0xFF)  // reserved
		route += Self.leBytes(UInt16(2)) + varString("WP 2") + [UInt8](repeating: 0, count: 8)
		// PGN 129284 — destination waypoint number 2.
		var nav = [UInt8](repeating: 0xFF, count: 34)
		for (k, b) in Self.leBytes(UInt32(1)).enumerated() { nav[16 + k] = b }
		for (k, b) in Self.leBytes(UInt32(2)).enumerated() { nav[20 + k] = b }

		let store = BoatMetricStore()
		store.feed(.nmea2000(pgn: 129_285, source: 0, priority: 6, data: route))
		store.feed(.nmea2000(pgn: 129_284, source: 0, priority: 6, data: nav))
		#expect(store.labels["route"] == "Monaco - La Maddalena")
		#expect(store.labels["waypoint"] == "WP 2")

		store.clear()
		#expect(store.labels["route"] == nil)
		#expect(store.labels["waypoint"] == nil)
	}

	/// PGN 128267 — Water Depth (8 bytes).
	/// SID + uint32 depth (0.01 m) + int16 offset (0.001 m) + uint8 range (10 m).
	@Test func `PGN 128267 — water depth, offset and range`() throws {
		var data: [UInt8] = [0x00]  // SID
		data.append(contentsOf: Self.leBytes(UInt32(1_075)))  // depth = 10.75 m
		data.append(contentsOf: Self.leBytes(Int16(100)))  // offset = 0.100 m
		data.append(0xC8)  // range = 2000 m

		let metrics = try #require(NMEA2000Decoder.decode(pgn: 128267, data: data))
		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })

		let depth = try #require(byName["depth"])
		let offset = try #require(byName["depth.offset"])
		#expect(abs(depth - 10.75) < 1e-6)
		#expect(abs(offset - 0.10) < 1e-6)
		#expect(byName["depth.range"] == 2000)
	}

	/// PGN 127250 — Vessel Heading (8 bytes).
	/// SID + uint16 heading (1e-4 rad) + i16 deviation + i16 variation + reference byte.
	@Test func `PGN 127250 — true heading`() throws {
		let rawHeading = UInt16((90.0 * .pi / 180.0 * 10_000.0).rounded())  // 90°

		var data: [UInt8] = [0x00]  // SID
		data.append(contentsOf: Self.leBytes(rawHeading))
		data.append(contentsOf: Self.leBytes(Int16.max))  // deviation N/A
		data.append(contentsOf: Self.leBytes(Int16.max))  // variation N/A
		data.append(0x00)  // reference = true

		let metrics = try #require(NMEA2000Decoder.decode(pgn: 127250, data: data))
		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })

		let heading = try #require(byName["HDG.true"])
		#expect(abs(heading - 90.0) < 0.05)
	}

	/// PGN 130306 — Wind Data.
	/// SID + uint16 speed (0.01 m/s) + uint16 angle (1e-4 rad) + 1-byte reference.
	@Test func `PGN 130306 — true wind speed and direction`() throws {
		let rawSpeed = UInt16(500)  // 5 m/s
		let rawAngle = UInt16((.pi * 10_000.0).rounded())  // 180°

		var data: [UInt8] = [0x00]  // SID
		data.append(contentsOf: Self.leBytes(rawSpeed))
		data.append(contentsOf: Self.leBytes(rawAngle))
		data.append(0x00)  // reference = true north
		data.append(contentsOf: [0xFF, 0xFF])  // reserved padding

		let metrics = try #require(NMEA2000Decoder.decode(pgn: 130306, data: data))
		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })

		let tws = try #require(byName["TWS"])
		let twd = try #require(byName["TWD"])
		#expect(abs(tws - 5.0 * 1.94384) < 0.01)
		#expect(abs(twd - 180.0) < 0.05)
	}

	/// PGN 129025 — Position Rapid Update.
	/// int32 latitude (1e-7°) + int32 longitude (1e-7°).
	@Test func `PGN 129025 — position rapid update`() throws {
		let lat = Int32((43.5 * 1e7).rounded())
		let lon = Int32((7.0 * 1e7).rounded())

		var data: [UInt8] = []
		data.append(contentsOf: Self.leBytes(lat))
		data.append(contentsOf: Self.leBytes(lon))

		let metrics = try #require(NMEA2000Decoder.decode(pgn: 129025, data: data))
		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })

		let latOut = try #require(byName["lat"])
		let lonOut = try #require(byName["lon"])
		#expect(abs(latOut - 43.5) < 1e-6)
		#expect(abs(lonOut - 7.0) < 1e-6)
	}

	@Test func `Unknown PGN returns nil`() {
		#expect(NMEA2000Decoder.decode(pgn: 999_999, data: [UInt8](repeating: 0, count: 8)) == nil)
	}

	/// The current reaches the store from three places, and the store has to
	/// pick the same way it does for every other quantity: the message that
	/// exists for nothing else wins, whichever arrives last.
	@MainActor @Test func `Set and drift are arbitrated, dedicated source first`() throws {
		func rapid(set: Double, drift: Double) -> [UInt8] {
			var d = [UInt8](repeating: 0xFF, count: 8)
			d[0] = 0
			d[1] = 0
			for (k, b) in Self.leBytes(UInt16((set * .pi / 180 * 1e4).rounded())).enumerated() {
				d[2 + k] = b
			}
			for (k, b) in Self.leBytes(UInt16((drift / 1.94384 / 0.01).rounded())).enumerated() {
				d[4 + k] = b
			}
			return d
		}
		func direction(set: Double, drift: Double) -> [UInt8] {
			var d = [UInt8](repeating: 0xFF, count: 14)
			d[0] = 0
			d[1] = 0
			for (k, b) in Self.leBytes(UInt16((set * .pi / 180 * 1e4).rounded())).enumerated() {
				d[10 + k] = b
			}
			for (k, b) in Self.leBytes(UInt16((drift / 1.94384 / 0.01).rounded())).enumerated() {
				d[12 + k] = b
			}
			return d
		}

		// `feed` tags the source; the metrics follow it as `.metric` frames,
		// exactly as the transport does.
		func send(_ store: BoatMetricStore, pgn: UInt32, _ data: [UInt8]) {
			store.feed(.nmea2000(pgn: pgn, source: 0, priority: 6, data: data))
			for m in NMEA2000Decoder.decode(pgn: pgn, data: data) ?? [] { store.feed(.metric(m)) }
		}
		func sendVDR(_ store: BoatMetricStore) {
			let frame = NMEA0183Parser.parse("$IIVDR,100.0,T,,,9.9,N")
			guard case .nmea0183(_, _, _, let fields)? = frame else { return }
			store.feed(frame!)
			for m in NMEA0183Parser.decode(fields) ?? [] { store.feed(.metric(m)) }
		}

		// The weaker sources first, then the dedicated one.
		let store = BoatMetricStore()
		sendVDR(store)
		send(store, pgn: 130_577, direction(set: 200, drift: 5))
		send(store, pgn: 129_291, rapid(set: 270, drift: 2))
		store.flushNow()
		#expect(abs(try #require(store.metrics["navigation.currentSet"]?.value) - 270) < 0.02)
		#expect(abs(try #require(store.metrics["navigation.currentDrift"]?.value) - 2) < 0.02)

		// And the other way round: a weaker source arriving later must not win.
		let reversed = BoatMetricStore()
		send(reversed, pgn: 129_291, rapid(set: 270, drift: 2))
		send(reversed, pgn: 130_577, direction(set: 200, drift: 5))
		sendVDR(reversed)
		reversed.flushNow()
		#expect(abs(try #require(reversed.metrics["navigation.currentSet"]?.value) - 270) < 0.02)
	}

	/// Direction Data repeats COG, SOG, heading and speed through water, so it
	/// must lose those to the messages dedicated to each.
	@MainActor @Test func `Direction Data does not displace the dedicated speed and heading sources`()
		throws
	{
		var direction = [UInt8](repeating: 0xFF, count: 14)
		direction[0] = 0
		direction[1] = 0
		for (k, b) in Self.leBytes(UInt16(1_000)).enumerated() { direction[8 + k] = b }  // STW 10 m/s

		var speed = [UInt8](repeating: 0xFF, count: 8)
		speed[0] = 0
		for (k, b) in Self.leBytes(UInt16(257)).enumerated() { speed[1 + k] = b }  // STW 2.57 m/s ≈ 5 kn

		func send(_ store: BoatMetricStore, pgn: UInt32, _ data: [UInt8]) {
			store.feed(.nmea2000(pgn: pgn, source: 0, priority: 6, data: data))
			for m in NMEA2000Decoder.decode(pgn: pgn, data: data) ?? [] { store.feed(.metric(m)) }
		}
		let store = BoatMetricStore()
		send(store, pgn: 128_259, speed)
		send(store, pgn: 130_577, direction)
		store.flushNow()
		#expect(abs(try #require(store.metrics["STW"]?.value) - 5.0) < 0.02)
	}
}
