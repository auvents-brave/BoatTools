public import Foundation

/// A tidal stream at one place and instant: a prediction, not a measurement.
///
/// The convention is the one a current is always given in and the one
/// ``BoatMetricStore`` publishes a measured stream under: the set is the
/// direction the water flows *towards*, in degrees true.
public struct TidalStream: Sendable, Equatable {
	/// The direction the water flows towards, in degrees true over 0…360.
	public let set: Double
	/// How fast it flows, in knots.
	public let drift: Double

	/// Creates a stream.
	/// - Parameters:
	///   - set: Degrees true, the direction the water flows towards.
	///   - drift: Knots.
	public init(set: Double, drift: Double) {
		self.set = set
		self.drift = drift
	}
}

/// A harmonic atlas of tidal streams, read from a file.
///
/// For every node of a regular latitude/longitude grid the atlas holds, for
/// each tidal constituent, the eastward and northward velocity written as an
/// in-phase and a quadrature component. A prediction is then the sum over the
/// constituents of `f · (C cos θ + S sin θ)`, where θ is the constituent's
/// equilibrium argument plus its nodal phase correction.
///
/// The components are stored that way rather than as an amplitude and a phase
/// lag because the atlas has to be interpolated between its nodes, and a phase
/// cannot be: the mean of 355° and 5° is 180°. In this form the interpolation
/// is an ordinary weighted sum, and the prediction never calls an arctangent
/// until the very last step.
///
/// ## What an atlas can and cannot tell you
///
/// The grid is barotropic and, for FES2014, 1/16° — about four miles. It gives
/// a fair account of the stream offshore and over an open shelf. It does not
/// resolve a race, an overfall, an eddy behind a headland or a narrow channel,
/// which is where a stream matters most and where a printed atlas or the local
/// pilot remains the better authority. Nor does it know about wind-driven or
/// density-driven set, which on some coasts rivals the tidal part.
public struct TidalStreamAtlas: Sendable {

	/// What went wrong reading an atlas file.
	public enum Failure: Error, Equatable {
		/// The file does not begin with the atlas magic number.
		case notAnAtlas
		/// The file's format version is newer than this library.
		case unsupportedVersion(Int)
		/// The file is shorter than its own header says it should be.
		case truncated
		/// The grid has no nodes, or a step of zero.
		case emptyGrid
		/// None of the file's constituents is one this library can predict with.
		case noSupportedConstituents
	}

	/// The regular grid an atlas is sampled on.
	public struct Grid: Sendable, Equatable {
		/// Latitude of the southernmost row, in degrees.
		public let latitudeMinimum: Double
		/// Longitude of the westernmost column, in degrees.
		public let longitudeMinimum: Double
		/// Spacing between rows, in degrees.
		public let latitudeStep: Double
		/// Spacing between columns, in degrees.
		public let longitudeStep: Double
		/// Number of rows, running north.
		public let rows: Int
		/// Number of columns, running east.
		public let columns: Int

		/// Number of nodes in one plane.
		var nodeCount: Int { rows * columns }

		/// Whether the columns close the globe, so that a longitude off the
		/// eastern edge is taken from the western one.
		var wrapsEastWest: Bool { Double(columns) * longitudeStep >= 359.9 }
	}

	/// How the file is laid out, byte by byte, so that a converter in another
	/// language can write one.
	enum Layout {
		static let magic: [UInt8] = Array("BTSA".utf8)
		static let version: UInt16 = 1
		static let headerSize = 56
		static let nameSize = 8
		/// The unit the velocity components are stored in, in metres per second.
		static let componentStep = 0.001
		/// Planes per constituent: eastward and northward, each in phase and
		/// in quadrature.
		static let planes = 4
	}

	/// One metre per second in knots.
	static let knotsPerMetrePerSecond = 1.94384

	private let data: Data

	/// The grid the atlas is sampled on.
	public let grid: Grid
	/// The constituents the atlas holds that this library can predict with, in
	/// the order their planes appear in the file.
	public let constituents: [TidalConstituent]
	/// Names the file holds that this library has no constituent for. Their
	/// planes are read past and ignored.
	public let unsupportedConstituents: [String]

	/// Byte offset of the land mask.
	private let maskOffset: Int
	/// Byte offset of the first plane of each supported constituent, in the
	/// order of ``constituents``.
	private let componentOffsets: [Int]

	/// Reads an atlas from a file.
	/// - Parameter url: The atlas file.
	/// - Throws: ``Failure`` when the file is not a readable atlas, or any
	///   error reading it.
	public init(contentsOf url: URL) throws {
		try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
	}

