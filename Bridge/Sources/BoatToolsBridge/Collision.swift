import BoatToolsKit
public import Stheno

/// Works out how close two vessels will come, and when.
///
/// The arithmetic lives in `BoatToolsKit.CollisionGeometry`; this only carries
/// it across the C boundary, so the companion app runs the same watch as the
/// Apple one instead of a second implementation of its own.
///
/// - Parameters:
///   - ownLatitude: our latitude in degrees.
///   - ownLongitude: our longitude in degrees.
///   - ourCourseDegrees: our course over ground, degrees true.
///   - ourSpeedKnots: our speed over ground, in knots.
///   - targetLatitude: her latitude in degrees.
///   - targetLongitude: her longitude in degrees.
///   - targetCourseDegrees: her course; pass NaN when she reports none.
///   - targetSpeedKnots: her speed; pass NaN when she reports none.
///   - outDistanceMetres: filled with the separation at the closest point.
///   - outMinutes: filled with the time from now to that point.
/// - Returns: `false` when there is no approach to speak of — the two hold
///   their separation, or are already opening — in which case the outputs are
///   left untouched.
@_cdecl("boattools_bridge_collision_approach")
public func boattools_bridge_collision_approach(
	_ ownLatitude: Double,
	_ ownLongitude: Double,
	_ ourCourseDegrees: Double,
	_ ourSpeedKnots: Double,
	_ targetLatitude: Double,
	_ targetLongitude: Double,
	_ targetCourseDegrees: Double,
	_ targetSpeedKnots: Double,
	_ outDistanceMetres: UnsafeMutablePointer<Double>?,
	_ outMinutes: UnsafeMutablePointer<Double>?
) -> Bool {
	guard
		let approach = CollisionGeometry.approach(
			from: Coordinate(latitude: ownLatitude, longitude: ownLongitude),
			courseDeg: ourCourseDegrees,
			speedKnots: ourSpeedKnots,
			to: Coordinate(latitude: targetLatitude, longitude: targetLongitude),
			targetCourseDeg: targetCourseDegrees.isNaN ? 0 : targetCourseDegrees,
			targetSpeedKnots: targetSpeedKnots.isNaN ? 0 : targetSpeedKnots)
	else { return false }
	outDistanceMetres?.pointee = approach.distanceMetres
	outMinutes?.pointee = approach.minutes
	return true
}

/// How far ahead an approach is worth raising, in minutes.
@_cdecl("boattools_bridge_collision_horizon_minutes")
public func boattools_bridge_collision_horizon_minutes() -> Double {
	CollisionGeometry.horizonMinutes
}

/// Below this speed in knots a vessel is taken to be at anchor or alongside,
/// and the watch says nothing.
@_cdecl("boattools_bridge_collision_own_speed_floor_knots")
public func boattools_bridge_collision_own_speed_floor_knots() -> Double {
	CollisionGeometry.ownSpeedFloorKnots
}

/// How far past a limit a flagged target must go before she is cleared.
@_cdecl("boattools_bridge_collision_clearance_factor")
public func boattools_bridge_collision_clearance_factor() -> Double {
	CollisionGeometry.clearanceFactor
}
