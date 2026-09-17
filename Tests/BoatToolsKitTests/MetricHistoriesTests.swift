import Foundation
import Testing

@testable import BoatToolsKit

@Test func `Histories keep a 5-second series per charted metric`() {
	var histories = MetricHistories()
	let start = Date(timeIntervalSince1970: 1_800_000_000)
	for second in stride(from: 0, to: 20, by: 1) {
		histories.add(name: "SOG", value: Double(second), at: start.addingTimeInterval(Double(second)))
	}
	histories.add(name: "not.charted", value: 1, at: start)

	let series = histories.series(name: "SOG")
	#expect(series.count == 4)
	#expect(series.map(\.timestamp) == series.map(\.timestamp).sorted())
	#expect(histories.series(name: "not.charted").isEmpty)
}

@Test func `Angles are averaged around the circle`() {
	var histories = MetricHistories()
	let start = Date(timeIntervalSince1970: 1_800_000_000)
	histories.add(name: "COG", value: 350, at: start)
	histories.add(name: "COG", value: 10, at: start.addingTimeInterval(1))
	histories.add(name: "COG", value: 10, at: start.addingTimeInterval(5))

	let last = try? #require(histories.series(name: "COG").last)
	#expect(last.map { $0.value < 20 || $0.value > 340 } == true)
}

@Test func `Pressure is kept at 30-minute resolution and reset clears it`() {
	var histories = MetricHistories()
	let start = Date(timeIntervalSince1970: 1_800_000_000)
	for minute in stride(from: 0, through: 90, by: 10) {
		histories.add(name: "pressure.atmospheric", value: 1013, at: start.addingTimeInterval(Double(minute) * 60))
	}
	#expect(histories.series(name: "pressure.atmospheric").count == 4)

	histories.reset(name: "pressure.atmospheric")
	#expect(histories.series(name: "pressure.atmospheric").isEmpty)
}
