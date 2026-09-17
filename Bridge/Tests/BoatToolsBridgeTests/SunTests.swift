import Foundation
import Testing

@testable import BoatToolsBridge

@Suite("Bridge sun times")
struct SunTests {
	private struct Decoded: Decodable {
		let noon: Double
		let sunrise: Double?
		let sunset: Double?
		let polar: String?
	}

	private func call(_ latitude: Double, _ longitude: Double, _ iso: String, offset: Int32, horizon: Int32 = 0)
		throws -> Decoded
	{
		let instant = try #require(ISO8601DateFormatter().date(from: iso)).timeIntervalSince1970
		let pointer = try #require(boattools_bridge_sun_times(latitude, longitude, instant, offset, horizon))
		defer { boattools_bridge_string_free(pointer) }
		return try JSONDecoder().decode(Decoded.self, from: Data(String(cString: pointer).utf8))
	}

	@Test("The local day comes from the offset, the times are Unix seconds")
	func monacoSummer() throws {
		let times = try call(43.7384, 7.4246, "2026-06-21T09:00:00+02:00", offset: 7200)
		let sunrise = try #require(ISO8601DateFormatter().date(from: "2026-06-21T03:48:45Z")).timeIntervalSince1970
		#expect(abs(try #require(times.sunrise) - sunrise) < 30)
		#expect(times.polar == nil)
	}

	@Test("Polar days report the side and omit the events")
	func midnightSun() throws {
		let times = try call(69.6492, 18.9553, "2026-06-21T12:00:00+02:00", offset: 7200)
		#expect(times.polar == "above")
		#expect(times.sunrise == nil && times.sunset == nil)
	}

	@Test("Twilight horizons move the events; an unknown one falls back to sunrise")
	func horizons() throws {
		let official = try call(43.7384, 7.4246, "2026-06-21T12:00:00+02:00", offset: 7200)
		let nautical = try call(43.7384, 7.4246, "2026-06-21T12:00:00+02:00", offset: 7200, horizon: 2)
		let unknown = try call(43.7384, 7.4246, "2026-06-21T12:00:00+02:00", offset: 7200, horizon: 9)
		#expect(try #require(nautical.sunrise) < (try #require(official.sunrise)) - 3000)
		#expect(unknown.sunrise == official.sunrise)
	}

	@Test("Upcoming events come soonest first, one of each kind")
	func upcoming() throws {
		struct Event: Decodable {
			let kind: String
			let time: Double
		}
		let now = try #require(ISO8601DateFormatter().date(from: "2026-06-21T13:00:00Z")).timeIntervalSince1970
		let pointer = try #require(boattools_bridge_sun_upcoming(43.7384, 7.4246, now))
		defer { boattools_bridge_string_free(pointer) }
		let events = try JSONDecoder().decode([Event].self, from: Data(String(cString: pointer).utf8))

		#expect(events.map(\.kind) == ["sunset", "sunrise", "solarNoon"])
		#expect(events.allSatisfy { $0.time > now })
	}
}
