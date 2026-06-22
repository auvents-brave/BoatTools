internal import ArgumentParser
internal import BoatToolsKit
internal import Foundation
internal import Stheno

// `isatty` comes from the platform C library. Foundation re-exports it on
// Darwin, but Linux needs an explicit Glibc/Musl import. We pass the standard
// file-descriptor numbers (0/1/2) directly rather than `fileno(stdout)` etc.,
// because the `stdout`/`stderr`/`stdin` globals are mutable `var`s under Glibc
// and tripping strict concurrency.
#if canImport(Glibc)
	import Glibc
#elseif canImport(Musl)
	import Musl
#endif

// MARK: - ANSI colours (TTY-gated)

/// Whether the given file descriptor is an interactive terminal. Returns `false`
/// on Windows, where ANSI styling and interactive prompts are disabled (the
/// platform `isatty` is not wired up in this build).
private func fdIsTTY(_ fd: Int32) -> Bool {
	#if os(Windows)
		return false
	#else
		return isatty(fd) != 0
	#endif
}

/// ANSI escape codes only when stdout is a terminal — keeps pipes/redirects clean.
private let isStdoutTTY: Bool = fdIsTTY(1)
private let ANSI_RED: String = isStdoutTTY ? "\u{1B}[31m" : ""
private let ANSI_ORANGE: String = isStdoutTTY ? "\u{1B}[38;5;208m" : ""
private let ANSI_YELLOW: String = isStdoutTTY ? "\u{1B}[33m" : ""
private let ANSI_DIM: String = isStdoutTTY ? "\u{1B}[2m" : ""
private let ANSI_RESET: String = isStdoutTTY ? "\u{1B}[0m" : ""

// MARK: - Coordinate formatting

/// Formats decimal degrees as `DDDdeg MM.mmm'H` (e.g. `48°07.038'N`).
private func formatCoordDDM(_ dd: Double, isLatitude: Bool) -> String {
	let abs = Swift.abs(dd)
	let deg = Int(abs)
	let min = (abs - Double(deg)) * 60.0
	let hemi: String
	if isLatitude { hemi = dd >= 0 ? "N" : "S" } else { hemi = dd >= 0 ? "E" : "W" }
	return String(format: "%0*d°%06.3f'%@", isLatitude ? 2 : 3, deg, min, hemi)
}

// MARK: - Metric display helpers

