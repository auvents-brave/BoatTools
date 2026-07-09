public import Foundation

/// Device sensors supplied by the **host platform** — for the platforms where
/// Swift cannot read the hardware directly (Android, Windows). The host reads
/// its native APIs (Geolocator, sensor manager, …) and pushes raw values here;
/// the feed turns them into the same canonical metrics ``DeviceSensors`` emits
/// on Apple platforms — `lat`/`lon`/`SOG`/`COG`/`altitude`, `HDG.magnetic`/
/// `HDG.true`/`magneticVariation`, `pressure.atmospheric` — so everything
/// downstream stays platform-blind.
///
/// Thread-safe: push from any thread; one active ``stream()`` consumer.
public final class ExternalSensorFeed: @unchecked Sendable {
	// @unchecked: the single mutable member (`continuation`) is only ever
	// touched under `lock` — the type upholds Sendable by construction.
	private let lock = NSLock()
	private var continuation: AsyncStream<BoatMetric>.Continuation?

	/// Creates an empty feed; call ``stream()`` to start consuming.
	public init() {}

	/// The canonical metric stream. Creating a new stream replaces (and
	/// finishes) the previous one.
	public func stream() -> AsyncStream<BoatMetric> {
		AsyncStream { continuation in
			lock.lock()
			self.continuation?.finish()
			self.continuation = continuation
			lock.unlock()
		}
	}

	/// Pushes a position fix.
	/// - Parameters:
	///   - latitude: Degrees, positive north.
	///   - longitude: Degrees, positive east.
	///   - altitudeMetres: Metres above sea level, when known.
	///   - speedMetresPerSecond: Ground speed, when known (converted to knots).
	///   - courseDegrees: Course over ground, when known.
	///   - timestamp: The fix time. Defaults to now.
	public func pushLocation(
		latitude: Double,
		longitude: Double,
		altitudeMetres: Double? = nil,
		speedMetresPerSecond: Double? = nil,
		courseDegrees: Double? = nil,
		timestamp: Date = Date()
	) {
		yield(BoatMetric(name: "lat", value: latitude, unit: "°", timestamp: timestamp))
		yield(BoatMetric(name: "lon", value: longitude, unit: "°", timestamp: timestamp))
		if let altitudeMetres {
			yield(BoatMetric(name: "altitude", value: altitudeMetres, unit: "m", timestamp: timestamp))
		}
		if let speedMetresPerSecond, speedMetresPerSecond >= 0 {
			yield(
				BoatMetric(
					name: "SOG", value: speedMetresPerSecond * 1.94384, unit: "kn", timestamp: timestamp))
		}
		if let courseDegrees, courseDegrees >= 0 {
			yield(BoatMetric(name: "COG", value: courseDegrees, unit: "°", timestamp: timestamp))
		}
	}

	/// Pushes a compass reading. Mirrors the Apple path: when both headings are
	/// present, their difference is yielded as the local magnetic variation
	/// (positive east) — sound here because both come from the same sensor.
	public func pushHeading(
		magneticDegrees: Double? = nil,
		trueDegrees: Double? = nil,
		timestamp: Date = Date()
	) {
		if let magneticDegrees {
			yield(BoatMetric(name: "HDG.magnetic", value: magneticDegrees, unit: "°", timestamp: timestamp))
		}
		if let trueDegrees, trueDegrees >= 0 {
			yield(BoatMetric(name: "HDG.true", value: trueDegrees, unit: "°", timestamp: timestamp))
			if let magneticDegrees {
				var variation = trueDegrees - magneticDegrees
				if variation > 180 { variation -= 360 } else if variation < -180 { variation += 360 }
				yield(
					BoatMetric(name: "magneticVariation", value: variation, unit: "°", timestamp: timestamp))
			}
		}
	}

	/// Pushes a barometric pressure reading (canonical hPa).
	public func pushPressure(hectopascals: Double, timestamp: Date = Date()) {
		yield(
			BoatMetric(
				name: "pressure.atmospheric", value: hectopascals, unit: "hPa", timestamp: timestamp))
	}

	/// Ends the stream.
	public func finish() {
		lock.lock()
		continuation?.finish()
		continuation = nil
		lock.unlock()
	}

	private func yield(_ metric: BoatMetric) {
		lock.lock()
		continuation?.yield(metric)
		lock.unlock()
	}
}
