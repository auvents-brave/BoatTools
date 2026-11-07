public import Foundation

/// The navigation values BoatTools works out for itself: the leeway a two-axis
/// log measures outright, the true wind behind a masthead unit that reports
/// only the apparent, the tidal stream, and both velocities made good.
///
/// Everything produced here is published under a name carrying ``suffix``,
/// never under the canonical name a source would use, so a computed figure can
/// neither be mistaken for a measured one nor mask it. ``BoatMetricStore``
/// rebuilds them all from scratch on every flush.
///
/// The angle conventions are the library's: directions are degrees true over
/// 0…360, angles off the bow are signed positive to starboard, and the leeway
/// is the angle from the heading to the track through the water — so
/// `waterTrack = heading + leeway`.
public enum DerivedNavigation {

	/// The suffix every derived metric name carries.
	public static let suffix = ".computed"

	/// Every metric name this type can produce.
	public static let names: [String] = [
		"TWS" + suffix, "TWD" + suffix, "TWA" + suffix,
		"navigation.leeway" + suffix,
		"navigation.currentSet" + suffix, "navigation.currentDrift" + suffix,
		"navigation.vmgWind" + suffix, "navigation.vmgWindGround" + suffix,
	]

	/// Below this speed the boat is not making way, and the angles derived from
	/// her motion are all noise.
	static let speedFloor = 0.5

	// MARK: Leeway

	/// The leeway a two-axis log measures outright: the angle from the boat's
	/// fore-and-aft line to her track through the water, positive to starboard.
	///
	/// This is a measurement, not a model. Only Doppler and ultrasonic logs
	/// report the athwartships component, but where they do there is nothing
	/// left to estimate.
	///
	/// - Parameters:
	///   - transverseWater: Athwartships water speed in knots, positive to starboard.
	///   - speedThroughWater: Longitudinal water speed in knots.
	/// - Returns: The angle in degrees, or `nil` while the boat is not making way.
	public static func leeway(transverseWater: Double, speedThroughWater: Double) -> Double? {
		guard speedThroughWater >= speedFloor else { return nil }
		return atan2(transverseWater, speedThroughWater) * 180 / .pi
	}

	// MARK: True wind

	/// The true wind behind a masthead unit that reports only the apparent.
	///
	/// The result is referenced to whichever track and speed are passed in:
	/// the boat's track through the water gives the wind over the water, which
	/// is what the sails feel and what a polar is drawn against; her track over
	/// the ground gives the wind over the ground, and the two differ by the
	/// tidal stream.
	///
	/// - Parameters:
	///   - apparentSpeed: Apparent wind speed in knots.
	///   - apparentAngle: Apparent wind angle off the bow — signed or 0…360, either reads alike.
	///   - heading: The boat's heading in degrees true: the axis the vane measures from.
	///   - track: The direction she is actually travelling in, degrees true.
	///   - speed: Her speed along that track, in knots.
	/// - Returns: The wind's speed in knots and the direction it blows from, or
	///   `nil` while she is not moving along that track.
	public static func trueWind(
		apparentSpeed: Double, apparentAngle: Double, heading: Double, track: Double, speed: Double
	) -> (speed: Double, direction: Double)? {
		guard speed >= speedFloor, apparentSpeed >= 0 else { return nil }
		// The vane measures off the bow, but the vectors add around the track.
		let axisAngle = signed(apparentAngle + heading - track) * .pi / 180
		let east = apparentSpeed * sin(axisAngle)
		let north = apparentSpeed * cos(axisAngle) - speed
		return (
			speed: (east * east + north * north).squareRoot(),
			direction: normalise(track + atan2(east, north) * 180 / .pi)
		)
	}

	// MARK: Tidal stream

