import Foundation
import Testing

@testable import BoatToolsKit

// MARK: - 6-bit AIS bit-writer

/// Inverse of `AISBitBuffer` — writes integer fields into a bit stream and
/// packs the result into the 6-bit ASCII payload format used by AIVDM, along
/// with the number of trailing pad bits.
///
/// The numeric mapping mirrors the buffer's reader: bits are packed MSB-first
/// per field; each 6-bit group is mapped to a payload character as
/// `v < 40 ? '0' + v : '0' + v + 8`. Text fields use the AIS 6-bit table.
private struct AISBitWriter {
	private(set) var bits: [UInt8] = []

	mutating func appendUInt(_ value: UInt32, bits length: Int) {
		for shift in stride(from: length - 1, through: 0, by: -1) {
			bits.append(UInt8((value >> shift) & 1))
		}
	}

	mutating func appendInt(_ value: Int32, bits length: Int) {
		let mask: UInt32 = length >= 32 ? .max : (UInt32(1) << length) - 1
		appendUInt(UInt32(bitPattern: value) & mask, bits: length)
	}

	/// Encodes `string` into the 6-bit AIS text alphabet, right-padded with `@`
	/// (the 0 index) to fill exactly `totalBits` bits.
	mutating func appendText(_ string: String, totalBits: Int) {
		let table: [Character] = Array("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?")
		let charCount = totalBits / 6
		let chars = Array(string.uppercased())
		for i in 0..<charCount {
			let index: UInt32
			if i < chars.count, let position = table.firstIndex(of: chars[i]) {
				index = UInt32(position)
			} else {
				index = 0
			}
			appendUInt(index, bits: 6)
		}
	}

	/// Pads to a multiple of 6 bits with zeros and returns the AIVDM-style
	/// payload string plus the number of pad bits.
	func payload() -> (payload: String, fillBits: Int) {
		var padded = bits
		let pad = (6 - padded.count % 6) % 6
		for _ in 0..<pad { padded.append(0) }
		var out = ""
		out.reserveCapacity(padded.count / 6)
		for i in stride(from: 0, to: padded.count, by: 6) {
			var v = 0
			for k in 0..<6 { v = (v << 1) | Int(padded[i + k]) }
			let ord = v < 40 ? v + 48 : v + 56
			out.append(Character(UnicodeScalar(ord)!))
		}
		return (out, pad)
	}
}

// MARK: - Convenience builders for the AIS message types under test

extension AISBitWriter {
	/// Builds a 168-bit Class A position report payload (type 1/2/3).
	static func type123(
		type: UInt32, mmsi: UInt32, navStatus: UInt32, rotSigned: Int32,
		sogTenthsKn: UInt32, posAcc: Bool,
		lonScaled: Int32, latScaled: Int32, cogTenthsDeg: UInt32, heading: UInt32,
		timestamp: UInt32 = 60, maneuver: UInt32 = 0, raim: Bool = false
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(type, bits: 6)  // 0:   message type
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   MMSI
		w.appendUInt(navStatus, bits: 4)  // 38:  nav status
		w.appendInt(rotSigned, bits: 8)  // 42:  ROT (signed)
		w.appendUInt(sogTenthsKn, bits: 10)  // 50:  SOG (0.1 kn)
		w.appendUInt(posAcc ? 1 : 0, bits: 1)  // 60:  pos accuracy
		w.appendInt(lonScaled, bits: 28)  // 61:  longitude (signed)
		w.appendInt(latScaled, bits: 27)  // 89:  latitude (signed)
		w.appendUInt(cogTenthsDeg, bits: 12)  // 116: COG (0.1°)
		w.appendUInt(heading, bits: 9)  // 128: true heading
		w.appendUInt(timestamp, bits: 6)  // 137: timestamp
		w.appendUInt(maneuver, bits: 2)  // 143: manoeuvre indicator
		w.appendUInt(0, bits: 3)  // 145: spare
		w.appendUInt(raim ? 1 : 0, bits: 1)  // 148: RAIM
		w.appendUInt(0, bits: 19)  // 149: radio status
		return w
	}

