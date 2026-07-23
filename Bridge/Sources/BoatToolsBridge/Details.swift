// AIS target details, vessel photographs and GMDSS high-seas forecasts for the
// C ABI — the data behind the chart's target panel and context menu, sourced
// from BoatToolsKit exactly like the Swift app.

internal import BoatToolsKit
internal import Dispatch
internal import Foundation
internal import Synchronization

// MARK: - AIS target detail

/// What `boattools_bridge_ais_detail` returns — every field the Swift app's
/// vessel panel shows, labels already rendered by BoatToolsKit.
private struct AisDetailPayload: Encodable {
	let found: Bool
	var mmsi = 0
	var kind = "vessel"
	var stale = false
	var name: String?
	var country: String?
	var flag: String?
	var callsign: String?
	var shipType: String?
	var imo: Int?
	var lat: Double?
	var lon: Double?
	var accuracy = false
	var raim = false
	var sog: Double?
	var cog: Double?
	var heading: Int?
	var rateOfTurn: Int?
	var maneuver: String?
	var status: String?
	var destination: String?
	var etaMonth: Int?
	var etaDay: Int?
	var etaHour: Int?
	var etaMinute: Int?
	var draught: Double?
	var length: Double?
	var beam: Double?
}

/// The full record of one AIS target held by a connection, for the detail
/// panel: identity (with country and flag from the MMSI), position quality,
/// motion, and the type-5 voyage data (destination, ETA, draught).
/// - Returns: JSON to release with `boattools_bridge_string_free`;
///   `{"found":false}` when the handle or MMSI is unknown.
@_cdecl("boattools_bridge_ais_detail")
public func boattools_bridge_ais_detail(_ handle: Int64, _ mmsi: Int64) -> UnsafeMutablePointer<CChar>? {
	guard let connection = registry.connection(handle),
		let entry = connection.target(mmsi: Int(mmsi))
	else {
		return cString(#"{"found":false}"#)
	}
	let t = entry.target
	var payload = AisDetailPayload(found: true)
	payload.mmsi = t.mmsi
	payload.kind = BridgeConnection.kind(for: t)
	payload.stale = Date().timeIntervalSince(entry.seen) > 600
	payload.name = t.shipName
	payload.country = t.country?.name
	payload.flag = t.country?.flag
	payload.callsign = t.callsign
	payload.shipType = t.shipType?.label
	payload.imo = t.imoNumber
	payload.lat = t.latitude
	payload.lon = t.longitude
	payload.accuracy = t.positionAccuracy
	payload.raim = t.raim
	payload.sog = t.speedOverGround
	payload.cog = t.courseOverGround
	payload.heading = t.trueHeading
	payload.rateOfTurn = t.rateOfTurn
	// The Swift app omits manoeuvre 0 ("not available"); mirror that.
	if let maneuver = t.maneuverIndicator, maneuver.rawValue != 0 {
		payload.maneuver = maneuver.label
	}
	payload.status = t.navigationStatus?.label
	payload.destination = t.destination
	payload.etaMonth = t.eta?.month
	payload.etaDay = t.eta?.day
	payload.etaHour = t.eta?.hour
	payload.etaMinute = t.eta?.minute
	payload.draught = t.draught
	payload.length = t.length
	payload.beam = t.beam
	guard let data = try? JSONEncoder().encode(payload) else {
		return cString(#"{"found":false}"#)
	}
	return cString(String(decoding: data, as: UTF8.self))
}

// MARK: - Shared plumbing

/// The portable HTTP fetch the services are given — BoatToolsKit's transport
/// works on every bridge platform (NIO on macOS/Linux/Android, libcurl on
/// Windows), where `URLSession` does not.
private let portableFetch: GMDSSForecastService.Fetch = { url in
	let transport = NetworkStack.makeHTTPTransport()
	do {
		let response = try await transport.execute(HTTPRequest(url: url.absoluteString))
		try? await transport.shutdown()
		return (Data(response.body), Int(response.status))
	} catch {
		try? await transport.shutdown()
		throw error
	}
}

/// Runs an async operation to completion on the calling C thread — safe
/// because P/Invoke callers are .NET worker threads, never part of Swift
/// concurrency's cooperative pool.
func awaitBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
	let semaphore = DispatchSemaphore(value: 0)
	let box = Mutex<T?>(nil)
	Task {
		let value = await operation()
		box.withLock { $0 = value }
		semaphore.signal()
	}
	semaphore.wait()
	return box.withLock { $0! }
}

// MARK: - Vessel photographs

/// What `boattools_bridge_vessel_photo` returns.
private struct VesselPhotoPayload: Encodable {
	let found: Bool
	var image: String?
	var page: String?
	var name: String?
	var credit: String?
}

/// One service for the whole process, so its cache — hits *and* misses — is
/// shared by every lookup the host makes.
private let vesselPhotos = VesselPhotoService(fetch: portableFetch)

/// A freely-licensed photograph of the vessel carrying an IMO number, from
/// Wikimedia Commons. Most vessels have none — that is a `found:false`, not an
/// error. Blocks on the network — call from a background thread.
///
/// The photographs are Creative Commons: `credit` **must** be shown wherever
/// `image` is, and `page` carries the full licence terms.
/// - Returns: JSON `{"found","image","page","name","credit"}` to release with
///   `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_vessel_photo")
public func boattools_bridge_vessel_photo(_ imo: Int64, _ width: Int32) -> UnsafeMutablePointer<CChar>? {
	let payload: VesselPhotoPayload = awaitBlocking {
		guard let photo = await vesselPhotos.photo(imo: Int(imo), width: Int(width)) else {
			return VesselPhotoPayload(found: false)
		}
		return VesselPhotoPayload(
			found: true,
			image: photo.imageURL.absoluteString,
			page: photo.descriptionURL.absoluteString,
			name: photo.vesselName,
			credit: photo.credit)
	}
	guard let data = try? JSONEncoder().encode(payload) else {
		return cString(#"{"found":false}"#)
	}
	return cString(String(decoding: data, as: UTF8.self))
}

// MARK: - GMDSS forecasts

/// What the GMDSS functions return.
private struct GmdssPayload: Encodable {
	let ok: Bool
	var error: String?
	var metarea = 0
	var title = ""
	var issued = ""
	var bulletins: [Bulletin] = []

	struct Bulletin: Encodable {
		let label: String
		let text: String
	}
}

/// The METAREA (1…21) whose box contains a position, or 0 when the position
/// falls outside every known area. Instant — no network.
@_cdecl("boattools_bridge_gmdss_metarea")
public func boattools_bridge_gmdss_metarea(_ latitude: Double, _ longitude: Double) -> Int32 {
	Int32(GMDSSForecastService.metarea(latitude: latitude, longitude: longitude)?.number ?? 0)
}

/// Every GMDSS high-seas bulletin for a METAREA. Blocks on the network —
/// call from a background thread.
/// - Returns: JSON `{"ok","error","metarea","title","issued","bulletins":
///   [{label,text}]}` to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_gmdss_forecast")
public func boattools_bridge_gmdss_forecast(_ metarea: Int32) -> UnsafeMutablePointer<CChar>? {
	encodeGmdss { try await GMDSSForecastService(fetch: portableFetch).forecast(metarea: Int(metarea)) }
}

/// The GMDSS bulletin(s) covering a position — the METAREA resolved and the
/// directional sub-bulletin picked, as in the Swift app's "forecast for this
/// zone". Blocks on the network — call from a background thread.
/// - Returns: The same JSON shape as `boattools_bridge_gmdss_forecast`.
@_cdecl("boattools_bridge_gmdss_forecast_at")
public func boattools_bridge_gmdss_forecast_at(
	_ latitude: Double, _ longitude: Double
) -> UnsafeMutablePointer<CChar>? {
	encodeGmdss {
		try await GMDSSForecastService(fetch: portableFetch)
			.forecast(latitude: latitude, longitude: longitude)
	}
}

private func encodeGmdss(
	_ operation: @escaping @Sendable () async throws -> GMDSSForecast
) -> UnsafeMutablePointer<CChar>? {
	let payload: GmdssPayload = awaitBlocking {
		do {
			let forecast = try await operation()
			return GmdssPayload(
				ok: true, metarea: forecast.metarea, title: forecast.title, issued: forecast.issued,
				bulletins: forecast.bulletins.map { .init(label: $0.label, text: $0.text) })
		} catch {
			return GmdssPayload(ok: false, error: "\(error)")
		}
	}
	guard let data = try? JSONEncoder().encode(payload) else {
		return cString(#"{"ok":false,"error":"encoding failed"}"#)
	}
	return cString(String(decoding: data, as: UTF8.self))
}
