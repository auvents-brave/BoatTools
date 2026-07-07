// The C ABI non-Swift hosts load. Rules of the surface: every function
// is `@_cdecl`, takes and returns C types only, and every returned string is a
// caller-owned UTF-8 buffer to release with `boattools_bridge_string_free`.

internal import BoatToolsKit
internal import Foundation

/// Copies a Swift string into a caller-owned, NUL-terminated C buffer —
/// released by ``boattools_bridge_string_free``. Allocation and release both go
/// through Swift's allocator (`strdup`/`free` would work too, but the POSIX
/// names are deprecated on Windows).
func cString(_ string: String) -> UnsafeMutablePointer<CChar>? {
	let bytes = string.utf8CString
	let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
	bytes.withUnsafeBufferPointer { source in
		buffer.initialize(from: source.baseAddress!, count: bytes.count)
	}
	return buffer
}

/// The bridge's own version tag, so the host can log what it loaded.
@_cdecl("boattools_bridge_version")
public func boattools_bridge_version() -> UnsafeMutablePointer<CChar>? {
	cString("BoatToolsBridge 0.1")
}

/// Releases a string returned by any `boattools_bridge_*` function.
@_cdecl("boattools_bridge_string_free")
public func boattools_bridge_string_free(_ pointer: UnsafeMutablePointer<CChar>?) {
	pointer?.deallocate()
}


/// What `boattools_bridge_parse_nmea` serialises for a decoded sentence.
private struct FramePayload: Encodable {
	struct Metric: Encodable {
		let name: String
		let value: Double
		let unit: String?
	}
	let talker: String
	let type: String
	let metrics: [Metric]
}

/// Parses one NMEA 0183 sentence — BoatToolsKit's `NMEA0183Parser` — and
/// returns a JSON object: `{"talker","type","metrics":[{name,value,unit}]}`,
/// or `{"error": "…"}` when the line is not a valid sentence.
/// - Returns: A JSON string to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_parse_nmea")
public func boattools_bridge_parse_nmea(
	_ sentence: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
	guard let sentence else { return cString(#"{"error":"null sentence"}"#) }
	let line = String(cString: sentence)
	switch NMEA0183Parser.parse(line) {
	case .some(.nmea0183(_, let talker, let type, let fields)):
		let metrics = (NMEA0183Parser.decode(fields) ?? []).map { metric in
			FramePayload.Metric(name: metric.name, value: metric.value, unit: metric.unit)
		}
		let payload = FramePayload(talker: talker, type: type, metrics: metrics)
		guard let data = try? JSONEncoder().encode(payload) else {
			return cString(#"{"error":"encoding failed"}"#)
		}
		return cString(String(decoding: data, as: UTF8.self))
	case .some(.invalidChecksum):
		return cString(#"{"error":"invalid checksum"}"#)
	default:
		return cString(#"{"error":"not an NMEA 0183 sentence"}"#)
	}
}