private func formatMetricValue(_ m: BoatMetric) -> String {
	let v = m.value
	switch m.name {
	case "lat",
		"waypoint.lat",
		"weatherStation.lat":
		return formatCoordDDM(v, isLatitude: true)
	case "lon",
		"waypoint.lon",
		"weatherStation.lon":
		return formatCoordDDM(v, isLatitude: false)
	case "SOG", "STW", "AWS", "TWS", "TWS.gust",
		"speed.water.transverse", "speed.ground.transverse":
		return String(format: "%.1f kn", v)
	case "utc.timestamp":
		let formatter = ISO8601DateFormatter()
		formatter.timeZone = TimeZone(identifier: "UTC")
		return formatter.string(from: Date(timeIntervalSince1970: v))
	case "COG", "AWA", "TWA", "TWD", "TWD.gust", "HDG":
		return String(format: "%.1f°", v)
	case "HDG.true": return String(format: "%.1f° T", v)
	case "HDG.magnetic": return String(format: "%.1f° M", v)
	case "depth": return String(format: "%.2f m", v)
	case "ROT": return String(format: "%.1f °/min", v)
	case "altitude": return String(format: "%.1f m", v)
	case "temperature.water",
		"temperature.air":
		return String(format: "%.1f °C", v)
	case "log.total", "log.trip": return String(format: "%.1f NM", v)
	case "pitch", "roll", "yaw": return String(format: "%.2f°", v)
	case "rudder": return String(format: "%.1f°", v)
	case "pressure.atmospheric": return String(format: "%.0f hPa", v)
	case "gps.fix":
		switch Int(v) {
		case 1: return "1 (no fix)"
		case 2: return "2 (2D)"
		case 3: return "3 (3D)"
		default: return String(format: "%g", v)
		}
	case "gps.satellites": return String(format: "%.0f sats", v)
	case "gps.pdop",
		"gps.hdop",
		"gps.vdop",
		"gps.tdop":
		return String(format: "%.1f", v)
	case "gps.quality":
		switch Int(v) {
		case 0: return "0 (invalid)"
		case 1: return "1 (autonomous)"
		case 2: return "2 (DGPS)"
		case 3: return "3 (PPS)"
		case 4: return "4 (RTK fixed)"
		case 5: return "5 (RTK float)"
		case 6: return "6 (estimated / DR)"
		case 7: return "7 (manual)"
		case 8: return "8 (simulator)"
		default: return String(format: "%g", v)
		}
	case "gps.rms",
		"gps.error.lat",
		"gps.error.lon",
		"gps.error.alt":
		return String(format: "%.2f m", v)
	case "tilt": return String(format: "%.2f°", v)
	case "pjk.northing",
		"pjk.easting":
		return String(format: "%.3f m", v)
	case "navigation.xte": return String(format: "%+.3f NM", v)  // sign carries L/R
	case "navigation.bearingOriginToDest",
		"navigation.bearingOriginToDest.magnetic",
		"navigation.bearingToDest",
		"navigation.bearingToDest.magnetic",
		"navigation.bearingNextLeg",
		"navigation.bearingNextLeg.magnetic",
		"navigation.headingToSteer":
		return String(format: "%.1f°", v)
	case "navigation.distanceToWaypoint": return String(format: "%.2f NM", v)
	case "navigation.vmg": return String(format: "%+.1f kn", v)  // signed: + = approaching
	case "radar.rangeScale",
		"radar.cursor.range":
		return String(format: "%.2f NM", v)
	case "radar.cursor.bearing": return String(format: "%.1f°", v)
	case "route.id",
		"route.waypointsInMessage":
		return String(format: "%.0f", v)
	case "humidity": return String(format: "%.0f %%", v)
	case "temperature.dewPoint": return String(format: "%.1f °C", v)
	case "rudder.port": return String(format: "%.1f°", v)
	case "rudder.target": return String(format: "%+.1f°", v)
	case "HDG.deviation",
		"magneticVariation":
		return String(format: "%+.2f°", v)
	case "gps.geoidalSeparation": return String(format: "%+.2f m", v)
	case "depth.offset": return String(format: "%+.2f m", v)
	case "depth.range": return String(format: "%.0f m", v)
	case "utc.timeSource":
		switch Int(v) {
		case 0: return "GPS"
		case 1: return "GLONASS"
		case 2: return "Radio Station"
		case 3: return "Local Cesium"
		case 4: return "Local Rubidium"
		case 5: return "Local Crystal"
		default: return String(format: "%g", v)
		}
	case "COG.magnetic",
		"TWD.magnetic":
		return String(format: "%.1f° M", v)
	case "dsc.format",
		"dsc.category":
		return String(format: "%.0f", v)
	case "dsc.mmsi",
		"dse.mmsi":
		return String(format: "%.0f", v)  // MMSI is a 9–10 digit int
	default:
		if m.name.hasSuffix(".rpm") { return String(format: "%.0f rpm", v) }
		if m.name.hasSuffix(".voltage") { return String(format: "%.2f V", v) }
		if m.name.hasSuffix(".current") { return String(format: "%.1f A", v) }
		if m.name.hasSuffix(".temperature") { return String(format: "%.1f °C", v) }
		if m.name.hasSuffix(".level") { return String(format: "%.1f %%", v) }
		// Engine pressures — all reported in Pa, displayed in bar.
		if m.name.hasSuffix(".oilPressure") { return String(format: "%.2f bar", v / 100_000) }
		if m.name.hasSuffix(".coolantPressure") { return String(format: "%.2f bar", v / 100_000) }
		if m.name.hasSuffix(".fuelPressure") { return String(format: "%.2f bar", v / 100_000) }
		if m.name.hasSuffix(".boostPressure") { return String(format: "%.2f bar", v / 100_000) }
		// Engine dynamic metrics
		if m.name.hasSuffix(".oilTemperature") { return String(format: "%.1f °C", v) }
		if m.name.hasSuffix(".coolantTemperature") { return String(format: "%.1f °C", v) }
		if m.name.hasSuffix(".alternatorVoltage") { return String(format: "%.2f V", v) }
		if m.name.hasSuffix(".fuelRate") { return String(format: "%.1f L/h", v) }
		if m.name.hasSuffix(".tiltTrim") { return String(format: "%+.0f %%", v) }
		if m.name.hasSuffix(".load") { return String(format: "%.0f %%", v) }
		if m.name.hasSuffix(".torque") { return String(format: "%.0f %%", v) }
		if m.name.hasSuffix(".capacity") { return String(format: "%.0f L", v) }
		if m.name.hasSuffix(".setpoint") { return String(format: "%.1f °C", v) }
		if m.name.hasSuffix(".runtime") {
			let hours = v / 3600.0
			return String(format: "%.0f h (%.0f s)", hours, v)
		}
		// Per-category temperatures (cabin, engine, refrigerator, …)
		if m.name.hasPrefix("temperature.") { return String(format: "%.1f °C", v) }
		// Per-category pressures (water, hydraulic, …) — already in hPa
		if m.name.hasPrefix("pressure.") { return String(format: "%.0f hPa", v) }
		// Engine/shaft RPM via the .rpm suffix is handled above; pitch is a %
		if m.name.hasSuffix(".pitch") { return String(format: "%.1f %%", v) }
		// Alarm states (0/1) and power-device on/off states
		if m.name.hasPrefix("alarm.") || m.name.hasSuffix(".state") {
			switch Int(v) {
			case 0: return "off"
			case 1: return "on"
			default: return String(format: "%g", v)
			}
		}
		// Power devices — wattage
		if m.name.hasSuffix(".power") { return String(format: "%.0f W", v) }
		// Per-constellation GNSS metrics: glonass.satellites, beidou.hdop, …
		if m.name.hasSuffix(".satellites.inView") { return String(format: "%.0f visible", v) }
		if m.name.hasSuffix(".satellites") { return String(format: "%.0f sats", v) }
		if m.name.hasSuffix(".snr.avg")
			|| m.name.hasSuffix(".snr.max")
			|| m.name.hasSuffix(".snr.min")
		{
			return String(format: "%.0f dB", v)
		}
		if m.name.hasSuffix(".hdop")
			|| m.name.hasSuffix(".pdop")
			|| m.name.hasSuffix(".vdop")
		{
			return String(format: "%.1f", v)
		}
		if m.name.hasSuffix(".mode") {
			switch Int(v) {
			case 0: return "0 (no fix)"
			case 1: return "1 (autonomous)"
			case 2: return "2 (DGPS)"
			case 3: return "3 (PPS)"
			case 4: return "4 (RTK fixed)"
			case 5: return "5 (RTK float)"
			case 6: return "6 (estimated)"
			case 7: return "7 (manual)"
			case 8: return "8 (simulator)"
			default: return String(format: "%g", v)
			}
		}
		if let u = m.unit { return String(format: "%g \(u)", v) }
		return String(format: "%g", v)
	}
}

