// Device sensors for the platforms where Swift cannot read the hardware:
// the host (C#) reads its native APIs — Geolocator, compass, barometer — and
// pushes raw values through this C surface into BoatToolsKit's
// `ExternalSensorFeed`, which canonicalises them into the same metrics the
// Apple `DeviceSensors` emits. The feed then behaves like any connection:
// same handle, same `boattools_bridge_poll`, same close.

internal import BoatToolsKit
internal import Foundation
internal import Synchronization

/// The open device feeds, keyed by their connection handle.
private let deviceFeeds = Mutex<[Int64: ExternalSensorFeed]>([:])

/// Clears the feed for a closed handle (called by `boattools_bridge_close`).
func removeDeviceFeed(_ handle: Int64) {
	let feed = deviceFeeds.withLock { $0.removeValue(forKey: handle) }
	feed?.finish()
}

/// Opens a device-sensor feed: the host pushes readings with the
/// `boattools_bridge_push_*` functions and polls the canonical metrics like any
/// other connection.
/// - Returns: A handle (> 0) for push / `boattools_bridge_poll` /
///   `boattools_bridge_close`.
@_cdecl("boattools_bridge_open_device_feed")
public func boattools_bridge_open_device_feed() -> Int64 {
	let feed = ExternalSensorFeed()
	let metrics = feed.stream()
	let frames = AsyncThrowingStream<NMEAFrame, any Error> { continuation in
		let task = Task {
			for await metric in metrics {
				continuation.yield(.metric(metric))
			}
			continuation.finish()
		}
		continuation.onTermination = { @Sendable _ in
			task.cancel()
			feed.finish()
		}
	}
	let handle = registry.open(frames)
	deviceFeeds.withLock { $0[handle] = feed }
	return handle
}

/// Pushes a position fix. Pass NaN for the values the platform lacks
/// (altitude, speed in m/s, course in degrees).
@_cdecl("boattools_bridge_push_location")
public func boattools_bridge_push_location(
	_ handle: Int64,
	_ latitude: Double,
	_ longitude: Double,
	_ altitudeMetres: Double,
	_ speedMetresPerSecond: Double,
	_ courseDegrees: Double
) {
	guard let feed = deviceFeeds.withLock({ $0[handle] }) else { return }
	feed.pushLocation(
		latitude: latitude,
		longitude: longitude,
		altitudeMetres: altitudeMetres.isNaN ? nil : altitudeMetres,
		speedMetresPerSecond: speedMetresPerSecond.isNaN ? nil : speedMetresPerSecond,
		courseDegrees: courseDegrees.isNaN ? nil : courseDegrees
	)
}

/// Pushes a compass reading. Pass NaN for a heading the platform lacks.
@_cdecl("boattools_bridge_push_heading")
public func boattools_bridge_push_heading(
	_ handle: Int64,
	_ magneticDegrees: Double,
	_ trueDegrees: Double
) {
	guard let feed = deviceFeeds.withLock({ $0[handle] }) else { return }
	feed.pushHeading(
		magneticDegrees: magneticDegrees.isNaN ? nil : magneticDegrees,
		trueDegrees: trueDegrees.isNaN ? nil : trueDegrees
	)
}

/// Pushes a barometric pressure reading, in hectopascals.
@_cdecl("boattools_bridge_push_pressure")
public func boattools_bridge_push_pressure(_ handle: Int64, _ hectopascals: Double) {
	guard let feed = deviceFeeds.withLock({ $0[handle] }) else { return }
	feed.pushPressure(hectopascals: hectopascals)
}
