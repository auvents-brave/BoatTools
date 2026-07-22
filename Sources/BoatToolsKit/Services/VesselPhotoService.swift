public import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

// MARK: - Model

/// A freely-licensed photograph of a vessel, from Wikimedia Commons.
///
/// Commons images carry Creative Commons (or public-domain) licences, and the
/// CC ones **require attribution** — so ``author`` and ``licence`` are part of
/// the model and must be shown wherever ``imageURL`` is displayed, alongside a
/// link to ``descriptionURL`` (the file's Commons page, which carries the full
/// licence text).
public struct VesselPhoto: Sendable, Equatable {

	/// The photograph, already scaled to the requested width.
	public let imageURL: URL
	/// The image's page on Commons — the canonical source, and where the full
	/// licence terms live.
	public let descriptionURL: URL
	/// The vessel's name as Wikidata knows it (may differ from the AIS name).
	public let vesselName: String?
	/// The photographer, as credited on Commons. Display this.
	public let author: String?
	/// The licence's short name, e.g. `"CC BY-SA 4.0"`. Display this.
	public let licence: String?

	/// Creates a photo record.
	public init(
		imageURL: URL, descriptionURL: URL, vesselName: String? = nil,
		author: String? = nil, licence: String? = nil
	) {
		self.imageURL = imageURL
		self.descriptionURL = descriptionURL
		self.vesselName = vesselName
		self.author = author
		self.licence = licence
	}

	/// A one-line credit ready to render, e.g. `"Nils Jepsen · CC BY-SA 2.5"`.
	/// `nil` when Commons credited neither an author nor a licence.
	public var credit: String? {
		let parts = [author, licence].compactMap { $0 }.filter { $0.isEmpty == false }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}

// MARK: - Service

/// Looks up a freely-licensed vessel photograph by IMO number.
///
/// Two public Wikimedia APIs, in order:
/// 1. **Wikidata** — the ship item carrying that IMO number (property `P458`)
///    and its image (`P18`).
/// 2. **Commons** — that file's thumbnail at the requested width, plus the
///    photographer and licence needed to credit it.
///
/// Only vessels notable enough to be catalogued in Wikidata *and* pictured on
/// Commons return a photo: large merchant and passenger ships often, pleasure
/// craft essentially never. A miss is not an error — ``photo(imo:width:)``
/// simply returns `nil`.
///
/// Results are cached in memory for the process's lifetime (hits *and* misses),
/// so revisiting a target costs nothing and Wikimedia is not polled repeatedly
/// for the same ship.
///
/// The network transport is injectable (``Fetch``), mirroring
/// ``GMDSSForecastService``: the default uses `URLSession`.
public struct VesselPhotoService: Sendable {

	/// Fetches the bytes (and HTTP status) for a URL.
	public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

	private let fetch: Fetch
	private let cache: PhotoCache

	/// Creates a service.
	/// - Parameters:
	///   - fetch: The transport; defaults to ``urlSessionFetch``.
	///   - cache: The lookup cache. Defaults to a fresh one; pass ``shared``'s
	///     to share results across service instances.
	public init(
		fetch: @escaping Fetch = VesselPhotoService.urlSessionFetch,
		cache: PhotoCache = PhotoCache()
	) {
		self.fetch = fetch
		self.cache = cache
	}

	/// Remembers lookups — including misses, which are the common case and
	/// would otherwise be retried on every glance at the same vessel.
	public final class PhotoCache: @unchecked Sendable {
		// @unchecked: the dictionary is only ever touched under `lock`.
		private let lock = NSLock()
		private var entries: [Int: VesselPhoto?] = [:]

		public init() {}

		func value(for imo: Int) -> VesselPhoto?? {
			lock.withLock { entries[imo] }
		}

		func store(_ photo: VesselPhoto?, for imo: Int) {
			lock.withLock { entries[imo] = photo }
		}

		/// Forgets every lookup.
		public func removeAll() {
			lock.withLock { entries.removeAll() }
		}
	}

	/// The photograph for a vessel, or `nil` when Wikimedia has none.
	///
	/// - Parameters:
	///   - imo: The vessel's IMO number, as broadcast in AIS type 5 static data.
	///   - width: The desired image width in pixels. Commons scales server-side.
	/// - Returns: The photo with its attribution, or `nil` when the vessel is
	///   not in Wikidata, has no picture, or the lookup failed.
	public func photo(imo: Int, width: Int = 640) async -> VesselPhoto? {
		guard imo > 0 else { return nil }
		if let cached = cache.value(for: imo) { return cached }
		let found = try? await lookup(imo: imo, width: width)
		// Cache the miss too — most vessels have no photo, and asking again
		// on every selection would hammer Wikimedia for nothing.
		cache.store(found ?? nil, for: imo)
		return found ?? nil
	}