	/// The tidal stream, as the difference between the boat's track over the
	/// ground and her track through the water.
	///
	/// There is no other way to measure it: no instrument states a current
	/// unless something upstream has already done this subtraction. Two
	/// caveats come with it. The speed through the water is only as good as the
	/// log's calibration, and a heading error of 5° at 6 knots is worth half a
	/// knot of phantom stream — so the result wants filtering, which
	/// ``CurrentFilter`` does. And when the leeway is unknown the water track
	/// is taken as the heading, which hands the computed stream the whole of
	/// the leeway: `STW · sin(leeway)`, a third of a knot at 6 knots and 3°.
	///
	/// - Parameters:
	///   - courseOverGround: Degrees true.
	///   - speedOverGround: Knots.
	///   - waterTrack: The boat's track through the water, degrees true — her heading plus her leeway.
	///   - speedThroughWater: Knots.
	/// - Returns: The stream's east and north components in knots, for the
	///   caller to filter before turning them into a set and a drift.
	public static func streamComponents(
		courseOverGround: Double, speedOverGround: Double,
		waterTrack: Double, speedThroughWater: Double
	) -> (east: Double, north: Double) {
		let ground = courseOverGround * .pi / 180
		let water = waterTrack * .pi / 180
		return (
			east: speedOverGround * sin(ground) - speedThroughWater * sin(water),
			north: speedOverGround * cos(ground) - speedThroughWater * cos(water)
		)
	}

	/// A set and a drift from stream components: the direction the water flows
	/// *towards* — the convention for a current, the opposite of the wind's —
	/// and its speed in knots.
	public static func setAndDrift(east: Double, north: Double) -> (set: Double, drift: Double) {
		(
			set: normalise(atan2(east, north) * 180 / .pi),
			drift: (east * east + north * north).squareRoot()
		)
	}

	// MARK: Velocity made good

	/// The component of a speed along the wind axis: the velocity made good.
	/// Positive to windward and negative on a run, so the sign alone says which.
	///
	/// - Parameters:
	///   - speed: The boat's speed along `track`, in knots.
	///   - track: The direction she is travelling in, degrees true.
	///   - windDirection: The direction the wind blows from, degrees true, in
	///     the same reference as `track`.
	public static func velocityMadeGood(speed: Double, track: Double, windDirection: Double) -> Double {
		speed * cos(signed(windDirection - track) * .pi / 180)
	}

	// MARK: Angles

	/// `degrees` wrapped to 0…<360.
	public static func normalise(_ degrees: Double) -> Double {
		let wrapped = degrees.truncatingRemainder(dividingBy: 360)
		return wrapped < 0 ? wrapped + 360 : wrapped
	}

	/// `degrees` wrapped to −180…<180, so a 0–360 convention and a signed one
	/// read alike.
	public static func signed(_ degrees: Double) -> Double {
		let wrapped = normalise(degrees)
		return wrapped > 180 ? wrapped - 360 : wrapped
	}
}

// MARK: - CurrentFilter

/// A low-pass filter for the computed tidal stream.
///
/// The stream is smoothed as a vector, never as an angle: the arithmetic mean
/// of a set of 355° and one of 5° is 180°, the reciprocal. An exponential
/// filter on the east and north components cannot fail that way and keeps no
/// history.
struct CurrentFilter: Sendable {

	/// How long the filter takes to cover about 63% of a step change.
	let timeConstant: TimeInterval

	private var east = 0.0
	private var north = 0.0
	private var updated: Date?

	/// Creates a filter.
	/// - Parameter timeConstant: Seconds. A minute rides out GPS and log noise
	///   without lagging a real change of stream, which turns over hours.
	init(timeConstant: TimeInterval = 60) {
		self.timeConstant = timeConstant
	}

	/// Folds a new sample in and returns the filtered stream. The first sample
	/// is taken as it stands, so a fresh connection shows a stream at once.
	mutating func update(
		east sampleEast: Double, north sampleNorth: Double, at now: Date
	) -> (set: Double, drift: Double) {
		if let updated {
			let dt = max(0, now.timeIntervalSince(updated))
			let alpha = dt / (timeConstant + dt)
			east += (sampleEast - east) * alpha
			north += (sampleNorth - north) * alpha
		} else {
			east = sampleEast
			north = sampleNorth
		}
		updated = now
		return DerivedNavigation.setAndDrift(east: east, north: north)
	}

	/// Forgets everything, so a new source never inherits the last one's stream.
	mutating func reset() {
		east = 0
		north = 0
		updated = nil
	}
}