private let n2kPGNNames: [(pgn: UInt32, name: String)] = [
	(126992, "System Time"),
	(127245, "Rudder"),
	(127250, "Heading"),
	(127251, "Rate of Turn"),
	(127257, "Attitude"),
	(127488, "Engine Parameters Rapid"),
	(127489, "Engine Parameters Dynamic"),
	(127505, "Fluid Level"),
	(127508, "Battery Status"),
	(128259, "Speed Through Water"),
	(128267, "Water Depth"),
	(128275, "Distance Log"),
	(129025, "Position Rapid"),
	(129026, "COG & SOG Rapid"),
	(129029, "GNSS Position Data"),
	(129033, "Time & Date"),
	(129283, "Cross Track Error"),
	(129284, "Navigation Data"),
	(129285, "Navigation Route / WP Information"),
	(129038, "AIS Class A Position Report"),
	(129039, "AIS Class B Position Report"),
	(129040, "AIS Class B Extended Position Report"),
	(129041, "AIS Aids to Navigation Report"),
	(129539, "GNSS DOPs"),
	(129540, "GNSS Sats in View"),
	(129793, "AIS UTC and Date Report"),
	(129794, "AIS Class A Static and Voyage Data"),
	(129809, "AIS Class B Static Data Part A"),
	(129810, "AIS Class B Static Data Part B"),
	(130306, "Wind Data"),
	(130310, "Environmental Parameters"),
	(130311, "Environmental Parameters (extended)"),
	(130312, "Temperature"),
	(130314, "Actual Pressure"),
	(130323, "Meteorological Station Data"),
]

// MARK: - Frame renderer

/// Pretty-print an NMEAFrame, colourising the diagnostic cases.
private func render(_ frame: NMEAFrame) {
	switch frame {

	case .nmea0183(_, let talker, let type, let fields):
		let talkerLabel = TalkerId(rawValue: talker)?.label ?? talker
		let typeLabel = MessageId(rawValue: type)?.label ?? type
		let hasDecoder = NMEA0183Parser.decodedTypes.contains(type)

		// Multi-message sentences carry "<total>,<msgNum>" as fields [1] and [2].
		// Surface that "part X/N" right in the header so the cadence is visible.
		let multipartSuffix: String = {
			guard ["GSV", "VDM", "VDO"].contains(type), fields.count >= 3,
				let total = Int(fields[1]), let part = Int(fields[2]),
				total >= 1, part >= 1, part <= total
			else { return "" }
			return "\(ANSI_DIM)  — part \(part)/\(total)\(ANSI_RESET)"
		}()

		// For Trimble proprietary $PTNL,<sub>,…  — show the sub-command in clear text.
		var line: String
		if type == "TNL", fields.count >= 2 {
			let sub = fields[1]
			let subLabel: String
			switch sub {
			case "GGK": subLabel = "Position fix + quality (extended GGA)"
			case "AVR": subLabel = "Attitude — Yaw / Tilt / Roll"
			case "VHD": subLabel = "Heading (dual antenna)"
			case "PJK": subLabel = "Projected local coordinates"
			case "BPQ": subLabel = "Base position + quality"
			case "REX": subLabel = "Receiver exception"
			case "DG": subLabel = "L-band corrections control"
			default: subLabel = "subcommand"
			}
			line = "📡 [\(talker)] \(talkerLabel) · TNL Trimble · \(sub) \(subLabel)"
		} else {
			line = "📡 [\(talker)] \(talkerLabel) · \(type) \(typeLabel)"
		}

		if hasDecoder {
			// TNL is in decodedTypes but the dispatch may not recognise the sub-command —
			// we can't tell from here, so we trust the table.
			print(line + multipartSuffix)
			if type == "VER" { renderVER(fields: fields) }
		} else {
			print("\(ANSI_YELLOW)\(line)\(ANSI_DIM)  (no decoder yet)\(ANSI_RESET)")
		}

	case .nmea2000(let pgn, let src, let pri, _):
		let name = n2kPGNNames.first(where: { $0.pgn == pgn })?.name ?? "PGN \(pgn)"
		print("⚓ N2K  \(name)  (pgn=\(pgn) src=\(src) pri=\(pri))")

	case .metric(let m):
		let value = formatMetricValue(m)
		// Pad the name column to at least 24 chars, but never truncate longer names.
		let name = m.name.padding(toLength: max(24, m.name.count), withPad: " ", startingAt: 0)
		print("   ↳ \(name) \(value)")

	case .aisTarget(let t):
		renderAIS(t)

	case .gsvReport(let constellation, let inView, let satellites):
		print("   🛰  \(constellation) — \(inView) in view")
		for sat in satellites {
			let el = sat.elevation.map { String(format: "%2d°", $0) } ?? " —"
			let az = sat.azimuth.map { String(format: "%3d°", $0) } ?? "——"
			let snr = sat.snr.map { String(format: "%2d dB", $0) } ?? "no signal"
			print("   \(ANSI_DIM)     PRN \(String(format: "%3d", sat.prn))  el \(el)  az \(az)  \(snr)\(ANSI_RESET)")
		}

	case .invalidChecksum(let line):
		print("\(ANSI_RED)❌ bad checksum: \(line)\(ANSI_RESET)")

	case .unknown(let line):
		print("\(ANSI_ORANGE)⚠️  unknown: \(line)\(ANSI_RESET)")
	}
}

