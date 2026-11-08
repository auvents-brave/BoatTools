import Foundation
import Testing

@testable import BoatToolsKit

/// Tests the astronomy and the constituent catalogue a tidal prediction rests
/// on: the five fundamental longitudes, Schureman's auxiliary angles and the
/// nodal corrections built from them, and that each constituent's speed and
/// its equilibrium argument tell the same story.
@Suite("Tidal harmonics")
struct TidalHarmonicsTests {

	/// An instant, from a UTC calendar date.
	private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
		-> Date
	{
		var components = DateComponents()
		components.year = year
		components.month = month
		components.day = day
		components.hour = hour
		components.minute = minute
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
		return calendar.date(from: components) ?? .distantPast
	}

	/// Samples a nodal cycle and a bit: 19 years, every ten days.
	private var nodalCycle: [TidalAstronomy] {
		let start = date(2020, 1, 1)
		return stride(from: 0.0, to: 19 * 365.25, by: 10).map {
			TidalAstronomy(date: start.addingTimeInterval($0 * 86_400))
		}
	}

	// MARK: The fundamental longitudes

	@Test func `the fundamental longitudes stand where they should at the epoch`() {
		let a = TidalAstronomy(date: TidalAstronomy.epoch)
		// The standard J2000 mean longitudes. A typed-wrong digit in any
		// polynomial shows up here before it shows up as a wrong tide.
		#expect(abs(a.moon - 218.3165) < 0.001)
		#expect(abs(a.sun - 280.4665) < 0.001)
		#expect(abs(a.lunarPerigee - 83.3532) < 0.001)
		#expect(abs(a.node - 125.0445) < 0.001)
		#expect(abs(a.solarPerigee - 282.9373) < 0.001)
	}

	@Test func `the longitudes turn at the rates the constituent speeds are built from`() {
		// The arguments come from the polynomials, the speeds from the Rate
		// constants. If the two disagree, every prediction drifts away from
		// its own stated period — so they are checked against each other.
		let first = date(2026, 6, 1, 0)
		let second = first.addingTimeInterval(3600)
		let a = TidalAstronomy(date: first)
		let b = TidalAstronomy(date: second)
		func turned(_ from: Double, _ to: Double) -> Double {
			DerivedNavigation.signed(to - from)
		}
		#expect(abs(turned(a.moon, b.moon) - TidalAstronomy.Rate.moon) < 1e-7)
		#expect(abs(turned(a.sun, b.sun) - TidalAstronomy.Rate.sun) < 1e-7)
		#expect(abs(turned(a.lunarPerigee, b.lunarPerigee) - TidalAstronomy.Rate.lunarPerigee) < 1e-7)
		#expect(abs(turned(a.lunarTime, b.lunarTime) - TidalAstronomy.Rate.lunarTime) < 1e-7)
	}

	@Test func `mean lunar time is reckoned from Greenwich mean noon`() {
		// The hour angle of the mean Sun is zero at noon, not at midnight. Get
		// this wrong by half a day and every semidiurnal constituent still
		// comes out right while every diurnal one comes out backwards, which
		// is the kind of error that hides for a long time.
		let noon = TidalAstronomy(date: date(2026, 6, 1, 12))
		#expect(
			abs(DerivedNavigation.signed(noon.lunarTime - (noon.sun - noon.moon))) < 1e-9)

