import Foundation
import Testing

@testable import BoatToolsKit

/// Builds the bytes of an atlas file by the same rules as
/// `Scripts/fes-currents-to-atlas.py`, so that the reader can be exercised
/// without the real atlas — and so that the two writers can be held against
/// each other.
private struct AtlasFile {
	var latitudeMinimum = 48.0
	var longitudeMinimum = -6.0
	var latitudeStep = 0.25
	var longitudeStep = 0.25
	var rows = 3
	var columns = 4
	var names = ["M2"]
	var mask: [UInt8] = []
	/// Per constituent, four planes in metres per second: eastward in phase,
	/// eastward in quadrature, then the same two northward.
	var planes: [[[Double]]] = []
	var version: UInt16 = 1

	private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
		withUnsafeBytes(of: value.littleEndian) { Data($0) }
	}

	var data: Data {
		var out = Data("BTSA".utf8)
		out.append(littleEndian(version))
		out.append(littleEndian(UInt16(0)))
		for value in [latitudeMinimum, longitudeMinimum, latitudeStep, longitudeStep] {
			out.append(littleEndian(value.bitPattern))
		}
		out.append(littleEndian(UInt32(rows)))
		out.append(littleEndian(UInt32(columns)))
		out.append(littleEndian(UInt32(names.count)))
		out.append(littleEndian(UInt32(0)))
		for name in names {
			var bytes = Array(name.utf8)
			bytes += Array(repeating: 0, count: 8 - bytes.count)
			out.append(contentsOf: bytes)
		}
		out.append(contentsOf: mask)
		for plane in planes {
			for values in plane {
				for value in values {
					// Half-to-even, as the converter's own rounding is.
					let step = (value / TidalStreamAtlas.Layout.componentStep).rounded(
						.toNearestOrEven)
					out.append(littleEndian(Int16(clamping: Int(step)).littleEndian))
				}
			}
		}
		return out
	}

	var atlas: TidalStreamAtlas {
		get throws { try TidalStreamAtlas(data: data) }
	}
}

/// One constituent whose eastward and northward components are given outright,
/// over a grid that is all water.
private func atlas(
	_ name: String, rows: Int = 2, columns: Int = 2,
	latitudeStep: Double = 1, longitudeStep: Double = 1,
	eastInPhase: [Double], eastQuadrature: [Double]? = nil,
	northInPhase: [Double]? = nil, northQuadrature: [Double]? = nil,
	mask: [UInt8]? = nil
) throws -> TidalStreamAtlas {
	let nodes = rows * columns
	let zeros = [Double](repeating: 0, count: nodes)
	var file = AtlasFile()
	file.rows = rows
	file.columns = columns
	file.latitudeStep = latitudeStep
	file.longitudeStep = longitudeStep
	file.names = [name]
	file.mask = mask ?? [UInt8](repeating: 1, count: nodes)
	file.planes = [
		[eastInPhase, eastQuadrature ?? zeros, northInPhase ?? zeros, northQuadrature ?? zeros]
	]
	return try file.atlas
}

/// An instant, from a UTC calendar date.
private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
	var components = DateComponents()
	components.year = year
	components.month = month
	components.day = day
	components.hour = hour
	components.minute = minute
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
	return calendar.date(from: components) ?? .distantPast
}

/// Tests the atlas file format, the interpolation over its grid and the
/// prediction built on top of them.
@Suite("Tidal stream atlas")
struct TidalStreamAtlasTests {

	private let knots = TidalStreamAtlas.knotsPerMetrePerSecond

	// MARK: The file

	@Test func `the reader and the converter agree on the format`() throws {
		// `Scripts/fes-currents-to-atlas.py --selftest` wrote this file. The
		// same rules, applied here, must produce the same bytes: that is what
		// keeps a format written in Python readable by a reader in Swift.
		let url = try #require(
			Bundle.module.url(forResource: "tidal-atlas-fixture", withExtension: "btsa"))
		let golden = try Data(contentsOf: url)

		var file = AtlasFile()
		file.names = ["M2", "S2", "Msqm"]
		let nodes = file.rows * file.columns
		file.mask = [UInt8](repeating: 1, count: nodes)
		file.mask[0] = 0
		file.planes = (0..<3).map { index in
			let ashore = { (node: Int) in file.mask[node] == 0 }
			return [
				(0..<nodes).map { ashore($0) ? 0 : Double(index + 1) * 0.100 + Double($0) * 0.001 },
				(0..<nodes).map { ashore($0) ? 0 : -Double(index + 1) * 0.050 },
				(0..<nodes).map { ashore($0) ? 0 : Double($0) * 0.003 },
				(0..<nodes).map { ashore($0) ? 0 : 0.007 - Double($0) * 0.001 },
			]
		}
		#expect(file.data == golden)