/// Pretty-prints any `$..VER` sentence — Equipment Version Information.
///
/// Three layouts seen in the wild:
///  - IEC 61162-1 ed.4 multi-message form (9 named fields):
///      `$..VER,<numMsgs>,<msgNum>,<deviceType>,<vendor>,<uniqueID>,<model>,<sw>,<hw>,<seq>*hh`
///  - Vendor short form (no multi-message prefix, named fields):
///      `$..VER,<deviceType>,<vendor>,<model>,<sw>,<hw>*hh`
///  - AIS-display micro form (model code + firmware version):
///      `$ADVER,<modelCode>,<sw>*hh`   e.g. `$ADVER,3080,2.4P`
///
/// We detect:
///  - multi-message: f[1] and f[2] are both small ints (1–9)
///  - micro: exactly 3 fields and f[1] is purely digits (model code)
///  - otherwise: vendor short form
private func renderVER(fields: [String]) {
	func cleanField(_ s: String) -> String {
		let stripped = s.split(separator: "*").first.map(String.init) ?? s
		return stripped.trimmingCharacters(in: .whitespaces)
	}

	func printPair(_ label: String, _ value: String) {
		guard !value.isEmpty else { return }
		let pad = String(repeating: " ", count: max(0, 24 - label.count))
		print("   ↳ \(label)\(pad) \(value)")
	}

	// --- Micro form: $ADVER,3080,2.4P*XX ---------------------------------
	if fields.count == 3,
		!fields[1].isEmpty,
		fields[1].allSatisfy(\.isNumber)
	{
		printPair("model code", cleanField(fields[1]))
		printPair("software version", cleanField(fields[2]))
		return
	}

	// --- Multi-message form (IEC 61162-1 ed.4) ---------------------------
	let hasMultiMsgPrefix: Bool = {
		guard fields.count > 2,
			let n = Int(fields[1]), let m = Int(fields[2]),
			(1...9).contains(n), (1...9).contains(m)
		else { return false }
		return true
	}()
	let offset = hasMultiMsgPrefix ? 3 : 1
	let labels = ["device type", "vendor", "unique ID", "model", "software", "hardware", "sequence"]

	var anyPrinted = false
	for (i, label) in labels.enumerated() {
		let idx = offset + i
		guard idx < fields.count else { break }
		let v = cleanField(fields[idx])
		guard !v.isEmpty else { continue }
		printPair(label, v)
		anyPrinted = true
	}

	// --- Diagnostic fallback: dump raw non-empty fields ------------------
	if !anyPrinted {
		for idx in 1..<fields.count {
			let v = cleanField(fields[idx])
			guard !v.isEmpty else { continue }
			let label = "field \(idx)"
			let pad = String(repeating: " ", count: max(0, 24 - label.count))
			print("\(ANSI_DIM)   ↳ \(label)\(pad) \(v)\(ANSI_RESET)")
		}
	}
}

private func renderAIS(_ t: AISTarget) {
	let typeLabel = t.messageType.label
	let flag = t.country.map { " \($0.flag)" } ?? ""
	print("🚢 AIS  MMSI \(t.mmsi)\(flag)  [\(t.messageType.rawValue)] \(typeLabel)  ch:\(t.channel)")
	if let c = t.country { print("   ↳ country       \(c.name)") }
	if let name = t.shipName { print("   ↳ name          \(name)") }
	if let cs = t.callsign { print("   ↳ callsign      \(cs)") }
	if let st = t.shipType { print("   ↳ type          \(st.label)") }
	if let imo = t.imoNumber, imo > 0 { print("   ↳ IMO           \(imo)") }
	if let ns = t.navigationStatus {
		print("   ↳ nav status    \(ns.label)")
	}
	if let lat = t.latitude, let lon = t.longitude {
		print("   ↳ position      \(formatCoordDDM(lat, isLatitude: true))  \(formatCoordDDM(lon, isLatitude: false))")
	}
	if let sog = t.speedOverGround { print("   ↳ SOG           \(String(format: "%.1f kn", sog))") }
	if let cog = t.courseOverGround { print("   ↳ COG           \(String(format: "%.1f°", cog))") }
	if let hdg = t.trueHeading { print("   ↳ HDG           \(hdg)°") }
	if let rot = t.rateOfTurn { print("   ↳ ROT           \(rot) °/min") }
	if let mi = t.maneuverIndicator, mi != .notAvailable {
		print("   ↳ manoeuvre     \(mi.label)")
	}
	if let nt = t.navAidType { print("   ↳ aid type      \(nt.label)") }
	if let dest = t.destination { print("   ↳ destination   \(dest)") }
	if let dr = t.draught, dr > 0 { print("   ↳ draught       \(String(format: "%.1f m", dr))") }
	if let alt = t.altitude { print("   ↳ altitude      \(String(format: "%.0f m", alt))") }
	// Only show the position-quality footer when it carries non-default information
	// (acc:high or RAIM:on) — for typical Class B receivers it's always low/off and noisy.
	if t.positionAccuracy || t.raim {
		print("   ↳ acc:\(t.positionAccuracy ? "high" : "low")  RAIM:\(t.raim ? "on" : "off")")
	}
}

/// Shared consumer for any `AsyncThrowingStream<NMEAFrame>`. `duration == 0` → forever.
///
/// We race the iteration against a wall-clock timer rather than only checking the
/// deadline on each received frame: with a silent source (e.g. signalk-server
/// without configured plugins), no frame ever arrives and a frame-gated check
/// would block forever.
private func consumeFrames(
	_ stream: AsyncThrowingStream<NMEAFrame, any Error>,
	duration: Int
) async throws {
	if duration <= 0 {
		for try await frame in stream {
			render(frame)
		}
		return
	}

	let consumer = Task {
		for try await frame in stream {
			try Task.checkCancellation()
			render(frame)
		}
	}
	try? await Task.sleep(for: .seconds(duration))
	consumer.cancel()
	_ = try? await consumer.value
}