		let midnight = TidalAstronomy(date: date(2026, 6, 1, 0))
		#expect(
			abs(DerivedNavigation.signed(midnight.lunarTime - (180 + midnight.sun - midnight.moon)))
				< 1e-9)
	}

	// MARK: Schureman's auxiliaries

	@Test func `the orbit inclination swings with the node over 18 point 6 years`() {
		let inclinations = nodalCycle.map(\.inclination)
		// ω + i when the node is at the equinox, ω − i half a cycle later.
		#expect(abs((inclinations.max() ?? 0) - 28.585) < 0.02)
		#expect(abs((inclinations.min() ?? 0) - 18.294) < 0.02)
	}

	@Test func `xi and nu stay the small angles they are meant to be`() {
		// Both are a dozen degrees at most. The arctangents they come from
		// hand back ten times that if the half-node is not taken back out, so
		// this guards the one step of that derivation that is easy to drop.
		for a in nodalCycle {
			#expect(abs(a.xi) < 12.5, "ξ = \(a.xi) with the node at \(a.node)")
			#expect(abs(a.nu) < 13.5, "ν = \(a.nu) with the node at \(a.node)")
		}
		// And both vanish when the node reaches an equinox.
		let fromEquinox = { (a: TidalAstronomy) in
			min(
				abs(DerivedNavigation.signed(a.node)),
				abs(DerivedNavigation.signed(a.node - 180)))
		}
		if let near = nodalCycle.min(by: { fromEquinox($0) < fromEquinox($1) }) {
			#expect(abs(near.xi) < 1.5)
			#expect(abs(near.nu) < 1.5)
		}
	}

	// MARK: The nodal corrections

	@Test func `the nodal factors agree with Doodson and Warburg's series`() {
		// Schureman's exact factors and the truncated series Doodson and
		// Warburg published are two independent accounts of the same thing, so
		// they are made to agree here. Taking the two leading moments of f over
		// one nodal cycle — its mean, and the amplitude of its cos N term —
		// compares the parts both accounts state and ignores the harmonics the
		// series drops.
		let expected: [(name: String, mean: Double, swing: Double)] = [
			("M2", 1.000, -0.037),
			("O1", 1.009, 0.187),
			("K1", 1.006, 0.115),
			("K2", 1.024, 0.286),
			("Mf", 1.043, 0.414),
			("Mm", 1.000, -0.130),
			("J1", 1.013, 0.168),
		]
		// One turn of the node, sampled evenly, so that the cosine is
		// orthogonal to everything it is not meant to pick up.
		let nodalDays = 360 / 1_934.136_184_9 * 36_525
		let start = date(2020, 1, 1)
		let samples = (0..<680).map {
			TidalAstronomy(
				date: start.addingTimeInterval(Double($0) / 680 * nodalDays * 86_400))
		}
		let radians = Double.pi / 180
		for (name, mean, swing) in expected {
			guard let constituent = TidalConstituent.named(name) else {
				Issue.record("no constituent \(name)")
				continue
			}
			let factors = samples.map { constituent.amplitudeFactor($0) }
			let average = factors.reduce(0, +) / Double(factors.count)
			let amplitude =
				2 * zip(factors, samples).reduce(0) { $0 + $1.0 * cos($1.1.node * radians) }
				/ Double(factors.count)
			#expect(abs(average - mean) < 0.002, "\(name) averages \(average), not \(mean)")
			#expect(abs(amplitude - swing) < 0.003, "\(name) swings \(amplitude), not \(swing)")
		}
	}

	@Test func `the nodal phase corrections keep to their published swings`() {
		let expected = [("M2", 2.2), ("O1", 11.0), ("K1", 9.0), ("K2", 18.0), ("Mf", 24.0)]
		for (name, limit) in expected {
			guard let constituent = TidalConstituent.named(name) else {
				Issue.record("no constituent \(name)")
				continue
			}
			let corrections = nodalCycle.map {
				abs(DerivedNavigation.signed(constituent.phaseCorrection($0)))
			}
			#expect((corrections.max() ?? 0) < limit, "\(name) reached \(corrections.max() ?? 0)°")
			#expect((corrections.max() ?? 0) > limit * 0.75, "\(name) never swings at all")
		}
	}

	@Test func `a solar constituent has no nodal correction`() {
		let a = TidalAstronomy(date: date(2026, 3, 21))
		for name in ["S2", "P1", "S1", "T2", "R2", "Sa", "Ssa", "S4"] {
			guard let constituent = TidalConstituent.named(name) else {
				Issue.record("no constituent \(name)")
				continue
			}
			#expect(constituent.amplitudeFactor(a) == 1, "\(name)")
			#expect(constituent.phaseCorrection(a) == 0, "\(name)")
		}
	}

	@Test func `a compound constituent borrows its parents' corrections`() {
		let a = TidalAstronomy(date: date(2026, 3, 21))
		guard let m2 = TidalConstituent.named("M2"), let m4 = TidalConstituent.named("M4"),
			let msf = TidalConstituent.named("Msf"), let ms4 = TidalConstituent.named("MS4")
		else {
			Issue.record("missing constituents")
			return
		}
		// M₄ is M₂ twice over, in both the factor and the phase.
		#expect(abs(m4.amplitudeFactor(a) - pow(m2.amplitudeFactor(a), 2)) < 1e-12)
		#expect(abs(m4.phaseCorrection(a) - 2 * m2.phaseCorrection(a)) < 1e-12)
		// MS₄ is M₂ plus a solar term, so it takes M₂'s corrections unchanged.
		#expect(abs(ms4.amplitudeFactor(a) - m2.amplitudeFactor(a)) < 1e-12)
		// Msf is S₂ *minus* M₂: the same factor, the opposite phase.
		#expect(abs(msf.amplitudeFactor(a) - m2.amplitudeFactor(a)) < 1e-12)
		#expect(abs(msf.phaseCorrection(a) + m2.phaseCorrection(a)) < 1e-12)
	}

	// MARK: Speeds

	@Test func `every constituent turns at its published speed`() {
		// The library derives each speed from the Doodson coefficients; these
		// are the tabulated figures, held here as the independent check. A
		// coefficient typed wrong cannot pass this.
		let published: [String: Double] = [
			"Sa": 0.0410686, "Ssa": 0.0821373, "Mm": 0.5443747, "Msf": 1.0158958,
			"Mf": 1.0980331, "Mtm": 1.6424078,
			"Q1": 13.3986609, "O1": 13.9430356, "P1": 14.9589314, "S1": 15.0,
			"K1": 15.0410686, "J1": 15.5854433,
			"EPS2": 27.4238337, "2N2": 27.8953548, "MU2": 27.9682084, "N2": 28.4397295,
			"NU2": 28.5125831, "M2": 28.9841042, "MKS2": 29.0662415, "LA2": 29.4556253,
			"L2": 29.5284789, "T2": 29.9589333, "S2": 30.0, "R2": 30.0410667,
			"K2": 30.0821373,
			"M3": 43.4761563, "N4": 56.8794590, "MN4": 57.4238337, "M4": 57.9682084,
			"MS4": 58.9841042, "S4": 60.0, "M6": 86.9523127, "M8": 115.9364169,
		]
		#expect(TidalConstituent.all.count == published.count)
		for constituent in TidalConstituent.all {
			guard let speed = published[constituent.name] else {
				Issue.record("no published speed for \(constituent.name)")
				continue
			}
			#expect(
				abs(constituent.speed - speed) < 1e-6,
				"\(constituent.name) turns at \(constituent.speed), not \(speed)")
		}
	}

	@Test func `the equilibrium argument advances at the constituent's own speed`() {
		// The second half of the same guarantee: whatever the catalogue says a
		// constituent's speed is, its argument must actually move that fast.
		let first = date(2026, 6, 1, 3)
		let a = TidalAstronomy(date: first)
		let b = TidalAstronomy(date: first.addingTimeInterval(3600))
		for constituent in TidalConstituent.all {
			let advance = DerivedNavigation.signed(
				constituent.equilibriumArgument(b) - constituent.equilibriumArgument(a))
			let expected = DerivedNavigation.signed(constituent.speed)
			#expect(abs(advance - expected) < 1e-6, "\(constituent.name) advanced \(advance)")
		}
	}

	@Test func `S2 stands at zero at Greenwich mean noon`() {
		// S₂ is twice the mean Sun's hour angle and nothing else, so its
		// argument is a clock: zero at noon, 180° at six, right round by
		// midnight. This anchors the whole argument machinery to real time.
		guard let s2 = TidalConstituent.named("S2") else {
			Issue.record("no S2")
			return
		}
		#expect(
			abs(
				DerivedNavigation.signed(
					s2.equilibriumArgument(
						TidalAstronomy(date: date(2026, 6, 1, 12))))) < 1e-6)
		#expect(
			abs(
				DerivedNavigation.signed(
					s2.equilibriumArgument(
						TidalAstronomy(date: date(2026, 6, 1, 15))) - 90)) < 1e-6)
		#expect(
			abs(
				DerivedNavigation.signed(
					s2.equilibriumArgument(
						TidalAstronomy(date: date(2026, 11, 8, 18))) - 180)) < 1e-6)
	}

	@Test func `Sa is the Sun's own longitude and the overtones are multiples of M2`() {
		let a = TidalAstronomy(date: date(2026, 9, 15, 7))
		guard let sa = TidalConstituent.named("Sa"), let m2 = TidalConstituent.named("M2"),
			let m4 = TidalConstituent.named("M4"), let m6 = TidalConstituent.named("M6")
		else {
			Issue.record("missing constituents")
			return
		}
		#expect(abs(DerivedNavigation.signed(sa.equilibriumArgument(a) - a.sun)) < 1e-9)
		#expect(
			abs(
				DerivedNavigation.signed(
					m4.equilibriumArgument(a) - 2 * m2.equilibriumArgument(a))) < 1e-9)
		#expect(
			abs(
				DerivedNavigation.signed(
					m6.equilibriumArgument(a) - 3 * m2.equilibriumArgument(a))) < 1e-9)
	}

	@Test func `a constituent is found whatever an atlas calls it`() {
		#expect(TidalConstituent.named("m2")?.name == "M2")
		#expect(TidalConstituent.named("M2")?.name == "M2")
		#expect(TidalConstituent.named("lambda2")?.name == "LA2")
		#expect(TidalConstituent.named("epsilon2")?.name == "EPS2")
		#expect(TidalConstituent.named("mf")?.name == "Mf")
		// Msqm is in the atlas but not in the catalogue, on purpose.
		#expect(TidalConstituent.named("Msqm") == nil)
		#expect(TidalConstituent.named("not a tide") == nil)
	}
}
