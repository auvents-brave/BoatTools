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

	/// VDR — the only 0183 sentence that states a current at all.
	@Test func `VDR decodes set and drift, keeping the magnetic set apart`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$IIVDR,225.0,T,228.0,M,2.1,N")
		else {
			Issue.record("parse failed")
			return
		}
		let byName = Dictionary(
			uniqueKeysWithValues: try #require(NMEA0183Parser.decode(fields)).map { ($0.name, $0.value) })
		#expect(byName["navigation.currentSet"] == 225.0)
		#expect(byName["navigation.currentSet.magnetic"] == 228.0)
		#expect(byName["navigation.currentDrift"] == 2.1)
	}

	/// A current stated only in magnetic degrees must not land in the true slot.
	@Test func `VDR with no true field leaves the true set empty`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$IIVDR,,,228.0,M,2.1,N")
		else {
			Issue.record("parse failed")
			return
		}
		let names = Set(try #require(NMEA0183Parser.decode(fields)).map(\.name))
		#expect(names.contains("navigation.currentSet.magnetic"))
		#expect(!names.contains("navigation.currentSet"))
	}

	/// VPW — speed along the wind axis, the sailing VMG. Negative to leeward,
	/// and a different quantity from the VMG towards a waypoint.
	@Test func `VPW decodes the sailing VMG and keeps its sign`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$IIVPW,-3.2,N,-1.65,M")
		else {
			Issue.record("parse failed")
			return
		}
		let metrics = try #require(NMEA0183Parser.decode(fields))
		let vmg = try #require(metrics.first { $0.name == "navigation.vmgWind" })
		#expect(vmg.value == -3.2)
		#expect(vmg.unit == "kn")
		#expect(!metrics.contains { $0.name == "navigation.vmg" })
	}

	/// VPW in metres per second alone still reaches the store in knots.
	@Test func `VPW falls back to the metric field`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$IIVPW,,,2.0,M") else {
			Issue.record("parse failed")
			return
		}
		let v = try #require(NMEA0183Parser.decode(fields)?.first { $0.name == "navigation.vmgWind" }?.value)
		#expect(abs(v - 3.88768) < 1e-5)
	}

	/// WCV — waypoint closure velocity: the same quantity RMB buries in field 12.
	@Test func `WCV decodes the VMG towards the waypoint`() throws {
		guard case .nmea0183(_, _, _, let fields)? = NMEA0183Parser.parse("$IIWCV,6.4,N,CALVI,A")
		else {
			Issue.record("parse failed")
			return
		}
		let v = try #require(NMEA0183Parser.decode(fields)?.first { $0.name == "navigation.vmg" }?.value)
		#expect(v == 6.4)
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
