import Testing

@testable import BoatToolsKit

/// Unit tests for ``NMEA0183Parser`` — sentence framing and field decoding.
@Suite("NMEA 0183 parser")
struct NMEA0183Tests {
    @Test func `A valid sentence parses to a frame with talker and type`() throws {
        let frame = NMEA0183Parser.parse(
            "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
        )
        guard case let .nmea0183(_, talker, type, fields)? = frame else {
            Issue.record("expected .nmea0183, got \(String(describing: frame))")
            return
        }
        #expect(talker == "GP")
        #expect(type == "RMC")
        #expect(fields.first == "$GPRMC")
    }

    @Test func `A wrong XOR checksum yields an invalid-checksum frame, not nil`() {
        // Correct checksum is *31; *00 is deliberately wrong.
        let frame = NMEA0183Parser.parse("$GPGLL,4916.45,N,12311.12,W,225444,A*00")
        guard case .invalidChecksum = frame else {
            Issue.record("expected .invalidChecksum, got \(String(describing: frame))")
            return
        }
    }

    @Test func `A non-NMEA line returns nil`() {
        #expect(NMEA0183Parser.parse("this is not a valid sentence") == nil)
    }

    @Test func `A sentence with no checksum suffix still parses`() {
        let frame = NMEA0183Parser.parse("$IIHDG,98.3,0.0,E,12.6,W")
        guard case .nmea0183 = frame else {
            Issue.record("expected .nmea0183, got \(String(describing: frame))")
            return
        }
    }

    @Test func `A recognised sentence decodes to at least one metric`() throws {
        let frame = NMEA0183Parser.parse("$SDDBT,8.1,f,2.4,M,1.3,F*0B")
        guard case let .nmea0183(_, _, _, fields)? = frame else {
            Issue.record("parse failed")
            return
        }
        let metrics = try #require(NMEA0183Parser.decode(fields))
        #expect(!metrics.isEmpty)
    }
}