	/// Builds a 426-bit type-5 static-and-voyage payload, with text fields
	/// already padded to the required widths.
	static func type5(
		mmsi: UInt32, imo: UInt32, callsign: String, name: String,
		shipType: UInt32, draughtTenthsM: UInt32, destination: String
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(5, bits: 6)  // 0:   message type
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   MMSI
		w.appendUInt(0, bits: 2)  // 38:  AIS version
		w.appendUInt(imo, bits: 30)  // 40:  IMO number
		w.appendText(callsign, totalBits: 42)  // 70:  callsign (7 chars)
		w.appendText(name, totalBits: 120)  // 112: vessel name (20 chars)
		w.appendUInt(shipType, bits: 8)  // 232: ship/cargo type
		w.appendUInt(0, bits: 30)  // 240: dimension fields
		w.appendUInt(0, bits: 4)  // 270: EPFD type
		w.appendUInt(0, bits: 20)  // 274: ETA (month, day, hour, minute)
		w.appendUInt(draughtTenthsM, bits: 8)  // 294: max draught (0.1 m)
		w.appendText(destination, totalBits: 120)  // 302: destination (20 chars)
		w.appendUInt(0, bits: 1)  // 422: DTE
		w.appendUInt(0, bits: 3)  // 423: spare (pad to ≥ 426)
		return w
	}

	/// Builds a 168-bit type-18 Class B position payload.
	static func type18(
		mmsi: UInt32, sogTenthsKn: UInt32, posAcc: Bool,
		lonScaled: Int32, latScaled: Int32, cogTenthsDeg: UInt32, heading: UInt32
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(18, bits: 6)  // 0:   message type
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   MMSI
		w.appendUInt(0, bits: 8)  // 38:  reserved
		w.appendUInt(sogTenthsKn, bits: 10)  // 46:  SOG (0.1 kn)
		w.appendUInt(posAcc ? 1 : 0, bits: 1)  // 56:  pos accuracy
		w.appendInt(lonScaled, bits: 28)  // 57:  longitude
		w.appendInt(latScaled, bits: 27)  // 85:  latitude
		w.appendUInt(cogTenthsDeg, bits: 12)  // 112: COG
		w.appendUInt(heading, bits: 9)  // 124: heading
		w.appendUInt(60, bits: 6)  // 133: timestamp
		w.appendUInt(0, bits: 8)  // 139: regional + flags
		w.appendUInt(0, bits: 1)  // 147: RAIM
		w.appendUInt(0, bits: 20)  // 148: radio status
		return w
	}

	/// Builds a 168-bit type-9 SAR aircraft position report payload.
	static func type9(
		mmsi: UInt32, altitudeMetres: UInt32, sogKn: UInt32,
		lonScaled: Int32, latScaled: Int32, cogTenthsDeg: UInt32
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(9, bits: 6)  // 0:   message type
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   MMSI
		w.appendUInt(altitudeMetres, bits: 12)  // 38:  altitude (metres)
		w.appendUInt(sogKn, bits: 10)  // 50:  SOG (knots — 1 kn resolution, not 0.1)
		w.appendUInt(1, bits: 1)  // 60:  pos accuracy = true
		w.appendInt(lonScaled, bits: 28)  // 61:  longitude
		w.appendInt(latScaled, bits: 27)  // 89:  latitude
		w.appendUInt(cogTenthsDeg, bits: 12)  // 116: COG (0.1°)
		w.appendUInt(60, bits: 6)  // 128: timestamp
		w.appendUInt(0, bits: 13)  // 134: regional + DTE + spare + assigned (147)
		w.appendUInt(0, bits: 1)  // 147: RAIM
		w.appendUInt(0, bits: 20)  // 148: radio status
		return w
	}

	/// Builds a 272-bit type-21 Aid-to-Navigation report payload.
	static func type21(
		mmsi: UInt32, aidType: UInt32, name: String,
		lonScaled: Int32, latScaled: Int32
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(21, bits: 6)  // 0:   message type
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   MMSI
		w.appendUInt(aidType, bits: 5)  // 38:  aid type
		w.appendText(name, totalBits: 120)  // 43:  aid name (20 chars)
		w.appendUInt(1, bits: 1)  // 163: pos accuracy = true
		w.appendInt(lonScaled, bits: 28)  // 164: longitude
		w.appendInt(latScaled, bits: 27)  // 192: latitude
		w.appendUInt(0, bits: 30)  // 219: dimensions
		w.appendUInt(0, bits: 4)  // 249: EPFD
		w.appendUInt(60, bits: 6)  // 253: timestamp
		w.appendUInt(0, bits: 10)  // 259: off-position + reserved (to 269)
		w.appendUInt(0, bits: 1)  // 269: RAIM
		w.appendUInt(0, bits: 2)  // 270: virtual + assigned (pad to 272)
		return w
	}

