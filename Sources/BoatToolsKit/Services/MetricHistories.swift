public import Foundation

/// The curve histories kept for the metrics worth charting — wind, speed and
/// course over ground, depth, water temperature and pressure — keyed by metric
/// name, so every host smooths and retains them the same way.
public struct MetricHistories: Sendable {
	/// True wind speed — 5 s / 1 min two-tier history.
	public private(set) var windTWS = TieredHistory(isAngle: false)
	/// True wind direction — circular mean, 5 s / 1 min two-tier history.
	public private(set) var windTWD = TieredHistory(isAngle: true)
	/// Apparent wind speed — 5 s / 1 min two-tier history.
	public private(set) var windAWS = TieredHistory(isAngle: false)
	/// Apparent wind angle — circular mean, 5 s / 1 min two-tier history.
	public private(set) var windAWA = TieredHistory(isAngle: true)
	/// Speed over ground — 5 s / 1 min two-tier history.
	public private(set) var sog = TieredHistory(isAngle: false)
	/// Course over ground — circular mean, 5 s / 1 min two-tier history.
	public private(set) var cog = TieredHistory(isAngle: true)
	/// Water depth — 5 s / 1 min two-tier history.
	public private(set) var depth = TieredHistory(isAngle: false)
	/// Water temperature — 5 s / 1 min two-tier history.
	public private(set) var waterTemp = TieredHistory(isAngle: false)
	/// Atmospheric pressure — 30 min samples over 48 hours.
	public private(set) var pressure = PressureHistory()

	/// The metric names that have a history.
	public static let names: [String] = [
		"TWS", "TWD", "AWS", "AWA", "SOG", "COG", "depth", "temperature.water", "pressure.atmospheric",
	]

	/// Creates empty histories.
	public init() {}

	/// Records a raw value of `name` at `now`; names without a history are ignored.
	public mutating func add(name: String, value: Double, at now: Date) {
		switch name {
		case "TWS": windTWS.add(value, at: now)
		case "TWD": windTWD.add(value, at: now)
		case "AWS": windAWS.add(value, at: now)
		case "AWA": windAWA.add(value, at: now)
		case "SOG": sog.add(value, at: now)
		case "COG": cog.add(value, at: now)
		case "depth": depth.add(value, at: now)
		case "temperature.water": waterTemp.add(value, at: now)
		case "pressure.atmospheric": pressure.add(value, at: now)
		default: break
		}
	}

	/// Empties the history of `name`.
	public mutating func reset(name: String) {
		switch name {
		case "TWS": windTWS = TieredHistory(isAngle: false)
		case "TWD": windTWD = TieredHistory(isAngle: true)
		case "AWS": windAWS = TieredHistory(isAngle: false)
		case "AWA": windAWA = TieredHistory(isAngle: true)
		case "SOG": sog = TieredHistory(isAngle: false)
		case "COG": cog = TieredHistory(isAngle: true)
		case "depth": depth = TieredHistory(isAngle: false)
		case "temperature.water": waterTemp = TieredHistory(isAngle: false)
		case "pressure.atmospheric": pressure = PressureHistory()
		default: break
		}
	}

	/// The chart series of `name`, oldest first: the last hour at 5 s, or the
	/// last 48 hours at 30 min for pressure; empty for a name without history.
	public func series(name: String) -> [TimedSample] {
		switch name {
		case "TWS": windTWS.recent.chronological
		case "TWD": windTWD.recent.chronological
		case "AWS": windAWS.recent.chronological
		case "AWA": windAWA.recent.chronological
		case "SOG": sog.recent.chronological
		case "COG": cog.recent.chronological
		case "depth": depth.recent.chronological
		case "temperature.water": waterTemp.recent.chronological
		case "pressure.atmospheric": pressure.samples.chronological
		default: []
		}
	}
}
