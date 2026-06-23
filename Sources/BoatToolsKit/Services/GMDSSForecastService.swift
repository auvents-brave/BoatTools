public import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

// MARK: - Models

/// A single GMDSS high-seas bulletin within a METAREA — one issuing service or
/// directional sub-area (e.g. METAREA 3's "WEST" by Météo-France and "EAST" by
/// the Hellenic service).
public struct GMDSSBulletin: Sendable, Identifiable {

	/// The sub-area label, e.g. `"WEST / HIGH SEAS FORECAST"`.
	public let label: String
	/// The bulletin body, line by line in document order.
	public let lines: [String]

	public var id: String { label }

	/// The body as plain text.
	public var text: String { lines.joined(separator: "\n") }

	/// The WMO abbreviated header on the first line (e.g. `"FQMQ54 LFPW 221754"`),
	/// when present: data type, originating station, day/time.
	public var header: String? { lines.first }
}

/// The GMDSS forecast bulletins for one METAREA (1…21).
public struct GMDSSForecast: Sendable {

	/// METAREA number, 1…21.
	public let metarea: Int
	/// Service title, e.g. `"Bulletinset for METAREA 3"`.
	public let title: String
	/// The set's server timestamp, e.g. `"2026-06-22 17:57:41"`.
	public let issued: String
	/// The bulletins, one per issuing service / directional sub-area.
	public let bulletins: [GMDSSBulletin]
}

/// An error from ``GMDSSForecastService``.
public enum GMDSSError: Error, Sendable {
	/// A METAREA outside 1…21.
	case invalidMetarea(Int)
	/// A position that falls in no known METAREA box.
	case noMetareaForPosition(latitude: Double, longitude: Double)
	/// A non-2xx HTTP status.
	case server(status: Int)
}

// MARK: - Service

/// Fetches official GMDSS high-seas forecasts from the WMO Worldwide Met-ocean
/// Information and Warning Service (WWMIWS) — the global aggregator of the
/// SafetyNET / NAVTEX text bulletins for all 21 METAREAs.
///
/// Two entry points:
/// - ``forecast(metarea:)`` returns every bulletin for a METAREA.
/// - ``forecast(latitude:longitude:)`` resolves the position to its METAREA and
///   keeps only the matching directional sub-bulletin.
///
/// The network transport is injectable (``Fetch``): the default uses `URLSession`,
/// but a caller can supply the portable BoatToolsKit transport where needed.
public struct GMDSSForecastService: Sendable {

	/// Fetches the bytes (and HTTP status) for a URL.
	public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

	private let fetch: Fetch

	/// Creates a service.
	/// - Parameter fetch: The transport; defaults to ``urlSessionFetch``.
	public init(fetch: @escaping Fetch = GMDSSForecastService.urlSessionFetch) {
		self.fetch = fetch
	}

	private static let endpoint = "https://wwmiws.wmo.int/index.php/metareas/bulletinset_download"

	// MARK: Option 1 — a whole METAREA

	/// Every bulletin for a METAREA.
	/// - Parameter metarea: The METAREA number, 1…21.
	/// - Returns: The full bulletin set.
	public func forecast(metarea: Int) async throws -> GMDSSForecast {
		guard (1...21).contains(metarea), let url = URL(string: "\(Self.endpoint)/\(metarea)/json") else {
			throw GMDSSError.invalidMetarea(metarea)
		}
		let (data, status) = try await fetch(url)
		guard (200..<300).contains(status) else { throw GMDSSError.server(status: status) }
		let raw = try JSONDecoder().decode(RawBulletinSet.self, from: data)
		return GMDSSForecast(
			metarea: metarea, title: raw.title, issued: raw.date,
			bulletins: raw.bulletin.map(\.modelValue))
	}

	// MARK: Option 2 — by position

	/// The bulletin(s) covering a position: resolves the METAREA, then keeps the
	/// sub-bulletin whose direction (WEST/EAST/NORTH/SOUTH in its label) matches
	/// the position, split at the METAREA's mid-point. Returns every bulletin when
	/// the METAREA is not split (or no direction can be inferred).
	/// - Parameters:
	///   - latitude: Decimal degrees, north positive.
	///   - longitude: Decimal degrees, east positive.
	public func forecast(latitude: Double, longitude: Double) async throws -> GMDSSForecast {
		guard let area = Self.metarea(latitude: latitude, longitude: longitude) else {
			throw GMDSSError.noMetareaForPosition(latitude: latitude, longitude: longitude)
		}
		let full = try await forecast(metarea: area.number)
		let picked = Self.bulletins(
			full.bulletins, coveringLatitude: latitude, longitude: longitude, in: area)
		return GMDSSForecast(
			metarea: full.metarea, title: full.title, issued: full.issued, bulletins: picked)
	}

