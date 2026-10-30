// Exercises the closest-point-of-approach geometry behind a collision watch:
// the encounters it must raise, the ones it must stay silent on, and the time
// it puts on them.
//
// Ported from the Apple app, where this arithmetic used to live, so that both
// it and the companion compute a watch the same way instead of each carrying a
// version of their own to drift apart.

import Foundation
import Stheno
import Testing

@testable import BoatToolsKit

@Suite("Collision geometry")
struct CollisionGeometryTests {

	private let own = Coordinate(latitude: 43.0, longitude: 7.0)

	/// A position `northMetres` / `eastMetres` from `own`. One degree of
	/// latitude is 60 nautical miles; longitude shrinks with the cosine of the
	/// latitude.
	private func place(northMetres: Double, eastMetres: Double) -> Coordinate {
		let metresPerDegree = 1852.0 * 60
		return Coordinate(
			latitude: own.latitude + northMetres / metresPerDegree,
			longitude: own.longitude + eastMetres / (metresPerDegree * cos(own.latitude * .pi / 180)))
	}

	private func approach(
		northMetres: Double, eastMetres: Double, herCourse: Double, herSpeed: Double,
		ourCourse: Double, ourSpeed: Double
	) -> CollisionGeometry.Approach? {
		CollisionGeometry.approach(
			from: own, courseDeg: ourCourse, speedKnots: ourSpeed,
			to: place(northMetres: northMetres, eastMetres: eastMetres),
			targetCourseDeg: herCourse, targetSpeedKnots: herSpeed)
	}

	/// An approach that must exist is unwrapped here, so a missing one fails
	/// loudly on the figures rather than silently passing.
	private func unwrap(_ approach: CollisionGeometry.Approach?) -> CollisionGeometry.Approach {
		approach ?? CollisionGeometry.Approach(distanceMetres: .infinity, minutes: .infinity)
	}

	// MARK: Encounters that close

	@Test("A head-on meeting closes to nothing at the halfway time")
	func headOn() {
		// She is two miles due north, steering south at 10 kn; we steer north at
		// 10 kn. They meet in the middle: 2 NM closed at 20 kn = 6 minutes.
		let result = unwrap(
			approach(northMetres: 3704, eastMetres: 0, herCourse: 180, herSpeed: 10, ourCourse: 0, ourSpeed: 10))
		#expect(result.distanceMetres < 10)
		#expect(abs(result.minutes - 6) < 0.1)
	}

	@Test("A ship crossing ahead passes at the offset her turn-away buys")
	func crossingAhead() {
		// She is two miles due north running west at 10 kn; we hold north at 10
		// kn. In six minutes we have made her original position good while she
		// has gone a mile west of it — a mile and a half apart, on the diagonal.
		let result = unwrap(
			approach(northMetres: 3704, eastMetres: 0, herCourse: 270, herSpeed: 10, ourCourse: 0, ourSpeed: 10))
		#expect(abs(result.minutes - 6) < 0.2)
		#expect(abs(result.distanceMetres - 1852 * 2.0.squareRoot()) < 60)
	}

	@Test("A moored vessel dead ahead is an approach, being our own way")
	func mooredAhead() {
		// She reports nothing, so she is taken as stationary; we are making for
		// her at 6 kn from a mile off: 10 minutes, and we would run her down.
		let result = unwrap(
			approach(northMetres: 1852, eastMetres: 0, herCourse: 0, herSpeed: 0, ourCourse: 0, ourSpeed: 6))
		#expect(result.distanceMetres < 10)
		#expect(abs(result.minutes - 10) < 0.2)
	}

	// MARK: Encounters that do not

	@Test("A ship already past her closest point raises nothing")
	func alreadyPast() {
		// She is a mile north, going further north faster than we follow.
		#expect(
			approach(northMetres: 1852, eastMetres: 0, herCourse: 0, herSpeed: 15, ourCourse: 0, ourSpeed: 5)
				== nil)
	}

	@Test("A ship on our own course and speed never closes")
	func sameCourseAndSpeed() {
		// Line abreast at the same speed: the separation is fixed, so there is no
		// closest point to reach.
		#expect(
			approach(northMetres: 0, eastMetres: 926, herCourse: 45, herSpeed: 8, ourCourse: 45, ourSpeed: 8)
				== nil)
	}

	@Test("A ship fine on the bow that will pass clear keeps her offset")
	func passingClear() {
		// She is two miles ahead and half a mile to starboard, steering south as
		// we steer north: she passes down our starboard side at that offset.
		let result = unwrap(
			approach(northMetres: 3704, eastMetres: 926, herCourse: 180, herSpeed: 10, ourCourse: 0, ourSpeed: 10))
		#expect(abs(result.distanceMetres - 926) < 30)
	}

	// MARK: The rules the watch applies

	@Test("The own-speed floor is half a knot")
	func ownSpeedFloor() {
		// At anchor every vessel passing up the fairway has a closing approach on
		// us, so the watch stands down below this.
		#expect(CollisionGeometry.ownSpeedFloorKnots == 0.5)
	}

	@Test("An approach beyond the horizon is outside the watch")
	func beyondTheHorizon() {
		// Twenty miles off, closing at 20 kn: an hour away, so past the half-hour
		// the watch looks ahead.
		let result = unwrap(
			approach(northMetres: 37040, eastMetres: 0, herCourse: 180, herSpeed: 10, ourCourse: 0, ourSpeed: 10))
		#expect(result.minutes > CollisionGeometry.horizonMinutes)
	}
}