extension String {
	/// Returns nil if the string is empty, otherwise self. Lets us chain `.nonEmpty`
	/// after a trim to skip blank values cleanly.
	fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// Pretty-prints a batch of VRM diagnostic records, grouped by physical device.
/// Each group has its own header; labels are padded for readable column alignment.
/// Uses `formattedValue` ("12.43 V", "85 %") when present so units come pre-formatted
/// by Victron's API rather than reconstructed from `rawValue + unit`.
private func renderVRMDiagnostics(_ records: [VictronVRMClient.DiagnosticRecord], siteId: Int) {
	// Group preserving record order within each device.
	var groups: [(tag: String, records: [VictronVRMClient.DiagnosticRecord])] = []
	var index: [String: Int] = [:]
	for r in records {
		let tag = r.deviceTag.isEmpty ? "(unknown device)" : r.deviceTag
		if let i = index[tag] {
			groups[i].records.append(r)
		} else {
			index[tag] = groups.count
			groups.append((tag, [r]))
		}
	}
	groups.sort { $0.tag < $1.tag }

	print("— Site \(siteId) diagnostics, \(records.count) records across \(groups.count) device(s) —")
	for (tag, recs) in groups {
		// If the group exposes a user-friendly name (Battery / Solar Charger custom
		// name, Model…), surface it in the header so "Battery Monitor [0]" becomes
		// "Battery Monitor [0] — Lynx 24" at a glance.
		let friendly: String? = recs.first(where: { r in
			let d = (r.description ?? "").lowercased()
			return d.contains("custom name") || d == "model"
		})?.formattedValue?
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.nonEmpty
		let header = friendly.map { "\(tag) — \($0)" } ?? tag
		print("\n━━ \(header) ━━")

		let width = recs.compactMap(\.description).map(\.count).max() ?? 0
		for r in recs {
			let label = r.description ?? "(?)"
			let pad = String(repeating: " ", count: max(0, width - label.count))
			let value =
				r.formattedValue
				?? r.rawValue.map { String(format: "%g", $0) }
				?? "—"
			print("  \(label)\(pad)  \(value)")
		}
	}
}

/// Polls a one-shot REST `body` every `watch` seconds. `watch == 0` → single call (no polling).
/// `duration == 0` → forever (when polling). Errors during polling are printed to stderr and the
/// loop continues; errors in one-shot mode are rethrown.
private func pollLoop(
	watch: Int,
	duration: Int,
	body: () async throws -> Void
) async throws {
	let started = Date()
	var iteration = 0
	while true {
		if watch > 0 && iteration > 0 {
			print("\n— \(Date().formatted(.iso8601)) —")
		}
		iteration += 1
		do {
			try await body()
		} catch {
			if watch <= 0 { throw error }
			FileHandle.standardError.write(Data("⚠ \(error)\n".utf8))
		}
		if watch <= 0 { return }
		if duration > 0, Date().timeIntervalSince(started) >= Double(duration) { return }
		try await Task.sleep(for: .seconds(watch))
	}
}

@main
struct BoatToolsCLI: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "boattools",
		abstract: "CLI tools to explore sailboat data sources",
		version: ToolVersion.current,
		subcommands: [
			ConnectCommand.self,
			FileCommand.self,
			VRMCommand.self,
			DiscoverCommand.self,
			GMDSSCommand.self,
			SimulateCommand.self,
		])
}

// =============================================================================
// MARK: - WireFormat
// =============================================================================

enum WireFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
	case auto, nmea0183, ydraw, seasmart, signalk, canboat, ikonvert

	// Maps to the transport's input format.
	var transportFormat: NMEAInputFormat {
		switch self {
		case .auto: return .auto
		case .nmea0183: return .nmea0183
		case .ydraw: return .yachtDevicesRaw
		case .seasmart: return .seaSmartNet
		case .signalk: return .signalK
		case .canboat: return .canboatPlain
		case .ikonvert: return .iKonvert
		}
	}
}

/// Wraps a value so a `@Sendable` closure can capture it without relying on the
/// value's own, platform-specific `Sendable` conformance.
///
/// `FileHandle` is `Sendable` only on Darwin; the raw-log writer confines all
/// access to the transport's single consumer task, so the unchecked conformance
/// is safe and keeps the capture portable to Linux.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
	let value: Value
	init(_ value: Value) { self.value = value }
}

/// Current UTC time of day as `HH:mm:ss.SSS`, used for the Yacht Devices RAW
/// capture prefix. Built from value-type date components so it stays
/// `Sendable`-safe inside the raw-logger closure.
private func ydRawCaptureTimestamp() -> String {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC")!
	let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
	let milliseconds = (c.nanosecond ?? 0) / 1_000_000
	return String(
		format: "%02d:%02d:%02d.%03d",
		c.hour ?? 0, c.minute ?? 0, c.second ?? 0, milliseconds)
}

// =============================================================================
// MARK: - connect
// =============================================================================

