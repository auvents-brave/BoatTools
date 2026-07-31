public import Foundation

// MARK: - Man Overboard notification

/// A man-overboard alert to broadcast onto the boat's network — the position of
/// the incident and the vessel's motion when it was raised.
///
/// Encoded as **PGN 127233 (Man Overboard Notification)** on an NMEA 2000
/// connection and as an **`$--MOB`** sentence on NMEA 0183, so a chart plotter
/// on the bus shows the alert and its position alongside the app.
///
/// > Warning: The wire encodings below follow the published field layouts but
/// > have **not been checked against real MOB-aware hardware**. Treat them as a
/// > best-effort signal; the app's own return-to-casualty guidance does not
/// > depend on them.
public struct ManOverboardNotification: Sendable, Equatable {

	/// Whether the alert is being raised or stood down.
	public enum Status: Sendable, Equatable {
		/// The alert is active — a casualty is in the water.
		case activated
		/// The alert is being cancelled (recovery complete or false alarm).
		case cancelled
	}

	/// Whether the alert is active or being cancelled.
	public var status: Status
	/// Latitude of the incident, decimal degrees (north positive).
	public var latitude: Double
	/// Longitude of the incident, decimal degrees (east positive).
	public var longitude: Double
	/// When the alert was first raised.
	public var activation: Date
	/// The vessel's course over ground at activation, degrees true (`nil` = unknown).
	public var courseTrueDegrees: Double?
	/// The vessel's speed over ground at activation, knots (`nil` = unknown).
	public var speedKnots: Double?
	/// A stable identifier for the emitter — the app uses a fixed value.
	public var emitterID: UInt32

	/// Creates a notification.
	/// - Parameters:
	///   - status: Active or cancelled.
	///   - latitude: Incident latitude, decimal degrees.
	///   - longitude: Incident longitude, decimal degrees.
	///   - activation: When the alert was raised.
	///   - courseTrueDegrees: Course over ground at activation, degrees true.
	///   - speedKnots: Speed over ground at activation, knots.
	///   - emitterID: Emitter identifier (defaults to the app's marker).
	public init(
		status: Status,
		latitude: Double,
		longitude: Double,
		activation: Date,
		courseTrueDegrees: Double? = nil,
		speedKnots: Double? = nil,
		emitterID: UInt32 = 0x00_42_54_00
	) {
		self.status = status
		self.latitude = latitude
		self.longitude = longitude
		self.activation = activation
		self.courseTrueDegrees = courseTrueDegrees
		self.speedKnots = speedKnots
		self.emitterID = emitterID
	}

	// MARK: NMEA 2000 — PGN 127233

	/// The PGN 127233 message: a 35-byte fast-packet payload the encoder
	/// fragments for RAW gateways and carries whole on self-framing ones.
	public var nmea2000Message: OutboundMessage {
		var data = [UInt8]()
		data.append(0xFF)  // SID — not sequenced
		appendLE(&data, emitterID, bytes: 4)  // MOB Emitter ID

		// MOB status (3 bits) + reserved (5 bits). 2 = manual on-board button;
		// a stand-down carries 7 (not active) — the closest published value.
		data.append((status == .activated ? 0x02 : 0x07) | 0xF8)

		appendTime(&data, activation)  // Activation time
		data.append(0x00 | 0xF8)  // Position source: 0 = estimated by the vessel
		appendDate(&data, activation)  // Position date
		appendTime(&data, activation)  // Position time
		appendLE(&data, coordinateBits(latitude), bytes: 4)  // Latitude, 1e-7 deg
		appendLE(&data, coordinateBits(longitude), bytes: 4)  // Longitude, 1e-7 deg
		data.append(0x00 | 0xFC)  // COG reference: 0 = true

		// COG, 0.0001 rad/bit; SOG, 0.01 m/s/bit.
		appendLE(&data, angleBits(courseTrueDegrees), bytes: 2)
		appendLE(&data, speedBits(speedKnots), bytes: 2)
		appendLE(&data, 0xFFFF_FFFF, bytes: 4)  // MMSI — not applicable
		data.append(0xFF)  // MOB emitter battery status — unknown

		return .nmea2000(pgn: 127233, destination: 255, priority: 3, data: data)
	}

	// MARK: NMEA 0183 — $--MOB

