public import Foundation

/// The astronomical angles a harmonic tidal prediction rests on, for one instant.
///
/// The five fundamental longitudes come from Meeus' polynomials in Julian
/// centuries from J2000. The auxiliary angles — the inclination of the Moon's
/// orbit to the equator and Schureman's ξ, ν, ν′ and ν″ — follow Schureman
/// (1958) and serve only the nodal corrections.
///
/// The instant is read as UT1, for which UTC serves: the two never differ by
/// more than a second, and a second moves the fastest of these angles by four
/// thousandths of a degree.
///
/// Working these out is the costly half of a prediction and none of it depends
/// on position, so a caller drawing a field of arrows computes this once and
/// hands it to ``TidalStreamAtlas/stream(latitude:longitude:astronomy:)`` for
/// every point of the field.
public struct TidalAstronomy: Sendable, Equatable {

	/// 2000-01-01 12:00 UT, the epoch the polynomials below are referred to.
	static let epoch = Date(timeIntervalSince1970: 946_728_000)

	/// Obliquity of the ecliptic at the epoch, in degrees.
	static let meanObliquity = 23.439_291_1
	/// Inclination of the Moon's orbit to the ecliptic, in degrees. Held
	/// constant: it varies by a few hundredths of a degree.
	static let lunarInclination = 5.145

	/// How fast each fundamental longitude turns, in degrees per hour. The
	/// published speed of every constituent is a sum of these.
	enum Rate {
		/// Mean longitude of the Moon.
		static let moon = 481_267.881_342_36 / (36_525 * 24)
		/// Mean longitude of the Sun.
		static let sun = 36_000.769_83 / (36_525 * 24)
		/// Mean longitude of the lunar perigee.
		static let lunarPerigee = 4_069.013_711_1 / (36_525 * 24)
		/// Mean longitude of the solar perigee.
		static let solarPerigee = 1.719_02 / (36_525 * 24)
		/// Mean lunar time: the mean Sun's 15° an hour, carried to the Moon.
		static let lunarTime = 15.0 + sun - moon
	}

	/// Mean lunar time at Greenwich, in degrees: the hour angle of the mean Moon.
	public let lunarTime: Double
	/// Mean longitude of the Moon, in degrees.
	public let moon: Double
	/// Mean longitude of the Sun, in degrees.
	public let sun: Double
	/// Mean longitude of the lunar perigee, in degrees.
	public let lunarPerigee: Double
	/// Mean longitude of the solar perigee, in degrees.
	public let solarPerigee: Double
	/// Mean longitude of the Moon's ascending node, in degrees. It comes round
	/// in 18.6 years, and every nodal correction follows it.
	public let node: Double
	/// Inclination of the Moon's orbit to the equator, in degrees: between
	/// about 18.3° and 28.6° over the nodal cycle.
	public let inclination: Double

	/// Schureman's ξ, in degrees: the ascending intersection of orbit and
	/// equator, measured in the orbit from the node.
	let xi: Double
	/// Schureman's ν, in degrees: the right ascension of that intersection.
	let nu: Double
	/// Schureman's ν′, the correction K₁ alone needs.
	let nuPrime: Double
	/// Schureman's ν″ — stored as itself, not as the 2ν″ that K₂ uses.
	let nuDoublePrime: Double
	/// The lunar perigee measured in the orbit from the ascending
	/// intersection, which L₂ needs.
	let perigeeInOrbit: Double

	/// Works the angles out for one instant.
	/// - Parameter date: The instant, read as UT1.
	public init(date: Date) {
		let t = date.timeIntervalSince(Self.epoch) / (86_400 * 36_525)
		let normalise = DerivedNavigation.normalise

		moon = normalise(218.316_459_1 + 481_267.881_342_36 * t - 0.001_326_8 * t * t)
		sun = normalise(280.466_45 + 36_000.769_83 * t + 0.000_303_2 * t * t)
		lunarPerigee = normalise(83.353_243_0 + 4_069.013_711_1 * t - 0.010_323_8 * t * t)
		solarPerigee = normalise(282.937_35 + 1.719_02 * t + 0.000_459_1 * t * t)
		node = normalise(125.044_555_0 - 1_934.136_184_9 * t + 0.002_076_2 * t * t)

		// The hour angle of the mean Sun: zero at Greenwich mean noon, which is
		// the reference every equilibrium argument below is written against.
		let days = date.timeIntervalSince1970 / 86_400
		let intoDay = (days - days.rounded(.down)) * 86_400
		lunarTime = normalise(intoDay / 240 - 180 + sun - moon)

		// Schureman's auxiliaries. All of them turn with the node alone.
		let radians = Double.pi / 180
		let omega = Self.meanObliquity * radians
		let i = Self.lunarInclination * radians
		let n = node * radians

		inclination = acos(cos(i) * cos(omega) - sin(i) * sin(omega) * cos(n)) / radians

		// ξ and ν come from Napier's analogies on the triangle equinox-node-
		// intersection. Each analogy gives half their sum and half their
		// difference as an arctangent of tan(N/2), from which the half-node
		// must be taken back out — without that step both angles come out an
		// order of magnitude too large.
		let sum = atan(cos((omega - i) / 2) / cos((omega + i) / 2) * tan(n / 2))
		let difference = atan(sin((omega - i) / 2) / sin((omega + i) / 2) * tan(n / 2))
		xi = DerivedNavigation.signed((n - sum - difference) / radians)
		nu = DerivedNavigation.signed((sum - difference) / radians)

		let bigI = inclination * radians
		let nuRadians = nu * radians
		// Schureman 224 and 232. The constants are the solar coefficients that
		// make K₁ and K₂ lunisolar: their lunar and solar parts beat against
		// one another over the nodal cycle, which is why these two alone need a
		// correction of their own rather than a multiple of ξ and ν.
		nuPrime =
			atan(sin(2 * bigI) * sin(nuRadians) / (sin(2 * bigI) * cos(nuRadians) + 0.3347)) / radians
		let sinSquared = sin(bigI) * sin(bigI)
		nuDoublePrime =
			0.5
			* atan(
				sinSquared * sin(2 * nuRadians) / (sinSquared * cos(2 * nuRadians) + 0.0727)
			) / radians
		perigeeInOrbit = DerivedNavigation.normalise(lunarPerigee - xi)
	}
}