	/// Builds a 188-bit type-8 binary broadcast carrying the IMO 289 IFM 11
	/// (Meteorological and Hydrological Data) payload.
	static func type8MeteoIFM11(
		mmsi: UInt32,
		lonScaled1000Min: Int32, latScaled1000Min: Int32,
		avgWindKn: UInt32, gustWindKn: UInt32,
		windDirDeg: UInt32, gustDirDeg: UInt32,
		tempTenthsC: Int32, humidityPercent: UInt32,
		dewPointTenthsC: Int32, pressureMinus800: UInt32
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(8, bits: 6)  // 0:   type 8 (binary broadcast)
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   source MMSI
		w.appendUInt(0, bits: 2)  // 38:  spare
		w.appendUInt(1, bits: 10)  // 40:  DAC = 1 (international)
		w.appendUInt(11, bits: 6)  // 50:  FI = 11 (meteo/hydro)
		// Meteo payload — offsets are absolute from the start of the message.
		w.appendInt(lonScaled1000Min, bits: 24)  // 56:  longitude (1/1000 min)
		w.appendInt(latScaled1000Min, bits: 23)  // 80:  latitude  (1/1000 min)
		w.appendUInt(0, bits: 16)  // 103: day + hour + minute (skipped by decoder)
		w.appendUInt(avgWindKn, bits: 7)  // 119: average wind speed
		w.appendUInt(gustWindKn, bits: 7)  // 126: gust speed
		w.appendUInt(windDirDeg, bits: 9)  // 133: wind direction
		w.appendUInt(gustDirDeg, bits: 9)  // 142: gust direction
		w.appendInt(tempTenthsC, bits: 11)  // 151: air temperature (0.1 °C, signed)
		w.appendUInt(humidityPercent, bits: 7)  // 162: relative humidity
		w.appendInt(dewPointTenthsC, bits: 10)  // 169: dew point (0.1 °C, signed)
		w.appendUInt(pressureMinus800, bits: 9)  // 179: air pressure (hPa, offset 800)
		return w
	}

	/// Builds an IMO 289 IFM 31 meteo/hydro type-8 payload (wider position
	/// encoding; pressure offset 799).
	static func type8MeteoIFM31(
		mmsi: UInt32,
		lonScaled1000Min: Int32, latScaled1000Min: Int32,
		avgWindKn: UInt32, gustWindKn: UInt32,
		windDirDeg: UInt32, gustDirDeg: UInt32,
		tempTenthsC: Int32, humidityPercent: UInt32,
		dewPointTenthsC: Int32, pressureMinus799: UInt32
	) -> Self {
		var w = AISBitWriter()
		w.appendUInt(8, bits: 6)  // 0:   type 8
		w.appendUInt(0, bits: 2)  // 6:   repeat
		w.appendUInt(mmsi, bits: 30)  // 8:   source MMSI
		w.appendUInt(0, bits: 2)  // 38:  spare
		w.appendUInt(1, bits: 10)  // 40:  DAC = 1
		w.appendUInt(31, bits: 6)  // 50:  FI = 31
		w.appendInt(lonScaled1000Min, bits: 25)  // 56:  longitude (1/1000 min)
		w.appendInt(latScaled1000Min, bits: 24)  // 81:  latitude  (1/1000 min)
		w.appendUInt(0, bits: 17)  // 105: pos accuracy + day + hour + minute
		w.appendUInt(avgWindKn, bits: 7)  // 122: average wind speed
		w.appendUInt(gustWindKn, bits: 7)  // 129: gust speed
		w.appendUInt(windDirDeg, bits: 9)  // 136: wind direction
		w.appendUInt(gustDirDeg, bits: 9)  // 145: gust direction
		w.appendInt(tempTenthsC, bits: 11)  // 154: air temperature
		w.appendUInt(humidityPercent, bits: 7)  // 165: relative humidity
		w.appendInt(dewPointTenthsC, bits: 10)  // 172: dew point
		w.appendUInt(pressureMinus799, bits: 9)  // 182: air pressure (offset 799)
		return w
	}
}

// MARK: - Tests

@Suite("AIS decoder — round-trip")
struct AISTests {

	// MARK: Type 1 / 2 / 3 — Class A position report

