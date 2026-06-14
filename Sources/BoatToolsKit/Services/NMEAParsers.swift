internal import Foundation  // floor

// MARK: - NMEA 0183

/// NMEA 0183 parser and sentence-level metric decoder.
///
/// All methods are stateless pure functions — no side effects, trivially `Sendable`.
public enum NMEA0183Parser {

	/// Parses a single NMEA 0183 sentence string into an ``NMEAFrame``.
	///
	/// The sentence must start with `$` or `!`. When a `*XX` checksum suffix is
	/// present the XOR checksum is verified; a mismatch returns
	/// `.invalidChecksum(rawLine:)` rather than `nil` so callers can distinguish
	/// corrupt data from unrecognised formats.
	///
	/// - Returns: A `.nmea0183` frame on success, `.invalidChecksum` on bad XOR,
	///   or `nil` when the line is not an NMEA 0183 sentence at all.
	public static func parse(_ sentence: String) -> NMEAFrame? {
		guard sentence.hasPrefix("$") || sentence.hasPrefix("!") else { return nil }
		let parts = sentence.split(separator: "*", maxSplits: 1).map(String.init)
		let core = parts[0]
		if parts.count == 2, parts[1].count >= 2 {
			let expected = parts[1].prefix(2)
			let computed = String(format: "%02X", xorChecksum(core.dropFirst()))
			guard computed.caseInsensitiveCompare(expected) == .orderedSame else {
				return .invalidChecksum(rawLine: sentence)
			}
		}
		let fields = core.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
		guard let header = fields.first, header.count >= 4 else { return nil }
		let id = String(header.dropFirst())
		let talker = String(id.prefix(id.count - 3))
		let type = String(id.suffix(3))
		return .nmea0183(sentence: sentence, talker: talker, type: type, fields: fields)
	}

	/// XOR checksum over the characters between `$`/`!` and `*`.
	static func xorChecksum(_ s: some StringProtocol) -> UInt8 {
		s.utf8.reduce(0) { $0 ^ $1 }
	}

	/// The destination waypoint identifier carried by routing sentences —
	/// RMB (field 5), APB (field 10), BWC/BWR (field 12) and WPL (field 5).
	///
	/// Waypoint names are strings, so they cannot travel as ``BoatMetric``
	/// values; ``BoatMetricStore`` lifts them into its `labels` side channel.
	///
	/// - Parameters:
	///   - type: The three-letter sentence type (e.g. `"RMB"`).
	///   - fields: The sentence fields as split by ``parse(_:)``.
	/// - Returns: The waypoint identifier, or `nil` when absent or empty.
	public static func waypointName(type: String, fields f: [String]) -> String? {
		let id: String?
		switch type {
		case "RMB", "WPL": id = f.count > 5 ? f[5] : nil
		case "APB": id = f.count > 10 ? f[10] : nil
		case "BWC", "BWR": id = f.count > 12 ? f[12] : nil
		default: id = nil
		}
		guard let id, !id.isEmpty else { return nil }
		return id
	}

	/// The set of NMEA 0183 sentence types for which ``decode(_:)`` produces ``BoatMetric`` values.
	///
	/// Useful for distinguishing "recognised but no decoder implemented yet" from a fully
	/// supported sentence in user-facing displays.
	public static let decodedTypes: Set<String> = [
		"RMC", "MWV", "DPT", "DBT", "VBW", "VHW",
		"HDT", "HDG", "HDM", "MWD", "VTG",
		"GLL", "XDR",
		"GGA", "GSA", "GNS", "GST", "GSV",
		"ROT", "MTW", "VLW", "VWR", "ZDA",
		"MDA", "XTE", "APA", "APB", "RMB", "RSA", "RPM",
		"BWC", "BWR", "BWW", "BOD", "RTE", "RSD",
		"WPL", "ALR", "DSC", "DSE",
		"VDM", "VDO",  // AIS — multi-message, decoded by AISDecoder via FrameDispatcher
		"VER",  // Equipment Version — text fields rendered by the CLI
		"TNL",  // Trimble proprietary — GGK, AVR, VHD, PJK
		"TRO",  // $PHTRO — Hemisphere/CCS pitch & roll proprietary
		"OUT",  // $PMAROUT — Maretron power management (genset, inverter, charger)
	]

	/// Decodes the fields of a parsed NMEA 0183 sentence into ``BoatMetric`` values.
	///
	/// Supported sentence types are listed in ``decodedTypes``. Returns `nil` for
	/// unrecognised types or when required fields are absent.
	///
	/// - Parameter fields: The comma-split fields array from a `.nmea0183` frame,
	///   including the leading `$TTXXX` header as `fields[0]`.
	public static func decode(_ fields: [String]) -> [BoatMetric]? {
		guard let header = fields.first, header.count >= 4 else { return nil }
		let type = String(header.suffix(3))
		switch type {
		case "RMC": return decodeRMC(fields)
		case "MWV": return decodeMWV(fields)
		case "DPT": return decodeDPT(fields)
		case "DBT": return decodeDBT(fields)
		case "VBW": return decodeVBW(fields)
		case "VHW": return decodeVHW(fields)
		case "HDT", "HDG", "HDM": return decodeHeading(fields, type: type)
		case "MWD": return decodeMWD(fields)
		case "VTG": return decodeVTG(fields)
		case "GLL": return decodeGLL(fields)
		case "XDR": return decodeXDR(fields)
		case "GGA": return decodeGGA(fields)
		case "GSA": return decodeGSA(fields)
		case "GNS": return decodeGNS(fields)
		case "GST": return decodeGST(fields)
		// GSV is handled statefully by the FrameDispatcher's GSVAssembler
		// (multi-message series) — no per-sentence decode here.
		case "ROT": return decodeROT(fields)
		case "MTW": return decodeMTW(fields)
		case "VLW": return decodeVLW(fields)
		case "VWR": return decodeVWR(fields)
		case "ZDA": return decodeZDA(fields)
		case "TNL": return decodeTNL(fields)
		case "MDA": return decodeMDA(fields)
		case "MTA": return decodeMTA(fields)
		case "MMB": return decodeMMB(fields)
		case "VWT": return decodeVWT(fields)
		case "XTE": return decodeXTE(fields)
		case "APA", "APB": return decodeAPB(fields)  // APA = APB without the last 4 fields
		case "RMB": return decodeRMB(fields)
		case "RSA": return decodeRSA(fields)
		case "RPM": return decodeRPM(fields)
		case "WPL": return decodeWPL(fields)
		case "ALR": return decodeALR(fields)
		case "DSC": return decodeDSC(fields)
		case "DSE": return decodeDSE(fields)
		case "TRO": return decodePHTRO(fields)
		case "OUT": return decodePMAROUT(fields)
		case "BWC", "BWR": return decodeBWC(fields)  // great-circle / rhumb-line share format
		case "BWW": return decodeBWW(fields)
		case "BOD": return decodeBOD(fields)
		case "RTE": return decodeRTE(fields)
		case "RSD": return decodeRSD(fields)
		default: return nil
		}
	}

	// MARK: Sentence decoders

