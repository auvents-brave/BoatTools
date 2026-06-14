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

	/// PGN 129284 — the origin / destination waypoint numbers (bytes 17-24).
	@Test func `PGN 129284 — waypoint numbers decode and honour not-available`() {
		var data = [UInt8](repeating: 0xFF, count: 35)
		for (k, b) in Self.leBytes(UInt32(2)).enumerated() { data[17 + k] = b }
		for (k, b) in Self.leBytes(UInt32(3)).enumerated() { data[21 + k] = b }
		let numbers = NMEA2000Decoder.navigationWaypointNumbers(data)
		#expect(numbers.origin == 2)
		#expect(numbers.destination == 3)

		let unavailable = NMEA2000Decoder.navigationWaypointNumbers([UInt8](repeating: 0xFF, count: 35))
		#expect(unavailable.origin == nil)
		#expect(unavailable.destination == nil)
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
}