	@Test func `Type 1 round-trip — MMSI, position, kinematics, derived country`() throws {
		// Invented French vessel (MMSI starts with MID 227 → France).
		let mmsi: UInt32 = 227_123_456
		let lat = 43.5
		let lon = 7.0
		let writer = AISBitWriter.type123(
			type: 1, mmsi: mmsi,
			navStatus: 0,  // under way using engine
			rotSigned: 0,  // 0°/min
			sogTenthsKn: 100,  // 10.0 kn
			posAcc: true,
			lonScaled: Int32((lon * 600_000).rounded()),
			latScaled: Int32((lat * 600_000).rounded()),
			cogTenthsDeg: 900,  // 90.0°
			heading: 85
		)
		let (payload, fillBits) = writer.payload()
		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "A")
		)

		#expect(target.mmsi == Int(mmsi))
		#expect(target.messageType == .positionReportClassA)
		#expect(target.channel == "A")
		let lonOut = try #require(target.longitude)
		let latOut = try #require(target.latitude)
		#expect(abs(lonOut - lon) < 1e-4)
		#expect(abs(latOut - lat) < 1e-4)
		#expect(target.speedOverGround == 10.0)
		#expect(target.courseOverGround == 90.0)
		#expect(target.trueHeading == 85)
		#expect(target.positionAccuracy == true)

		// Derived country (the feature we built on top of the decoder).
		#expect(target.country?.code == "FR")
	}

	// MARK: Type 5 — Static and voyage data

	@Test func `Type 5 round-trip — name, callsign, IMO, destination, draught`() throws {
		let writer = AISBitWriter.type5(
			mmsi: 366_730_000,  // MID 366 → USA
			imo: 9_876_543,
			callsign: "WDE1234",
			name: "MY VESSEL",
			shipType: 70,  // cargo
			draughtTenthsM: 58,  // 5.8 m
			destination: "BREST"
		)
		let (payload, fillBits) = writer.payload()
		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "B")
		)

		#expect(target.mmsi == 366_730_000)
		#expect(target.messageType == .staticAndVoyageData)
		#expect(target.shipName == "MY VESSEL")
		#expect(target.callsign == "WDE1234")
		#expect(target.imoNumber == 9_876_543)
		#expect(target.destination == "BREST")
		if let d = target.draught { #expect(abs(d - 5.8) < 1e-3) }
		#expect(target.country?.code == "US")
	}

	// MARK: Type 18 — Class B position report

	@Test func `Type 18 round-trip — Class B position with heading`() throws {
		let lat = -33.86
		let lon = 151.21
		let writer = AISBitWriter.type18(
			mmsi: 503_999_111,  // MID 503 → Australia
			sogTenthsKn: 55,  // 5.5 kn
			posAcc: false,
			lonScaled: Int32((lon * 600_000).rounded()),
			latScaled: Int32((lat * 600_000).rounded()),
			cogTenthsDeg: 1800,  // 180.0°
			heading: 175
		)
		let (payload, fillBits) = writer.payload()
		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "A")
		)

		#expect(target.messageType == .standardClassBReport)
		#expect(target.speedOverGround == 5.5)
		#expect(target.courseOverGround == 180.0)
		#expect(target.trueHeading == 175)
		let lonOut = try #require(target.longitude)
		let latOut = try #require(target.latitude)
		#expect(abs(lonOut - lon) < 1e-3)
		#expect(abs(latOut - lat) < 1e-3)
		#expect(target.country?.code == "AU")
	}

	// MARK: Type 9 — SAR aircraft position report

	@Test func `Type 9 round-trip — SAR aircraft with altitude`() throws {
		let writer = AISBitWriter.type9(
			mmsi: 111_226_001,  // SAR aircraft (111 prefix), MID 226 → France
			altitudeMetres: 1500,
			sogKn: 200,  // 200 kn (1 kn resolution)
			lonScaled: Int32((1.3 * 600_000).rounded()),
			latScaled: Int32((48.7 * 600_000).rounded()),
			cogTenthsDeg: 450  // 45.0°
		)
		let (payload, fillBits) = writer.payload()
		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "B")
		)

		#expect(target.messageType == .standardSARAircraftReport)
		#expect(target.altitude == 1500.0)
		#expect(target.speedOverGround == 200.0)  // type 9 uses 1-knot resolution
		#expect(target.courseOverGround == 45.0)
		// SAR aircraft MMSI category: 111<MID><serial>; the country code routes through the MID.
		#expect(target.country?.code == "FR")
	}

	// MARK: Type 21 — Aid-to-Navigation report

	@Test func `Type 21 round-trip — aid to navigation name and type`() throws {
		let writer = AISBitWriter.type21(
			mmsi: 992_271_001,  // AtoN MMSI (99 prefix), MID 227 → France
			aidType: 17,  // light without sectors
			name: "BUOY ALPHA",
			lonScaled: Int32((-1.5 * 600_000).rounded()),
			latScaled: Int32((47.0 * 600_000).rounded())
		)
		let (payload, fillBits) = writer.payload()
		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "A")
		)

		#expect(target.messageType == .aidToNavigationReport)
		#expect(target.shipName == "BUOY ALPHA")
		#expect(target.navAidType?.rawValue == 17)
		let lonOut = try #require(target.longitude)
		#expect(abs(lonOut + 1.5) < 1e-3)
		#expect(target.country?.code == "FR")
	}

	// MARK: Type 8 — Binary broadcast (IMO 289 IFM 11 meteo)

	@Test func `Type 8 IFM 11 — meteorological metrics decode to wind, temperature, pressure`() throws {
		let writer = AISBitWriter.type8MeteoIFM11(
			mmsi: 002_270_001,  // coast station 00<MID>... → MID 227 (France)
			lonScaled1000Min: Int32((7.0 * 60_000).rounded()),
			latScaled1000Min: Int32((43.5 * 60_000).rounded()),
			avgWindKn: 15,
			gustWindKn: 22,
			windDirDeg: 270,
			gustDirDeg: 280,
			tempTenthsC: 215,  // 21.5 °C
			humidityPercent: 65,
			dewPointTenthsC: 145,  // 14.5 °C
			pressureMinus800: 213  // 1013 hPa = 800 + 213
		)
		let (payload, fillBits) = writer.payload()
		let metrics = try #require(
			AISDecoder.decodeMeteoMetrics(payload: payload, fillBits: fillBits)
		)

		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })
		// A remote station's readings live in the `meteo.` namespace so they never
		// clobber the own-ship GPS fix, wind or barometer in the shared store.
		#expect(byName["meteo.mmsi"] == 2_270_001)
		#expect(byName["meteo.lon"].map { abs($0 - 7.0) < 1e-4 } ?? false)
		#expect(byName["meteo.lat"].map { abs($0 - 43.5) < 1e-4 } ?? false)
		#expect(byName["meteo.TWS"] == 15)
		#expect(byName["meteo.TWS.gust"] == 22)
		#expect(byName["meteo.TWD"] == 270)
		#expect(byName["meteo.TWD.gust"] == 280)
		#expect(byName["meteo.temperature.air"].map { abs($0 - 21.5) < 1e-6 } ?? false)
		#expect(byName["meteo.humidity"] == 65)
		#expect(byName["meteo.temperature.dewPoint"].map { abs($0 - 14.5) < 1e-6 } ?? false)
		#expect(byName["meteo.pressure.atmospheric"] == 1013)
		// None of the generic own-ship names leak out of the meteo decoder.
		#expect(byName["lat"] == nil)
		#expect(byName["lon"] == nil)
		#expect(byName["TWS"] == nil)
		#expect(byName["TWD"] == nil)
	}

	@Test func `Type 8 IFM 31 — current meteo standard decodes wind, temperature, pressure`() throws {
		let writer = AISBitWriter.type8MeteoIFM31(
			mmsi: 002_270_001,
			lonScaled1000Min: Int32((7.0 * 60_000).rounded()),
			latScaled1000Min: Int32((43.5 * 60_000).rounded()),
			avgWindKn: 12, gustWindKn: 18,
			windDirDeg: 225, gustDirDeg: 230,
			tempTenthsC: 188,  // 18.8 °C
			humidityPercent: 72,
			dewPointTenthsC: 132,  // 13.2 °C
			pressureMinus799: 214  // 1013 hPa = 799 + 214
		)
		let (payload, fillBits) = writer.payload()
		let metrics = try #require(
			AISDecoder.decodeMeteoMetrics(payload: payload, fillBits: fillBits)
		)
		let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0.value) })
		#expect(byName["meteo.mmsi"] == 2_270_001)
		#expect(byName["meteo.lon"].map { abs($0 - 7.0) < 1e-4 } ?? false)
		#expect(byName["meteo.lat"].map { abs($0 - 43.5) < 1e-4 } ?? false)
		#expect(byName["meteo.TWS"] == 12)
		#expect(byName["meteo.TWS.gust"] == 18)
		#expect(byName["meteo.TWD"] == 225)
		#expect(byName["meteo.TWD.gust"] == 230)
		#expect(byName["meteo.temperature.air"].map { abs($0 - 18.8) < 1e-6 } ?? false)
		#expect(byName["meteo.humidity"] == 72)
		#expect(byName["meteo.temperature.dewPoint"].map { abs($0 - 13.2) < 1e-6 } ?? false)
		#expect(byName["meteo.pressure.atmospheric"] == 1013)
		#expect(byName["lat"] == nil)
		#expect(byName["lon"] == nil)
		#expect(byName["TWS"] == nil)
		#expect(byName["TWD"] == nil)
	}

	// MARK: Types 12 & 14 — Safety messages (free text)

	@Test func `Type 14 broadcast safety message decodes its text`() throws {
		var w = AISBitWriter()
		w.appendUInt(14, bits: 6)  // message type
		w.appendUInt(0, bits: 2)  // repeat indicator
		w.appendUInt(351_809_000, bits: 30)  // source MMSI
		w.appendUInt(0, bits: 2)  // spare
		w.appendText("SAFETY TEST MSG", totalBits: 15 * 6)
		let (payload, fillBits) = w.payload()

		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "A")
		)
		#expect(target.messageType == .safetyBroadcastMessage)
		#expect(target.mmsi == 351_809_000)
		#expect(target.text == "SAFETY TEST MSG")
	}

	@Test func `Type 12 addressed safety message decodes its text`() throws {
		var w = AISBitWriter()
		w.appendUInt(12, bits: 6)  // message type
		w.appendUInt(0, bits: 2)  // repeat indicator
		w.appendUInt(123_456_789, bits: 30)  // source MMSI
		w.appendUInt(0, bits: 2)  // sequence number
		w.appendUInt(987_654_321, bits: 30)  // destination MMSI
		w.appendUInt(0, bits: 1)  // retransmit flag
		w.appendUInt(0, bits: 1)  // spare
		w.appendText("MEET AT MARINA", totalBits: 14 * 6)
		let (payload, fillBits) = w.payload()

		let target = try #require(
			AISDecoder.decode(payload: payload, fillBits: fillBits, channel: "B")
		)
		#expect(target.messageType == .addressedSafetyMessage)
		#expect(target.mmsi == 123_456_789)
		#expect(target.text == "MEET AT MARINA")
	}

	// MARK: Unrecognised payload

	@Test func `An overly short payload yields nil`() {
		// A single 6-bit character carries 6 bits — far below any type's minimum.
		#expect(AISDecoder.decode(payload: "1", fillBits: 0, channel: "A") == nil)
	}

	// MARK: Multi-part reassembly

	@Test func `Multi-part type 5 with a zero sequential ID assembles and decodes the ship name`() async throws {
		// A 426-bit type-5 payload split across two AIVDM fragments with an
		// empty/zero sequential ID (field 3) — the common real-world case. A
		// per-part fallback key used to scatter the fragments so they never
		// combined, leaving every target nameless.
		let (payload, fill) = AISBitWriter.type5(
			mmsi: 366_000_001, imo: 9_074_729, callsign: "WDE1234",
			name: "MY VESSEL", shipType: 70, draughtTenthsM: 64, destination: "NEW YORK"
		).payload()
		let mid = payload.index(payload.startIndex, offsetBy: payload.count / 2)
		let fragment1 = String(payload[..<mid])
		let fragment2 = String(payload[mid...])

		func vdm(part: Int, _ fragment: String, fillBits: Int) -> String {
			let body = "AIVDM,2,\(part),0,A,\(fragment),\(fillBits)"
			let checksum = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
			return "!\(body)*\(String(format: "%02X", checksum))"
		}
		// First fragment ends on a character boundary, so it has no pad bits;
		// the original pad count belongs to the final fragment.
		let log =
			vdm(part: 1, fragment1, fillBits: 0) + "\n"
			+ vdm(part: 2, fragment2, fillBits: fill) + "\n"

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("ais-type5-\(UUID().uuidString).nmea")
		try log.write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }

		var shipName: String?
		for try await fileFrame in NMEATransport.fileStream(path: url.path) {
			if case .aisTarget(let target) = fileFrame.frame, let name = target.shipName {
				shipName = name
				break
			}
		}
		#expect(shipName == "MY VESSEL")
	}
}
