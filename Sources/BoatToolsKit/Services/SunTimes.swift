public import Foundation

/// Sunrise, solar noon and sunset for one day at one place, computed offline.
///
/// The NOAA solar calculator's algorithm (after Meeus): accurate to about a
/// minute between latitudes ±72°, less so nearer the poles where the Sun
/// grazes the horizon. Refraction is the standard 34′ and the Sun's radius
/// 16′, both folded into ``Horizon/official``; the observer's height is ignored.
public struct SunTimes: Sendable, Equatable {
	/// The Sun altitude that defines the events.
	public enum Horizon: Sendable, Equatable, CaseIterable {
		/// The upper limb on the horizon: sunrise and sunset proper.
		case official
		/// Centre 6° below: civil dawn and dusk.
		case civil
		/// Centre 12° below: nautical dawn and dusk.
		case nautical
		/// Centre 18° below: astronomical dawn and dusk.
		case astronomical

		/// The zenith distance of the Sun's centre at the event, in degrees.
		var zenith: Double {
			switch self {
			case .official: 90.833
			case .civil: 96
			case .nautical: 102
			case .astronomical: 108
			}
		}
	}

	/// Why a day has no ``sunrise`` or ``sunset``.
	public enum Polar: Sendable, Equatable {
		/// The Sun stays above the horizon all day.
		case alwaysAbove
		/// The Sun stays below the horizon all day.
		case alwaysBelow
	}

	/// The Sun's highest point of the day.
	public let solarNoon: Date
	/// The Sun crossing the horizon upwards — dawn for a twilight ``Horizon`` —
	/// or `nil` when it does not that day.
	public let sunrise: Date?
	/// The Sun crossing the horizon downwards — dusk for a twilight ``Horizon`` —
	/// or `nil` when it does not that day.
	public let sunset: Date?
	/// Set when the Sun neither rises nor sets that day.
	public let polar: Polar?

	/// Computes the events of the calendar day containing `day`.
	/// - Parameters:
	///   - latitude: Degrees, north positive.
	///   - longitude: Degrees, east positive.
	///   - day: Any instant of the wanted day.
	///   - timeZone: The time zone whose calendar day is meant; the events are
	///     those around that day's local noon.
	///   - horizon: The altitude defining rise and set.
	public init(
		latitude: Double, longitude: Double, day: Date,
		timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!, horizon: Horizon = .official
	) {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = timeZone
		let localNoon = calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
		let latitude = min(max(latitude, -89.9999), 89.9999)

		let noon = Self.solarNoon(near: localNoon, longitude: longitude)
		solarNoon = noon

		let atNoon = Self.cosineHourAngle(at: noon, latitude: latitude, zenith: horizon.zenith)
		if atNoon > 1 || atNoon < -1 {
			// Deciding at noon keeps one answer for the whole day, even where the
			// declination drifts across the threshold between morning and evening.
			polar = atNoon > 1 ? .alwaysBelow : .alwaysAbove
			sunrise = nil
			sunset = nil
			return
		}
		polar = nil
		sunrise = Self.event(-1, noon: noon, latitude: latitude, longitude: longitude, zenith: horizon.zenith)
		sunset = Self.event(1, noon: noon, latitude: latitude, longitude: longitude, zenith: horizon.zenith)
	}

	// MARK: Algorithm

	/// The solar noon closest to `instant`, refined once for the equation of time.
	private static func solarNoon(near instant: Date, longitude: Double) -> Date {
		let seconds = instant.timeIntervalSince1970
		let midnight = (seconds / 86400).rounded(.down) * 86400
		var noon = midnight + (720 - 4 * longitude - equationOfTime(at: seconds)) * 60
		while noon - seconds > 43200 { noon -= 86400 }
		while seconds - noon > 43200 { noon += 86400 }
		noon += (equationOfTime(at: seconds) - equationOfTime(at: noon)) * 60
		return Date(timeIntervalSince1970: noon)
	}

