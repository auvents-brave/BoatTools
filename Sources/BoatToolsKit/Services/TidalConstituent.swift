import Foundation

/// One harmonic constituent of the tide: a cosine of fixed speed whose
/// amplitude and phase lag are what a tidal atlas stores for each place.
///
/// A constituent's speed and its equilibrium argument both come from the same
/// five Doodson coefficients, so nothing can drift apart: the speed is the
/// argument's rate of change, and ``speed`` is computed from the coefficients
/// rather than tabulated beside them.
///
/// The Moon's node turns once in 18.6 years and modulates the lunar terms as
/// it goes. That is carried by ``amplitudeFactor(_:)`` and
/// ``phaseCorrection(_:)`` — Schureman's *f* and *u* — which together move M₂
/// by up to 4% in height and 2° in phase, and O₁ by more than 20%.
public struct TidalConstituent: Sendable, Hashable {

	/// The family of satellite terms a constituent takes its nodal corrections
	/// from. Shallow-water and compound constituents name the families of
	/// their parents instead of a family of their own.
	enum NodalFamily: Sendable, Hashable {
		/// M₂ and the other second-degree lunar semidiurnals.
		case lunarSemidiurnal
		/// O₁ and Q₁.
		case lunarDiurnal
		/// K₁, whose lunar and solar parts beat over the nodal cycle.
		case lunisolarDiurnal
		/// K₂, likewise.
		case lunisolarSemidiurnal
		/// J₁.
		case lunarDiurnalJ
		/// Mf, the fortnightly declinational tide.
		case lunarFortnightly
		/// Mm, the monthly elliptic tide.
		case lunarMonthly
		/// L₂, which needs a correction from the perigee as well as the node.
		case lunarEllipticSemidiurnal
	}

	/// One family's contribution to a constituent's nodal corrections.
	///
	/// The amplitude factor is raised to the magnitude of ``multiplier`` and
	/// the phase correction multiplied by its signed value: a compound such as
	/// Msf = S₂ − M₂ borrows M₂'s factor but the opposite of its phase.
	struct NodalTerm: Sendable, Hashable {
		let family: NodalFamily
		let multiplier: Double

		init(_ family: NodalFamily, _ multiplier: Double) {
			self.family = family
			self.multiplier = multiplier
		}
	}

	/// The constituent's conventional name, as a tidal atlas spells it.
	public let name: String

	/// Multiple of the mean lunar time in the equilibrium argument.
	let tau: Int
	/// Multiple of the Moon's mean longitude.
	let s: Int
	/// Multiple of the Sun's mean longitude.
	let h: Int
	/// Multiple of the lunar perigee.
	let p: Int
	/// Multiple of the solar perigee.
	let p1: Int
	/// Quarter turns added to the equilibrium argument: the conventional
	/// ±90° and 180° offsets.
	let quarterTurns: Int
	/// The nodal corrections this constituent takes.
	let nodal: [NodalTerm]

	init(
		_ name: String, tau: Int = 0, s: Int = 0, h: Int = 0, p: Int = 0, p1: Int = 0,
		quarterTurns: Int = 0, nodal: [NodalTerm] = []
	) {
		self.name = name
		self.tau = tau
		self.s = s
		self.h = h
		self.p = p
		self.p1 = p1
		self.quarterTurns = quarterTurns
		self.nodal = nodal
	}

	/// How fast the constituent turns, in degrees per hour.
	public var speed: Double {
		Double(tau) * TidalAstronomy.Rate.lunarTime
			+ Double(s) * TidalAstronomy.Rate.moon
			+ Double(h) * TidalAstronomy.Rate.sun
			+ Double(p) * TidalAstronomy.Rate.lunarPerigee
			+ Double(p1) * TidalAstronomy.Rate.solarPerigee
	}

	/// The equilibrium argument *V* at Greenwich, in degrees: where the
	/// constituent's cosine stands before the place's own phase lag is taken
	/// off it.
	public func equilibriumArgument(_ astronomy: TidalAstronomy) -> Double {
		DerivedNavigation.normalise(
			Double(tau) * astronomy.lunarTime
				+ Double(s) * astronomy.moon
				+ Double(h) * astronomy.sun
				+ Double(p) * astronomy.lunarPerigee
				+ Double(p1) * astronomy.solarPerigee
				+ Double(quarterTurns) * 90
		)
	}

	/// Schureman's *f*: the factor the node applies to the constituent's
	/// amplitude, 1 when nothing lunar is involved.
	public func amplitudeFactor(_ astronomy: TidalAstronomy) -> Double {
		nodal.reduce(1) { $0 * pow($1.family.amplitudeFactor(astronomy), abs($1.multiplier)) }
	}

