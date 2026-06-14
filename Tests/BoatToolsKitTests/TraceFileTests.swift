internal import Foundation
import Testing

@testable import BoatToolsKit

/// Parametrised end-to-end decoding over capture files in `Resources/`.
///
/// Each case feeds a trace file through ``NMEATransport/fileStream(path:format:decodePGNs:)``
/// — the very same pipeline (format auto-detection, PGN decoding, AIS assembly)
/// used by the live transports and the `boattools file` command — then counts
/// source lines that decoded cleanly versus lines that produced a diagnostic
/// (`.invalidChecksum` or `.unknown`).
///
/// A single source line can yield several frames (a raw frame plus metrics, or
/// an AIS target), so counting is keyed on ``FileFrame/lineIndex`` rather than
/// on the number of frames.
///
/// To add coverage: drop a capture into `Resources/` and append a ``Case`` with
/// the expected line counts.
@Suite("Trace file decoding")
struct TraceFileTests {
	/// One trace file together with the counts it is expected to produce.
	struct Case: Sendable {
		/// Resource base name (without extension).
		let resource: String
		/// Resource file extension.
		let ext: String
		/// Number of source lines expected to decode without a diagnostic.
		let expectedOK: Int
		/// Number of source lines expected to produce `.invalidChecksum` or `.unknown`.
		let expectedErrors: Int
	}

	static let cases: [Case] = [
		// Authored sample: six valid NMEA 0183 sentences, one bad checksum, one
		// line of non-NMEA junk.
		Case(resource: "sample", ext: "nmea", expectedOK: 6, expectedErrors: 2),
		// Canboat PLAIN CSV: four complete PGN 127489 (engine dynamic) envelopes.
		Case(resource: "canboat", ext: "csv", expectedOK: 4, expectedErrors: 0),
		// Yacht Devices RAW with a "<timestamp> R/T" prefix: three single-frame
		// PGN 128267 (water depth) lines plus one line with an invalid CAN ID.
		Case(resource: "ydraw-prefixed", ext: "log", expectedOK: 3, expectedErrors: 1),
		// Digital Yacht iKonvert: 26 !PDGY data sentences (Base64 N2K payloads),
		// all well-formed — every line emits at least its raw N2K frame.
		Case(resource: "ikonvert", ext: "txt", expectedOK: 26, expectedErrors: 0),
		// Add your own captures below, e.g.:
		// Case(resource: "raymarine-tcp", ext: "log", expectedOK: 4123, expectedErrors: 7),
	]

	@Test(arguments: TraceFileTests.cases)
	func `Line counts match the expected OK and error totals`(_ testCase: Case) async throws {
		let url = try #require(
			Bundle.module.url(forResource: testCase.resource, withExtension: testCase.ext),
			"Missing resource \(testCase.resource).\(testCase.ext)"
		)

		var okLines = Set<Int>()
		var errorLines = Set<Int>()
		for try await fileFrame in NMEATransport.fileStream(path: url.path, format: .auto) {
			switch fileFrame.frame {
			case .invalidChecksum, .unknown:
				errorLines.insert(fileFrame.lineIndex)
			default:
				okLines.insert(fileFrame.lineIndex)
			}
		}
		// A line counts as "in error" as soon as it produced any diagnostic frame.
		okLines.subtract(errorLines)

		#expect(
			okLines.count == testCase.expectedOK,
			"OK lines: got \(okLines.count), expected \(testCase.expectedOK)")
		#expect(
			errorLines.count == testCase.expectedErrors,
			"error lines: got \(errorLines.count), expected \(testCase.expectedErrors)")
	}
}