	private static func decodeRMC(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9, f[2] == "A" else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[3], hemi: f[4]) { out.append(.init(name: "lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[5], hemi: f[6]) { out.append(.init(name: "lon", value: lon, unit: "°")) }
		if let sog = Double(f[7]) { out.append(.init(name: "SOG", value: sog, unit: "kn")) }
		if let cog = Double(f[8]) { out.append(.init(name: "COG", value: cog, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	private static func decodeMWV(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 6, f[5].hasPrefix("A") else { return nil }
		let isTrue = f[2] == "T"
		var out: [BoatMetric] = []
		if let a = Double(f[1]) { out.append(.init(name: isTrue ? "TWA" : "AWA", value: a, unit: "°")) }
		if let s = Double(f[3]) { out.append(.init(name: isTrue ? "TWS" : "AWS", value: s, unit: f[4])) }
		return out.isEmpty ? nil : out
	}

	// DPT — Depth of water relative to the transducer.
	//   $--DPT,<metres>,<offset>,<maxRange>*cs
	private static func decodeDPT(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 2, let d = Double(f[1]) else { return nil }
		return [.init(name: "depth", value: d, unit: "m")]
	}

	// DBT — Depth below transducer, reported simultaneously in feet, metres and
	// fathoms.
	//   $--DBT,<feet>,f,<metres>,M,<fathoms>,F*cs
	// The metres field (index 3) is authoritative; some talkers omit it, so fall
	// back to converting the feet field.
	private static func decodeDBT(_ f: [String]) -> [BoatMetric]? {
		if f.count >= 4, let m = Double(f[3]) {
			return [.init(name: "depth", value: m, unit: "m")]
		}
		if f.count >= 2, let feet = Double(f[1]) {
			return [.init(name: "depth", value: feet * 0.3048, unit: "m")]
		}
		return nil
	}

	// VBW — Dual ground/water speed.
	//   $--VBW,<longWater>,<transWater>,<statusWater A|V>,
	//          <longGround>,<transGround>,<statusGround A|V>,…*cs
	// Longitudinal components are positive forward; transverse components are
	// positive to starboard. Each pair is gated on its own A/V status flag.
	//
	// The longitudinal components are the same physical quantities as `STW`
	// (water) and `SOG` (ground), so they are emitted under those canonical
	// names and resolved against VHW/VTG/RMC by the metric store's priority
	// tables. The transverse components (leeway / sideways set) have no
	// equivalent in any other sentence and keep their own names.
	private static func decodeVBW(_ f: [String]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if f.count >= 4, f[3].hasPrefix("A") {
			if let l = Double(f[1]) { out.append(.init(name: "STW", value: l, unit: "kn")) }
			if let t = Double(f[2]) { out.append(.init(name: "speed.water.transverse", value: t, unit: "kn")) }
		}
		if f.count >= 7, f[6].hasPrefix("A") {
			if let l = Double(f[4]) { out.append(.init(name: "SOG", value: l, unit: "kn")) }
			if let t = Double(f[5]) { out.append(.init(name: "speed.ground.transverse", value: t, unit: "kn")) }
		}
		return out.isEmpty ? nil : out
	}

	// VHW — Water speed and heading.
	//   $--VHW,<headTrue>,T,<headMag>,M,<speedKn>,N,<speedKmh>,K*cs
	private static func decodeVHW(_ f: [String]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if f.count >= 2, let ht = Double(f[1]) { out.append(.init(name: "HDG.true", value: ht, unit: "°")) }
		if f.count >= 4, let hm = Double(f[3]) { out.append(.init(name: "HDG.magnetic", value: hm, unit: "°")) }
		if f.count >= 6, let s = Double(f[5]) { out.append(.init(name: "STW", value: s, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	private static func decodeHeading(_ f: [String], type: String) -> [BoatMetric]? {
		guard f.count >= 2, let h = Double(f[1]) else { return nil }
		let name: String
		switch type {
		case "HDT": name = "HDG.true"
		case "HDM": name = "HDG.magnetic"
		default: name = "HDG"
		}
		return [.init(name: name, value: h, unit: "°")]
	}

	private static func decodeMWD(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 6 else { return nil }
		var out: [BoatMetric] = []
		if let d = Double(f[1]) { out.append(.init(name: "TWD", value: d, unit: "°")) }
		if let s = Double(f[5]) { out.append(.init(name: "TWS", value: s, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	private static func decodeVTG(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 6 else { return nil }
		var out: [BoatMetric] = []
		if let c = Double(f[1]) { out.append(.init(name: "COG", value: c, unit: "°")) }
		if let s = Double(f[5]) { out.append(.init(name: "SOG", value: s, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	private static func decodeGLL(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 7, f[6].hasPrefix("A") else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[1], hemi: f[2]) { out.append(.init(name: "lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[3], hemi: f[4]) { out.append(.init(name: "lon", value: lon, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	private static func decodeXDR(_ f: [String]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		var i = 1
		while i + 3 < f.count {
			if let v = Double(f[i + 1]) {
				let id = f[i + 3]
				let unit = f[i + 2]
				out.append(.init(name: id.isEmpty ? "xdr.\(i)" : id, value: v, unit: unit))
			}
			i += 4
		}
		return out.isEmpty ? nil : out
	}

	// GGA — GPS fix data
	private static func decodeGGA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 10 else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[2], hemi: f[3]) { out.append(.init(name: "lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[4], hemi: f[5]) { out.append(.init(name: "lon", value: lon, unit: "°")) }
		if let alt = Double(f[9]) { out.append(.init(name: "altitude", value: alt, unit: "m")) }
		if let q = Int(f[6]) { out.append(.init(name: "gps.quality", value: Double(q))) }
		if let n = Int(f[7]) { out.append(.init(name: "gps.satellites", value: Double(n))) }
		if let h = Double(f[8]) { out.append(.init(name: "gps.hdop", value: h)) }
		return out.isEmpty ? nil : out
	}

	// GSA — GPS DOP and active satellites
	// $..GSA,<mode>,<fix>,<PRN×12>,<PDOP>,<HDOP>,<VDOP>[,<systemID>]
	private static func decodeGSA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 18 else { return nil }
		var out: [BoatMetric] = []
		if let fix = Int(f[2]) { out.append(.init(name: "gps.fix", value: Double(fix))) }
		// Count non-empty PRN slots (f[3] … f[14])
		let usedSats = (3...14).reduce(0) { acc, i in
			i < f.count && !f[i].isEmpty ? acc + 1 : acc
		}
		if usedSats > 0 { out.append(.init(name: "gps.satellites", value: Double(usedSats))) }
		if let p = Double(f[15]) { out.append(.init(name: "gps.pdop", value: p)) }
		if let h = Double(f[16]) { out.append(.init(name: "gps.hdop", value: h)) }
		// VDOP may contain a checksum suffix on the last field — strip it
		let vdopStr = f[17].split(separator: "*").first.map(String.init) ?? f[17]
		if let v = Double(vdopStr) { out.append(.init(name: "gps.vdop", value: v)) }
		return out.isEmpty ? nil : out
	}

	// GNS — Fix data, multi-constellation
	// $..GNS,<UTC>,<lat>,<N/S>,<lon>,<E/W>,<modeIndicator>,<satsUsed>,<HDOP>,<alt>,<geoidSep>,<diffAge>,<diffRef>
	//
	// Per-constellation talker IDs ($GPGNS, $GLGNS, …) carry that constellation's
	// satellite count and HDOP only — the position fields are often empty since
	// the aggregate $GNGNS already holds them. We namespace those by talker to
	// keep them separate from the aggregate.
	private static func decodeGNS(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9, let header = f.first, header.count >= 4 else { return nil }
		// Extract talker from header to namespace per-constellation metrics.
		let id = String(header.dropFirst())  // e.g. "GPGNS"
		let talker = String(id.prefix(id.count - 3))  // "GP", "GL", "BD", "GN"
		let prefix: String
		switch talker {
		case "GP": prefix = "gps"
		case "GL": prefix = "glonass"
		case "GA": prefix = "galileo"
		case "BD", "GB": prefix = "beidou"
		case "GQ", "QZ": prefix = "qzss"
		case "GI": prefix = "navic"
		default: prefix = "gnss"  // GN aggregate or unknown
		}

		// Mode indicator: aggregate has one char per system, per-constellation has 1 char.
		let mode = f[6]
		var out: [BoatMetric] = []

		// Decode the mode indicator for this constellation as a fix status (per-prefix).
		if !mode.isEmpty {
			let firstChar = mode.first!
			// 0=no fix(N), 1=autonomous(A), 2=DGPS(D), 3=PPS(P),
			// 4=RTK fixed(R), 5=RTK float(F), 6=estimated(E), 7=manual(M), 8=sim(S)
			let modeValue: Int
			switch firstChar {
			case "N": modeValue = 0
			case "A": modeValue = 1
			case "D": modeValue = 2
			case "P": modeValue = 3
			case "R": modeValue = 4
			case "F": modeValue = 5
			case "E": modeValue = 6
			case "M": modeValue = 7
			case "S": modeValue = 8
			default: modeValue = -1
			}
			if modeValue >= 0 {
				out.append(.init(name: "\(prefix).mode", value: Double(modeValue)))
			}
		}

		if let lat = nmeaCoord(f[2], hemi: f[3]) { out.append(.init(name: "lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[4], hemi: f[5]) { out.append(.init(name: "lon", value: lon, unit: "°")) }
		if let n = Int(f[7]) { out.append(.init(name: "\(prefix).satellites", value: Double(n))) }
		if let h = Double(f[8]) { out.append(.init(name: "\(prefix).hdop", value: h)) }
		if f.count >= 10, let a = Double(f[9]) {
			out.append(.init(name: "altitude", value: a, unit: "m"))
		}
		return out.isEmpty ? nil : out
	}

	// ROT — Rate of turn
	private static func decodeROT(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 3, f[2].hasPrefix("A"), let rot = Double(f[1]) else { return nil }
		return [.init(name: "ROT", value: rot, unit: "°/min")]
	}

	// MTW — Water temperature
	private static func decodeMTW(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 3, let t = Double(f[1]) else { return nil }
		// f[2] is unit: C or F; always store as °C
		let celsius = f[2] == "F" ? (t - 32) * 5 / 9 : t
		return [.init(name: "temperature.water", value: celsius, unit: "°C")]
	}

	// VLW — Distance traveled through the water
	private static func decodeVLW(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let total = Double(f[1]) { out.append(.init(name: "log.total", value: total, unit: "NM")) }
		if let trip = Double(f[3]) { out.append(.init(name: "log.trip", value: trip, unit: "NM")) }
		return out.isEmpty ? nil : out
	}

	// VWR — Relative wind speed and angle
	private static func decodeVWR(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9 else { return nil }
		var out: [BoatMetric] = []
		if let a = Double(f[1]) {
			let signed = f[2] == "L" ? -a : a
			out.append(.init(name: "AWA", value: signed, unit: "°"))
		}
		if let s = Double(f[3]) { out.append(.init(name: "AWS", value: s, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	// VWT — True wind speed and angle (relative to the bow)
	private static func decodeVWT(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9 else { return nil }
		var out: [BoatMetric] = []
		if let a = Double(f[1]) {
			let signed = f[2] == "L" ? -a : a
			out.append(.init(name: "TWA", value: signed, unit: "°"))
		}
		if let s = Double(f[3]) { out.append(.init(name: "TWS", value: s, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	// MTA — Air temperature
	private static func decodeMTA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 3, let t = Double(f[1]) else { return nil }
		let celsius = f[2] == "F" ? (t - 32) * 5 / 9 : t
		return [.init(name: "temperature.air", value: celsius, unit: "°C")]
	}

	// MMB — Barometer (inches of mercury and/or bars)
	private static func decodeMMB(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		if let bars = Double(f[3]) {
			return [.init(name: "pressure.atmospheric", value: bars * 1000, unit: "hPa")]
		}
		if let inHg = Double(f[1]) {
			return [.init(name: "pressure.atmospheric", value: inHg * 33.8639, unit: "hPa")]
		}
		return nil
	}

	// ZDA — Time and date
	private static func decodeZDA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5,
			let d = Int(f[2]), let mo = Int(f[3]), let yr = Int(f[4]),
			let timeStr = f[1].split(separator: ".").first.map(String.init),
			timeStr.count >= 6,
			let hh = Int(timeStr.prefix(2)),
			let mm = Int(timeStr.dropFirst(2).prefix(2)),
			let ss = Int(timeStr.dropFirst(4).prefix(2))
		else { return nil }

		var components = DateComponents()
		components.year = yr
		components.month = mo
		components.day = d
		components.hour = hh
		components.minute = mm
		components.second = ss
		components.timeZone = TimeZone(identifier: "UTC")
		guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
		return [.init(name: "utc.timestamp", value: date.timeIntervalSince1970, unit: "s")]
	}

	// GST — GPS pseudorange noise statistics
	// $..GST,<utc>,<rmsTotal>,<smjrDev>,<smnrDev>,<smjrOri>,<latErr>,<lonErr>,<altErr>*cs
	private static func decodeGST(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9 else { return nil }
		var out: [BoatMetric] = []
		if let r = Double(f[2]) { out.append(.init(name: "gps.rms", value: r, unit: "m")) }
		if let l = Double(f[6]) { out.append(.init(name: "gps.error.lat", value: l, unit: "m")) }
		if let l = Double(f[7]) { out.append(.init(name: "gps.error.lon", value: l, unit: "m")) }
		// Last field may carry a *XX checksum suffix.
		let altStr = f[8].split(separator: "*").first.map(String.init) ?? f[8]
		if let a = Double(altStr) { out.append(.init(name: "gps.error.alt", value: a, unit: "m")) }
		return out.isEmpty ? nil : out
	}

	// MDA — Meteorological Composite
	//   $..MDA,<inHg>,I,<bar>,B,<airT>,C,<waterT>,C,<rh%>,<absH%>,<dewC>,C,
	//         <windDirT>,T,<windDirM>,M,<windKn>,N,<windMS>,M*cs
	private static func decodeMDA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 21 else { return nil }
		var out: [BoatMetric] = []
		// Pressure — prefer bars (more precise), else fall back to inches Hg.
		if let p = Double(f[3]) {
			out.append(.init(name: "pressure.atmospheric", value: p * 1000, unit: "hPa"))
		} else if let p = Double(f[1]) {
			out.append(.init(name: "pressure.atmospheric", value: p * 33.8639, unit: "hPa"))
		}
		if let t = Double(f[5]) { out.append(.init(name: "temperature.air", value: t, unit: "°C")) }
		if let t = Double(f[7]) { out.append(.init(name: "temperature.water", value: t, unit: "°C")) }
		if let h = Double(f[9]) { out.append(.init(name: "humidity", value: h, unit: "%")) }
		if let d = Double(f[11]) { out.append(.init(name: "temperature.dewPoint", value: d, unit: "°C")) }
		if let wd = Double(f[13]) { out.append(.init(name: "TWD", value: wd, unit: "°")) }
		if let ws = Double(f[17]) { out.append(.init(name: "TWS", value: ws, unit: "kn")) }
		return out.isEmpty ? nil : out
	}

	// XTE — Cross-Track Error, Measured
	//   $..XTE,<status>,<cycleLock>,<magnitude>,<L|R>,<units N|K|M>*cs
	//   units: N=nm, K=km, M=metres. Sign convention: L of track is negative.
	private static func decodeXTE(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 6, f[1].hasPrefix("A"),
			let mag = Double(f[3])
		else { return nil }
		let signed = f[4] == "L" ? -mag : mag
		let nm: Double
		switch f[5].prefix(1) {
		case "K": nm = signed / 1.852
		case "M": nm = signed / 1852.0
		default: nm = signed  // assume N
		}
		return [.init(name: "navigation.xte", value: nm, unit: "NM")]
	}

	// APA / APB — Autopilot Sentences
	//   APB: $..APB,<s1>,<s2>,<xte>,<L|R>,<units>,<arrival>,<perpPassed>,
	//              <bearingOrigToDest>,<M|T>,<dest>,<bearingPresToDest>,<M|T>,
	//              <headingToSteer>,<M|T>*cs
	//   APA: same as APB without the last 4 fields (no position-to-dest bearing,
	//        no heading-to-steer). APA is older / deprecated but still present
	//        in many real streams.
	//
	// We accept any sentence with at least 9 fields (the APA minimum) and only
	// emit the APB-only metrics when the full 14 fields are present.
	private static func decodeAPB(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 9, f[1].hasPrefix("A") else { return nil }
		var out: [BoatMetric] = []
		if let mag = Double(f[3]) {
			let signed = f[4] == "L" ? -mag : mag
			let nm: Double
			switch f[5].prefix(1) {
			case "K": nm = signed / 1.852
			case "M": nm = signed / 1852.0
			default: nm = signed
			}
			out.append(.init(name: "navigation.xte", value: nm, unit: "NM"))
		}
		if let b = Double(f[8]) {
			out.append(.init(name: "navigation.bearingOriginToDest", value: b, unit: "°"))
		}
		// APB-only fields — guarded on field count
		if f.count >= 12, let b = Double(f[11]) {
			out.append(.init(name: "navigation.bearingToDest", value: b, unit: "°"))
		}
		if f.count >= 14, let h = Double(f[13]) {
			out.append(.init(name: "navigation.headingToSteer", value: h, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	// RMB — Recommended Minimum Navigation Information
	//   $..RMB,<status>,<xte>,<L|R>,<origWP>,<destWP>,<destLat>,<N|S>,<destLon>,<E|W>,
	//          <range>,<bearing>,<vmg>,<arrival>,<mode>*cs
	//
	// Single sentence carrying XTE, destination waypoint position, range, bearing
	// and VMG — typically broadcast by chartplotters as a richer alternative to APB.
	// XTE is already in NM (no unit field).
	private static func decodeRMB(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 13, f[1].hasPrefix("A") else { return nil }
		var out: [BoatMetric] = []
		if let mag = Double(f[2]) {
			let signed = f[3] == "L" ? -mag : mag
			out.append(.init(name: "navigation.xte", value: signed, unit: "NM"))
		}
		if let lat = nmeaCoord(f[6], hemi: f[7]) {
			out.append(.init(name: "waypoint.lat", value: lat, unit: "°"))
		}
		if let lon = nmeaCoord(f[8], hemi: f[9]) {
			out.append(.init(name: "waypoint.lon", value: lon, unit: "°"))
		}
		if let r = Double(f[10]) {
			out.append(.init(name: "navigation.distanceToWaypoint", value: r, unit: "NM"))
		}
		if let b = Double(f[11]) {
			out.append(.init(name: "navigation.bearingToDest", value: b, unit: "°"))
		}
		if let vmg = Double(f[12]) {
			out.append(.init(name: "navigation.vmg", value: vmg, unit: "kn"))
		}
		return out.isEmpty ? nil : out
	}

	// RSA — Rudder Sensor Angle
	//   $..RSA,<starboard>,A,<port>,A*cs
	//   Convention: negative = port, positive = starboard.
	private static func decodeRSA(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 3 else { return nil }
		var out: [BoatMetric] = []
		if f[2].hasPrefix("A"), let a = Double(f[1]) {
			out.append(.init(name: "rudder", value: a, unit: "°"))
		}
		if f.count >= 5, f[4].hasPrefix("A"), let a = Double(f[3]) {
			out.append(.init(name: "rudder.port", value: a, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	// RPM — Revolutions
	//   $..RPM,<source S|E>,<number>,<speedRPM>,<pitch%>,<status A|V>*cs
	private static func decodeRPM(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 6, f[5].hasPrefix("A") else { return nil }
		let inst = Int(f[2]) ?? 0
		let bucket = f[1] == "S" ? "shaft" : "engine"
		var out: [BoatMetric] = []
		if let rpm = Double(f[3]) { out.append(.init(name: "\(bucket).\(inst).rpm", value: rpm, unit: "rpm")) }
		if let pitch = Double(f[4]) { out.append(.init(name: "\(bucket).\(inst).pitch", value: pitch, unit: "%")) }
		return out.isEmpty ? nil : out
	}

	// WPL — Waypoint Location
	//   $..WPL,<lat>,<N|S>,<lon>,<E|W>,<waypoint_id>*cs
	private static func decodeWPL(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[1], hemi: f[2]) { out.append(.init(name: "waypoint.lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[3], hemi: f[4]) { out.append(.init(name: "waypoint.lon", value: lon, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	// ALR — Set Alarm State
	//   $..ALR,<utc>,<alarmId>,<condition A|V>,<ack A|V>,<description>*cs
	//   Emits alarm.<id>.active (1/0) and alarm.<id>.acknowledged (1/0).
	private static func decodeALR(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5, let id = Int(f[2]) else { return nil }
		return [
			.init(name: "alarm.\(id).active", value: f[3].hasPrefix("A") ? 1 : 0),
			.init(name: "alarm.\(id).acknowledged", value: f[4].hasPrefix("A") ? 1 : 0),
		]
	}

	// DSC — Digital Selective Calling Information
	//   $..DSC,<format>,<address>,<category>,<nature>,<distressType>,<position>,…
	//   Format codes: 00=geographic, 02=all ships, 12=routine, 16=distress.
	private static func decodeDSC(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 3 else { return nil }
		var out: [BoatMetric] = []
		if let fmt = Double(f[1]) { out.append(.init(name: "dsc.format", value: fmt)) }
		if let mmsi = Double(f[2]) { out.append(.init(name: "dsc.mmsi", value: mmsi)) }
		if f.count >= 4, let cat = Double(f[3]) { out.append(.init(name: "dsc.category", value: cat)) }
		if f.count >= 7, let position = dscPosition(f[6]) {
			out.append(.init(name: "dsc.lat", value: position.latitude, unit: "°"))
			out.append(.init(name: "dsc.lon", value: position.longitude, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	/// Decodes the ITU-R M.493 distress-coordinates field: ten digits
	/// `Q DD MM DDD MM` — quadrant (0 NE, 1 NW, 2 SE, 3 SW), then latitude
	/// degrees/minutes and longitude degrees/minutes. Returns `nil` for an empty,
	/// out-of-range or malformed field (e.g. the "no position" sentinel).
	static func dscPosition(_ field: String) -> (latitude: Double, longitude: Double)? {
		let digits = field.trimmingCharacters(in: .whitespaces)
		guard digits.count == 10, digits.allSatisfy(\.isNumber) else { return nil }
		let d = Array(digits)
		func value(_ lower: Int, _ upper: Int) -> Double { Double(String(d[lower..<upper])) ?? 0 }
		let quadrant = Int(String(d[0])) ?? 0
		let latitude = value(1, 3) + value(3, 5) / 60
		let longitude = value(5, 8) + value(8, 10) / 60
		guard latitude <= 90, longitude <= 180 else { return nil }
		return (
			latitude: (quadrant == 2 || quadrant == 3) ? -latitude : latitude,
			longitude: (quadrant == 1 || quadrant == 3) ? -longitude : longitude
		)
	}

	// DSE — Expanded DSC (sent after DSC to provide more detail)
	//   $..DSE,<totalMsgs>,<msgNum>,<queryFlag>,<vesselMMSI>,<expansionCode>,<expansionData>,…
	private static func decodeDSE(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let mmsi = Double(f[4]) { out.append(.init(name: "dse.mmsi", value: mmsi)) }
		return out.isEmpty ? nil : out
	}

	// $PHTRO — Hemisphere / CCS / Furuno proprietary pitch & roll attitude
	//   $PHTRO,<pitch>,<P|M>,<roll>,<L|R>*cs
	//   Sign convention used here:
	//     pitch: P → positive (bow up),   M → negative (bow down)
	//     roll:  L → positive (port up),  R → negative (starboard up)
	private static func decodePHTRO(_ f: [String]) -> [BoatMetric]? {
		// Guard against any other $..TRO sentence falling here.
		guard let header = f.first, header == "$PHTRO", f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let p = Double(f[1]) {
			out.append(.init(name: "pitch", value: f[2] == "M" ? -p : p, unit: "°"))
		}
		if let r = Double(f[3]) {
			out.append(.init(name: "roll", value: f[4] == "R" ? -r : r, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	// BWC / BWR — Bearing and Distance to Waypoint (Great Circle / Rhumb Line)
	//   $..BWC,<utc>,<lat>,<N|S>,<lon>,<E|W>,<bearingTrue>,T,<bearingMag>,M,<distance>,N,<wpID>*cs
	//
	// The two sentences share their field layout; only the calculation model differs.
	// Both emit the destination waypoint position and the bearing/distance.
	private static func decodeBWC(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 12 else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[2], hemi: f[3]) { out.append(.init(name: "waypoint.lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[4], hemi: f[5]) { out.append(.init(name: "waypoint.lon", value: lon, unit: "°")) }
		if let b = Double(f[6]) { out.append(.init(name: "navigation.bearingToDest", value: b, unit: "°")) }
		if let b = Double(f[8]) { out.append(.init(name: "navigation.bearingToDest.magnetic", value: b, unit: "°")) }
		if let d = Double(f[10]) {
			// f[11] should be "N" (nautical miles); we trust that here as it's the only canonical unit.
			out.append(.init(name: "navigation.distanceToWaypoint", value: d, unit: "NM"))
		}
		return out.isEmpty ? nil : out
	}

	// BWW — Bearing, Waypoint to Waypoint (bearing of the next leg in a route)
	//   $..BWW,<bearingTrue>,T,<bearingMag>,M,<destWP>,<origWP>*cs
	private static func decodeBWW(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let b = Double(f[1]) { out.append(.init(name: "navigation.bearingNextLeg", value: b, unit: "°")) }
		if let b = Double(f[3]) { out.append(.init(name: "navigation.bearingNextLeg.magnetic", value: b, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	// BOD — Bearing, Origin to Destination
	//   $..BOD,<bearingTrue>,T,<bearingMag>,M,<destWP>,<origWP>*cs
	private static func decodeBOD(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let b = Double(f[1]) { out.append(.init(name: "navigation.bearingOriginToDest", value: b, unit: "°")) }
		if let b = Double(f[3]) {
			out.append(.init(name: "navigation.bearingOriginToDest.magnetic", value: b, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	// RTE — Routes (multi-message, carries waypoint identifiers as strings)
	//   $..RTE,<totalMsgs>,<msgNum>,<type c|w>,<routeID>,<wp1>,<wp2>,…*cs
	//
	// Waypoint IDs are strings — not representable as BoatMetric. We emit just the
	// numeric envelope (route id when numeric, waypoint count in this message).
	private static func decodeRTE(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 5 else { return nil }
		var out: [BoatMetric] = []
		if let routeId = Double(f[4]) {
			out.append(.init(name: "route.id", value: routeId))
		}
		let wpCount = max(0, f.count - 5)  // total tokens minus header(1) + msgFields(3) + routeId(1)
		if wpCount > 0 {
			out.append(.init(name: "route.waypointsInMessage", value: Double(wpCount)))
		}
		return out.isEmpty ? nil : out
	}

	// RSD — RADAR System Data
	//   $..RSD,<o1Range>,<o1Brg>,<vrm1>,<ebl1>,<o2Range>,<o2Brg>,<vrm2>,<ebl2>,
	//          <cursorRange>,<cursorBrg>,<rangeScale>,<rangeUnit K|N|S>,<displayRot>*cs
	private static func decodeRSD(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 13 else { return nil }
		var out: [BoatMetric] = []
		if let scale = Double(f[11]) {
			// Convert km/SM → NM so all distances share one canonical unit.
			let nm: Double
			switch f[12].prefix(1) {
			case "K": nm = scale / 1.852  // kilometres
			case "S": nm = scale / 1.15078  // statute miles
			default: nm = scale  // "N" = nautical miles (canonical)
			}
			out.append(.init(name: "radar.rangeScale", value: nm, unit: "NM"))
		}
		if let r = Double(f[9]) { out.append(.init(name: "radar.cursor.range", value: r, unit: "NM")) }
		if let b = Double(f[10]) { out.append(.init(name: "radar.cursor.bearing", value: b, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	// $PMAROUT — Maretron Power Management Unit output status
	//   $PMAROUT,<device>,<state>[,<value><unit>]…*cs
	//   Example: $PMAROUT,GENSET,ON,230V,12A*6A
	//            $PMAROUT,INVERTER,ACTIVE,24V*35
	//
	// Device is the equipment name (GENSET, INVERTER, CHARGER, …) — used directly
	// as the metric category. Optional value fields carry their unit as a one-letter
	// suffix (V/A/W/%) baked into the same field.
	private static func decodePMAROUT(_ f: [String]) -> [BoatMetric]? {
		guard let header = f.first, header == "$PMAROUT",
			f.count >= 3
		else { return nil }

		let device = f[1].lowercased()  // "genset", "inverter", "charger", …
		let state = f[2].uppercased()
		let active: Double = ["ON", "ACTIVE", "RUN", "RUNNING", "1"].contains(state) ? 1 : 0

		var out: [BoatMetric] = [
			.init(name: "power.\(device).state", value: active)
		]

		// Optional value fields — the unit letter is concatenated with the number
		// (e.g. "230V", "12.5A", "1500W", "85%"). Strip the *XX checksum from the last one.
		for idx in 3..<f.count {
			let raw = f[idx].split(separator: "*").first.map(String.init) ?? f[idx]
			let trimmed = raw.trimmingCharacters(in: .whitespaces)
			guard let unitChar = trimmed.last,
				let value = Double(trimmed.dropLast())
			else { continue }
			switch unitChar {
			case "V", "v": out.append(.init(name: "power.\(device).voltage", value: value, unit: "V"))
			case "A", "a": out.append(.init(name: "power.\(device).current", value: value, unit: "A"))
			case "W", "w": out.append(.init(name: "power.\(device).power", value: value, unit: "W"))
			case "%": out.append(.init(name: "power.\(device).level", value: value, unit: "%"))
			default: break
			}
		}
		return out
	}

	// MARK: Trimble proprietary (PTNL)

	/// Trimble proprietary `$PTNL,<sub>,<…>` — dispatches on sub-command in `fields[1]`.
	private static func decodeTNL(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 2 else { return nil }
		switch f[1] {
		case "GGK": return decodeTNL_GGK(f)
		case "AVR": return decodeTNL_AVR(f)
		case "VHD": return decodeTNL_VHD(f)
		case "PJK": return decodeTNL_PJK(f)
		default: return nil
		}
	}

	// $PTNL,GGK,<utc>,<date>,<lat>,<N/S>,<lon>,<E/W>,<quality>,<sats>,<dop>,EHT<alt>,M*cs
	// quality: 0=no fix, 1=autonomous, 2=DGPS, 3=PPS, 4=RTK fixed, 5=RTK float, 6=DR, 7=manual, 8=sim
	private static func decodeTNL_GGK(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 11 else { return nil }
		var out: [BoatMetric] = []
		if let lat = nmeaCoord(f[4], hemi: f[5]) { out.append(.init(name: "lat", value: lat, unit: "°")) }
		if let lon = nmeaCoord(f[6], hemi: f[7]) { out.append(.init(name: "lon", value: lon, unit: "°")) }
		if let q = Int(f[8]) { out.append(.init(name: "gps.quality", value: Double(q))) }
		if let n = Int(f[9]) { out.append(.init(name: "gps.satellites", value: Double(n))) }
		if let d = Double(f[10]) { out.append(.init(name: "gps.pdop", value: d)) }
		if f.count >= 12 {
			var alt = f[11]
			if alt.hasPrefix("EHT") { alt = String(alt.dropFirst(3)) }
			if let a = Double(alt) { out.append(.init(name: "altitude", value: a, unit: "m")) }
		}
		return out.isEmpty ? nil : out
	}

	// $PTNL,AVR,<utc>,<yaw>,Yaw,<tilt>,Tilt,<roll>,Roll,<range>,<quality>,<pdop>,<sats>*cs
	// Trimble RTK moving-baseline attitude — yaw/tilt/roll from dual antennas.
	private static func decodeTNL_AVR(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 13 else { return nil }
		var out: [BoatMetric] = []
		if let y = Double(f[3]) { out.append(.init(name: "yaw", value: y, unit: "°")) }
		if let t = Double(f[5]) { out.append(.init(name: "tilt", value: t, unit: "°")) }
		if let r = Double(f[7]) { out.append(.init(name: "roll", value: r, unit: "°")) }
		if let q = Int(f[10]) { out.append(.init(name: "gps.quality", value: Double(q))) }
		if let d = Double(f[11]) { out.append(.init(name: "gps.pdop", value: d)) }
		let satsStr = f[12].split(separator: "*").first.map(String.init) ?? f[12]
		if let n = Int(satsStr) { out.append(.init(name: "gps.satellites", value: Double(n))) }
		return out.isEmpty ? nil : out
	}

	// $PTNL,VHD,<utc>,<azimuth>,<dAz>,<vertAngle>,<dVA>,<range>,<dRange>,<quality>,<sats>,<pdop>*cs
	// True heading derived from a dual-antenna GNSS.
	private static func decodeTNL_VHD(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 11 else { return nil }
		var out: [BoatMetric] = []
		if let a = Double(f[3]) { out.append(.init(name: "HDG.true", value: a, unit: "°")) }
		if let q = Int(f[9]) { out.append(.init(name: "gps.quality", value: Double(q))) }
		if f.count >= 11, let n = Int(f[10]) {
			out.append(.init(name: "gps.satellites", value: Double(n)))
		}
		return out.isEmpty ? nil : out
	}

	// $PTNL,PJK,<utc>,<date>,<northing>,N,<easting>,E,<quality>,<sats>,<dop>,EHT<height>,M*cs
	// Position in projected local coordinates (northing/easting in metres).
	private static func decodeTNL_PJK(_ f: [String]) -> [BoatMetric]? {
		guard f.count >= 11 else { return nil }
		var out: [BoatMetric] = []
		if let n = Double(f[4]) { out.append(.init(name: "pjk.northing", value: n, unit: "m")) }
		if let e = Double(f[6]) { out.append(.init(name: "pjk.easting", value: e, unit: "m")) }
		if let q = Int(f[8]) { out.append(.init(name: "gps.quality", value: Double(q))) }
		if let s = Int(f[9]) { out.append(.init(name: "gps.satellites", value: Double(s))) }
		if let d = Double(f[10]) { out.append(.init(name: "gps.pdop", value: d)) }
		if f.count >= 12 {
			var h = f[11]
			if h.hasPrefix("EHT") { h = String(h.dropFirst(3)) }
			if let alt = Double(h) { out.append(.init(name: "altitude", value: alt, unit: "m")) }
		}
		return out.isEmpty ? nil : out
	}

	// MARK: Coordinate helper

	/// Converts an NMEA `DDDMM.mmm` coordinate string and hemisphere letter to decimal degrees.
	static func nmeaCoord(_ raw: String, hemi: String) -> Double? {
		guard let v = Double(raw) else { return nil }
		let deg = floor(v / 100)
		let min = v - deg * 100
		var r = deg + min / 60
		if hemi == "S" || hemi == "W" { r = -r }
		return r
	}
}

// MARK: - Yacht Devices RAW

/// Parser for the Yacht Devices RAW (YD RAW) log format.
///
/// Each line encodes one CAN frame as space-separated hex tokens:
/// `<CAN-ID> <byte0> <byte1> …`. The CAN ID encodes the PGN, source address,
/// and priority following the NMEA 2000 CAN ID layout.
///
/// An optional logging prefix `<timestamp> <R|T>` — as written by Yacht Devices
/// gateways and `candump`-style tools (e.g. `21:55:35.928 R 19F51323 …`) — is
/// accepted and skipped: everything up to and including the direction marker is
/// dropped before the CAN ID is read.
internal enum YachtDevicesRawParser {

	/// Parses a single YD RAW line into an ``NMEAFrame/nmea2000(pgn:source:priority:data:)`` frame.
	///
	/// - Returns: A `.nmea2000` frame, or `nil` if the line is not valid YD RAW.
	static func parse(_ line: String) -> NMEAFrame? {
		var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

		// Skip an optional "<timestamp> <R|T>" logging prefix. A bare YD RAW
		// line is all hex tokens, so a standalone "R"/"T" only ever marks the
		// direction column — taking the token after it gives the CAN ID.
		if let dir = tokens.firstIndex(where: { $0 == "R" || $0 == "T" || $0 == "r" || $0 == "t" }),
			dir + 1 < tokens.count
		{
			tokens = Array(tokens[(dir + 1)...])
		}

		guard tokens.count >= 2, let canId = UInt32(tokens[0], radix: 16) else { return nil }

		let priority = UInt8((canId >> 26) & 0x07)
		let pf = UInt8((canId >> 16) & 0xFF)
		let ps = UInt8((canId >> 8) & 0xFF)
		let source = UInt8(canId & 0xFF)
		let dp = UInt8((canId >> 24) & 0x01)

		let pgn: UInt32 =
			pf < 240
			? UInt32(dp) << 16 | UInt32(pf) << 8
			: UInt32(dp) << 16 | UInt32(pf) << 8 | UInt32(ps)

		var data: [UInt8] = []
		data.reserveCapacity(tokens.count - 1)
		for byteHex in tokens.dropFirst() {
			guard let b = UInt8(byteHex, radix: 16) else { return nil }
			data.append(b)
		}
		return .nmea2000(pgn: pgn, source: source, priority: priority, data: data)
	}
}

// MARK: - SeaSmart

/// Parser for the SeaSmart.Net `$PCDIN` sentence encapsulation of NMEA 2000.
///
/// SeaSmart wraps NMEA 2000 frames inside an NMEA 0183-style sentence:
/// `$PCDIN,<PGN>,<timestamp>,<src>,<hex-payload>*<checksum>`
internal enum SeaSmartParser {

	/// Parses a `$PCDIN` sentence into an ``NMEAFrame/nmea2000(pgn:source:priority:data:)`` frame.
	///
	/// - Returns: A `.nmea2000` frame, or `nil` if the line is not a valid `$PCDIN` sentence.
	static func parse(_ line: String) -> NMEAFrame? {
		guard line.hasPrefix("$PCDIN,") else { return nil }
		let core = line.split(separator: "*").first.map(String.init) ?? line
		let fields = core.split(separator: ",").map(String.init)
		guard fields.count >= 5,
			let pgn = UInt32(fields[1], radix: 16),
			let src = UInt8(fields[3], radix: 16)
		else { return nil }
		let hex = fields[4]
		var data: [UInt8] = []
		var i = hex.startIndex
		while i < hex.endIndex {
			let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
			if let b = UInt8(hex[i..<next], radix: 16) { data.append(b) }
			i = next
		}
		return .nmea2000(pgn: pgn, source: src, priority: 0, data: data)
	}
}

// MARK: - Canboat PLAIN

/// Parser for the Canboat "PLAIN" CSV format, as written by Canboat's
/// `analyzer` / `actisense-serial` and many NMEA 2000 logging tools:
/// `TIMESTAMP,PRIO,PGN,SRC,DST,LEN,D0,D1,…`.
///
/// The payload is already reassembled (fast-packet PGNs arrive whole), so no
/// further fragment assembly is required — the line maps directly to one
/// ``NMEAFrame/nmea2000(pgn:source:priority:data:)`` frame.
internal enum CanboatPlainParser {

	/// Parses a single Canboat PLAIN CSV line into a `.nmea2000` frame.
	///
	/// - Returns: A `.nmea2000` frame, or `nil` when the line does not match the
	///   `TIMESTAMP,PRIO,PGN,SRC,DST,LEN,bytes…` shape or the byte count is short.
	static func parse(_ line: String) -> NMEAFrame? {
		let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
		// 6 envelope fields (timestamp, prio, pgn, src, dst, len) + at least one data byte.
		guard fields.count >= 7,
			let priority = UInt8(fields[1]),
			let pgn = UInt32(fields[2]),
			let source = UInt8(fields[3]),
			let length = Int(fields[5]),
			length > 0
		else { return nil }

		let byteFields = fields.dropFirst(6)
		guard byteFields.count >= length else { return nil }
		var data: [UInt8] = []
		data.reserveCapacity(length)
		for hex in byteFields.prefix(length) {
			guard let b = UInt8(hex, radix: 16) else { return nil }
			data.append(b)
		}
		return .nmea2000(pgn: pgn, source: source, priority: priority, data: data)
	}
}

// MARK: - Digital Yacht iKonvert

/// Parser for the Digital Yacht iKonvert `!PDGY` format, which wraps a single
/// NMEA 2000 message in an NMEA 0183-style sentence with a Base64 payload:
/// `!PDGY,<PGN>,<PRIO>,<SRC>,<DST>,<timer>,<base64-payload>`.
///
/// Only received-data sentences (`!PDGY`) are handled; iKonvert status and
/// command sentences use `$PDGY`. Fast-packet PGNs arrive already reassembled,
/// so the decoded payload maps directly to one
/// ``NMEAFrame/nmea2000(pgn:source:priority:data:)`` frame.
internal enum IKonvertParser {

	/// Parses a single iKonvert `!PDGY` data sentence into a `.nmea2000` frame.
	///
	/// - Returns: A `.nmea2000` frame, or `nil` when the line is not a `!PDGY`
	///   data sentence or its Base64 payload is invalid.
	static func parse(_ line: String) -> NMEAFrame? {
		guard line.hasPrefix("!PDGY,") else { return nil }
		// The Base64 payload never contains a comma, so a plain comma split
		// yields exactly: !PDGY, PGN, PRIO, SRC, DST, timer, payload.
		let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
		guard fields.count >= 7,
			let pgn = UInt32(fields[1]),
			let priority = UInt8(fields[2]),
			let source = UInt8(fields[3]),
			let payload = base64Decode(fields[6])
		else { return nil }
		return .nmea2000(pgn: pgn, source: source, priority: priority, data: [UInt8](payload))
	}

	/// Decodes standard Base64, re-adding `=` padding when the source omits it
	/// (some iKonvert firmware emits unpadded payloads).
	private static func base64Decode(_ string: String) -> Data? {
		var padded = string
		let remainder = padded.count % 4
		if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
		return Data(base64Encoded: padded)
	}
}

// MARK: - NMEA 2000 Decoder

/// Decoder for a subset of NMEA 2000 PGNs into ``BoatMetric`` values.
///
/// Only covers the PGNs that carry commonly useful navigation and engineering data.
/// Unknown PGNs return `nil` — the raw ``NMEAFrame/nmea2000(pgn:source:priority:data:)``
/// frame is still emitted by the transport for consumers that handle PGNs directly.
internal enum NMEA2000Decoder {

	/// Returns `true` if the given PGN is a multi-frame fast-packet whose data
	/// payload must be reassembled before being passed to ``decode(pgn:data:)``.
	///
	/// Used by the transport layer to route raw YD/RAW CAN frames through a
	/// fast-packet assembler. SeaSmart `$PCDIN` already carries reassembled
	/// payloads, so that path bypasses the assembler.
	static func isFastPacket(_ pgn: UInt32) -> Bool {
		return fastPacketPGNs.contains(pgn)
	}

	/// Returns `true` if the given PGN encodes an AIS message that should be
	/// decoded into an ``AISTarget`` via ``AISDecoder/decodeN2K(pgn:source:data:)``
	/// rather than into ``BoatMetric`` values.
	static func isAISPGN(_ pgn: UInt32) -> Bool {
		return aisPGNs.contains(pgn)
	}

	/// Well-known NMEA 2000 fast-packet PGNs (per Canboat reference).
	private static let fastPacketPGNs: Set<UInt32> = [
		126208, 126464, 126996, 126998,
		127237, 127489, 127496, 127497, 127498,
		128275,
		129029, 129038, 129039, 129040, 129041,
		129283, 129284, 129285,
		129539, 129540, 129542, 129545, 129547,
		129549, 129551, 129556,
		129793, 129794, 129795, 129796, 129797, 129798,
		129801, 129802, 129803, 129804, 129805, 129806,
		129807, 129808, 129809, 129810,
		130074, 130311, 130314, 130316, 130323, 130577,
	]

	/// AIS-related PGNs — payload decodes into an ``AISTarget`` rather than metrics.
	private static let aisPGNs: Set<UInt32> = [
		129038,  // Class A Position Report (msg type 1/2/3)
		129039,  // Class B Position Report (msg type 18)
		129040,  // Class B Extended Position Report (msg type 19)
		129041,  // Aids to Navigation Report (msg type 21)
		129793,  // UTC and Date Report (msg type 4)
		129794,  // Class A Static and Voyage Related Data (msg type 5)
		129798,  // SAR Aircraft Position Report (msg type 9)
		129809,  // Class B "CS" Static Data Report, Part A (msg type 24A)
		129810,  // Class B "CS" Static Data Report, Part B (msg type 24B)
	]

	/// Decodes PGNs that emit composite ``NMEAFrame`` values alongside metrics.
	///
	/// Currently handles:
	/// - `129540` — GNSS Sats in View → ``NMEAFrame/gsvReport(_:_:_:)`` + summary metrics.
	///
	/// Returns `nil` for all other PGNs; the caller then falls back to ``decode(pgn:data:)``.
	static func decodeFrames(pgn: UInt32, data: [UInt8]) -> [NMEAFrame]? {
		switch pgn {
		case 129540: return gnssSatsInViewFrames(data)
		default: return nil
		}
	}

	/// Decodes a known NMEA 2000 PGN payload into ``BoatMetric`` values.
	///
	/// Supported PGNs:
	/// - 126992 (system time), 127245 (rudder), 127250 (heading),
	///   127251 (rate of turn), 127257 (attitude), 127488 (engine rapid),
	///   127489 (engine dynamic), 127505 (fluid level), 127508 (battery status),
	/// - 128259 (STW), 128267 (depth), 128275 (distance log),
	/// - 129025 (position rapid), 129026 (COG/SOG), 129029 (GNSS position data),
	///   129033 (time & date), 129539 (GNSS DOPs), 129540 (GNSS sats in view),
	/// - 130306 (wind), 130310 (environmental), 130312 (temperature).
	///
	/// Fast-packet PGNs (> 8 bytes) must be reassembled before being passed in:
	/// SeaSmart `$PCDIN` carries reassembled payloads natively; raw YD format does not.
	///
	/// - Returns: An array of metrics, or `nil` for unknown PGNs or insufficient data.
	static func decode(pgn: UInt32, data: [UInt8]) -> [BoatMetric]? {
		switch pgn {
		case 126992: return systemTime(data)
		case 127245: return rudder(data)
		case 127250: return heading(data)
		case 127251: return rateOfTurn(data)
		case 127257: return attitude(data)
		case 127258: return magneticVariation(data)
		case 127488: return engineRapid(data)
		case 127489: return engineDynamic(data)
		case 127505: return fluidLevel(data)
		case 127506: return dcDetailedStatus(data)
		case 127508: return batteryStatus(data)
		case 128776: return windlassControl(data)
		case 128777: return windlassOperating(data)
		case 128778: return windlassMonitoring(data)
		case 128259: return stw(data)
		case 128267: return depth(data)
		case 128275: return distanceLog(data)
		case 129025: return positionRapid(data)
		case 129026: return cogSog(data)
		case 129029: return gnssPosition(data)
		case 129033: return timeAndDate(data)
		case 129539: return gnssDops(data)
		// 129540 handled by decodeFrames() — emits gsvReport + metrics
		case 130306: return wind(data)
		case 130310: return env(data)
		case 130312: return temperature(data)
		case 129283: return crossTrackError(data)
		case 129284: return navigationData(data)
		case 130311: return envWithHumidity(data)
		case 130314: return actualPressure(data)
		case 130323: return meteorologicalStation(data)
		default: return nil
		}
	}

	// MARK: Byte readers

	private static func u8(_ d: [UInt8], _ at: Int) -> UInt8? { at < d.count ? d[at] : nil }
	private static func u16(_ d: [UInt8], _ at: Int) -> UInt16? {
		guard at + 1 < d.count else { return nil }
		return UInt16(d[at]) | UInt16(d[at + 1]) << 8
	}
	private static func i16(_ d: [UInt8], _ at: Int) -> Int16? { u16(d, at).map { Int16(bitPattern: $0) } }
	private static func u32(_ d: [UInt8], _ at: Int) -> UInt32? {
		guard at + 3 < d.count else { return nil }
		var v: UInt32 = 0
		for k in 0..<4 { v |= UInt32(d[at + k]) << (8 * k) }
		return v
	}
	private static func i32(_ d: [UInt8], _ at: Int) -> Int32? { u32(d, at).map { Int32(bitPattern: $0) } }
	private static func u64(_ d: [UInt8], _ at: Int) -> UInt64? {
		guard at + 7 < d.count else { return nil }
		var v: UInt64 = 0
		for k in 0..<8 { v |= UInt64(d[at + k]) << (8 * k) }
		return v
	}
	private static func i64(_ d: [UInt8], _ at: Int) -> Int64? { u64(d, at).map { Int64(bitPattern: $0) } }
	private static func na(_ v: UInt16) -> Bool { v == 0xFFFF }
	private static func na(_ v: UInt32) -> Bool { v == 0xFFFF_FFFF }
	private static func na(_ v: UInt64) -> Bool { v == 0xFFFF_FFFF_FFFF_FFFF }
	private static func na(_ v: Int16) -> Bool { v == Int16.max }
	private static func na(_ v: Int32) -> Bool { v == Int32.max }
	private static func na(_ v: Int64) -> Bool { v == Int64.max }

	// MARK: PGN decoders

	private static func positionRapid(_ d: [UInt8]) -> [BoatMetric]? {
		guard let lat = i32(d, 0), let lon = i32(d, 4) else { return nil }
		return [
			.init(name: "lat", value: Double(lat) * 1e-7, unit: "°"),
			.init(name: "lon", value: Double(lon) * 1e-7, unit: "°"),
		]
	}

	// 129026 — COG & SOG, Rapid Update
	//   byte 0: SID
	//   byte 1: COG Reference (2 bits — 0=true, 1=magnetic) + reserved
	//   bytes 2-3: COG (uint16, 1e-4 rad per LSB)
	//   bytes 4-5: SOG (uint16, 0.01 m/s per LSB)
	//   bytes 6-7: reserved
	private static func cogSog(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		let cogRef = (u8(d, 1) ?? 0xFF) & 0x03
		if let cog = u16(d, 2), !na(cog) {
			let name = cogRef == 1 ? "COG.magnetic" : "COG"
			out.append(.init(name: name, value: Double(cog) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let sog = u16(d, 4), !na(sog) {
			out.append(.init(name: "SOG", value: Double(sog) * 0.01 * 1.94384, unit: "kn"))
		}
		return out.isEmpty ? nil : out
	}

	// 130306 — Wind Data
	//   byte 0: SID
	//   bytes 1-2: Wind Speed (uint16, 0.01 m/s per LSB)
	//   bytes 3-4: Wind Angle (uint16, 1e-4 rad per LSB)
	//   byte 5: Wind Reference (3 bits) + reserved
	//
	// Reference codes:
	//   0 = True (north-referenced)   — speed = TWS, angle = TWD (direction)
	//   1 = Magnetic (north-referenced) — angle = TWD.magnetic
	//   2 = Apparent                  — speed = AWS, angle = AWA (relative to bow)
	//   3 = True (boat-referenced)    — speed = TWS, angle = TWA (relative to bow)
	//   4 = True (water-referenced)   — same as 3 in our model
	private static func wind(_ d: [UInt8]) -> [BoatMetric]? {
		guard let speed = u16(d, 1), let angle = u16(d, 3), let ref = u8(d, 5) else { return nil }
		let speedKn = Double(speed) * 0.01 * 1.94384
		let angleDeg = Double(angle) * 1e-4 * 180 / .pi
		var out: [BoatMetric] = []

		switch ref & 0x07 {
		case 0:  // True, north-referenced — angle is direction
			if !na(speed) { out.append(.init(name: "TWS", value: speedKn, unit: "kn")) }
			if !na(angle) { out.append(.init(name: "TWD", value: angleDeg, unit: "°")) }
		case 1:  // Magnetic, north-referenced
			if !na(speed) { out.append(.init(name: "TWS", value: speedKn, unit: "kn")) }
			if !na(angle) { out.append(.init(name: "TWD.magnetic", value: angleDeg, unit: "°")) }
		case 2:  // Apparent
			if !na(speed) { out.append(.init(name: "AWS", value: speedKn, unit: "kn")) }
			if !na(angle) { out.append(.init(name: "AWA", value: angleDeg, unit: "°")) }
		case 3, 4:  // True, boat- or water-referenced — angle is relative
			if !na(speed) { out.append(.init(name: "TWS", value: speedKn, unit: "kn")) }
			if !na(angle) { out.append(.init(name: "TWA", value: angleDeg, unit: "°")) }
		default:
			break
		}
		return out.isEmpty ? nil : out
	}

	// 128267 — Water Depth
	//   byte 0: SID
	//   bytes 1-4: Depth Below Transducer (uint32, 0.01 m per LSB)
	//   bytes 5-6: Offset (int16, 0.001 m per LSB) — surface-to-transducer (positive)
	//              or transducer-to-keel (negative). When applied, gives depth below surface.
	//   byte 7: Range (uint8, 10 m per LSB) — max range the transducer is set to scan
	private static func depth(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let depth = u32(d, 1), !na(depth) {
			out.append(.init(name: "depth", value: Double(depth) * 0.01, unit: "m"))
		}
		if let off = i16(d, 5), !na(off) {
			out.append(.init(name: "depth.offset", value: Double(off) * 0.001, unit: "m"))
		}
		if let rng = u8(d, 7), rng != 0xFF {
			out.append(.init(name: "depth.range", value: Double(rng) * 10.0, unit: "m"))
		}
		return out.isEmpty ? nil : out
	}

	// 128259 — Speed, Water and Ground Referenced
	//   byte 0: SID
	//   bytes 1-2: Speed Water Referenced (uint16, 0.01 m/s per LSB)
	//   bytes 3-4: Speed Ground Referenced (uint16, 0.01 m/s per LSB)
	//   byte 5: Speed Water Reference Type (4 bits) + reserved
	//   bytes 6-7: reserved
	private static func stw(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let w = u16(d, 1), !na(w) {
			out.append(.init(name: "STW", value: Double(w) * 0.01 * 1.94384, unit: "kn"))
		}
		if let g = u16(d, 3), !na(g) {
			out.append(.init(name: "SOG", value: Double(g) * 0.01 * 1.94384, unit: "kn"))
		}
		return out.isEmpty ? nil : out
	}

	// 127250 — Vessel Heading
	//   byte 0: SID
	//   bytes 1-2: Heading (uint16, 1e-4 rad)
	//   bytes 3-4: Deviation (int16, 1e-4 rad)  — compass deviation (calibration error)
	//   bytes 5-6: Variation (int16, 1e-4 rad)  — geomagnetic variation
	//   byte 7: Reference (2 bits — 0=true, 1=magnetic) + reserved
	private static func heading(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let h = u16(d, 1), !na(h) {
			let deg = Double(h) * 1e-4 * 180 / .pi
			let name: String
			if let r = u8(d, 7) { name = (r & 0x03) == 0 ? "HDG.true" : "HDG.magnetic" } else { name = "HDG" }
			out.append(.init(name: name, value: deg, unit: "°"))
		}
		if let dev = i16(d, 3), !na(dev) {
			out.append(.init(name: "HDG.deviation", value: Double(dev) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let varia = i16(d, 5), !na(varia) {
			out.append(.init(name: "magneticVariation", value: Double(varia) * 1e-4 * 180 / .pi, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	private static func attitude(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let yaw = i16(d, 1) { out.append(.init(name: "yaw", value: Double(yaw) * 1e-4 * 180 / .pi, unit: "°")) }
		if let pitch = i16(d, 3) {
			out.append(.init(name: "pitch", value: Double(pitch) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let roll = i16(d, 5) { out.append(.init(name: "roll", value: Double(roll) * 1e-4 * 180 / .pi, unit: "°")) }
		return out.isEmpty ? nil : out
	}

	// 127245 — Rudder
	//   byte 0: Instance
	//   byte 1: Direction Order (3 bits) + reserved (5 bits)
	//   bytes 2-3: Angle Order (int16, 1e-4 rad)  — autopilot commanded angle
	//   bytes 4-5: Position    (int16, 1e-4 rad)  — actual measured angle
	private static func rudder(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let order = i16(d, 2), !na(order) {
			out.append(.init(name: "rudder.target", value: Double(order) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let pos = i16(d, 4), !na(pos) {
			out.append(.init(name: "rudder", value: Double(pos) * 1e-4 * 180 / .pi, unit: "°"))
		}
		return out.isEmpty ? nil : out
	}

	// 127488 — Engine Parameters, Rapid Update
	//   byte 0: Engine Instance
	//   bytes 1-2: Engine Speed (uint16, 0.25 rpm per LSB)
	//   bytes 3-4: Boost Pressure (uint16, 100 Pa per LSB)
	//   byte 5: Tilt / Trim (int8, 1 % per LSB; 0x7F = N/A)
	//   bytes 6-7: reserved
	private static func engineRapid(_ d: [UInt8]) -> [BoatMetric]? {
		guard let inst = u8(d, 0) else { return nil }
		var out: [BoatMetric] = []
		if let rpm = u16(d, 1), !na(rpm) {
			out.append(.init(name: "engine.\(inst).rpm", value: Double(rpm) * 0.25, unit: "rpm"))
		}
		if let boost = u16(d, 3), !na(boost) {
			out.append(
				.init(
					name: "engine.\(inst).boostPressure",
					value: Double(boost) * 100, unit: "Pa"))
		}
		if let raw = u8(d, 5), raw != 0x7F {
			out.append(
				.init(
					name: "engine.\(inst).tiltTrim",
					value: Double(Int8(bitPattern: raw)), unit: "%"))
		}
		return out.isEmpty ? nil : out
	}

	// 127505 — Fluid Level
	//   byte 0: Instance (low 4 bits) + Type (high 4 bits)
	//   bytes 1-2: Level (int16, 0.004 % per LSB)
	//   bytes 3-6: Capacity (uint32, 0.1 L per LSB)
	//   byte 7: reserved
	private static func fluidLevel(_ d: [UInt8]) -> [BoatMetric]? {
		guard let head = u8(d, 0) else { return nil }
		let instance = head & 0x0F
		let type = (head >> 4) & 0x0F
		let bucket: String
		switch type {
		case 0: bucket = "fuel"
		case 1: bucket = "water"
		case 2: bucket = "graywater"
		case 3: bucket = "livewell"
		case 4: bucket = "oil"
		case 5: bucket = "blackwater"
		default: bucket = "fluid.\(type)"
		}
		var out: [BoatMetric] = []
		if let level = i16(d, 1), level != Int16.max {
			out.append(
				.init(
					name: "\(bucket).\(instance).level",
					value: Double(level) * 0.004, unit: "%"))
		}
		if let cap = u32(d, 3), !na(cap) {
			out.append(
				.init(
					name: "\(bucket).\(instance).capacity",
					value: Double(cap) * 0.1, unit: "L"))
		}
		return out.isEmpty ? nil : out
	}

	private static func batteryStatus(_ d: [UInt8]) -> [BoatMetric]? {
		guard let inst = u8(d, 0) else { return nil }
		var out: [BoatMetric] = []
		if let v = u16(d, 1), !na(v) {
			out.append(.init(name: "battery.\(inst).voltage", value: Double(v) * 0.01, unit: "V"))
		}
		if let c = i16(d, 3), c != Int16.max {
			out.append(.init(name: "battery.\(inst).current", value: Double(c) * 0.1, unit: "A"))
		}
		if let t = u16(d, 5), !na(t) {
			out.append(
				.init(
					name: "battery.\(inst).temperature",
					value: Double(t) * 0.01 - 273.15, unit: "°C"))
		}
		return out.isEmpty ? nil : out
	}

	// 127258 — Magnetic Variation
	//   byte 0: SID, byte 1: source, bytes 2-3: age of service
	//   bytes 4-5: Variation (int16, 1e-4 rad per LSB) — positive = East
	private static func magneticVariation(_ d: [UInt8]) -> [BoatMetric]? {
		guard let varia = i16(d, 4), !na(varia) else { return nil }
		return [.init(name: "magneticVariation", value: Double(varia) * 1e-4 * 180 / .pi, unit: "°")]
	}

	// 127506 — DC Detailed Status
	//   byte 0: SID, byte 1: DC instance, byte 2: DC type
	//   byte 3: State of Charge (%), byte 4: State of Health (%)
	//   bytes 5-6: Time Remaining (uint16, minutes)
	//   bytes 7-8: Ripple Voltage (uint16, 0.001 V)
	private static func dcDetailedStatus(_ d: [UInt8]) -> [BoatMetric]? {
		guard let inst = u8(d, 1) else { return nil }
		var out: [BoatMetric] = []
		if let soc = u8(d, 3), soc != 0xFF {
			out.append(.init(name: "battery.\(inst).stateOfCharge", value: Double(soc), unit: "%"))
		}
		if let soh = u8(d, 4), soh != 0xFF {
			out.append(.init(name: "battery.\(inst).stateOfHealth", value: Double(soh), unit: "%"))
		}
		if let tr = u16(d, 5), !na(tr) {
			out.append(.init(name: "battery.\(inst).timeRemaining", value: Double(tr), unit: "min"))
		}
		return out.isEmpty ? nil : out
	}

	// -------------------------------------------------------------------------
	// 128776 — Anchor Windlass Control Status
	//
	// Reflects what the *controller* (remote, MFD) is commanding.
	// Sent by the controller; the windlass echoes back status on 128777/128778.
	//
	// Layout (fast-packet, 6 data bytes):
	//   byte 0 bits 0-3 : Windlass Identifier (instance 0-15)
	//   byte 0 bits 4-7 : Reserved
	//   byte 1 bits 0-1 : Windlass Direction Control
	//                       0 = off/idle   1 = deploying (down)   2 = retrieving (up)
	//   byte 1 bits 2-3 : Anchor Docking Control (0=off, 1=engaged)
	//   byte 1 bits 4-5 : Speed Control Type (0=single, 1=dual, 2=proportional)
	//   bytes 2-3       : Speed Control value (uint16)
	//   byte 4 bits 0-3 : Power Enable
	//   byte 4 bits 4-7 : Mechanical Lock Status
	//   byte 5          : Windlass Control Events
	//
	// Note — Quick compatibility: Quick N2K certified windlasses should transmit
	// this PGN when their Smart Controller is paired.  If PGN 128776 never appears
	// on the bus, run `boattools connect --url tcp://<host>:<port>` and look at
	// `.unknown` frames to find the actual PGN Quick uses.
	private static func windlassControl(_ d: [UInt8]) -> [BoatMetric]? {
		guard let b0 = u8(d, 0) else { return nil }
		let i = Int(b0 & 0x0F)
		var out: [BoatMetric] = []
		if let b1 = u8(d, 1) {
			let dir = b1 & 0x03  // 0=off, 1=deploying, 2=retrieving
			out.append(
				.init(
					name: "windlass.\(i).commandedDirection",
					value: Double(dir), unit: nil))
		}
		return out.isEmpty ? nil : out
	}

	// -------------------------------------------------------------------------
	// 128777 — Anchor Windlass Operating Status
	//
	// The primary real-time status PGN: chain length and motion state.
	// Sent by the windlass itself.
	//
	// Layout (fast-packet, 6 data bytes):
	//   byte 0 bits 0-3 : Windlass Identifier (instance 0-15)
	//   byte 0 bits 4-7 : Reserved
	//   bytes 1-2       : Rode Counter Value (uint16 LE, 0.1 m/bit) ← chain length
	//                       0xFFFF = not available
	//   byte 3          : Windlass Operating Speed (uint8, 0.1 m/s per bit)
	//                       0xFF = not available
	//   byte 4 bits 0-1 : Windlass Motion Status
	//                       0 = unavailable
	//                       1 = deployed / stopped
	//                       2 = deploying (chain going out)
	//                       3 = retrieving (chain coming in)
	//   byte 4 bits 2-3 : Rode Type Status (1=chain, 2=rope)
	//   byte 4 bits 4-5 : Anchor Docking Status ← anchor up/down
	//                       0 = unavailable
	//                       1 = fully docked (anchor up, at the bow)
	//                       2 = not docked (chain out)
	//                       3 = unknown
	//   byte 4 bits 6-7 : Windlass Operating Events (0=normal, others = fault codes)
	//   byte 5          : Reserved
	private static func windlassOperating(_ d: [UInt8]) -> [BoatMetric]? {
		guard let b0 = u8(d, 0) else { return nil }
		let i = Int(b0 & 0x0F)
		var out: [BoatMetric] = []

		// Chain length (Rode Counter)
		if let raw = u16(d, 1), !na(raw) {
			out.append(
				.init(
					name: "windlass.\(i).chainLength",
					value: Double(raw) * 0.1, unit: "m"))
		}

		// Chain speed
		if let spd = u8(d, 3), spd != 0xFF {
			out.append(
				.init(
					name: "windlass.\(i).chainSpeed",
					value: Double(spd) * 0.1, unit: "m/s"))
		}

		if let b4 = u8(d, 4) {
			// Motion status (0=stopped/deployed, 1=deploying, 2=retrieving)
			let motion = b4 & 0x03
			if motion != 0 {
				// 0=unavail: skip; map 1=stopped→0, 2=deploying→1, 3=retrieving→2
				let mapped: UInt8 = motion == 1 ? 0 : motion - 1
				out.append(
					.init(
						name: "windlass.\(i).motion",
						value: Double(mapped), unit: nil))
			}

			// Anchor docking status — emit as a clean boolean-style metric
			//   1.0 = anchor fully docked (up)   0.0 = anchor deployed (out)
			let docking = (b4 >> 4) & 0x03
			if docking == 1 || docking == 2 {
				out.append(
					.init(
						name: "windlass.\(i).anchorUp",
						value: docking == 1 ? 1.0 : 0.0, unit: nil))
			}

			// Rode type (1=chain, 2=rope) — informational
			let rode = (b4 >> 2) & 0x03
			if rode == 1 || rode == 2 {
				out.append(
					.init(
						name: "windlass.\(i).rodeType",
						value: Double(rode), unit: nil))
			}
		}

		return out.isEmpty ? nil : out
	}

	// -------------------------------------------------------------------------
	// 128778 — Anchor Windlass Monitoring Status
	//
	// Electrical telemetry from the windlass motor controller.
	//
	// Layout (fast-packet, 7 data bytes):
	//   byte 0 bits 0-3 : Windlass Identifier (instance 0-15)
	//   byte 1          : Total Motor Time (uint8, hours, 0xFF = not available)
	//   bytes 2-3       : Controller Voltage (uint16 LE, 0.01 V/bit, 0xFFFF = N/A)
	//   bytes 4-5       : Motor Current     (uint16 LE, 0.1  A/bit, 0xFFFF = N/A)
	//   byte 6 bits 0-3 : Windlass Monitoring Events (fault flags)
	private static func windlassMonitoring(_ d: [UInt8]) -> [BoatMetric]? {
		guard let b0 = u8(d, 0) else { return nil }
		let i = Int(b0 & 0x0F)
		var out: [BoatMetric] = []
		if let hrs = u8(d, 1), hrs != 0xFF {
			out.append(
				.init(
					name: "windlass.\(i).motorHours",
					value: Double(hrs), unit: "h"))
		}
		if let v = u16(d, 2), !na(v) {
			out.append(
				.init(
					name: "windlass.\(i).controllerVoltage",
					value: Double(v) * 0.01, unit: "V"))
		}
		if let a = u16(d, 4), !na(a) {
			out.append(
				.init(
					name: "windlass.\(i).motorCurrent",
					value: Double(a) * 0.1, unit: "A"))
		}
		return out.isEmpty ? nil : out
	}

	private static func env(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let wt = u16(d, 1), !na(wt) {
			out.append(.init(name: "temperature.water", value: Double(wt) * 0.01 - 273.15, unit: "°C"))
		}
		if let at = u16(d, 3), !na(at) {
			out.append(.init(name: "temperature.air", value: Double(at) * 0.01 - 273.15, unit: "°C"))
		}
		if let p = u16(d, 5), !na(p) {
			out.append(.init(name: "pressure.atmospheric", value: Double(p), unit: "hPa"))
		}
		return out.isEmpty ? nil : out
	}

	// MARK: Shared helpers

	/// Canonical metric name for an NMEA 2000 temperature-source code.
	/// Used by PGN 130311 (Environmental Parameters, extended) and 130312 (Temperature).
	private static func temperatureSourceName(_ source: UInt8) -> String {
		switch source {
		case 0: return "temperature.water"
		case 1: return "temperature.air"
		case 2: return "temperature.inside"
		case 3: return "temperature.engine"
		case 4: return "temperature.cabin"
		case 5: return "temperature.liveWell"
		case 6: return "temperature.baitWell"
		case 7: return "temperature.refrigerator"
		case 8: return "temperature.heating"
		case 9: return "temperature.dewPoint"
		case 10: return "temperature.windChillApparent"
		case 11: return "temperature.windChillTheoretical"
		case 12: return "temperature.heatIndex"
		case 13: return "temperature.freezer"
		case 14: return "temperature.exhaustGas"
		default: return "temperature.source\(source)"
		}
	}

	// MARK: GNSS — equivalents to NMEA 0183 GGA / GLL / GNS / GSA / GSV / ZDA / ROT / MTW / VLW

	// 126992 — System Time
	//   byte 0: SID
	//   byte 1: source (low 4 bits) + reserved (4 bits)
	//   bytes 2-3: date (uint16 days since 1970-01-01)
	//   bytes 4-7: time (uint32 seconds × 10000)
	//
	// Source codes: 0=GPS, 1=GLONASS, 2=Radio station, 3=Local cesium,
	//               4=Local rubidium, 5=Local crystal
	private static func systemTime(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let date = u16(d, 2), !na(date),
			let time = u32(d, 4), !na(time)
		{
			let epoch = Double(date) * 86_400.0 + Double(time) / 10_000.0
			out.append(.init(name: "utc.timestamp", value: epoch, unit: "s"))
		}
		if let src = u8(d, 1) {
			let code = src & 0x0F
			if code <= 5 {
				out.append(.init(name: "utc.timeSource", value: Double(code)))
			}
		}
		return out.isEmpty ? nil : out
	}

	// 127251 — Rate of Turn
	//   byte 0: SID, bytes 1-4 (int32): rate in 1/(32×10⁶) rad/s per LSB
	private static func rateOfTurn(_ d: [UInt8]) -> [BoatMetric]? {
		guard let r = i32(d, 1), !na(r) else { return nil }
		let radPerSec = Double(r) / 32_000_000.0
		let degPerMin = radPerSec * 180 / .pi * 60
		return [.init(name: "ROT", value: degPerMin, unit: "°/min")]
	}

	// 127489 — Engine Parameters Dynamic (fast packet, 26 bytes)
	//   byte 0: Instance
	//   bytes 1-2: Oil Pressure (uint16, 100 Pa per LSB)
	//   bytes 3-4: Oil Temperature (uint16, 0.1 K per LSB)
	//   bytes 5-6: Coolant/Engine Temperature (uint16, 0.01 K per LSB)
	//   bytes 7-8: Alternator Voltage (int16, 0.01 V per LSB)
	//   bytes 9-10: Fuel Rate (int16, 0.1 L/h per LSB)
	//   bytes 11-14: Total Engine Hours (uint32, seconds)
	//   bytes 15-16: Coolant Pressure (uint16, 100 Pa per LSB)
	//   bytes 17-18: Fuel Pressure (uint16, 1000 Pa per LSB)
	//   byte 19: reserved
	//   bytes 20-21: Discrete Status 1 (bitfield — fault flags)
	//   bytes 22-23: Discrete Status 2 (bitfield)
	//   byte 24: Engine Load (int8, % per LSB)
	//   byte 25: Engine Torque (int8, % per LSB)
	private static func engineDynamic(_ d: [UInt8]) -> [BoatMetric]? {
		guard let inst = u8(d, 0) else { return nil }
		var out: [BoatMetric] = []
		if let p = u16(d, 1), !na(p) {
			out.append(.init(name: "engine.\(inst).oilPressure", value: Double(p) * 100, unit: "Pa"))
		}
		if let t = u16(d, 3), !na(t) {
			out.append(
				.init(
					name: "engine.\(inst).oilTemperature",
					value: Double(t) * 0.1 - 273.15, unit: "°C"))
		}
		if let c = u16(d, 5), !na(c) {
			out.append(
				.init(
					name: "engine.\(inst).coolantTemperature",
					value: Double(c) * 0.01 - 273.15, unit: "°C"))
		}
		if let v = i16(d, 7), !na(v) {
			out.append(
				.init(
					name: "engine.\(inst).alternatorVoltage",
					value: Double(v) * 0.01, unit: "V"))
		}
		if let r = i16(d, 9), !na(r) {
			out.append(.init(name: "engine.\(inst).fuelRate", value: Double(r) * 0.1, unit: "L/h"))
		}
		if let s = u32(d, 11), !na(s) {
			out.append(.init(name: "engine.\(inst).runtime", value: Double(s), unit: "s"))
		}
		if let cp = u16(d, 15), !na(cp) {
			out.append(.init(name: "engine.\(inst).coolantPressure", value: Double(cp) * 100, unit: "Pa"))
		}
		if let fp = u16(d, 17), !na(fp) {
			out.append(.init(name: "engine.\(inst).fuelPressure", value: Double(fp) * 1000, unit: "Pa"))
		}
		if let raw = u8(d, 24), raw != 0x7F {
			out.append(
				.init(
					name: "engine.\(inst).load",
					value: Double(Int8(bitPattern: raw)), unit: "%"))
		}
		if let raw = u8(d, 25), raw != 0x7F {
			out.append(
				.init(
					name: "engine.\(inst).torque",
					value: Double(Int8(bitPattern: raw)), unit: "%"))
		}
		return out.isEmpty ? nil : out
	}

	// 128275 — Distance Log
	//   bytes 0-1: date, bytes 2-5: time, bytes 6-9: log total (m), bytes 10-13: trip (m)
	private static func distanceLog(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let total = u32(d, 6), !na(total) {
			out.append(.init(name: "log.total", value: Double(total) / 1852.0, unit: "NM"))
		}
		if let trip = u32(d, 10), !na(trip) {
			out.append(.init(name: "log.trip", value: Double(trip) / 1852.0, unit: "NM"))
		}
		return out.isEmpty ? nil : out
	}

	// 129029 — GNSS Position Data (fast packet, 43+ bytes)
	//   byte 0: SID
	//   bytes 1-2: date (days since 1970)
	//   bytes 3-6: time (seconds × 10000)
	//   bytes 7-14: latitude (int64, 1e-16 deg per LSB)
	//   bytes 15-22: longitude (int64, 1e-16 deg per LSB)
	//   bytes 23-30: altitude (int64, 1e-6 m per LSB)
	//   byte 31: type (low 4 bits) + method (high 4 bits)
	//   byte 32: integrity (low 2 bits) + reserved
	//   byte 33: number of SVs
	//   bytes 34-35: HDOP (int16, 0.01 per LSB)
	//   bytes 36-37: PDOP (int16, 0.01 per LSB)
	//   bytes 38-41: geoidal separation (int32, 0.01 m per LSB)
	private static func gnssPosition(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let lat = i64(d, 7), !na(lat) {
			out.append(.init(name: "lat", value: Double(lat) * 1e-16, unit: "°"))
		}
		if let lon = i64(d, 15), !na(lon) {
			out.append(.init(name: "lon", value: Double(lon) * 1e-16, unit: "°"))
		}
		if let alt = i64(d, 23), !na(alt) {
			out.append(.init(name: "altitude", value: Double(alt) * 1e-6, unit: "m"))
		}
		if let tm = u8(d, 31) {
			let method = (tm >> 4) & 0x0F  // GPS method: 0=no fix, 1=GNSS, 2=DGNSS, 3=PPS, 4=RTK fixed, …
			if method != 0x0F {
				out.append(.init(name: "gps.quality", value: Double(method)))
			}
		}
		if let nsats = u8(d, 33), nsats != 0xFF {
			out.append(.init(name: "gps.satellites", value: Double(nsats)))
		}
		if let h = i16(d, 34), !na(h) {
			out.append(.init(name: "gps.hdop", value: Double(h) * 0.01))
		}
		if let p = i16(d, 36), !na(p) {
			out.append(.init(name: "gps.pdop", value: Double(p) * 0.01))
		}
		if let geoid = i32(d, 38), !na(geoid) {
			out.append(
				.init(
					name: "gps.geoidalSeparation",
					value: Double(geoid) * 0.01, unit: "m"))
		}
		return out.isEmpty ? nil : out
	}

	// 129033 — Time and Date
	//   bytes 0-1: date (days since 1970)
	//   bytes 2-5: time (seconds × 10000)
	//   bytes 6-7: local offset (minutes, signed)
	private static func timeAndDate(_ d: [UInt8]) -> [BoatMetric]? {
		guard let date = u16(d, 0), !na(date),
			let time = u32(d, 2), !na(time)
		else { return nil }
		let epoch = Double(date) * 86_400.0 + Double(time) / 10_000.0
		return [.init(name: "utc.timestamp", value: epoch, unit: "s")]
	}

	// 129539 — GNSS DOPs
	//   byte 0: SID
	//   byte 1: set mode (low 3 bits) + op mode (next 3 bits) + reserved
	//   bytes 2-3: HDOP (int16, 0.01 per LSB)
	//   bytes 4-5: VDOP (int16, 0.01 per LSB)
	//   bytes 6-7: TDOP (int16, 0.01 per LSB)
	private static func gnssDops(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let modes = u8(d, 1) {
			let opMode = (modes >> 3) & 0x07  // 1=1D, 2=2D, 3=3D, 4=auto
			if opMode > 0 && opMode <= 4 {
				out.append(.init(name: "gps.fix", value: Double(opMode)))
			}
		}
		if let h = i16(d, 2), !na(h) { out.append(.init(name: "gps.hdop", value: Double(h) * 0.01)) }
		if let v = i16(d, 4), !na(v) { out.append(.init(name: "gps.vdop", value: Double(v) * 0.01)) }
		if let t = i16(d, 6), !na(t) { out.append(.init(name: "gps.tdop", value: Double(t) * 0.01)) }
		return out.isEmpty ? nil : out
	}

	// 129540 — GNSS Sats in View (fast packet, variable length)
	//   byte 0: SID
	//   byte 1: range residual mode (low 2 bits) + reserved
	//   byte 2: number of SVs in view
	//   Per satellite — 12-byte blocks starting at offset 3:
	//     off+0      PRN         u8
	//     off+1..2   elevation   i16  1e-4 rad/bit  (Int16.max = N/A)
	//     off+3..4   azimuth     u16  1e-4 rad/bit  (0xFFFF = N/A)
	//     off+5..6   SNR         i16  0.01 dB/bit   (Int16.max = N/A; ≤0 = no lock)
	//     off+7..10  range residual  i32  (ignored)
	//     off+11     status          u8   (ignored)
	private static func gnssSatsInViewFrames(_ d: [UInt8]) -> [NMEAFrame]? {
		guard let n = u8(d, 2), n != 0xFF else { return nil }

		var sats: [SatelliteInfo] = []
		var snrsDB: [Double] = []
		var off = 3

		while off + 11 < d.count {
			guard let prnByte = u8(d, off) else { break }

			// Elevation: i16, 1e-4 rad/bit → degrees
			let el: Int? = i16(d, off + 1).flatMap {
				guard !na($0) else { return nil }
				return Int(round(Double($0) * 1e-4 * 180 / .pi))
			}
			// Azimuth: u16, 1e-4 rad/bit → degrees
			let az: Int? = u16(d, off + 3).flatMap {
				guard !na($0) else { return nil }
				return Int(round(Double($0) * 1e-4 * 180 / .pi))
			}
			// SNR: i16, 0.01 dB/bit → whole dB (nil if N/A or no lock)
			let snrRaw = i16(d, off + 5)
			let snr: Int? = snrRaw.flatMap { raw -> Int? in
				guard !na(raw) else { return nil }
				let dB = Double(raw) * 0.01
				return dB > 0 ? Int(round(dB)) : nil
			}
			if let raw = snrRaw, !na(raw) {
				let dB = Double(raw) * 0.01
				if dB > 0 { snrsDB.append(dB) }
			}

			sats.append(SatelliteInfo(prn: Int(prnByte), elevation: el, azimuth: az, snr: snr))
			off += 12
		}

		var out: [NMEAFrame] = [
			.gsvReport(constellation: "GNSS", inView: Int(n), satellites: sats)
		]
		out.append(.metric(.init(name: "gps.satellites.inView", value: Double(n))))
		if !snrsDB.isEmpty {
			let avg = snrsDB.reduce(0, +) / Double(snrsDB.count)
			out.append(.metric(.init(name: "gps.snr.avg", value: avg, unit: "dB")))
			out.append(.metric(.init(name: "gps.snr.max", value: snrsDB.max()!, unit: "dB")))
			out.append(.metric(.init(name: "gps.snr.min", value: snrsDB.min()!, unit: "dB")))
		}
		return out
	}

	// 130312 — Temperature
	//   byte 0: SID, byte 1: instance, byte 2: source
	//   bytes 3-4: actual temperature (uint16, 0.01 K per LSB)
	//   bytes 5-6: set temperature (uint16, 0.01 K per LSB)
	//
	// Source codes per Canboat:
	//   0=sea, 1=outside, 2=inside, 3=engine, 4=main cabin, 5=live well, 6=bait well,
	//   7=refrigerator, 8=heating system, 9=dew point, 10=apparent wind chill,
	//   11=theoretical wind chill, 12=heat index, 13=freezer, 14=exhaust gas, 15=shaft seal
	// 130312 — Temperature
	//   byte 0: SID, byte 1: Instance, byte 2: Source
	//   bytes 3-4: Actual Temperature (uint16, 0.01 K per LSB)
	//   bytes 5-6: Set Temperature    (uint16, 0.01 K per LSB) — thermostat target
	private static func temperature(_ d: [UInt8]) -> [BoatMetric]? {
		guard let source = u8(d, 2) else { return nil }
		let name = temperatureSourceName(source)
		var out: [BoatMetric] = []
		if let raw = u16(d, 3), !na(raw) {
			out.append(.init(name: name, value: Double(raw) * 0.01 - 273.15, unit: "°C"))
		}
		if let setRaw = u16(d, 5), !na(setRaw) {
			out.append(
				.init(
					name: "\(name).setpoint",
					value: Double(setRaw) * 0.01 - 273.15, unit: "°C"))
		}
		return out.isEmpty ? nil : out
	}

	// 129283 — Cross Track Error
	//   byte 0: SID
	//   byte 1: XTE mode (low 4 bits) + reserved + navigation terminated (1 bit)
	//   bytes 2-5: XTE (int32, 0.01 m per LSB; signed — negative = left of track)
	private static func crossTrackError(_ d: [UInt8]) -> [BoatMetric]? {
		guard let xte = i32(d, 2), !na(xte) else { return nil }
		let meters = Double(xte) * 0.01
		return [.init(name: "navigation.xte", value: meters / 1852.0, unit: "NM")]
	}

	// 130311 — Environmental Parameters (fast packet, supersedes 130310)
	//   byte 0: SID
	//   byte 1: temperature source (low 6 bits) + humidity source (high 2 bits)
	//   bytes 2-3: temperature (uint16, 0.01 K per LSB)
	//   bytes 4-5: humidity (int16, 0.004 % per LSB)
	//   bytes 6-7: atmospheric pressure (uint16, 100 Pa per LSB → hPa directly)
	private static func envWithHumidity(_ d: [UInt8]) -> [BoatMetric]? {
		guard let modes = u8(d, 1) else { return nil }
		let tempSource = modes & 0x3F
		var out: [BoatMetric] = []
		if let t = u16(d, 2), !na(t) {
			out.append(
				.init(
					name: temperatureSourceName(tempSource),
					value: Double(t) * 0.01 - 273.15, unit: "°C"))
		}
		if let h = i16(d, 4), !na(h) {
			out.append(.init(name: "humidity", value: Double(h) * 0.004, unit: "%"))
		}
		if let p = u16(d, 6), !na(p) {
			out.append(.init(name: "pressure.atmospheric", value: Double(p), unit: "hPa"))
		}
		return out.isEmpty ? nil : out
	}

	// 129284 — Navigation Data (fast packet)
	//   byte 0: SID
	//   bytes 1-4: distance to destination waypoint (uint32, 0.01 m per LSB)
	//   byte 5: course/bearing reference (4 bits) + perpendicular crossed (2 bits) + arrival circle entered (2 bits)
	//   byte 6: calculation type (2 bits) + reserved
	//   bytes 7-10: ETA time, bytes 11-12: ETA date — skipped
	//   bytes 13-14: bearing origin → destination waypoint (uint16, 1e-4 rad)
	//   bytes 15-16: bearing position → destination waypoint (uint16, 1e-4 rad)
	//   bytes 17-20: origin waypoint number, bytes 21-24: destination waypoint number — skipped (IDs are numeric refs)
	//   bytes 25-28: destination waypoint latitude (int32, 1e-7 deg)
	//   bytes 29-32: destination waypoint longitude (int32, 1e-7 deg)
	//   bytes 33-34: waypoint closing velocity (int16, 0.01 m/s — signed, positive = approaching)
	private static func navigationData(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let dist = u32(d, 1), !na(dist) {
			out.append(
				.init(
					name: "navigation.distanceToWaypoint",
					value: Double(dist) * 0.01 / 1852.0, unit: "NM"))
		}
		// ETA at the destination waypoint: time (0.0001 s of day) + date (days
		// since 1970), combined into a UNIX timestamp.
		if let etaTime = u32(d, 7), !na(etaTime), let etaDate = u16(d, 11), !na(etaDate) {
			let epoch = Double(etaDate) * 86_400.0 + Double(etaTime) * 0.0001
			out.append(.init(name: "navigation.eta", value: epoch, unit: "s"))
		}
		if let b = u16(d, 13), !na(b) {
			out.append(
				.init(
					name: "navigation.bearingOriginToDest",
					value: Double(b) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let b = u16(d, 15), !na(b) {
			out.append(
				.init(
					name: "navigation.bearingToDest",
					value: Double(b) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let lat = i32(d, 25), !na(lat) {
			out.append(.init(name: "waypoint.lat", value: Double(lat) * 1e-7, unit: "°"))
		}
		if let lon = i32(d, 29), !na(lon) {
			out.append(.init(name: "waypoint.lon", value: Double(lon) * 1e-7, unit: "°"))
		}
		if let vmg = i16(d, 33), !na(vmg) {
			out.append(
				.init(
					name: "navigation.vmg",
					value: Double(vmg) * 0.01 * 1.94384, unit: "kn"))
		}
		return out.isEmpty ? nil : out
	}

	// 129285 — Navigation Route / WP Information (fast packet)
	//   bytes 0-1: start RPS, bytes 2-3: number of WPs in this message
	//   bytes 4-5: database ID, bytes 6-7: route ID, byte 8: direction + flags
	//   route name (variable string), 1 reserved byte, then per waypoint:
	//   WP ID (uint16), WP name (variable string), lat / lon (int32, 1e-7°)
	/// Route and waypoint names — the companion of 129284, which only carries
	/// the destination waypoint *number*. Names are strings, so they reach the
	/// UI through ``BoatMetricStore``'s labels side channel, not as metrics.
	static func routeInfo(_ d: [UInt8]) -> (route: String?, waypoints: [Int: String])? {
		guard d.count >= 10 else { return nil }
		var offset = 9
		let route = variableString(d, at: &offset)
		offset += 1  // reserved
		var names: [Int: String] = [:]
		while offset + 2 <= d.count {
			guard let id = u16(d, offset), !na(id) else { break }
			offset += 2
			let name = variableString(d, at: &offset)
			offset += 8  // waypoint latitude + longitude, unused here
			if let name { names[Int(id)] = name }
		}
		return (route, names)
	}

	/// The origin and destination waypoint numbers of PGN 129284 (bytes 17-24)
	/// — indices into the route broadcast by 129285.
	static func navigationWaypointNumbers(_ d: [UInt8]) -> (origin: Int?, destination: Int?) {
		let origin = u32(d, 17).flatMap { na($0) ? nil : Int($0) }
		let destination = u32(d, 21).flatMap { na($0) ? nil : Int($0) }
		return (origin, destination)
	}

	/// Decodes an NMEA 2000 variable-length string — a length byte counting the
	/// two header bytes, a control byte (0 = UTF-16 LE, else 8-bit text), then
	/// the characters — advancing `offset` past the field.
	private static func variableString(_ d: [UInt8], at offset: inout Int) -> String? {
		guard offset < d.count else { return nil }
		let length = Int(d[offset])
		guard length >= 2, offset + length <= d.count else {
			offset = d.count
			return nil
		}
		let control = d[offset + 1]
		let raw = Array(d[(offset + 2)..<(offset + length)])
		offset += length
		let text: String? =
			control == 0
			? String(bytes: raw, encoding: .utf16LittleEndian)
			: String(bytes: raw.filter { $0 != 0x00 && $0 != 0xFF }, encoding: .isoLatin1)
		let trimmed = text?.trimmingCharacters(in: .whitespaces)
		return (trimmed?.isEmpty == false) ? trimmed : nil
	}

	// 130323 — Meteorological Station Data (fast packet)
	//
	// Broadcast by fixed or buoy-mounted weather stations. Carries the station's
	// position alongside its sensor readings — we namespace position under
	// `weatherStation.*` so it doesn't collide with the vessel's own GNSS fix.
	//
	//   byte 0: Mode (4 bits) + reserved
	//   bytes 1-2: measurement date, bytes 3-6: measurement time — skipped
	//   bytes 7-10: station latitude (int32, 1e-7 deg)
	//   bytes 11-14: station longitude (int32, 1e-7 deg)
	//   bytes 15-16: wind speed (uint16, 0.01 m/s)
	//   bytes 17-18: wind direction (uint16, 1e-4 rad)
	//   byte 19: wind reference (3 bits) + reserved
	//   bytes 20-21: wind gust speed (uint16, 0.01 m/s)
	//   bytes 22-23: atmospheric pressure (uint16, 100 Pa per LSB → hPa directly)
	//   bytes 24-25: ambient temperature (uint16, 0.01 K)
	private static func meteorologicalStation(_ d: [UInt8]) -> [BoatMetric]? {
		var out: [BoatMetric] = []
		if let lat = i32(d, 7), !na(lat) {
			out.append(.init(name: "weatherStation.lat", value: Double(lat) * 1e-7, unit: "°"))
		}
		if let lon = i32(d, 11), !na(lon) {
			out.append(.init(name: "weatherStation.lon", value: Double(lon) * 1e-7, unit: "°"))
		}
		if let ws = u16(d, 15), !na(ws) {
			out.append(.init(name: "TWS", value: Double(ws) * 0.01 * 1.94384, unit: "kn"))
		}
		if let wd = u16(d, 17), !na(wd) {
			out.append(.init(name: "TWD", value: Double(wd) * 1e-4 * 180 / .pi, unit: "°"))
		}
		if let g = u16(d, 20), !na(g) {
			out.append(.init(name: "TWS.gust", value: Double(g) * 0.01 * 1.94384, unit: "kn"))
		}
		if let p = u16(d, 22), !na(p) {
			out.append(.init(name: "pressure.atmospheric", value: Double(p), unit: "hPa"))
		}
		if let t = u16(d, 24), !na(t) {
			out.append(.init(name: "temperature.air", value: Double(t) * 0.01 - 273.15, unit: "°C"))
		}
		return out.isEmpty ? nil : out
	}

	// 130314 — Actual Pressure
	//   byte 0: SID, byte 1: instance, byte 2: source
	//   bytes 3-6: pressure (int32, 0.1 Pa per LSB)
	private static func actualPressure(_ d: [UInt8]) -> [BoatMetric]? {
		guard let source = u8(d, 2),
			let raw = i32(d, 3), !na(raw)
		else { return nil }
		let hPa = Double(raw) * 0.1 / 100.0
		let name: String
		switch source {
		case 0: name = "pressure.atmospheric"
		case 1: name = "pressure.water"
		case 2: name = "pressure.steam"
		case 3: name = "pressure.compressedAir"
		case 4: name = "pressure.hydraulic"
		case 5: name = "pressure.filter"
		default: name = "pressure.source\(source)"
		}
		return [.init(name: name, value: hPa, unit: "hPa")]
	}
}
