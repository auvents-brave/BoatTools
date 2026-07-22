import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for ``VesselPhotoService`` — the Wikidata → Commons vessel photo
/// lookup. The network transport is stubbed, so these never touch Wikimedia.
@Suite("Vessel photo")
struct VesselPhotoTests {

	/// A Wikidata SPARQL response naming a Commons file.
	private static func sparql(file: String, label: String? = "Emma Mærsk") -> String {
		let encoded =
			file.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.")))
			?? file
		let labelJSON = label.map { #""itemLabel": { "value": "\#($0)" },"# } ?? ""
		return """
			{"results":{"bindings":[{\(labelJSON)
			"image":{"type":"uri","value":"http://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)"}}]}}
			"""
	}

	/// A Commons imageinfo response, with the HTML fragments Commons really
	/// wraps attribution in.
	private static func commons(
		thumb: String? = "https://upload.wikimedia.org/thumb/Emma.jpg",
		url: String? = "https://upload.wikimedia.org/Emma.jpg",
		// Single-quoted attributes: still the HTML wrapper Commons sends, but
		// embeddable in a JSON fixture without escaping.
		artist: String? = "<a href='/wiki/User:Nico' title='x'>Nils Jepsen</a>",
		licence: String? = "CC BY-SA 2.5"
	) -> String {
		func field(_ name: String, _ value: String?) -> String {
			value.map { #""\#(name)": { "value": "\#($0)" },"# } ?? ""
		}
		let quoted = { (s: String?) in s.map { "\"\($0)\"" } ?? "null" }
		return """
			{"query":{"pages":{"42":{"imageinfo":[{
			"url": \(quoted(url)), "thumburl": \(quoted(thumb)),
			"descriptionurl": "https://commons.wikimedia.org/wiki/File:Emma.jpg",
			"extmetadata": { \(field("Artist", artist)) \(field("LicenseShortName", licence))
			"ObjectName": { "value": "Emma" } } }]}}}}
			"""
	}

	/// Serves canned bodies in call order, recording the URLs requested.
	private final class Stub: @unchecked Sendable {
		private let lock = NSLock()
		private var bodies: [String]
		private(set) var requested: [URL] = []
		var status = 200

		init(_ bodies: [String]) { self.bodies = bodies }

		var fetch: VesselPhotoService.Fetch {
			{ url in
				self.lock.withLock {
					self.requested.append(url)
					let body = self.bodies.isEmpty ? "{}" : self.bodies.removeFirst()
					return (Data(body.utf8), self.status)
				}
			}
		}
	}

	@Test func `a pictured vessel resolves to a credited photo`() async throws {
		let stub = Stub([Self.sparql(file: "Emma Mærsk2.jpg"), Self.commons()])
		let service = VesselPhotoService(fetch: stub.fetch)

		let photo = try #require(await service.photo(imo: 9_321_483, width: 480))
		#expect(photo.imageURL.absoluteString == "https://upload.wikimedia.org/thumb/Emma.jpg")
		#expect(photo.descriptionURL.absoluteString == "https://commons.wikimedia.org/wiki/File:Emma.jpg")
		#expect(photo.vesselName == "Emma Mærsk")
		// The HTML wrapper Commons uses is stripped for display.
		#expect(photo.author == "Nils Jepsen")
		#expect(photo.licence == "CC BY-SA 2.5")
		#expect(photo.credit == "Nils Jepsen · CC BY-SA 2.5")

		// The IMO reaches Wikidata, and the file name — accents and all —
		// reaches Commons.
		#expect(stub.requested.count == 2)
		#expect(stub.requested[0].absoluteString.contains("9321483"))
		#expect(stub.requested[0].host == "query.wikidata.org")
		#expect(stub.requested[1].host == "commons.wikimedia.org")
		#expect(stub.requested[1].absoluteString.contains("iiurlwidth=480"))
		let commonsQuery = try #require(stub.requested[1].query?.removingPercentEncoding)
		#expect(commonsQuery.contains("File:Emma Mærsk2.jpg"))
	}

	@Test func `a vessel Wikidata does not picture yields nothing`() async {
		let stub = Stub([#"{"results":{"bindings":[]}}"#])
		let service = VesselPhotoService(fetch: stub.fetch)
		#expect(await service.photo(imo: 1_234_567) == nil)
		// Commons is never asked when Wikidata has no image.
		#expect(stub.requested.count == 1)
	}

	@Test func `both hits and misses are cached`() async {
		let hit = Stub([Self.sparql(file: "Emma.jpg"), Self.commons()])
		let service = VesselPhotoService(fetch: hit.fetch)
		#expect(await service.photo(imo: 9_321_483) != nil)
		#expect(await service.photo(imo: 9_321_483) != nil)
		#expect(hit.requested.count == 2)  // not four — the second call is cached

		// A miss must not be retried either: most vessels have no photo, and
		// re-asking on every selection would hammer Wikimedia.
		let miss = Stub([#"{"results":{"bindings":[]}}"#])
		let service2 = VesselPhotoService(fetch: miss.fetch)
		#expect(await service2.photo(imo: 42) == nil)
		#expect(await service2.photo(imo: 42) == nil)
		#expect(miss.requested.count == 1)
	}

	@Test func `an unusable lookup fails quietly`() async {
		// A server error, a malformed body and an absent IMO are all misses,
		// never thrown errors — a photo is decoration, not data.
		let failing = Stub([Self.sparql(file: "Emma.jpg")])
		failing.status = 503
		#expect(await VesselPhotoService(fetch: failing.fetch).photo(imo: 9_321_483) == nil)

		let garbled = Stub(["<html>not json</html>"])
		#expect(await VesselPhotoService(fetch: garbled.fetch).photo(imo: 9_321_483) == nil)

		let unused = Stub([Self.sparql(file: "Emma.jpg")])
		#expect(await VesselPhotoService(fetch: unused.fetch).photo(imo: 0) == nil)
		#expect(unused.requested.isEmpty)  // a zero IMO never reaches the network
	}

	@Test func `an unscalable file falls back to the original`() async throws {
		// Commons omits `thumburl` for files it cannot scale.
		let stub = Stub([Self.sparql(file: "Emma.svg"), Self.commons(thumb: nil)])
		let photo = try #require(await VesselPhotoService(fetch: stub.fetch).photo(imo: 9_321_483))
		#expect(photo.imageURL.absoluteString == "https://upload.wikimedia.org/Emma.jpg")
	}

	@Test func `an uncredited photo reports no credit line`() async throws {
		let stub = Stub([Self.sparql(file: "Emma.jpg"), Self.commons(artist: nil, licence: nil)])
		let photo = try #require(await VesselPhotoService(fetch: stub.fetch).photo(imo: 9_321_483))
		#expect(photo.author == nil)
		#expect(photo.licence == nil)
		#expect(photo.credit == nil)
	}
}
