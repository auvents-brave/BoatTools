import Foundation
import Testing

@testable import BoatToolsKit

/// A METAREA-3-shaped bulletin set (West = Météo-France, East = Hellenic), as the
/// WMO WWMIWS endpoint returns it, for offline decoding tests.
private let sampleJSON = """
	{
	  "title": "Bulletinset for METAREA 3",
	  "date": "2026-06-22 17:57:41",
	  "bulletin": [
	    {
	      "label": "WEST / HIGH SEAS FORECAST",
	      "content": { "1": "FQMQ54 LFPW 221754", "2": "Weather bulletin on METAREA 3", "3": "METEO-FRANCE Toulouse" }
	    },
	    {
	      "label": "EAST / HIGH SEAS FORECAST",
	      "content": { "1": "FQME26 LGAT 221400", "2": "WEATHER BULLETIN ON METAREA 3", "3": "HELLENIC NATIONAL MET. SERVICE" }
	    }
	  ]
	}
	""".data(using: .utf8)!

private func service() -> GMDSSForecastService {
	GMDSSForecastService { _ in (sampleJSON, 200) }
}

@Test func decodesBulletinSet() async throws {
	let forecast = try await service().forecast(metarea: 3)
	#expect(forecast.metarea == 3)
	#expect(forecast.title == "Bulletinset for METAREA 3")
	#expect(forecast.bulletins.count == 2)
	let west = forecast.bulletins.first { $0.label.hasPrefix("WEST") }
	#expect(west?.lines.count == 3)
	#expect(west?.header == "FQMQ54 LFPW 221754")  // ordered by numeric key
	#expect(west?.text.contains("METEO-FRANCE") == true)
}

@Test func rejectsOutOfRangeMetarea() async {
	await #expect(throws: GMDSSError.self) { try await service().forecast(metarea: 99) }
}

@Test func resolvesPositionToMetarea() {
	// Off Sicily (Mediterranean) → METAREA 3.
	#expect(GMDSSForecastService.metarea(latitude: 37.1, longitude: 14.1)?.number == 3)
	// Bay of Biscay → METAREA 2.
	#expect(GMDSSForecastService.metarea(latitude: 45.5, longitude: -5.0)?.number == 2)
	// Mid–North Sea → METAREA 1.
	#expect(GMDSSForecastService.metarea(latitude: 56.0, longitude: 3.0)?.number == 1)
}

@Test func picksDirectionalSubBulletinByPosition() async throws {
	let area = try #require(GMDSSForecastService.metarea(latitude: 37.1, longitude: 14.1))
	let full = try await service().forecast(metarea: 3)
	// Western Med (Sicily) → the WEST (Météo-France) bulletin only.
	let west = GMDSSForecastService.bulletins(
		full.bulletins, coveringLatitude: 37.1, longitude: 14.1, in: area)
	#expect(west.count == 1)
	#expect(west.first?.label.hasPrefix("WEST") == true)
	// Aegean → the EAST (Hellenic) bulletin only.
	let east = GMDSSForecastService.bulletins(
		full.bulletins, coveringLatitude: 37.0, longitude: 25.0, in: area)
	#expect(east.first?.label.hasPrefix("EAST") == true)
}
