import Foundation
import Testing

@testable import BoatToolsBridge

@Suite("Bridge histories")
struct HistoriesTests {
	private func series(_ handle: Int64, _ name: String) throws -> [[Double]] {
		let pointer = try #require(name.withCString { boattools_bridge_history_series(handle, $0) })
		defer { boattools_bridge_string_free(pointer) }
		return try JSONDecoder().decode([[Double]].self, from: Data(String(cString: pointer).utf8))
	}

	@Test("Values fed in come back as a smoothed series")
	func feedAndRead() throws {
		let handle = boattools_bridge_history_open()
		defer { boattools_bridge_history_close(handle) }
		for second in 0..<12 {
			"AWS".withCString { boattools_bridge_history_add(handle, $0, 10, 1_800_000_000 + Double(second)) }
		}

		let points = try series(handle, "AWS")
		#expect(points.count == 3)
		#expect(points.allSatisfy { $0.count == 2 && $0[1] == 10 })
		#expect(try series(handle, "rudder").isEmpty)
	}

	@Test("A closed or unknown handle gives an empty series")
	func closedHandle() throws {
		let handle = boattools_bridge_history_open()
		boattools_bridge_history_close(handle)
		"SOG".withCString { boattools_bridge_history_add(handle, $0, 5, 1_800_000_000) }
		#expect(try series(handle, "SOG").isEmpty)
	}
}