	/// Schureman's *u*: the degrees the node adds to the equilibrium argument,
	/// 0 when nothing lunar is involved.
	public func phaseCorrection(_ astronomy: TidalAstronomy) -> Double {
		nodal.reduce(0) { $0 + $1.multiplier * $1.family.phaseCorrection(astronomy) }
	}
}

// MARK: - Nodal corrections

extension TidalConstituent.NodalFamily {

	/// Schureman's *f* for this family: the amplitude at the present
	/// inclination over its value at the mean inclination, so that the factor
	/// averages to one across the nodal cycle.
	func amplitudeFactor(_ a: TidalAstronomy) -> Double {
		let radians = Double.pi / 180
		let omega = TidalAstronomy.meanObliquity * radians
		let i = TidalAstronomy.lunarInclination * radians
		let bigI = a.inclination * radians
		let nu = a.nu * radians

		switch self {
		case .lunarSemidiurnal:
			// Schureman 78, 70.
			return pow(cos(bigI / 2), 4) / (pow(cos(omega / 2), 4) * pow(cos(i / 2), 4))
		case .lunarDiurnal:
			// Schureman 75, 67.
			let mean = sin(omega) * pow(cos(omega / 2), 2) * pow(cos(i / 2), 4)
			return sin(bigI) * pow(cos(bigI / 2), 2) / mean
		case .lunisolarDiurnal:
			// Schureman 227, 226, 68.
			let mean = 0.5023 * sin(2 * omega) * (1 - 1.5 * pow(sin(i), 2)) + 0.1681
			let amplitude =
				0.2523 * pow(sin(2 * bigI), 2) + 0.1689 * sin(2 * bigI) * cos(nu) + 0.0283
			return amplitude.squareRoot() / mean
		case .lunisolarSemidiurnal:
			// Schureman 235, 234, 71.
			let mean = 0.5023 * pow(sin(omega), 2) * (1 - 1.5 * pow(sin(i), 2)) + 0.0365
			let amplitude =
				0.2523 * pow(sin(bigI), 4) + 0.0367 * pow(sin(bigI), 2) * cos(2 * nu) + 0.0013
			return amplitude.squareRoot() / mean
		case .lunarDiurnalJ:
			// Schureman 76, 68.
			return sin(2 * bigI) / (sin(2 * omega) * (1 - 1.5 * pow(sin(i), 2)))
		case .lunarFortnightly:
			// Schureman 74, 66.
			return pow(sin(bigI), 2) / (pow(sin(omega), 2) * pow(cos(i / 2), 4))
		case .lunarMonthly:
			// Schureman 73, 65.
			let mean = (2.0 / 3 - pow(sin(omega), 2)) * (1 - 1.5 * pow(sin(i), 2))
			return (2.0 / 3 - pow(sin(bigI), 2)) / mean
		case .lunarEllipticSemidiurnal:
			// Schureman 215, 213, 204: M₂'s factor, divided by the elliptic
			// factor the perigee contributes.
			let perigee = a.perigeeInOrbit * radians
			let tanHalf = tan(bigI / 2)
			let inverse =
				(1 - 12 * tanHalf * tanHalf * cos(2 * perigee) + 36 * pow(tanHalf, 4))
				.squareRoot()
			return Self.lunarSemidiurnal.amplitudeFactor(a) * inverse
		}
	}

	/// Schureman's *u* for this family, in degrees.
	func phaseCorrection(_ a: TidalAstronomy) -> Double {
		switch self {
		case .lunarSemidiurnal: return 2 * a.xi - 2 * a.nu
		case .lunarDiurnal: return 2 * a.xi - a.nu
		case .lunisolarDiurnal: return -a.nuPrime
		case .lunisolarSemidiurnal: return -2 * a.nuDoublePrime
		case .lunarDiurnalJ: return -a.nu
		case .lunarFortnightly: return -2 * a.xi
		case .lunarMonthly: return 0
		case .lunarEllipticSemidiurnal:
			// Schureman 214.
			let radians = Double.pi / 180
			let bigI = a.inclination * radians
			let perigee = a.perigeeInOrbit * radians
			let tanHalf = tan(bigI / 2)
			let r =
				atan(sin(2 * perigee) / (1 / (6 * tanHalf * tanHalf) - cos(2 * perigee)))
				/ radians
			return 2 * a.xi - 2 * a.nu - r
		}
	}
}

// MARK: - The catalogue

extension TidalConstituent {

	private static let m2 = [NodalTerm(.lunarSemidiurnal, 1)]
	private static let m2Twice = [NodalTerm(.lunarSemidiurnal, 2)]
	private static let o1 = [NodalTerm(.lunarDiurnal, 1)]

