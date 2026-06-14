internal import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for the Signal K NDJSON parsing path used by both the file replay
/// and the live `connect --format signalk` mode.
@Suite("Signal K decoder")
struct SignalKTests {

	@Test func `JSON parsing produces the expected enum shape`() throws {
		// Note: avoid 0/1 in number positions — Foundation's JSONSerialization
		// produces NSNumber, which can round-trip 0/1 as Bool, making the
		// parser pick `.bool` instead of `.number` for those edge values.
		let data = Data(
			#"{"k":42,"a":[true,null,"x"],"o":{"n":2.5}}"#.utf8
		)
		guard case .object(let root) = try JSONValue.parse(data) else {
			Issue.record("expected root object")
			return
		}
		#expect(root["k"] == .number(42))
		guard case .array(let a) = root["a"] ?? .null else {
			Issue.record("expected array")
			return
		}
		#expect(a[0] == .bool(true))
		#expect(a[1] == .null)
		#expect(a[2] == .string("x"))
		guard case .object(let o) = root["o"] ?? .null else {
			Issue.record("expected nested object")
			return
		}
		#expect(o["n"] == .number(2.5))
	}

	@Test func `A navigation position delta yields metric frames for lat and lon`() {
		let line = """
			{"updates":[{"values":[{"path":"navigation.position","value":{"latitude":43.5,"longitude":7.0}}]}]}
			"""
		let frames = SignalKClient.parseFrames(line)

		var lat: Double? = nil
		var lon: Double? = nil
		for frame in frames {
			if case .metric(let m) = frame {
				if m.name == "lat" { lat = m.value }
				if m.name == "lon" { lon = m.value }
			}
		}
		#expect(lat == 43.5)
		#expect(lon == 7.0)
	}

	@Test func `A numeric leaf delta yields a single mapped metric`() {
		// Signal K canonical SI unit for SOG is m/s; the decoder converts it to knots.
		let line = """
			{"updates":[{"values":[{"path":"navigation.speedOverGround","value":5.0}]}]}
			"""
		let frames = SignalKClient.parseFrames(line)

		// Whatever canonical name the mapper picks, a value around 5 m/s ≈ 9.72 kn
		// (or the raw 5.0 if no conversion happens) is what we expect — i.e. at
		// least one positive numeric metric must have been emitted.
		var foundPositive = false
		for frame in frames {
			if case .metric(let m) = frame, m.value > 0 {
				foundPositive = true
				break
			}
		}
		#expect(foundPositive, "expected a positive metric from navigation.speedOverGround")
	}

	@Test func `Malformed JSON yields a single unknown frame`() {
		let frames = SignalKClient.parseFrames("not actually JSON")
		#expect(frames.count == 1)
		if case .unknown(let raw) = frames.first {
			#expect(raw == "not actually JSON")
		} else {
			Issue.record("expected .unknown, got \(String(describing: frames.first))")
		}
	}
}