	// MARK: Lookup

	private func lookup(imo: Int, width: Int) async throws -> VesselPhoto? {
		guard let (fileName, vesselName) = try await wikidataImage(imo: imo) else { return nil }
		return try await commonsPhoto(fileName: fileName, vesselName: vesselName, width: width)
	}

	/// The Commons file name of the image (`P18`) on the Wikidata item whose
	/// IMO number (`P458`) matches, plus that item's English label.
	private func wikidataImage(imo: Int) async throws -> (fileName: String, vesselName: String?)? {
		let query = """
			SELECT ?itemLabel ?image WHERE { \
			?item wdt:P458 "\(imo)". ?item wdt:P18 ?image. \
			SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } } LIMIT 1
			"""
		guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
			let url = URL(string: "https://query.wikidata.org/sparql?format=json&query=\(encoded)")
		else { return nil }
		let (data, status) = try await fetch(url)
		guard (200..<300).contains(status) else { return nil }
		let results = try JSONDecoder().decode(SPARQLResults.self, from: data)
		guard let binding = results.results.bindings.first,
			// The image value is a Special:FilePath URL whose last component is
			// the percent-encoded file name.
			let fileName = binding.image?.value.split(separator: "/").last
				.map(String.init)?.removingPercentEncoding
		else { return nil }
		return (fileName, binding.itemLabel?.value)
	}

	/// The thumbnail and attribution for a Commons file.
	private func commonsPhoto(fileName: String, vesselName: String?, width: Int) async throws
		-> VesselPhoto?
	{
		guard
			let title = "File:\(fileName)".addingPercentEncoding(
				withAllowedCharacters: .urlQueryValueAllowed),
			let url = URL(
				string: "https://commons.wikimedia.org/w/api.php?action=query&format=json"
					+ "&prop=imageinfo&iiprop=url%7Cextmetadata&iiurlwidth=\(max(1, width))&titles=\(title)")
		else { return nil }
		let (data, status) = try await fetch(url)
		guard (200..<300).contains(status) else { return nil }
		let response = try JSONDecoder().decode(CommonsResponse.self, from: data)
		guard let info = response.query?.pages.values.compactMap(\.imageinfo?.first).first,
			// `thumburl` is absent for files Commons cannot scale (e.g. some
			// SVGs); fall back to the original.
			let image = URL(string: info.thumburl ?? info.url ?? ""),
			let page = URL(string: info.descriptionurl ?? "")
		else { return nil }
		let meta = info.extmetadata
		return VesselPhoto(
			imageURL: image,
			descriptionURL: page,
			vesselName: vesselName,
			author: meta?.Artist?.value.strippingHTML,
			licence: meta?.LicenseShortName?.value.strippingHTML
		)
	}

	// MARK: Default transport

	/// The default `URLSession` transport. Wikimedia asks API clients to send a
	/// descriptive User-Agent identifying the application.
	public static let urlSessionFetch: Fetch = { url in
		var request = URLRequest(url: url)
		request.setValue(
			"BoatToolsKit/1.0 (https://github.com/auvents-brave/BoatTools) Swift-URLSession",
			forHTTPHeaderField: "User-Agent")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
	}

	// MARK: Wire formats

	private struct SPARQLResults: Decodable {
		struct Results: Decodable { let bindings: [Binding] }
		struct Binding: Decodable {
			let image: Value?
			let itemLabel: Value?
		}
		struct Value: Decodable { let value: String }
		let results: Results
	}

	private struct CommonsResponse: Decodable {
		struct Query: Decodable { let pages: [String: Page] }
		struct Page: Decodable { let imageinfo: [ImageInfo]? }
		struct ImageInfo: Decodable {
			let url: String?
			let thumburl: String?
			let descriptionurl: String?
			let extmetadata: ExtMetadata?
		}
		// Commons' field names, kept verbatim so the JSON maps without a
		// CodingKeys table.
		// swift-format-ignore
		struct ExtMetadata: Decodable {
			let Artist: Value?
			let LicenseShortName: Value?
		}
		struct Value: Decodable { let value: String }
		let query: Query?
	}
}

// MARK: - Helpers

extension String {
	/// Commons returns attribution as small HTML fragments (links, spans).
	/// Reduce them to the plain text a label can show.
	fileprivate var strippingHTML: String? {
		let text = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
			.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#039;", with: "'")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}
}

extension CharacterSet {
	/// Query-value safe: the standard query set minus the sub-delimiters that
	/// would otherwise be taken as separators (`&`, `+`, `=`…).
	fileprivate static let urlQueryValueAllowed: CharacterSet = {
		var set = CharacterSet.urlQueryAllowed
		set.remove(charactersIn: "&+=?#")
		return set
	}()
}