struct ConnectCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "connect",
		abstract: "Connect to a marine data source (TCP, UDP, or Signal K web)",
		discussion: """
			Two mutually exclusive addressing modes:

			  URL mode (--url):
			    --url tcp://host:port        TCP socket — NMEA or Signal K NDJSON (--format signalk)
			    --url udp://:port            UDP broadcast
			    --url udp://group:port       UDP multicast
			    --url ws://host:port         Signal K WebSocket stream
			    --url wss://host:port        Signal K WebSocket stream (TLS)
			    --url http://host:port       Signal K REST snapshot (--live to force WebSocket)
			    --url https://host:port      Signal K REST snapshot (TLS)

			  Classic socket mode (--port):
			    --port P                     UDP broadcast on port P
			    --port P --host H            TCP to host H on port P
			    --port P --multicast A       UDP multicast — join group A on port P
			"""
	)

	// --- addressing -----------------------------------------------------------

	@Option(
		name: .shortAndLong,
		help: "Universal endpoint URL (tcp://, udp://, ws://, http://…)")
	var url: String?

	@Option(
		name: .shortAndLong,
		help: "Host — with --port: TCP. Incompatible with --url.")
	var host: String?

	@Option(
		name: .shortAndLong,
		help: "Port — alone: UDP broadcast; +--host: TCP; +--multicast: UDP multicast. Incompatible with --url.")
	var port: Int?

	@Option(help: "Multicast group address — requires --port. Incompatible with --url.")
	var multicast: String?

	// --- common ---------------------------------------------------------------

	@Option(help: "Wire format for TCP/UDP streams (auto|nmea0183|ydraw|seasmart|signalk)")
	var format: WireFormat = .auto

	@Option(
		name: .shortAndLong,
		help: ArgumentHelp("Listen/stream duration in seconds (0 = forever)", valueName: "sec"))
	var duration: Int = 0

	@Option(
		name: .shortAndLong,
		help: ArgumentHelp(
			"REST snapshot poll interval in seconds (0 = one-shot; ignored for live streams)", valueName: "sec"))
	var watch: Int = 0

	@Flag(help: "Force WebSocket live stream on an http(s) URL")
	var live: Bool = false

	@Option(help: "Bearer token (Signal K / web auth)")
	var token: String?

	@Option(help: "Username (Signal K auth)")
	var username: String?

	@Option(help: "Password (Signal K auth)")
	var password: String?

	@Option(
		name: .shortAndLong,
		help: "Write raw received lines to a .log file for later replay with `file`")
	var log: String?

	// -------------------------------------------------------------------------

	/// Internal transport discriminator, resolved from CLI arguments.
	fileprivate enum Transport {
		case tcp(host: String, port: Int)
		case udpBroadcast(port: Int)
		case udpMulticast(port: Int, group: String)
		case web(url: String)
	}

	fileprivate func resolveTransport() throws -> Transport {
		let hasURL = url != nil
		let hasSocket = host != nil || port != nil || multicast != nil

		guard !(hasURL && hasSocket) else {
			throw ValidationError("--url cannot be combined with --host / --port / --multicast")
		}
		guard hasURL || port != nil else {
			throw ValidationError("Specify either --url or --port (with optional --host or --multicast)")
		}
		if host != nil, port == nil {
			throw ValidationError("--host requires --port")
		}
		if multicast != nil, port == nil {
			throw ValidationError("--multicast requires --port")
		}
		if host != nil, multicast != nil {
			throw ValidationError("--host and --multicast are mutually exclusive")
		}

		if let raw = url {
			return try Self.parseURL(raw)
		}

		// Classic socket mode — port is guaranteed non-nil here.
		let p = port!
		if let m = multicast { return .udpMulticast(port: p, group: m) }
		if let h = host { return .tcp(host: h, port: p) }
		return .udpBroadcast(port: p)
	}

	private static func parseURL(_ raw: String) throws -> Transport {
		let lower = raw.lowercased()
		if lower.hasPrefix("tcp://") {
			guard let comps = URLComponents(string: raw),
				let h = comps.host, !h.isEmpty,
				let p = comps.port
			else {
				throw ValidationError("Invalid tcp:// URL — expected tcp://host:port")
			}
			return .tcp(host: h, port: p)
		}
		if lower.hasPrefix("udp://") {
			guard let comps = URLComponents(string: raw),
				let p = comps.port
			else {
				throw ValidationError("Invalid udp:// URL — expected udp://:port or udp://group:port")
			}
			let h = comps.host ?? ""
			return h.isEmpty ? .udpBroadcast(port: p) : .udpMulticast(port: p, group: h)
		}
		// http / https / ws / wss → Signal K web
		return .web(url: raw)
	}

	// -------------------------------------------------------------------------

	func run() async throws {
		let transport = try resolveTransport()
		let logger = try log.map { try makeRawLogger(path: $0) }

		switch transport {

		case .tcp(let h, let p):
			if format == .signalk {
				try await consumeFrames(
					SignalKClient.tcpStream(host: h, port: p, rawLogger: logger),
					duration: duration)
			} else {
				let cfg = NMEATransportConfig(
					mode: .tcp(host: h, port: p),
					format: format.transportFormat,
					decodePGNs: true,
					rawLogger: logger)
				try await consumeFrames(
					NMEATransport.frameStream(config: cfg),
					duration: duration)
			}

		case .udpBroadcast(let p):
			if format == .signalk {
				try await consumeFrames(
					SignalKClient.udpStream(listenPort: p, rawLogger: logger),
					duration: duration)
			} else {
				let cfg = NMEATransportConfig(
					mode: .udp(listenPort: p, multicastGroup: nil),
					format: format.transportFormat,
					decodePGNs: true,
					rawLogger: logger)
				try await consumeFrames(
					NMEATransport.frameStream(config: cfg),
					duration: duration)
			}

		case .udpMulticast(let p, let group):
			let cfg = NMEATransportConfig(
				mode: .udp(listenPort: p, multicastGroup: group),
				format: format.transportFormat,
				decodePGNs: true,
				rawLogger: logger)
			try await consumeFrames(
				NMEATransport.frameStream(config: cfg),
				duration: duration)

		case .web(let urlStr):
			try await runWeb(urlStr: urlStr, rawLogger: logger)
		}
	}

	/// Creates (or truncates) a log file and returns a `@Sendable` closure that
	/// appends one raw line at a time. The `FileHandle` is `Sendable` (macOS 14+)
	/// and all writes come from the transport's single consumer task, so no lock needed.
	///
	/// Bare Yacht Devices RAW frames (whitespace-separated hex, no embedded
	/// timestamp) are written with a `<HH:mm:ss.SSS> R` prefix so the capture can
	/// be replayed at the original pace with `file --realtime`. Every other format
	/// carries its own timestamp (or would be corrupted by a prefix) and is written
	/// verbatim.
	private func makeRawLogger(path: String) throws -> @Sendable (String) -> Void {
		guard FileManager.default.createFile(atPath: path, contents: nil) else {
			throw ValidationError("Cannot create log file at '\(path)'")
		}
		let handle = UncheckedSendableBox(try FileHandle(forWritingTo: URL(fileURLWithPath: path)))
		return { @Sendable line in
			let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
			let isBareYDRaw = tokens.count >= 2 && tokens.allSatisfy { $0.allSatisfy(\.isHexDigit) }
			let out = isBareYDRaw ? "\(ydRawCaptureTimestamp()) R \(line)" : line
			if let data = (out + "\n").data(using: .utf8) {
				try? handle.value.write(contentsOf: data)
			}
		}
	}

	private func runWeb(
		urlStr: String,
		rawLogger: (@Sendable (String) -> Void)? = nil
	) async throws {
		let client = SignalKClient(
			config: .init(baseURL: urlStr, token: token, username: username, password: password))

		let isWS = urlStr.lowercased().hasPrefix("ws://") || urlStr.lowercased().hasPrefix("wss://")
		let wantsLive = isWS || live

		do {
			if wantsLive {
				let stream = await client.liveStream(rawLogger: rawLogger)
				try await consumeFrames(stream, duration: duration)
			} else {
				try await pollLoop(watch: watch, duration: duration) {
					let snap = try await client.snapshot()
					let leaves = snap.numericLeaves()
					if leaves.isEmpty {
						print("Snapshot received — no numeric values.")
						if case .object(let dict) = snap {
							let keys = dict.keys.sorted().joined(separator: ", ")
							print("  top-level keys: \(keys)")
						}
					} else {
						print("Snapshot — \(leaves.count) numeric value\(leaves.count > 1 ? "s" : ""):")
						for (path, v) in leaves {
							print("  \(path) = \(v)")
						}
					}
				}
			}
		} catch {
			try? await client.shutdown()
			throw error
		}

		try await client.shutdown()
	}
}