	/// Keeps the directional bulletins covering a position; falls back to all of
	/// them when the METAREA carries no directional split.
	static func bulletins(
		_ bulletins: [GMDSSBulletin], coveringLatitude lat: Double, longitude lon: Double, in area: Metarea
	) -> [GMDSSBulletin] {
		guard bulletins.count > 1 else { return bulletins }
		let midLon = (area.minLon + area.maxLon) / 2
		let midLat = (area.minLat + area.maxLat) / 2
		func isDirectional(_ l: String) -> Bool {
			let u = l.uppercased()
			return u.contains("WEST") || u.contains("EAST") || u.contains("NORTH") || u.contains("SOUTH")
		}
		guard bulletins.contains(where: { isDirectional($0.label) }) else { return bulletins }
		// Prefer a known issuing-service boundary over the bounding-box centre.
		let splitLon = splitLongitude[area.number] ?? midLon
		func covers(_ label: String) -> Bool {
			let u = label.uppercased()
			if u.contains("WEST"), lon >= splitLon { return false }
			if u.contains("EAST"), lon < splitLon { return false }
			if u.contains("NORTH"), lat < midLat { return false }
			if u.contains("SOUTH"), lat >= midLat { return false }
			return true
		}
		let picked = bulletins.filter { covers($0.label) }
		return picked.isEmpty ? bulletins : picked
	}

	/// The WEST/EAST issuing-service boundary longitude per METAREA, where known.
	/// METAREA 3: Météo-France (west) hands over to the Hellenic service near 20°E.
	static let splitLongitude: [Int: Double] = [3: 20]

	// MARK: Position → METAREA

	/// A METAREA's number and approximate bounding box.
	public struct Metarea: Sendable {
		public let number: Int
		public let minLat, maxLat, minLon, maxLon: Double
		func contains(_ lat: Double, _ lon: Double) -> Bool {
			lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
		}
	}

	/// The METAREA whose box contains the position, or `nil`.
	public static func metarea(latitude: Double, longitude: Double) -> Metarea? {
		metareas.first { $0.contains(latitude, longitude) }
	}

	/// Approximate METAREA bounding boxes, enclosed/smaller seas first so a
	/// position resolves to the most specific area. The Atlantic / Mediterranean /
	/// European boxes are close to the official WMO limits; the Indian and Pacific
	/// ones are rough placeholders to refine with the official polygons.
	static let metareas: [Metarea] = [
		// The Mediterranean is diagonal — a single box would swallow the NW Atlantic
		// coast, so split it: the Alboran/Gibraltar entrance and the main basin.
		.init(number: 3, minLat: 35, maxLat: 37.8, minLon: -6, maxLon: 0),  // Alboran / Gibraltar
		.init(number: 3, minLat: 30, maxLat: 47.5, minLon: 0, maxLon: 42),  // main basin & Black Sea
		.init(number: 9, minLat: 0, maxLat: 30, minLon: 30, maxLon: 78),  // Red Sea / Gulf / Arabian Sea (approx)
		.init(number: 1, minLat: 48.45, maxLat: 90, minLon: -35, maxLon: 13),  // NE Atlantic, North & Baltic seas
		.init(number: 2, minLat: 6, maxLat: 48.45, minLon: -35, maxLon: 0),  // E North Atlantic
		.init(number: 4, minLat: 7, maxLat: 67, minLon: -100, maxLon: -35),  // W North Atlantic
		.init(number: 5, minLat: -35.83, maxLat: 7, minLon: -55, maxLon: -20),  // W South Atlantic
		.init(number: 6, minLat: -90, maxLat: -35.83, minLon: -67, maxLon: -20),  // SW Atlantic (+ Antarctic)
		.init(number: 7, minLat: -90, maxLat: -6, minLon: -20, maxLon: 20),  // SE Atlantic (approx)
		.init(number: 8, minLat: -90, maxLat: 30, minLon: 20, maxLon: 95),  // Indian Ocean (approx)
		.init(number: 10, minLat: -90, maxLat: 12, minLon: 95, maxLon: 170),  // Australia (approx)
		.init(number: 11, minLat: 0, maxLat: 45, minLon: 95, maxLon: 180),  // E Asia (approx)
		.init(number: 12, minLat: 3, maxLat: 67, minLon: -160, maxLon: -100),  // E North Pacific (approx)
		.init(number: 13, minLat: 40, maxLat: 90, minLon: 100, maxLon: 180),  // NW Pacific (approx)
		.init(number: 14, minLat: -90, maxLat: 25, minLon: 170, maxLon: 180),  // SW Pacific / NZ (approx)
		.init(number: 15, minLat: -90, maxLat: 18.35, minLon: -120, maxLon: -67),  // SE Pacific (approx)
		.init(number: 16, minLat: -60, maxLat: 18.35, minLon: -120, maxLon: -67),  // E Pacific / Peru (approx)
	]

	// MARK: Transport

	/// The default `URLSession`-based transport.
	public static let urlSessionFetch: Fetch = { url in
		let (data, response) = try await URLSession.shared.data(from: url)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 200
		return (data, status)
	}

	// MARK: Decoding

	private struct RawBulletinSet: Decodable {
		let title: String
		let date: String
		let bulletin: [RawBulletin]
	}

	private struct RawBulletin: Decodable {
		let label: String
		let content: [String: String]

		/// The bulletin with its numbered content lines restored to order.
		var modelValue: GMDSSBulletin {
			let lines = content.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map(\.value)
			return GMDSSBulletin(label: label, lines: lines)
		}
	}
}