		let read = try TidalStreamAtlas(data: golden)
		#expect(read.grid.rows == 3)
		#expect(read.grid.columns == 4)
		#expect(read.grid.latitudeMinimum == 48)
		#expect(read.grid.longitudeMinimum == -6)
		#expect(read.constituents.map(\.name) == ["M2", "S2"])
		// Msqm is in the file and not in the catalogue: it is named, not used.
		#expect(read.unsupportedConstituents == ["Msqm"])
		#expect(read.isWater(node: 0) == false)
		#expect(read.isWater(node: 1))
	}

	@Test func `a file that is not an atlas is refused rather than misread`() throws {
		#expect(throws: TidalStreamAtlas.Failure.notAnAtlas) {
			try TidalStreamAtlas(data: Data("not a tidal atlas at all".utf8))
		}
		var newer = AtlasFile()
		newer.version = 2
		newer.mask = [UInt8](repeating: 1, count: 12)
		newer.planes = [Array(repeating: [Double](repeating: 0, count: 12), count: 4)]
		#expect(throws: TidalStreamAtlas.Failure.unsupportedVersion(2)) {
			try TidalStreamAtlas(data: newer.data)
		}
		var whole = AtlasFile()
		whole.mask = [UInt8](repeating: 1, count: 12)
		whole.planes = [Array(repeating: [Double](repeating: 0, count: 12), count: 4)]
		#expect(throws: TidalStreamAtlas.Failure.truncated) {
			try TidalStreamAtlas(data: whole.data.dropLast(40))
		}
		var unknown = whole
		unknown.names = ["Msqm"]
		#expect(throws: TidalStreamAtlas.Failure.noSupportedConstituents) {
			try TidalStreamAtlas(data: unknown.data)
		}
	}

	// MARK: The prediction

	@Test func `S2 alone turns the atlas into a clock`() throws {
		// S₂ has no nodal correction and its argument is twice the mean Sun's
		// hour angle, so an atlas holding S₂ and a metre per second of eastward
		// in-phase component must run due east at noon, stop at three and run
		// due west at six. Nothing else pins the prediction to real time so
		// plainly: an hour out here is an hour out everywhere.
		let east = try atlas("S2", eastInPhase: [Double](repeating: 1, count: 4))

		let noon = try #require(east.stream(latitude: 48, longitude: -6, at: utc(2026, 6, 1, 12)))
		#expect(abs(noon.set - 90) < 0.001)
		#expect(abs(noon.drift - knots) < 0.001)

		let three = try #require(east.stream(latitude: 48, longitude: -6, at: utc(2026, 6, 1, 15)))
		#expect(three.drift < 0.001)

		let six = try #require(east.stream(latitude: 48, longitude: -6, at: utc(2026, 6, 1, 18)))
		#expect(abs(six.set - 270) < 0.001)
		#expect(abs(six.drift - knots) < 0.001)
	}

	@Test func `the set is the way the water goes`() throws {
		let noon = utc(2026, 6, 1, 12)
		let ones = [Double](repeating: 1, count: 4)
		let zeros = [Double](repeating: 0, count: 4)

		let northward = try atlas("S2", eastInPhase: zeros, northInPhase: ones)
		#expect(
			abs(
				try #require(northward.stream(latitude: 48, longitude: -6, at: noon)).set - 0)
				< 0.001)

		let westward = try atlas("S2", eastInPhase: ones.map { -$0 })
		#expect(
			abs(try #require(westward.stream(latitude: 48, longitude: -6, at: noon)).set - 270)
				< 0.001)

		// The quadrature component is the part a quarter of a cycle behind: it
		// contributes nothing when the in-phase part is at its peak.
		let quadrature = try atlas("S2", eastInPhase: zeros, eastQuadrature: ones)
		#expect(try #require(quadrature.stream(latitude: 48, longitude: -6, at: noon)).drift < 0.001)
		let threeHoursOn = try #require(
			quadrature.stream(latitude: 48, longitude: -6, at: utc(2026, 6, 1, 15)))
		#expect(abs(threeHoursOn.set - 90) < 0.001)
		#expect(abs(threeHoursOn.drift - knots) < 0.001)
	}

	@Test func `the stream comes round again after the constituent's own period`() throws {
		// M₂'s period follows from its speed and nothing else, so this closes
		// the loop from the catalogue through the astronomy to a prediction.
		let m2 = try atlas("M2", eastInPhase: [0.8, 0.8, 0.8, 0.8], northQuadrature: [0.3, 0.3, 0.3, 0.3])
		let first = utc(2026, 11, 8, 4)
		let period = try #require(TidalConstituent.named("M2")).speed
		let later = first.addingTimeInterval(360 / period * 3600)

		let before = try #require(m2.stream(latitude: 48.4, longitude: -5.6, at: first))
		let after = try #require(m2.stream(latitude: 48.4, longitude: -5.6, at: later))
		#expect(abs(DerivedNavigation.signed(before.set - after.set)) < 0.05)
		#expect(abs(before.drift - after.drift) < 0.001)

		// And half a period on it has turned right round.
		let half = first.addingTimeInterval(180 / period * 3600)
		let opposite = try #require(m2.stream(latitude: 48.4, longitude: -5.6, at: half))
		#expect(abs(abs(DerivedNavigation.signed(before.set - opposite.set)) - 180) < 0.05)
	}

	@Test func `a whole chart at one instant predicts what one point does`() throws {
		// The form that takes a prepared astronomy is the one a chart overlay
		// uses; it must not be a different prediction.
		let m2 = try atlas("M2", eastInPhase: [0.4, 0.5, 0.6, 0.7])
		let when = utc(2026, 11, 8, 9, 20)
		let single = try #require(m2.stream(latitude: 48.3, longitude: -5.4, at: when))
		let prepared = try #require(
			m2.stream(latitude: 48.3, longitude: -5.4, astronomy: TidalAstronomy(date: when)))
		#expect(single == prepared)
	}

	// MARK: The grid

	@Test func `the atlas is interpolated between its nodes`() throws {
		let ramp = try atlas("S2", eastInPhase: [0.1, 0.4, 0.1, 0.4])
		let noon = utc(2026, 6, 1, 12)
		// Halfway along a row, halfway between the two values on it.
		let middle = try #require(ramp.stream(latitude: 48, longitude: -5.5, at: noon))
		#expect(abs(middle.drift - 0.25 * knots) < 0.001)
		// On a node, that node's own value.
		let onNode = try #require(ramp.stream(latitude: 48, longitude: -5, at: noon))
		#expect(abs(onNode.drift - 0.4 * knots) < 0.001)
	}

	@Test func `a node ashore drops out and the rest take up its weight`() throws {
		let noon = utc(2026, 6, 1, 12)
		let values = [0.1, 0.4, 0.1, 0.4]
		// With the eastern node at sea, halfway between is the mean.
		let open = try atlas("S2", eastInPhase: values)
		#expect(
			abs(
				try #require(open.stream(latitude: 48, longitude: -5.5, at: noon)).drift
					- 0.25 * knots) < 0.001)

		// With it ashore, the western node answers for the whole cell rather
		// than being averaged with a hole.
		let coast = try atlas("S2", eastInPhase: values, mask: [1, 0, 1, 0])
		#expect(
			abs(
				try #require(coast.stream(latitude: 48, longitude: -5.5, at: noon)).drift
					- 0.1 * knots) < 0.001)

		// All four ashore and there is nothing to interpolate.
		let inland = try atlas("S2", eastInPhase: values, mask: [0, 0, 0, 0])
		#expect(inland.stream(latitude: 48.5, longitude: -5.5, at: noon) == nil)
	}

	@Test func `a position off the atlas has no prediction`() throws {
		let local = try atlas("S2", eastInPhase: [0.2, 0.2, 0.2, 0.2])
		let noon = utc(2026, 6, 1, 12)
		#expect(local.stream(latitude: 47, longitude: -5.5, at: noon) == nil, "south of it")
		#expect(local.stream(latitude: 50, longitude: -5.5, at: noon) == nil, "north of it")
		#expect(local.stream(latitude: 48.5, longitude: -7, at: noon) == nil, "west of it")
		#expect(local.stream(latitude: 48.5, longitude: 2, at: noon) == nil, "east of it")
		#expect(local.stream(latitude: 48.5, longitude: -5.5, at: noon) != nil, "inside it")
	}

	@Test func `a global atlas closes round the back of the globe`() throws {
		// Columns at 0°, 90°, 180° and 270° span the world, so a longitude of
		// 350° lies between the last column and the first.
		var file = AtlasFile()
		file.rows = 2
		file.columns = 4
		file.latitudeStep = 1
		file.longitudeStep = 90
		file.longitudeMinimum = 0
		file.names = ["S2"]
		file.mask = [UInt8](repeating: 1, count: 8)
		let eastward = [0.0, 0.0, 0.0, 0.9, 0.0, 0.0, 0.0, 0.9]
		file.planes = [
			[
				eastward, [Double](repeating: 0, count: 8),
				[Double](repeating: 0, count: 8), [Double](repeating: 0, count: 8),
			]
		]
		let world = try file.atlas
		#expect(world.grid.wrapsEastWest)

		let noon = utc(2026, 6, 1, 12)
		// Eight ninths of the way from the 270° node to the 0° one, whose
		// value is zero: a ninth of 0.9 knots' worth of component is left.
		let behind = try #require(world.stream(latitude: 48, longitude: 350, at: noon))
		#expect(abs(behind.drift - 0.1 * knots) < 0.01)
		#expect(abs(behind.set - 90) < 0.001)
		// And the 270° node itself still answers for itself.
		let onNode = try #require(world.stream(latitude: 48, longitude: -90, at: noon))
		#expect(abs(onNode.drift - 0.9 * knots) < 0.001)
	}
}