// =============================================================================
// MARK: - file (local log file)
// =============================================================================

struct FileCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "file",
		abstract: "Read and parse a local log file",
		discussion: """
			Supported formats (auto-detected by default):
			  NMEA 0183  — sentences starting with $ or !
			  YD RAW     — Yacht Devices CAN hex format (bare, or with a
			               "<timestamp> R/T" logging prefix)
			  SeaSmart   — $PCDIN sentences
			  Signal K   — NDJSON deltas (lines starting with {)
			  Canboat    — PLAIN CSV: TIMESTAMP,PRIO,PGN,SRC,DST,LEN,bytes…
			  iKonvert   — Digital Yacht !PDGY sentences (Base64 N2K payload)

			Timing options (mutually exclusive):
			  (none)      Emit all frames as fast as possible.
			  --rate N    Artificial throttle: N frames per second.
			  --realtime  Replay at original recorded pace, using timestamps
			              embedded in the data:
			                · Signal K NDJSON: updates[].timestamp (ISO 8601)
			                · NMEA 0183 RMC:   date (DDMMYY) + time (HHMMSS)
			              Lines with no recognisable timestamp are emitted
			              immediately in sequence.
			"""
	)

	@Argument(help: "Path to the log file")
	var path: String

	@Option(help: "Wire format (auto|nmea0183|ydraw|seasmart|signalk|canboat|ikonvert; default: auto-detect)")
	var format: WireFormat = .auto

	@Flag(help: "Replay at the original recorded pace using embedded timestamps")
	var realtime: Bool = false

	@Option(
		name: .shortAndLong,
		help: ArgumentHelp(
			"Replay at fixed rate: N source lines per second — one NMEA sentence, "
				+ "one CAN frame, or one Signal K delta per tick, regardless of how many "
				+ "metrics each line produces. (0 = as fast as possible)",
			valueName: "lines/s"))
	var rate: Double = 0

	func run() async throws {
		if realtime && rate > 0 {
			throw ValidationError("--realtime and --rate are mutually exclusive")
		}

		let stream = NMEATransport.fileStream(
			path: path,
			format: format.transportFormat,
			decodePGNs: true)

		if realtime {
			try await runRealtime(stream)
		} else if rate > 0 {
			try await runAtRate(stream, fps: rate)
		} else {
			for try await ff in stream { render(ff.frame) }
		}
	}

	/// Replay at the pace embedded in the data.
	/// The wall clock is anchored to the first line that carries a timestamp;
	/// timestamp-less lines are emitted immediately.
	private func runRealtime(_ stream: AsyncThrowingStream<FileFrame, any Error>) async throws {
		var wallAnchor: Date? = nil
		var logAnchor: Date? = nil

		for try await ff in stream {
			if let ts = ff.timestamp {
				let now = Date()
				if wallAnchor == nil {
					wallAnchor = now
					logAnchor = ts
				}
				let elapsed = ts.timeIntervalSince(logAnchor!)
				let target = wallAnchor!.addingTimeInterval(elapsed)
				let delay = target.timeIntervalSinceNow
				if delay > 0.001 {
					try await Task.sleep(for: .seconds(delay))
				}
			}
			render(ff.frame)
		}
	}

	/// Artificial fixed-rate replay.
	///
	/// `--rate` paces source lines, not output frames — one input sentence/CAN frame
	/// can decode into several frames (raw + multiple metrics + AIS target) which are
	/// all rendered as one visual group, with the sleep applied *between* groups.
	/// So `--rate 1` really means "1 input line per second" regardless of how many
	/// metrics each line produces.
	private func runAtRate(_ stream: AsyncThrowingStream<FileFrame, any Error>, fps: Double) async throws {
		let interval = 1.0 / fps
		var lastLineIndex = 0
		for try await ff in stream {
			if lastLineIndex != 0, ff.lineIndex != lastLineIndex {
				try await Task.sleep(for: .seconds(interval))
			}
			render(ff.frame)
			lastLineIndex = ff.lineIndex
		}
	}
}

// =============================================================================
// MARK: - vrm (Victron VRM cloud)
// =============================================================================