	/// Reads an atlas already in memory.
	/// - Parameter data: The contents of an atlas file.
	/// - Throws: ``Failure`` when the bytes are not a readable atlas.
	public init(data: Data) throws {
		guard data.count >= Layout.headerSize, Array(data.prefix(4)) == Layout.magic else {
			throw Failure.notAnAtlas
		}
		self.data = data

		func u16(_ offset: Int) -> UInt16 {
			data.withUnsafeBytes {
				UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
			}
		}
		func u32(_ offset: Int) -> UInt32 {
			data.withUnsafeBytes {
				UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
			}
		}
		func f64(_ offset: Int) -> Double {
			data.withUnsafeBytes {
				Double(
					bitPattern: UInt64(
						littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
			}
		}

		let version = u16(4)
		guard version <= Layout.version else { throw Failure.unsupportedVersion(Int(version)) }

		grid = Grid(
			latitudeMinimum: f64(8),
			longitudeMinimum: f64(16),
			latitudeStep: f64(24),
			longitudeStep: f64(32),
			rows: Int(u32(40)),
			columns: Int(u32(44))
		)
		guard grid.rows > 0, grid.columns > 0, grid.latitudeStep > 0, grid.longitudeStep > 0 else {
			throw Failure.emptyGrid
		}

		let count = Int(u32(48))
		let nameTable = Layout.headerSize
		let mask = nameTable + count * Layout.nameSize
		let planeBytes = grid.nodeCount * 2
		let expected = mask + grid.nodeCount + count * Layout.planes * planeBytes
		guard data.count >= expected else { throw Failure.truncated }
		maskOffset = mask

		var known: [TidalConstituent] = []
		var unknown: [String] = []
		var offsets: [Int] = []
		for index in 0..<count {
			let start = nameTable + index * Layout.nameSize
			let bytes = data[
				(data.startIndex + start)..<(data.startIndex + start + Layout.nameSize)]
			let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
			if let constituent = TidalConstituent.named(name) {
				known.append(constituent)
				offsets.append(mask + grid.nodeCount + index * Layout.planes * planeBytes)
			} else {
				unknown.append(name)
			}
		}
		guard !known.isEmpty else { throw Failure.noSupportedConstituents }
		constituents = known
		unsupportedConstituents = unknown
		componentOffsets = offsets
	}

	// MARK: Prediction

	/// The stream at one place and instant.
	/// - Parameters:
	///   - latitude: Degrees, north positive.
	///   - longitude: Degrees, east positive.
	///   - date: The instant, read as UT1.
	/// - Returns: The predicted stream, or `nil` outside the atlas or over land.
	public func stream(latitude: Double, longitude: Double, at date: Date) -> TidalStream? {
		stream(latitude: latitude, longitude: longitude, astronomy: TidalAstronomy(date: date))
	}

	/// The stream at one place, for an instant whose astronomy is already
	/// worked out — the form to use when covering a whole chart at one time.
	/// - Parameters:
	///   - latitude: Degrees, north positive.
	///   - longitude: Degrees, east positive.
	///   - astronomy: The angles for the instant wanted.
	/// - Returns: The predicted stream, or `nil` outside the atlas or over land.
	public func stream(latitude: Double, longitude: Double, astronomy: TidalAstronomy)
		-> TidalStream?
	{
		guard let corners = neighbourhood(latitude: latitude, longitude: longitude) else {
			return nil
		}
		let radians = Double.pi / 180
		var east = 0.0
		var north = 0.0
		data.withUnsafeBytes { raw in
			func component(_ offset: Int, _ node: Int) -> Double {
				let value = Int16(
					littleEndian: raw.loadUnaligned(
						fromByteOffset: offset + node * 2, as: Int16.self))
				return Double(value) * Layout.componentStep
			}
			for (index, constituent) in constituents.enumerated() {
				let base = componentOffsets[index]
				let planeBytes = grid.nodeCount * 2
				var eastInPhase = 0.0
				var eastQuadrature = 0.0
				var northInPhase = 0.0
				var northQuadrature = 0.0
				for corner in corners {
					eastInPhase += corner.weight * component(base, corner.node)
					eastQuadrature += corner.weight * component(base + planeBytes, corner.node)
					northInPhase += corner.weight * component(base + 2 * planeBytes, corner.node)
					northQuadrature +=
						corner.weight
						* component(base + 3 * planeBytes, corner.node)
				}
				let theta =
					(constituent.equilibriumArgument(astronomy)
						+ constituent.phaseCorrection(astronomy)) * radians
				let factor = constituent.amplitudeFactor(astronomy)
				east += factor * (eastInPhase * cos(theta) + eastQuadrature * sin(theta))
				north += factor * (northInPhase * cos(theta) + northQuadrature * sin(theta))
			}
		}
		let knots = Self.knotsPerMetrePerSecond
		let stream = DerivedNavigation.setAndDrift(east: east * knots, north: north * knots)
		return TidalStream(set: stream.set, drift: stream.drift)
	}

	// MARK: Grid

	/// The water nodes around a position with their interpolation weights.
	///
	/// A node on land carries no data, so its weight is dropped and the rest
	/// are scaled back up: that keeps a prediction usable right up to the
	/// coast, where the atlas's own nodes start falling ashore. When all four
	/// corners are dry there is nothing to interpolate.
	func neighbourhood(latitude: Double, longitude: Double) -> [(node: Int, weight: Double)]? {
		let y = (latitude - grid.latitudeMinimum) / grid.latitudeStep
		guard y >= 0, y <= Double(grid.rows - 1) else { return nil }

		let offset = DerivedNavigation.normalise(longitude - grid.longitudeMinimum)
		let x = offset / grid.longitudeStep
		guard grid.wrapsEastWest || x <= Double(grid.columns - 1) else { return nil }

		let row = min(Int(y), grid.rows - 1)
		let column = min(Int(x), grid.columns - 1)
		let northward = min(row + 1, grid.rows - 1)
		let eastward = grid.wrapsEastWest ? (column + 1) % grid.columns : min(column + 1, grid.columns - 1)
		let dy = y - Double(row)
		let dx = x - Double(column)

		let candidates = [
			(node: row * grid.columns + column, weight: (1 - dy) * (1 - dx)),
			(node: row * grid.columns + eastward, weight: (1 - dy) * dx),
			(node: northward * grid.columns + column, weight: dy * (1 - dx)),
			(node: northward * grid.columns + eastward, weight: dy * dx),
		]
		let wet = candidates.filter { $0.weight > 0 && isWater(node: $0.node) }
		let total = wet.reduce(0) { $0 + $1.weight }
		guard total > 0 else { return nil }
		return wet.map { (node: $0.node, weight: $0.weight / total) }
	}

	/// Whether a node carries data.
	func isWater(node: Int) -> Bool {
		data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: maskOffset + node, as: UInt8.self) == 1 }
	}
}
