import Foundation
import Testing

@testable import BoatToolsKit

/// Tests the values BoatTools works out for itself — the leeway, the true wind
/// behind an apparent-only masthead unit, the tidal stream and both velocities
/// made good — and that they are published apart from the measured ones.
@Suite("Derived navigation")
struct DerivedNavigationTests {

	// MARK: Leeway

	@Test func `a two-axis log states the leeway outright`() {
		// Slipping 0.6 kn to starboard at 6 kn through the water.
		let angle = try? #require(DerivedNavigation.leeway(transverseWater: 0.6, speedThroughWater: 6))
		#expect(abs((angle ?? 0) - 5.71) < 0.02)
		// The sign follows the side she slips to.
		let toPort = try? #require(DerivedNavigation.leeway(transverseWater: -0.6, speedThroughWater: 6))
		#expect((toPort ?? 0) < 0)
		// At rest the arctangent is all noise.
		#expect(DerivedNavigation.leeway(transverseWater: 0.2, speedThroughWater: 0.1) == nil)
	}

	// MARK: True wind

	@Test func `the true wind is recovered from the apparent it would produce`() {
		let track = 40.0
		for trueDirection in stride(from: 0.0, to: 360, by: 37) {
			for speed in [3.0, 6.5] {
				let apparent = NMEASimulator.apparentWind(
					trueSpeed: 12, trueDirection: trueDirection, heading: track, boatSpeed: speed)
				let wind = try? #require(
					DerivedNavigation.trueWind(
						apparentSpeed: apparent.speed, apparentAngle: apparent.angle,
						heading: track, track: track, speed: speed))
				#expect(abs((wind?.speed ?? 0) - 12) < 0.01)
				#expect(
					abs(DerivedNavigation.signed((wind?.direction ?? 0) - trueDirection)) < 0.01,
					"true wind from \(trueDirection)° at \(speed) kn")
			}
		}
	}

	@Test func `the vane reads off the bow, the vectors add around the track`() {
		// Six degrees of leeway to starboard, as the simulator now composes it:
		// the apparent wind is built around the water track and read off the bow.
		let heading = 100.0
		let leeway = 6.0
		let speed = 6.0
		let direction = 300.0
		let onTrack = NMEASimulator.apparentWind(
			trueSpeed: 12, trueDirection: direction, heading: heading + leeway, boatSpeed: speed)
		let offBow = DerivedNavigation.normalise(onTrack.angle + leeway)

		// Honouring the leeway recovers the breeze exactly.
		let exact = try? #require(
			DerivedNavigation.trueWind(
				apparentSpeed: onTrack.speed, apparentAngle: offBow,
				heading: heading, track: heading + leeway, speed: speed))
		#expect(abs(DerivedNavigation.signed((exact?.direction ?? 0) - direction)) < 0.01)
		#expect(abs((exact?.speed ?? 0) - 12) < 0.01)

		// Taking the vane reading as if the bow were the track — all one can do
		// without a leeway — costs a few degrees of wind direction.
		let naive = try? #require(
			DerivedNavigation.trueWind(
				apparentSpeed: onTrack.speed, apparentAngle: offBow,
				heading: heading, track: heading, speed: speed))
		#expect(abs(DerivedNavigation.signed((naive?.direction ?? 0) - direction)) > 2)
	}

	@Test func `she makes no true wind of her own while stopped`() {
		#expect(
			DerivedNavigation.trueWind(
				apparentSpeed: 10, apparentAngle: 20, heading: 90, track: 90, speed: 0.1) == nil)
	}

	// MARK: Tidal stream

	@Test func `the stream is what the ground track has that the water track has not`() {
		// Making 6 kn over the ground due east, 5 kn through the water: a knot
		// of stream carrying her east.
		let components = DerivedNavigation.streamComponents(
			courseOverGround: 90, speedOverGround: 6, waterTrack: 90, speedThroughWater: 5)
		let stream = DerivedNavigation.setAndDrift(east: components.east, north: components.north)
		#expect(abs(stream.drift - 1) < 0.001)
		#expect(abs(DerivedNavigation.signed(stream.set - 90)) < 0.001)

		// Crabbing: the same speed over both references, 10° apart, is a stream
		// across her track and nothing along it.
		let across = DerivedNavigation.streamComponents(
			courseOverGround: 100, speedOverGround: 6, waterTrack: 90, speedThroughWater: 6)
		let sideways = DerivedNavigation.setAndDrift(east: across.east, north: across.north)
		#expect(abs(sideways.drift - 2 * 6 * sin(5 * .pi / 180)) < 0.001)
	}

	@Test func `the stream is filtered as a vector, never as an angle`() {
		var filter = CurrentFilter(timeConstant: 10)
		let start = Date(timeIntervalSince1970: 1_800_000_000)
		var result = (set: 0.0, drift: 0.0)
		// A stream setting due north, reported alternately as 355° and 005°.
		for second in 0..<120 {
			let set = second.isMultiple(of: 2) ? 355.0 : 5.0
			let components = DerivedNavigation.streamComponents(
				courseOverGround: set, speedOverGround: 1, waterTrack: 0, speedThroughWater: 0)
			result = filter.update(
				east: components.east, north: components.north,
				at: start.addingTimeInterval(Double(second)))
		}
		// The mean of 355 and 5 is north, not the reciprocal an arithmetic mean
		// of the two angles would give.
		#expect(abs(DerivedNavigation.signed(result.set)) < 1)
		#expect(abs(result.drift - 1) < 0.01)

		filter.reset()
		let fresh = filter.update(east: 0, north: 2, at: start)
		#expect(abs(fresh.drift - 2) < 0.001, "a reset filter takes the next sample as it stands")
	}

	// MARK: Velocity made good

	@Test func `the velocity made good is signed by the point of sail`() {
		// Hard on the wind: 6 kn at 45° off a wind from due north.
		#expect(
			abs(DerivedNavigation.velocityMadeGood(speed: 6, track: 45, windDirection: 0) - 6 * cos(.pi / 4))
				< 0.001)
		// Dead run: all of it, and away from the wind.
		#expect(abs(DerivedNavigation.velocityMadeGood(speed: 6, track: 180, windDirection: 0) + 6) < 0.001)
		// Beam reach: none of it either way.
		#expect(abs(DerivedNavigation.velocityMadeGood(speed: 6, track: 90, windDirection: 0)) < 0.001)
	}

	// MARK: In the store

	/// A store holding one flush of the given metrics, each uncontested.
	@MainActor private func store(_ feed: [String: Double]) -> BoatMetricStore {
		let store = BoatMetricStore()
		for (name, value) in feed {
			store.feed(.metric(BoatMetric(name: name, value: value, unit: "")))
		}
		store.flushNow()
		return store
	}

	@MainActor @Test func `computed values are published apart from the measured ones`() {
		let store = store([
			"HDG.true": 100, "STW": 6, "COG": 104, "SOG": 6.4,
			"AWS": 14, "AWA": 35, "speed.water.transverse": 0.6,
		])

		// Each one lands under its own name, and no measured name is invented.
		for name in ["TWS", "TWD", "TWA", "navigation.leeway", "navigation.currentSet"] {
			#expect(store.metrics[name + DerivedNavigation.suffix] != nil, "missing \(name)")
			#expect(store.metrics[name] == nil, "\(name) was published as if measured")
		}
		// The leeway a two-axis log gives bends the water track, so the stream
		// is not simply the difference of the two courses.
		#expect(abs((store.metrics["navigation.leeway.computed"]?.value ?? 0) - 5.71) < 0.02)
		#expect(store.metrics["navigation.vmgWind.computed"] != nil)
		#expect(store.metrics["navigation.vmgWindGround.computed"] != nil)
	}

	@MainActor @Test func `a measured value is never replaced by a computed one`() {
		let store = store([
			"HDG.true": 100, "STW": 6, "COG": 104, "SOG": 6.4, "AWS": 14, "AWA": 35,
			"TWD": 300, "TWS": 11, "navigation.leeway": -4,
		])

		#expect(store.metrics["TWD"]?.value == 300)
		#expect(store.metrics["TWS"]?.value == 11)
		#expect(store.metrics["navigation.leeway"]?.value == -4)
		// And the computed figures stand beside them for comparison.
		#expect(store.metrics["TWD.computed"] != nil)
		#expect(abs((store.metrics["TWD.computed"]?.value ?? 0) - 300) > 1, "the two should differ here")
	}

	@MainActor @Test func `a COG-derived heading cannot father a tidal stream`() {
		// No heading source at all: the store falls back to COG, which would
		// make the "stream" a bare speed difference along the course.
		let store = store(["COG": 104, "SOG": 6.4, "STW": 6])

		#expect(store.metrics["HDG.true"]?.value == 104, "the COG fallback still stands")
		#expect(store.metrics["navigation.currentSet.computed"] == nil)
		#expect(store.metrics["navigation.currentDrift.computed"] == nil)
	}

	@MainActor @Test func `a magnetic heading is used once the variation is known`() {
		#expect(
			store(["HDG.magnetic": 100, "STW": 6, "COG": 104, "SOG": 6.4])
				.metrics["navigation.currentSet.computed"] == nil)

		let known = store([
			"HDG.magnetic": 100, "magneticVariation": 3, "STW": 6, "COG": 104, "SOG": 6.4,
		])
		#expect(known.metrics["navigation.currentSet.computed"] != nil)
	}

	@MainActor @Test func `the stream is cleared with the source that produced it`() {
		let store = store(["HDG.true": 100, "STW": 6, "COG": 104, "SOG": 6.4])
		#expect(store.metrics["navigation.currentDrift.computed"] != nil)

		store.clear()
		store.flushNow()
		#expect(store.metrics["navigation.currentDrift.computed"] == nil)
	}

	// MARK: Against the simulator

	@MainActor @Test func `the derived values agree with the simulated passage`() async throws {
		let stream = NMEASimulator.frameStream(
			route: .monacoToMaddalena, speedKnots: 6, loop: false
		)
		let store = BoatMetricStore()
		// Two ticks, so every value below comes from the first — where the
		// simulated GPS wander is zero and the vectors must close exactly.
		var fixes = 0
		for try await frame in stream {
			if case .nmea2000(129025, _, _, _) = frame {
				fixes += 1
				if fixes >= 2 { break }
			}
			store.feed(frame)
		}
		store.flushNow()

		func value(_ name: String) throws -> Double {
			try #require(store.metrics[name]?.value, "\(name) missing")
		}

		// The stream the passage is sailed in, recovered from the tracks alone.
		// Its direction is a small difference of two six-knot vectors, so the
		// hundredth-of-a-knot step the PGNs quantise the speeds to is worth a
		// degree and a half of set on its own — the sensitivity the filter
		// exists for.
		#expect(
			abs(
				DerivedNavigation.signed(
					try value("navigation.currentSet.computed") - (try value("navigation.currentSet")))) < 3)
		#expect(
			abs(try value("navigation.currentDrift.computed") - (try value("navigation.currentDrift"))) < 0.05)

		// The true wind, recovered from the apparent the masthead unit reports.
		#expect(abs(DerivedNavigation.signed(try value("TWD.computed") - (try value("TWD")))) < 0.5)
		#expect(abs(try value("TWS.computed") - (try value("TWS"))) < 0.1)
		#expect(abs(DerivedNavigation.signed(try value("TWA.computed") - (try value("TWA")))) < 0.5)

		// And the sailing VMG the performance processor sends on VPW.
		#expect(abs(try value("navigation.vmgWind.computed") - (try value("navigation.vmgWind"))) < 0.1)
		// The ground figure differs from it by the stream, and can never exceed
		// the speed it is a component of.
		#expect(abs(try value("navigation.vmgWindGround.computed")) <= (try value("SOG")) + 0.01)
	}
}
