import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for the NMEA 2000 **receive** decoders added for MOB, DSC, pilot
/// heading/track control, battery configuration and CZone digital switching, the
/// N2K AIS safety/broadcast messages, and the **transmit** side (the individual
/// routine DSC VHF call encoder).
@Suite("N2K receive decoders + VHF call")
struct N2KReceiveVHFTests {

	/// Little-endian bytes of a fixed-width integer.
	private static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
		withUnsafeBytes(of: value.littleEndian) { Array($0) }
	}

	/// The value of the metric named `name`, or `nil` when absent.
	private static func value(_ metrics: [BoatMetric], _ name: String) -> Double? {
		metrics.first { $0.name == name }?.value
	}

	// MARK: - 127233 Man Overboard

	@Test func `PGN 127233 — MOB position, status, speed and MMSI`() throws {
		var d = [UInt8](repeating: 0, count: 34)
		d[0] = 0  // SID
		for (k, b) in Self.le(UInt32(12345)).enumerated() { d[1 + k] = b }  // emitter id
		d[5] = 1  // status (low 3 bits)
		for (k, b) in Self.le(Int32(437_384_000)).enumerated() { d[17 + k] = b }  // 43.7384°
		for (k, b) in Self.le(Int32(74_246_000)).enumerated() { d[21 + k] = b }  // 7.4246°
		for (k, b) in Self.le(UInt16(15708)).enumerated() { d[26 + k] = b }  // ≈90° COG
		for (k, b) in Self.le(UInt16(257)).enumerated() { d[28 + k] = b }  // ≈5 kn SOG
		for (k, b) in Self.le(UInt32(227_123_456)).enumerated() { d[30 + k] = b }  // MMSI

		let m = try #require(NMEA2000Decoder.decode(pgn: 127233, data: d))
		#expect(Self.value(m, "mob.emitterId") == 12345)
		#expect(Self.value(m, "mob.status") == 1)
		#expect(abs((Self.value(m, "mob.latitude") ?? 0) - 43.7384) < 1e-4)
		#expect(abs((Self.value(m, "mob.longitude") ?? 0) - 7.4246) < 1e-4)
		#expect(abs((Self.value(m, "mob.cog") ?? 0) - 90) < 0.5)
		#expect(abs((Self.value(m, "mob.sog") ?? 0) - 5) < 0.2)
		#expect(Self.value(m, "mob.mmsi") == 227_123_456)
	}

	// MARK: - 127237 Heading/Track Control

	@Test func `PGN 127237 — steering mode, commanded rudder, heading to steer`() throws {
		var d = [UInt8](repeating: 0, count: 7)
		d[1] = 2  // steering mode (low 3 bits)
		for (k, b) in Self.le(Int16(873)).enumerated() { d[3 + k] = b }  // ≈5°
		for (k, b) in Self.le(UInt16(20944)).enumerated() { d[5 + k] = b }  // ≈120°

		let m = try #require(NMEA2000Decoder.decode(pgn: 127237, data: d))
		#expect(Self.value(m, "autopilot.steeringMode") == 2)
		#expect(abs((Self.value(m, "autopilot.commandedRudder") ?? 0) - 5) < 0.2)
		#expect(abs((Self.value(m, "navigation.headingToSteer") ?? 0) - 120) < 0.5)
	}

	// MARK: - 127513 Battery Configuration

	@Test func `PGN 127513 — nominal voltage lookup and capacity`() throws {
		var d = [UInt8](repeating: 0, count: 5)
		d[0] = 1  // instance
		d[2] = 0x01  // nominal-voltage index 1 → 12 V
		for (k, b) in Self.le(UInt16(200)).enumerated() { d[3 + k] = b }  // 200 Ah

		let m = try #require(NMEA2000Decoder.decode(pgn: 127513, data: d))
		#expect(Self.value(m, "battery.1.nominalVoltage") == 12)
		#expect(Self.value(m, "battery.1.capacityAh") == 200)
	}

	// MARK: - 65284 CZone circuit status

	@Test func `PGN 65284 — CZone bitmap decoded only for BEP Marine (295)`() throws {
		var d = [UInt8](repeating: 0, count: 8)
		d[0] = 0x27
		d[1] = 0x01  // manufacturer field low 11 bits = 295 (BEP Marine)
		d[2] = 3  // module id
		for (k, b) in Self.le(UInt32(0b101)).enumerated() { d[4 + k] = b }  // circuits 0 and 2 on

		let m = try #require(NMEA2000Decoder.decode(pgn: 65284, data: d))
		#expect(Self.value(m, "czone.3.circuits") == 5)

		// A different manufacturer must be ignored (proprietary frame, not ours).
		var other = d
		other[0] = 0x2A  // 298, not BEP Marine
		#expect(NMEA2000Decoder.decode(pgn: 65284, data: other) == nil)
	}

	// MARK: - 129808 DSC Call Information (received)

	@Test func `PGN 129808 — DSC caller MMSI, reported position and ship in distress`() throws {
		var d: [UInt8] = [120, 100]  // format (individual), category (routine)
		d += VHFCommands.decimalAddress(mmsi: 227_123_456)  // caller MMSI @2
		d += [UInt8](repeating: 0, count: 14)  // telecommands + channels @7..20
		d += [0x02, 0x01]  // telephone STRING_LAU (empty) @21
		d += Self.le(Int32(437_384_000))  // lat @23 → 43.7384°
		d += Self.le(Int32(74_246_000))  // lon @27 → 7.4246°
		d += [0xFF, 0xFF, 0xFF, 0xFF]  // time of position @31
		d += VHFCommands.decimalAddress(mmsi: 366_123_456)  // ship in distress @35

		let m = try #require(NMEA2000Decoder.decode(pgn: 129808, data: d))
		#expect(Self.value(m, "dsc.format") == 120)
		#expect(Self.value(m, "dsc.category") == 100)
		#expect(Self.value(m, "dsc.mmsi") == 227_123_456)
		#expect(abs((Self.value(m, "dsc.lat") ?? 0) - 43.7384) < 1e-4)
		#expect(abs((Self.value(m, "dsc.lon") ?? 0) - 7.4246) < 1e-4)
		#expect(Self.value(m, "dsc.distressMMSI") == 366_123_456)
	}

	// MARK: - Transmit: individual routine DSC VHF call

	@Test func `VHF individual routine call encodes PGN 129808 and round-trips the MMSI`() throws {
		let message = VHFCommands.individualRoutineCall(toMMSI: 227_123_456, channel: 72, destination: 42)
		guard case .nmea2000(let pgn, let destination, let priority, let data) = message else {
			Issue.record("expected an NMEA 2000 outbound message")
			return
		}
		#expect(pgn == 129808)
		#expect(destination == 42)
		#expect(priority == 4)
		#expect(data[0] == 120)  // Individual stations
		#expect(data[1] == 100)  // Routine
		#expect(Array(data[9..<15]) == Array("900072".utf8))  // proposed channel field

		// The encoder's address must decode back to the same MMSI (encode↔decode).
		let decoded = try #require(NMEA2000Decoder.decode(pgn: 129808, data: data))
		#expect(Self.value(decoded, "dsc.mmsi") == 227_123_456)
	}

	@Test func `VHF channel field is the 9000-prefixed two-digit channel`() {
		#expect(VHFCommands.channelField(72) == Array("900072".utf8))
		#expect(VHFCommands.channelField(6) == Array("900006".utf8))
	}

	// MARK: - N2K AIS safety / broadcast messages

	@Test func `PGN 129797 — binary broadcast carries the source MMSI`() throws {
		var d = [UInt8](repeating: 0, count: 6)
		for (k, b) in Self.le(UInt32(227_123_456)).enumerated() { d[1 + k] = b }
		let target = try #require(AISDecoder.decodeN2K(pgn: 129797, source: 1, data: d))
		#expect(target.mmsi == 227_123_456)
		#expect(target.messageType == .binaryBroadcastMessage)
	}

	@Test func `PGN 129802 — safety broadcast MMSI and text`() throws {
		var d = [UInt8](repeating: 0, count: 6)
		for (k, b) in Self.le(UInt32(227_123_456)).enumerated() { d[1 + k] = b }
		d += [6, 1] + Array("TEST".utf8)  // STRING_LAU @6
		let target = try #require(AISDecoder.decodeN2K(pgn: 129802, source: 1, data: d))
		#expect(target.mmsi == 227_123_456)
		#expect(target.messageType == .safetyBroadcastMessage)
		#expect(target.text == "TEST")
	}

	@Test func `PGN 129801 — addressed safety MMSI and text`() throws {
		var d = [UInt8](repeating: 0, count: 11)
		for (k, b) in Self.le(UInt32(227_123_456)).enumerated() { d[1 + k] = b }
		d += [6, 1] + Array("TEST".utf8)  // STRING_LAU @11
		let target = try #require(AISDecoder.decodeN2K(pgn: 129801, source: 1, data: d))
		#expect(target.mmsi == 227_123_456)
		#expect(target.messageType == .addressedSafetyMessage)
		#expect(target.text == "TEST")
	}

	// MARK: - 129285 Route/WP information (positions via the metric decoder)

	@Test func `PGN 129285 — route id, waypoint count and per-waypoint positions`() throws {
		var d: [UInt8] = []
		d += Self.le(UInt16(0))  // start RPS
		d += Self.le(UInt16(2))  // 2 waypoints
		d += Self.le(UInt16(0))  // database id
		d += Self.le(UInt16(7))  // route id
		d.append(0)  // flags
		d += [4, 1] + Array("RT".utf8)  // route-name STRING_LAU @9
		d.append(0)  // reserved
		d += Self.le(UInt16(3)) + [2, 1] + Self.le(Int32(437_384_000)) + Self.le(Int32(74_246_000))  // WP 3
		d += Self.le(UInt16(4)) + [2, 1] + Self.le(Int32(430_000_000)) + Self.le(Int32(90_000_000))  // WP 4

		let m = try #require(NMEA2000Decoder.decode(pgn: 129285, data: d))
		#expect(Self.value(m, "route.waypointCount") == 2)
		#expect(Self.value(m, "route.id") == 7)
		#expect(abs((Self.value(m, "route.waypoint.3.latitude") ?? 0) - 43.7384) < 1e-4)
		#expect(abs((Self.value(m, "route.waypoint.4.latitude") ?? 0) - 43.0) < 1e-4)
	}
}
