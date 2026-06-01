import Testing

@testable import BoatToolsKit

/// Unit tests for the line-envelope parsers that wrap NMEA 2000 frames:
/// Canboat PLAIN CSV and Yacht Devices RAW (bare and with a logging prefix).
@Suite("Envelope formats")
struct EnvelopeFormatsTests {

    // MARK: Canboat PLAIN

    @Test func `Canboat PLAIN line decodes to the right PGN, source and payload`() throws {
        let line = "2022-09-23T11:05:12.918Z,2,127489,236,255,26," +
                   "00,28,00,ff,ff,bb,71,a7,03,00,00,e0,b0,05,00,ff,ff,ff,ff,ff,20,00,00,00,7e,ff"
        guard case let .nmea2000(pgn, source, priority, data)? = CanboatPlainParser.parse(line) else {
            Issue.record("expected .nmea2000")
            return
        }
        #expect(pgn == 127489)            // Engine Parameters, Dynamic
        #expect(source == 236)
        #expect(priority == 2)
        #expect(data.count == 26)         // matches the LEN field

        // The PGN decoder downstream recognises the assembled payload.
        #expect(NMEA2000Decoder.decode(pgn: pgn, data: data) != nil)
    }

    @Test func `A malformed Canboat line returns nil`() {
        #expect(CanboatPlainParser.parse("2022-09-23T11:05:12Z,2,127489") == nil)  // no data bytes
        #expect(CanboatPlainParser.parse("not,a,canboat,line") == nil)
    }

    // MARK: Yacht Devices RAW — with logging prefix

    @Test func `YD RAW with a timestamp and direction prefix decodes`() throws {
        // 0DF50B23 → PGN 128267 (Water Depth), source 0x23 = 35.
        let line = "21:55:36.918 R 0DF50B23 FF FF FF FF FF 00 00 FF"
        guard case let .nmea2000(pgn, source, _, data)? = YachtDevicesRawParser.parse(line) else {
            Issue.record("expected .nmea2000")
            return
        }
        #expect(pgn == 128267)
        #expect(source == 35)
        #expect(data.count == 8)
    }

    // MARK: Yacht Devices RAW — bare form still works

    @Test func `Bare YD RAW without a prefix still decodes`() throws {
        let line = "0DF50B23 FF FF FF FF FF 00 00 FF"
        guard case let .nmea2000(pgn, source, _, _)? = YachtDevicesRawParser.parse(line) else {
            Issue.record("expected .nmea2000")
            return
        }
        #expect(pgn == 128267)
        #expect(source == 35)
    }

    // MARK: Digital Yacht iKonvert

    @Test func `iKonvert PDGY line decodes its Base64 payload to the right PGN`() throws {
        // PGN 127250 (Vessel Heading), payload Base64 → D8 2D B4 00 00 00 00 01.
        let line = "!PDGY,127250,2,3,255,481.734,2C20AAAAAAE="
        guard case let .nmea2000(pgn, source, priority, data)? = IKonvertParser.parse(line) else {
            Issue.record("expected .nmea2000")
            return
        }
        #expect(pgn == 127250)
        #expect(source == 3)
        #expect(priority == 2)
        #expect(data == [0xD8, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x01])
    }

    @Test func `iKonvert AIS PGN decodes to an AIS target`() throws {
        // PGN 129039 — AIS Class B position report.
        let line = "!PDGY,129039,4,43,255,481.706,ErZcAw6BGlf/h2BIHkP//wAABgAG//8AdAH/"
        guard case let .nmea2000(pgn, source, _, data)? = IKonvertParser.parse(line) else {
            Issue.record("expected .nmea2000")
            return
        }
        #expect(pgn == 129039)
        let target = try #require(AISDecoder.decodeN2K(pgn: pgn, source: source, data: data))
        #expect(target.mmsi > 0)
    }

    @Test func `A non-iKonvert or malformed PDGY line returns nil`() {
        #expect(IKonvertParser.parse("$PDGY,STATUS,...") == nil)            // status, not data
        #expect(IKonvertParser.parse("!PDGY,127250,2,3,255,481.7") == nil)  // no payload field
    }
}