	/// The `$--MOB` sentence body (talker `EC`), without the leading `$` and the
	/// checksum, which ``NMEASession/send(_:)``'s encoder appends.
	public var nmea0183Message: OutboundMessage {
		let time = Self.utcTimeField(activation)
		let date = Self.utcDateField(activation)
		let statusCode = status == .activated ? "A" : "V"
		let (lat, ns) = Self.latitudeField(latitude)
		let (lon, ew) = Self.longitudeField(longitude)
		let cog = courseTrueDegrees.map { String(format: "%.1f", $0) } ?? ""
		let sog = speedKnots.map { String(format: "%.1f", $0) } ?? ""
		let id = String(format: "%08X", emitterID)
		let body = [
			"ECMOB", id, statusCode, time, "0", date + time,
			lat, ns, lon, ew, cog, sog, "", "A",
		].joined(separator: ",")
		return .nmea0183(body: body)
	}

	// MARK: Field encoding

	private func coordinateBits(_ degrees: Double) -> UInt32 {
		UInt32(bitPattern: Int32((degrees * 1e7).rounded()))
	}

	private func angleBits(_ degrees: Double?) -> UInt32 {
		guard let degrees else { return 0xFFFF }
		let radians = degrees * .pi / 180
		return UInt32(max(0, min(0xFFFE, Int((radians / 0.0001).rounded()))))
	}

	private func speedBits(_ knots: Double?) -> UInt32 {
		guard let knots else { return 0xFFFF }
		let metresPerSecond = knots * 0.514_444
		return UInt32(max(0, min(0xFFFE, Int((metresPerSecond / 0.01).rounded()))))
	}

	private func appendLE(_ data: inout [UInt8], _ value: UInt32, bytes: Int) {
		for i in 0..<bytes { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
	}

	/// NMEA 2000 date: days since 1970-01-01, little-endian uint16.
	private func appendDate(_ data: inout [UInt8], _ date: Date) {
		let days = UInt32(max(0, Int(date.timeIntervalSince1970 / 86_400)))
		appendLE(&data, days, bytes: 2)
	}

	/// NMEA 2000 time: seconds since midnight UTC at 0.0001 s/bit, little-endian uint32.
	private func appendTime(_ data: inout [UInt8], _ date: Date) {
		let seconds = date.timeIntervalSince1970
		let secondsOfDay = seconds - (seconds / 86_400).rounded(.down) * 86_400
		appendLE(&data, UInt32(max(0, (secondsOfDay / 0.0001).rounded())), bytes: 4)
	}

	private static func utcTimeField(_ date: Date) -> String {
		let seconds = date.timeIntervalSince1970
		let secondsOfDay = seconds - (seconds / 86_400).rounded(.down) * 86_400
		let h = Int(secondsOfDay / 3600)
		let m = Int(secondsOfDay.truncatingRemainder(dividingBy: 3600) / 60)
		let s = secondsOfDay.truncatingRemainder(dividingBy: 60)
		return String(format: "%02d%02d%05.2f", h, m, s)
	}

	private static func utcDateField(_ date: Date) -> String {
		// ddmmyy in UTC.
		let days = Int(date.timeIntervalSince1970 / 86_400)
		var year = 1970
		var day = days
		func leap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
		while day >= (leap(year) ? 366 : 365) {
			day -= leap(year) ? 366 : 365
			year += 1
		}
		let monthLengths = [31, leap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
		var month = 0
		while day >= monthLengths[month] {
			day -= monthLengths[month]
			month += 1
		}
		return String(format: "%02d%02d%02d", day + 1, month + 1, year % 100)
	}

	private static func latitudeField(_ degrees: Double) -> (String, String) {
		let hemisphere = degrees >= 0 ? "N" : "S"
		let value = abs(degrees)
		let d = Int(value)
		let minutes = (value - Double(d)) * 60
		return (String(format: "%02d%07.4f", d, minutes), hemisphere)
	}

	private static func longitudeField(_ degrees: Double) -> (String, String) {
		let hemisphere = degrees >= 0 ? "E" : "W"
		let value = abs(degrees)
		let d = Int(value)
		let minutes = (value - Double(d)) * 60
		return (String(format: "%03d%07.4f", d, minutes), hemisphere)
	}
}

// MARK: - Session sugar

extension NMEASession {

	/// Broadcasts a man-overboard alert on this connection — PGN 127233 on an
	/// NMEA 2000 link, an `$--MOB` sentence on NMEA 0183.
	///
	/// - Parameter notification: The alert to send.
	/// - Throws: The ``send(_:)`` transport errors.
	public func send(_ notification: ManOverboardNotification) async throws {
		if resolvedFormat == .nmea0183 {
			try await send(notification.nmea0183Message)
		} else {
			try await send(notification.nmea2000Message)
		}
	}
}