	/// Sunrise (`side` −1) or sunset (+1), recomputing the Sun's position at the
	/// event itself twice so the result converges within seconds.
	private static func event(_ side: Double, noon: Date, latitude: Double, longitude: Double, zenith: Double) -> Date?
	{
		let noonSeconds = noon.timeIntervalSince1970
		var estimate = noonSeconds
		for _ in 0..<3 {
			let cosine = cosineHourAngle(at: Date(timeIntervalSince1970: estimate), latitude: latitude, zenith: zenith)
			guard cosine >= -1, cosine <= 1 else { return nil }
			let hourAngle = acos(cosine) * 180 / .pi
			let shiftedNoon = noonSeconds + (equationOfTime(at: noonSeconds) - equationOfTime(at: estimate)) * 60
			estimate = shiftedNoon + side * 4 * hourAngle * 60
		}
		return Date(timeIntervalSince1970: estimate)
	}

	/// The cosine of the hour angle at which the Sun's centre reaches `zenith`;
	/// outside −1…1 when it never does.
	private static func cosineHourAngle(at date: Date, latitude: Double, zenith: Double) -> Double {
		let declination = position(at: date.timeIntervalSince1970).declination
		let phi = latitude * .pi / 180
		return cos(zenith * .pi / 180) / (cos(phi) * cos(declination)) - tan(phi) * tan(declination)
	}

	private static func equationOfTime(at seconds: TimeInterval) -> Double {
		position(at: seconds).equationOfTime
	}

	/// The Sun's declination (radians) and the equation of time (minutes).
	private static func position(at seconds: TimeInterval) -> (declination: Double, equationOfTime: Double) {
		let radians = Double.pi / 180
		let julianDay = seconds / 86400 + 2_440_587.5
		let t = (julianDay - 2_451_545) / 36525

		let meanLongitude = (280.46646 + t * (36000.76983 + 0.0003032 * t)).truncatingRemainder(dividingBy: 360)
		let meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
		let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
		let m = meanAnomaly * radians
		let centre =
			sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
			+ sin(2 * m) * (0.019993 - 0.000101 * t)
			+ sin(3 * m) * 0.000289
		let omega = (125.04 - 1934.136 * t) * radians
		let apparentLongitude = (meanLongitude + centre - 0.00569 - 0.00478 * sin(omega)) * radians
		let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
		let obliquity = (meanObliquity + 0.00256 * cos(omega)) * radians

		let declination = asin(sin(obliquity) * sin(apparentLongitude))
		let y = pow(tan(obliquity / 2), 2)
		let l0 = meanLongitude * radians
		let equation =
			y * sin(2 * l0) - 2 * eccentricity * sin(m)
			+ 4 * eccentricity * y * sin(m) * cos(2 * l0)
			- 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m)
		return (declination, 4 * equation / radians)
	}
}

/// One of the Sun's daily events, at the time it happens.
public struct SunEvent: Sendable, Equatable {
	/// Which event.
	public enum Kind: String, Sendable, CaseIterable {
		/// The upper limb clearing the horizon.
		case sunrise
		/// The Sun at its highest.
		case solarNoon
		/// The upper limb dropping below the horizon.
		case sunset
	}

	/// Which event this is.
	public let kind: Kind
	/// When it happens.
	public let date: Date

	/// Creates an event.
	public init(kind: Kind, date: Date) {
		self.kind = kind
		self.date = date
	}
}

extension SunTimes {
	/// The next sunrise, solar noon and sunset after `date`, soonest first —
	/// what a sailor looks ahead to. An event the Sun does not make within
	/// two days (a polar day or night) is left out.
	/// - Parameters:
	///   - latitude: Degrees, north positive.
	///   - longitude: Degrees, east positive.
	///   - date: The moment to look ahead from, usually now.
	/// - Returns: Up to three events, one of each kind, in chronological order.
	public static func upcoming(latitude: Double, longitude: Double, after date: Date) -> [SunEvent] {
		// UTC days either side cover every longitude: a day's events all fall
		// within twelve hours of its solar noon.
		let candidates = (-1...2).flatMap { offset -> [SunEvent] in
			let times = SunTimes(
				latitude: latitude, longitude: longitude, day: date.addingTimeInterval(Double(offset) * 86400))
			return [
				times.sunrise.map { SunEvent(kind: .sunrise, date: $0) },
				SunEvent(kind: .solarNoon, date: times.solarNoon),
				times.sunset.map { SunEvent(kind: .sunset, date: $0) },
			].compactMap(\.self)
		}
		return SunEvent.Kind.allCases
			.compactMap { kind in
				candidates.filter { $0.kind == kind && $0.date > date }.min { $0.date < $1.date }
			}
			.sorted { $0.date < $1.date }
	}
}