	/// Every constituent this library can predict with, named as the FES atlas
	/// names its files.
	///
	/// These are the 34 constituents FES2014 distributes, less Msqm, whose
	/// Doodson coefficients could not be corroborated: the reader reports it
	/// among ``TidalStreamAtlas/unsupportedConstituents`` rather than guess.
	/// Msqm is a long-period term of a few millimetres per second.
	public static let all: [TidalConstituent] = [
		// Long period.
		TidalConstituent("Sa", h: 1),
		TidalConstituent("Ssa", h: 2),
		TidalConstituent("Mm", s: 1, p: -1, nodal: [NodalTerm(.lunarMonthly, 1)]),
		// Msf is S₂ − M₂, so it borrows M₂'s factor and the opposite of its phase.
		TidalConstituent("Msf", s: 2, h: -2, nodal: [NodalTerm(.lunarSemidiurnal, -1)]),
		TidalConstituent("Mf", s: 2, nodal: [NodalTerm(.lunarFortnightly, 1)]),
		TidalConstituent(
			"Mtm", s: 3, p: -1,
			nodal: [NodalTerm(.lunarFortnightly, 1), NodalTerm(.lunarMonthly, 1)]),

		// Diurnal.
		TidalConstituent("Q1", tau: 1, s: -2, p: 1, quarterTurns: 1, nodal: o1),
		TidalConstituent("O1", tau: 1, s: -1, quarterTurns: 1, nodal: o1),
		TidalConstituent("P1", tau: 1, s: 1, h: -2, quarterTurns: 1),
		TidalConstituent("S1", tau: 1, s: 1, h: -1),
		TidalConstituent(
			"K1", tau: 1, s: 1, quarterTurns: -1, nodal: [NodalTerm(.lunisolarDiurnal, 1)]),
		TidalConstituent(
			"J1", tau: 1, s: 2, p: -1, quarterTurns: -1,
			nodal: [NodalTerm(.lunarDiurnalJ, 1)]),

		// Semidiurnal.
		TidalConstituent("EPS2", tau: 2, s: -3, h: 2, p: 1, nodal: m2),
		TidalConstituent("2N2", tau: 2, s: -2, p: 2, nodal: m2),
		TidalConstituent("MU2", tau: 2, s: -2, h: 2, nodal: m2),
		TidalConstituent("N2", tau: 2, s: -1, p: 1, nodal: m2),
		TidalConstituent("NU2", tau: 2, s: -1, h: 2, p: -1, nodal: m2),
		TidalConstituent("M2", tau: 2, nodal: m2),
		// MKS₂ is M₂ + K₂ − S₂: a shallow-water compound of two lunar parents.
		TidalConstituent(
			"MKS2", tau: 2, h: 2,
			nodal: [NodalTerm(.lunarSemidiurnal, 1), NodalTerm(.lunisolarSemidiurnal, 1)]),
		TidalConstituent("LA2", tau: 2, s: 1, h: -2, p: 1, quarterTurns: 2, nodal: m2),
		TidalConstituent(
			"L2", tau: 2, s: 1, p: -1, quarterTurns: 2,
			nodal: [NodalTerm(.lunarEllipticSemidiurnal, 1)]),
		TidalConstituent("T2", tau: 2, s: 2, h: -3, p1: 1),
		TidalConstituent("S2", tau: 2, s: 2, h: -2),
		TidalConstituent("R2", tau: 2, s: 2, h: -1, p1: -1, quarterTurns: 2),
		TidalConstituent("K2", tau: 2, s: 2, nodal: [NodalTerm(.lunisolarSemidiurnal, 1)]),

		// Terdiurnal and the shallow-water overtones.
		TidalConstituent("M3", tau: 3, nodal: [NodalTerm(.lunarSemidiurnal, 1.5)]),
		TidalConstituent("N4", tau: 4, s: -2, p: 2, nodal: m2Twice),
		TidalConstituent("MN4", tau: 4, s: -1, p: 1, nodal: m2Twice),
		TidalConstituent("M4", tau: 4, nodal: m2Twice),
		TidalConstituent("MS4", tau: 4, s: 2, h: -2, nodal: m2),
		TidalConstituent("S4", tau: 4, s: 4, h: -4),
		TidalConstituent("M6", tau: 6, nodal: [NodalTerm(.lunarSemidiurnal, 3)]),
		TidalConstituent("M8", tau: 8, nodal: [NodalTerm(.lunarSemidiurnal, 4)]),
	]

	/// Spellings an atlas may use for a constituent this library knows under
	/// another name.
	private static let aliases = ["LAMBDA2": "LA2", "EPSILON2": "EPS2", "EPS": "EPS2", "MU": "MU2"]

	/// Looks a constituent up by name, ignoring case and accepting the usual
	/// spellings of the Greek-lettered ones.
	/// - Parameter name: A constituent name, as an atlas spells it.
	/// - Returns: The constituent, or `nil` when this library cannot predict
	///   with it.
	public static func named(_ name: String) -> TidalConstituent? {
		let key = name.uppercased()
		let canonical = aliases[key] ?? key
		return all.first { $0.name.uppercased() == canonical }
	}
}
