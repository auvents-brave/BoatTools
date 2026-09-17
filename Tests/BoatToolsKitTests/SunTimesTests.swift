import Foundation
import Testing

@testable import BoatToolsKit

// Reference times from astral 3.2, an independent implementation of the same
// NOAA algorithm, for places spread over both hemispheres and the date line.
// Astral takes the Sun's position at 0 h UTC rather than at the event, which
// the equation of time's drift turns into up to ~25 s — hence the tolerance.

private func instant(_ iso: String) -> Date {
	ISO8601DateFormatter().date(from: iso)!
}

private func expectClose(_ actual: Date?, _ iso: String, within seconds: TimeInterval = 30) {
	guard let actual else {
		Issue.record("expected \(iso), got nil")
		return
	}
	#expect(abs(actual.timeIntervalSince(instant(iso))) <= seconds, "\(actual) vs \(iso)")
}

private struct Case: Sendable, CustomTestStringConvertible {
	let place: String
	let latitude: Double
	let longitude: Double
	let zone: String
	let day: String
	let sunrise: String
	let noon: String
	let sunset: String

	var testDescription: String { "\(place) \(day)" }
}

private let cases: [Case] = [
	Case(
		place: "Monaco, summer", latitude: 43.7384, longitude: 7.4246, zone: "Europe/Paris",
		day: "2026-06-21T09:00:00+02:00", sunrise: "2026-06-21T05:48:45+02:00",
		noon: "2026-06-21T13:32:01+02:00", sunset: "2026-06-21T21:15:29+02:00"),
	Case(
		place: "Monaco, winter", latitude: 43.7384, longitude: 7.4246, zone: "Europe/Paris",
		day: "2026-12-21T23:30:00+01:00", sunrise: "2026-12-21T08:01:05+01:00",
		noon: "2026-12-21T12:28:07+01:00", sunset: "2026-12-21T16:55:37+01:00"),
	Case(
		place: "Auckland", latitude: -36.8485, longitude: 174.7633, zone: "Pacific/Auckland",
		day: "2026-03-20T01:00:00+13:00", sunrise: "2026-03-20T07:23:39+13:00",
		noon: "2026-03-20T13:28:31+13:00", sunset: "2026-03-20T19:32:47+13:00"),
	Case(
		place: "Honolulu", latitude: 21.3069, longitude: -157.8583, zone: "Pacific/Honolulu",
		day: "2026-09-17T20:00:00-10:00", sunrise: "2026-09-17T06:19:16-10:00",
		noon: "2026-09-17T12:26:07-10:00", sunset: "2026-09-17T18:32:00-10:00"),
	Case(
		place: "Quito", latitude: -0.1807, longitude: -78.4678, zone: "America/Guayaquil",
		day: "2026-01-01T12:00:00-05:00", sunrise: "2026-01-01T06:13:41-05:00",
		noon: "2026-01-01T12:17:12-05:00", sunset: "2026-01-01T18:21:23-05:00"),
]

@Test(arguments: cases)
private func `Sunrise, solar noon and sunset match the reference`(_ reference: Case) {
	let times = SunTimes(
		latitude: reference.latitude, longitude: reference.longitude, day: instant(reference.day),
		timeZone: TimeZone(identifier: reference.zone)!)

	#expect(times.polar == nil)
	expectClose(times.sunrise, reference.sunrise)
	expectClose(times.solarNoon, reference.noon)
	expectClose(times.sunset, reference.sunset)
}

@Test func `Twilight horizons give dawn and dusk`() {
	let day = instant("2026-06-21T12:00:00+02:00")
	let paris = TimeZone(identifier: "Europe/Paris")!
	let civil = SunTimes(latitude: 43.7384, longitude: 7.4246, day: day, timeZone: paris, horizon: .civil)
	let nautical = SunTimes(latitude: 43.7384, longitude: 7.4246, day: day, timeZone: paris, horizon: .nautical)

	expectClose(civil.sunrise, "2026-06-21T05:11:56+02:00")
	expectClose(civil.sunset, "2026-06-21T21:52:18+02:00")
	expectClose(nautical.sunrise, "2026-06-21T04:24:46+02:00")
	expectClose(nautical.sunset, "2026-06-21T22:39:28+02:00")
}

@Test func `Polar day and night have no sunrise nor sunset`() {
	let oslo = TimeZone(identifier: "Europe/Oslo")!
	let summer = SunTimes(
		latitude: 69.6492, longitude: 18.9553, day: instant("2026-06-21T12:00:00+02:00"), timeZone: oslo)
	let winter = SunTimes(
		latitude: 69.6492, longitude: 18.9553, day: instant("2026-12-21T12:00:00+01:00"), timeZone: oslo)

	#expect(summer.polar == .alwaysAbove)
	#expect(summer.sunrise == nil && summer.sunset == nil)
	expectClose(summer.solarNoon, "2026-06-21T12:45:53+02:00")
	#expect(winter.polar == .alwaysBelow)
	expectClose(winter.solarNoon, "2026-12-21T11:42:00+01:00")
}

@Test func `The events belong to the requested local day`() {
	// Just before local midnight in Auckland, the UTC date is still the day before.
	let auckland = TimeZone(identifier: "Pacific/Auckland")!
	let times = SunTimes(
		latitude: -36.8485, longitude: 174.7633, day: instant("2026-03-20T23:59:00+13:00"), timeZone: auckland)

	expectClose(times.solarNoon, "2026-03-20T13:28:31+13:00")
}

@Test func `The poles themselves do not produce invalid numbers`() {
	for latitude in [90.0, -90.0] {
		let times = SunTimes(latitude: latitude, longitude: 0, day: instant("2026-06-21T12:00:00Z"))
		#expect(times.polar != nil)
		#expect(times.solarNoon.timeIntervalSince1970.isFinite)
	}
}

@Test func `Upcoming events are the next of each kind, soonest first`() {
	// Monaco, 21 June at 15:00 local: noon has passed, so it comes tomorrow.
	let events = SunTimes.upcoming(latitude: 43.7384, longitude: 7.4246, after: instant("2026-06-21T15:00:00+02:00"))

	#expect(events.map(\.kind) == [.sunset, .sunrise, .solarNoon])
	expectClose(events[0].date, "2026-06-21T21:15:29+02:00")
	#expect(abs(events[1].date.timeIntervalSince(instant("2026-06-22T05:48:45+02:00"))) < 120)
	#expect(abs(events[2].date.timeIntervalSince(instant("2026-06-22T13:32:01+02:00"))) < 120)
}

@Test func `Upcoming events work across the date line`() {
	// Auckland just before local midnight: all three are the next day's.
	let now = instant("2026-03-20T23:30:00+13:00")
	let events = SunTimes.upcoming(latitude: -36.8485, longitude: 174.7633, after: now)

	#expect(events.map(\.kind) == [.sunrise, .solarNoon, .sunset])
	#expect(events.allSatisfy { $0.date > now && $0.date.timeIntervalSince(now) < 86400 })
}

@Test func `A polar day has only a solar noon ahead`() {
	let events = SunTimes.upcoming(latitude: 69.6492, longitude: 18.9553, after: instant("2026-06-21T12:00:00+02:00"))

	#expect(events.map(\.kind) == [.solarNoon])
}
