// Sunrise, solar noon and sunset for the C ABI — BoatToolsKit's offline
// `SunTimes`, so every host shows the same minutes as the Swift app.

internal import BoatToolsKit
internal import Foundation

/// What `boattools_bridge_sun_times` returns. Absent events are omitted.
struct SunTimesPayload: Encodable {
	let noon: Double
	let sunrise: Double?
	let sunset: Double?
	let polar: String?
}

/// Sunrise, solar noon and sunset of one local day. Instant — no network.
/// - Parameters:
///   - latitude: Degrees, north positive.
///   - longitude: Degrees, east positive.
///   - unixSeconds: Any instant of the wanted day.
///   - utcOffsetSeconds: The local offset on that day, which fixes where the
///     day starts and ends.
///   - horizon: 0 sunrise/sunset, 1 civil, 2 nautical, 3 astronomical twilight;
///     anything else is taken as 0.
/// - Returns: JSON `{"noon","sunrise","sunset","polar"}` — times in Unix
///   seconds, `polar` `"above"` or `"below"` when the Sun neither rises nor
///   sets — to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_sun_times")
public func boattools_bridge_sun_times(
	_ latitude: Double, _ longitude: Double, _ unixSeconds: Double,
	_ utcOffsetSeconds: Int32, _ horizon: Int32
) -> UnsafeMutablePointer<CChar>? {
	let horizons: [SunTimes.Horizon] = [.official, .civil, .nautical, .astronomical]
	let times = SunTimes(
		latitude: latitude, longitude: longitude,
		day: Date(timeIntervalSince1970: unixSeconds),
		timeZone: TimeZone(secondsFromGMT: Int(utcOffsetSeconds)) ?? TimeZone(secondsFromGMT: 0)!,
		horizon: horizons.indices.contains(Int(horizon)) ? horizons[Int(horizon)] : .official)
	let payload = SunTimesPayload(
		noon: times.solarNoon.timeIntervalSince1970,
		sunrise: times.sunrise?.timeIntervalSince1970,
		sunset: times.sunset?.timeIntervalSince1970,
		polar: times.polar.map { $0 == .alwaysAbove ? "above" : "below" })
	guard let data = try? JSONEncoder().encode(payload) else { return cString("{}") }
	return cString(String(decoding: data, as: UTF8.self))
}
