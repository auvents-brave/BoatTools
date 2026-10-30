import Foundation

public import Stheno

/// How close two vessels will come to each other, and when.
///
/// The arithmetic the collision watch runs on. It lives here, beside the AIS
/// decoding that feeds it, so every app that shows a watch computes it the same
/// way — the Apple app and the companion both, rather than each carrying its
/// own version to drift apart.
public enum CollisionGeometry {

	// MARK: The rules the watch applies

	/// How far ahead an approach is worth raising, in minutes. Beyond it the
	/// picture will have changed many times over before anything comes of it.
	public static let horizonMinutes: Double = 30

	/// Below this speed through the water a vessel is taken to be at anchor or
	/// alongside, and the watch says nothing: everything passing up the fairway
	/// would otherwise have a closing approach on her.
	public static let ownSpeedFloorKnots: Double = 0.5

	/// How far past a limit a flagged target must go before she is cleared.
	/// Without it a vessel sitting on the threshold would flicker and re-notify
	/// on every refresh.
	public static let clearanceFactor: Double = 1.2

	/// One knot in metres per second.
	private static let metresPerSecondPerKnot = 1852.0 / 3600

	/// Below this, the two hold their separation and there is no closest point.
	private static let stillnessThreshold = 1e-6

	/// How close another vessel will come, and how long from now.
	public struct Approach: Equatable, Sendable {
		/// The distance at the closest point of approach, in metres.
		public var distanceMetres: Double
		/// Time to that point, in minutes. Always positive — an approach already
		/// past its closest point is not one.
		public var minutes: Double

		/// Creates an approach.
		/// - Parameters:
		///   - distanceMetres: Separation at the closest point.
		///   - minutes: Time from now to that point.
		public init(distanceMetres: Double, minutes: Double) {
			self.distanceMetres = distanceMetres
			self.minutes = minutes
		}
	}

	/// The closest point of approach between two vessels.
	///
	/// Worked on the local tangent plane, with the target's position taken as a
	/// range and bearing from us — accurate well past any range at which an AIS
	/// target matters. A target with no course or speed of her own is taken to
	/// be stationary, which is what she is if she is moored or aground, and is
	/// in any case the geometry our own way through the water dictates.
	///
	/// - Parameters:
	///   - ownShip: Our position.
	///   - courseDeg: Our course over ground, in degrees true.
	///   - speedKnots: Our speed over ground, in knots.
	///   - target: The other vessel's position.
	///   - targetCourseDeg: Her course in degrees true; zero when she reports none.
	///   - targetSpeedKnots: Her speed in knots; zero when she reports none.
	/// - Returns: The approach, or `nil` when the two hold their separation (no
	///   relative motion) or are already opening.
	public static func approach(
		from ownShip: Coordinate, courseDeg: Double, speedKnots: Double,
		to target: Coordinate, targetCourseDeg: Double, targetSpeedKnots: Double
	) -> Approach? {
		// `Coordinate.distance` answers in KILOMETRES; everything here is metres.
		let range = ownShip.distance(to: target) * 1000
		let bearing = Geo.initialBearing(from: ownShip, to: target) * .pi / 180
		// Relative position, east/north in metres.
		let rx = range * sin(bearing)
		let ry = range * cos(bearing)

		let ownCourse = courseDeg * .pi / 180
		let otherCourse = targetCourseDeg * .pi / 180
		// Relative velocity, east/north in metres per second.
		let vx = (targetSpeedKnots * sin(otherCourse) - speedKnots * sin(ownCourse)) * metresPerSecondPerKnot
		let vy = (targetSpeedKnots * cos(otherCourse) - speedKnots * cos(ownCourse)) * metresPerSecondPerKnot

		let closingSquared = vx * vx + vy * vy
		// Same course and speed: the separation never changes, so there is no
		// closest point to reach and nothing to announce.
		guard closingSquared > stillnessThreshold else { return nil }

		let seconds = -(rx * vx + ry * vy) / closingSquared
		// Already past her closest point, and opening.
		guard seconds > 0 else { return nil }

		let cx = rx + vx * seconds
		let cy = ry + vy * seconds
		return Approach(distanceMetres: (cx * cx + cy * cy).squareRoot(), minutes: seconds / 60)
	}
}
