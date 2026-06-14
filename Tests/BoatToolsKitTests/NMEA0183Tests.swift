import Testing

@testable import BoatToolsKit

/// Unit tests for ``NMEA0183Parser`` — sentence framing and field decoding.
@Suite("NMEA 0183 parser")
struct NMEA0183Tests {
	@Test func `A valid sentence parses to a frame with talker and type`() throws {
		let frame = NMEA0183Parser.parse(
			"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
		)
		guard case .nmea0183(_, let talker, let type, let fields)? = frame else {
			Issue.record("expected .nmea0183, got \(String(describing: frame))")
			return
		}
		#expect(talker == "GP")
		#expect(type == "RMC")
		#expect(fields.first == "$GPRMC")
	}

	@Test func `A wrong XOR checksum yields an invalid-checksum frame, not nil`() {
		// Correct checksum is *31; *00 is deliberately wrong.
		let frame = NMEA0183Parser.parse("$GPGLL,4916.45,N,12311.12,W,225444,A*00")
		guard case .invalidChecksum = frame else {
			Issue.record("expected .invalidChecksum, got \(String(describing: frame))")
			return
		}
	}

	@Test func `A non-NMEA line returns nil`() {
		#expect(NMEA0183Parser.parse("this is not a valid sentence") == nil)
	}

	@Test func `A sentence with no checksum suffix still parses`() {
		let frame = NMEA0183Parser.parse("$IIHDG,98.3,0.0,E,12.6,W")
		guard case .nmea0183 = frame else {
			Issue.record("expected .nmea0183, got \(String(describing: frame))")
			return
		}
	}

	@Test func `Routing sentences expose the destination waypoint name`() throws {
		func name(_ sentence: String) -> String? {
			guard case .nmea0183(_, _, let type, let fields)? = NMEA0183Parser.parse(sentence) else { return nil }
			return NMEA0183Parser.waypointName(type: type, fields: fields)
		}
		// RMB: field 5 is the destination waypoint ID.
		#expect(name("$GPRMB,A,0.66,L,003,004,4917.24,N,12309.57,W,001.3,052.5,000.5,V") == "004")
		// APB: field 10.
		#expect(name("$GPAPB,A,A,0.10,R,N,V,V,011,M,DEST,011,M,011,M") == "DEST")
		// BWC: field 12.
		#expect(name("$GPBWC,081837,4917.24,N,12309.57,W,051.9,T,031.6,M,001.3,N,NICE") == "NICE")
		// WPL: field 5.
		#expect(name("$GPWPL,4917.16,N,12310.64,W,003") == "003")
		// A sentence without a waypoint field yields nil.
		#expect(name("$IIHDG,98.3,0.0,E,12.6,W") == nil)
	}

	@Test func `A recognised sentence decodes to at least one metric`() throws {
		let frame = NMEA0183Parser.parse("$SDDBT,8.1,f,2.4,M,1.3,F*0B")
		guard case .nmea0183(_, _, _, let fields)? = frame else {
			Issue.record("parse failed")
			return
		}
		let metrics = try #require(NMEA0183Parser.decode(fields))
		#expect(!metrics.isEmpty)
	}

	@Test func `MTA decodes air temperature`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$WIMTA,21.5,C")
		else {
			Issue.record("parse failed")
			return
		}
		let byName = Dictionary(
			uniqueKeysWithValues: try #require(NMEA0183Parser.decode(fields)).map { ($0.name, $0.value) })
		#expect(byName["temperature.air"] == 21.5)
	}

	@Test func `MMB decodes barometric pressure (bars preferred)`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$WIMMB,29.92,I,1.0132,B")
		else {
			Issue.record("parse failed")
			return
		}
		let p = try #require(NMEA0183Parser.decode(fields)?.first { $0.name == "pressure.atmospheric" }?.value)
		#expect(abs(p - 1013.2) < 1e-6)
	}

	@Test func `VWT decodes true wind angle and speed`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$WIVWT,45,L,10.5,N,5.4,M,19.4,K")
		else {
			Issue.record("parse failed")
			return
		}
		let byName = Dictionary(
			uniqueKeysWithValues: try #require(NMEA0183Parser.decode(fields)).map { ($0.name, $0.value) })
		#expect(byName["TWA"] == -45)
		#expect(byName["TWS"] == 10.5)
	}

	@Test func `DSC decodes the distress position from the coordinates field`() throws {
		guard
			case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse(
				"$CDDSC,12,003380400,12,00,00,0431200730,1423,,S")
		else {
			Issue.record("parse failed")
			return
		}
		let byName = Dictionary(
			uniqueKeysWithValues: try #require(NMEA0183Parser.decode(fields)).map { ($0.name, $0.value) })
		// Quadrant 0 (NE): 43°12′N, 007°30′E.
		#expect(abs(try #require(byName["dsc.lat"]) - 43.2) < 1e-6)
		#expect(abs(try #require(byName["dsc.lon"]) - 7.5) < 1e-6)
	}

	@Test func `DSC coordinate quadrant sets the hemisphere signs`() {
		// Quadrant 3 (SW): latitude and longitude both negative.
		let sw = NMEA0183Parser.dscPosition("3431200730")
		#expect(sw?.latitude == -43.2)
		#expect(sw?.longitude == -7.5)
		// An empty or out-of-range field carries no position.
		#expect(NMEA0183Parser.dscPosition("") == nil)
		#expect(NMEA0183Parser.dscPosition("9999999999") == nil)
	}
}