struct VRMCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "vrm",
		abstract: "Victron VRM installations and diagnostics"
	)

	@Option(name: .shortAndLong) var token: String
	@Option(name: .shortAndLong) var userId: Int
	@Option(name: .shortAndLong) var siteId: Int?
	@Option(
		name: .shortAndLong,
		help: ArgumentHelp("Poll interval (0 = one-shot)", valueName: "sec"))
	var watch: Int = 0
	@Option(
		name: .shortAndLong,
		help: ArgumentHelp("Total poll duration (0 = forever, requires --watch)", valueName: "sec"))
	var duration: Int = 0

	func run() async throws {
		let client = VictronVRMClient(config: .init(accessToken: token))

		do {
			try await pollLoop(watch: watch, duration: duration) {
				if let site = siteId {
					let records = try await client.diagnostics(siteId: site)
					renderVRMDiagnostics(records, siteId: site)
				} else {
					let sites = try await client.installations(userId: userId)
					print("— Installations —")
					for s in sites { print("  [\(s.idSite)] \(s.name)") }
				}
			}
		} catch {
			try? await client.shutdown()
			throw error
		}

		try await client.shutdown()
	}
}

// =============================================================================
// MARK: - gmdss (WMO high-seas forecasts)
// =============================================================================

struct GMDSSCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "gmdss",
		abstract: "Download official GMDSS high-seas forecasts (WMO WWMIWS)")

	@Option(name: .shortAndLong, help: ArgumentHelp("METAREA number (1–21) — prints all its bulletins", valueName: "n"))
	var metarea: Int?

	@Option(help: ArgumentHelp("Latitude, decimal degrees (N+); with --lon prints only the sub-area", valueName: "deg"))
	var lat: Double?

	@Option(help: ArgumentHelp("Longitude, decimal degrees (E+)", valueName: "deg"))
	var lon: Double?

	func validate() throws {
		switch (metarea, lat, lon) {
		case (.some, nil, nil), (nil, .some, .some): break
		default:
			throw ValidationError("Use either --metarea <1-21>, or --lat <deg> --lon <deg>.")
		}
	}

	func run() async throws {
		let service = GMDSSForecastService()
		let forecast =
			if let metarea {
				try await service.forecast(metarea: metarea)
			} else {
				try await service.forecast(latitude: lat!, longitude: lon!)
			}
		print("— \(forecast.title) · issued \(forecast.issued) —")
		for bulletin in forecast.bulletins {
			print("\n=== \(bulletin.label) ===")
			print(bulletin.text)
		}
	}
}

// =============================================================================
// MARK: - simulate (synthetic NMEA 2000 passage)
// =============================================================================

struct SimulateCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "simulate",
		abstract: "Replay a synthetic NMEA 2000 passage from the built-in simulator")

	@Option(name: .shortAndLong, help: ArgumentHelp("Route id (use --list to see them)", valueName: "id"))
	var route: String = SimulatorRoute.monacoToMaddalena.id

	@Option(name: .shortAndLong, help: ArgumentHelp("Speed over ground, knots", valueName: "kn"))
	var speed: Double = 6

	@Option(help: ArgumentHelp("Fast-forward factor for movement only (SOG stays realistic)", valueName: "x"))
	var fast: Double = 1

	@Option(name: .shortAndLong, help: ArgumentHelp("Stop after N seconds (0 = until Ctrl-C)", valueName: "sec"))
	var duration: Int = 0

	@Flag(help: "List the available routes and exit")
	var list: Bool = false

	func run() async throws {
		if list {
			print("— Simulator routes —")
			for r in SimulatorRoute.presets {
				print("  [\(r.id)] \(r.name) — \(r.waypoints.count) waypoints")
			}
			return
		}
		guard let passage = SimulatorRoute.preset(id: route) else {
			throw ValidationError("Unknown route '\(route)'. Use --list to see the available ids.")
		}
		print("— Simulating \(passage.name) at \(speed) kn (×\(fast)) — Ctrl-C to stop —")
		let stream = NMEASimulator.frameStream(
			route: passage, speedKnots: speed, timeMultiplier: fast, loop: true)
		try await consumeFrames(stream, duration: duration)
	}
}

// =============================================================================
// MARK: - discover (mDNS Bonjour)
// =============================================================================

struct DiscoverCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "discover",
		abstract: "Browse mDNS servers on the LAN (Signal K + NMEA 0183 TCP), then connect interactively."
	)

	@Option(
		name: .shortAndLong,
		help: ArgumentHelp("Scan duration", valueName: "sec"))
	var timeout: Double = 5

	@Flag(name: .long, help: "Skip the interactive prompt, just list endpoints")
	var noInteractive: Bool = false

	func run() async throws {
		let discovery = BonjourDiscovery()
		var found: [DiscoveredEndpoint] = []

		print("→ Scanning Bonjour for \(Int(timeout))s…")
		do {
			for try await endpoint in discovery.browse(timeout: timeout) {
				print("  [\(found.count + 1)] \(endpoint)")
				found.append(endpoint)
			}
		} catch BoatCloudError.transport(let msg) {
			// Already a user-friendly message (e.g. missing Avahi on Linux).
			// Print it in red on stderr and exit cleanly so users see the
			// install instructions without a Swift stack trace.
			let red = fdIsTTY(2) ? "\u{1B}[31m" : ""
			let reset = fdIsTTY(2) ? "\u{1B}[0m" : ""
			FileHandle.standardError.write(Data("\(red)\(msg)\(reset)\n".utf8))
			throw ExitCode.failure
		}

		guard !found.isEmpty else {
			print("No marine server found on the LAN.")
			return
		}

		// Non-interactive: stop at the listing.
		let isTTY = fdIsTTY(0)
		if noInteractive || !isTTY {
			return
		}

		print("\nSelect > ", terminator: "")
		guard let line = readLine(),
			let choice = Int(line),
			choice >= 1, choice <= found.count
		else {
			print("Cancelled.")
			return
		}

		let endpoint = found[choice - 1]
		print("→ Connecting to \(endpoint.url)\n")

		// Dispatch via ConnectCommand.parse([...]) — direct struct instantiation
		// is not safe with ArgumentParser (@Option / @Flag backing stores must be
		// initialised by the parser, not by field assignment).
		// endpoint.url already encodes the right scheme (http/ws/tcp).
		let cmd = try ConnectCommand.parse(["--url", endpoint.url])
		try await cmd.run()
	}
}
