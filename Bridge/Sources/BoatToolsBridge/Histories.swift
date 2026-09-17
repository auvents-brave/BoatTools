// Curve histories for the C ABI: the host feeds the metrics it merged from
// its connections, and reads back the series its charts draw — smoothed and
// retained by BoatToolsKit's `MetricHistories`, exactly as in the Swift app.

internal import BoatToolsKit
internal import Foundation
internal import Synchronization

/// The open history sets, by handle.
private let histories = Mutex<(next: Int64, sets: [Int64: MetricHistories])>((1, [:]))

/// Opens an empty set of histories.
/// - Returns: A handle for the other `boattools_bridge_history_*` calls.
@_cdecl("boattools_bridge_history_open")
public func boattools_bridge_history_open() -> Int64 {
	histories.withLock { state in
		let handle = state.next
		state.next += 1
		state.sets[handle] = MetricHistories()
		return handle
	}
}

/// Records a metric value; a name without history, or an unknown handle, is ignored.
/// - Parameters:
///   - handle: From `boattools_bridge_history_open`.
///   - name: The metric name, UTF-8.
///   - value: In the metric's canonical unit.
///   - unixSeconds: When the value was read.
@_cdecl("boattools_bridge_history_add")
public func boattools_bridge_history_add(
	_ handle: Int64, _ name: UnsafePointer<CChar>?, _ value: Double, _ unixSeconds: Double
) {
	guard let name else { return }
	let metric = String(cString: name)
	histories.withLock { state in
		state.sets[handle]?.add(name: metric, value: value, at: Date(timeIntervalSince1970: unixSeconds))
	}
}

/// The series of one metric, oldest first.
/// - Returns: JSON `[[unixSeconds, value], …]`, empty for a name without
///   history or an unknown handle, to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_history_series")
public func boattools_bridge_history_series(
	_ handle: Int64, _ name: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
	guard let name else { return cString("[]") }
	let metric = String(cString: name)
	let samples = histories.withLock { $0.sets[handle]?.series(name: metric) ?? [] }
	let pairs = samples.map { [$0.timestamp.timeIntervalSince1970, $0.value] }
	guard let data = try? JSONEncoder().encode(pairs) else { return cString("[]") }
	return cString(String(decoding: data, as: UTF8.self))
}

/// Closes a set of histories.
@_cdecl("boattools_bridge_history_close")
public func boattools_bridge_history_close(_ handle: Int64) {
	_ = histories.withLock { $0.sets.removeValue(forKey: handle) }
}
