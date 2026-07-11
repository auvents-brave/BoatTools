import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for ``OutboundEncoder`` — the transmit path onto the network —
/// and the multiplexer's outbound routing.
@Suite("Outbound encoding")
struct OutboundTests {

	@Test func `only client-transmit formats are transmit-capable`() {
		#expect(OutboundEncoder.canTransmit(.nmea0183))
		#expect(OutboundEncoder.canTransmit(.yachtDevicesRaw))
		#expect(OutboundEncoder.canTransmit(.seaSmartNet))
		#expect(OutboundEncoder.canTransmit(.iKonvert))
		#expect(OutboundEncoder.canTransmit(.auto) == false)
		#expect(OutboundEncoder.canTransmit(.canboatPlain) == false)
		#expect(OutboundEncoder.canTransmit(.signalK) == false)
	}

	@Test func `an 0183 sentence gains its dollar sign and checksum`() throws {
		let lines = try #require(
			OutboundEncoder.lines(.nmea0183(body: "GPGLL,4916.45,N,12311.12,W,225444,A"), format: .nmea0183))
		#expect(lines == ["$GPGLL,4916.45,N,12311.12,W,225444,A*31"])
		// The sentence round-trips through the 0183 parser.
		if case .nmea0183(_, let talker, let type, _)? = NMEA0183Parser.parse(lines[0]) {
			#expect(talker == "GP")
			#expect(type == "GLL")
		} else {
			Issue.record("encoded sentence did not parse back")
		}
	}

	@Test func `a mismatched message and format encode to nil`() {
		#expect(OutboundEncoder.lines(.nmea0183(body: "X"), format: .yachtDevicesRaw) == nil)
		#expect(
			OutboundEncoder.lines(.nmea2000(pgn: 59904, data: [0, 0xEE, 0]), format: .nmea0183) == nil)
		#expect(
			OutboundEncoder.lines(.nmea2000(pgn: 59904, data: [0, 0xEE, 0]), format: .signalK) == nil)
	}

	@Test func `the CAN identifier follows J1939 addressing`() {
		// PDU1 (PF < 240): the destination rides in PS.
		#expect(
			OutboundEncoder.canID(pgn: 59904, destination: 0x23, priority: 6, source: 0xFE)
				== 0x18EA_23FE)
		// PDU2 (PF ≥ 240): broadcast, PS comes from the PGN itself.
		#expect(
			OutboundEncoder.canID(pgn: 130306, destination: 0x23, priority: 2, source: 0x01)
				== 0x09FD_0201)
	}

	@Test func `a short payload becomes one RAW frame`() throws {
		let lines = try #require(
			OutboundEncoder.lines(
				.nmea2000(pgn: 59904, destination: 255, priority: 6, data: [0x14, 0xF0, 0x01]),
				format: .yachtDevicesRaw))
		#expect(lines == ["18EAFFFE 14 F0 01"])
	}

	@Test func `a long payload fragments into fast-packet frames`() throws {
		let payload = Array(UInt8(1)...23)
		let lines = try #require(
			OutboundEncoder.lines(
				.nmea2000(pgn: 126208, destination: 0x35, priority: 3, data: payload),
				format: .yachtDevicesRaw, sequence: 2))
		#expect(lines.count == 4)
		// Frame 0: sequence tag, total length, first six bytes.
		#expect(lines[0].hasSuffix(" 40 17 01 02 03 04 05 06"))
		// Following frames: tag | index, seven bytes each, last one padded.
		#expect(lines[1].hasSuffix(" 41 07 08 09 0A 0B 0C 0D"))
		#expect(lines[2].hasSuffix(" 42 0E 0F 10 11 12 13 14"))
		#expect(lines[3].hasSuffix(" 43 15 16 17 FF FF FF FF"))
		// All frames ride the same CAN identifier.
		#expect(Set(lines.map { $0.prefix(8) }).count == 1)
	}

	@Test func `iKonvert carries the payload whole, base64-encoded`() throws {
		let lines = try #require(
			OutboundEncoder.lines(
				.nmea2000(pgn: 126996, destination: 42, data: [0x01, 0x02, 0x03]),
				format: .iKonvert))
		#expect(lines == ["!PDGY,126996,42,AQID"])
	}

	@Test func `SeaSmart lines round-trip through the PCDIN parser`() throws {
		let data: [UInt8] = [0x60, 0xEA, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
		let lines = try #require(
			OutboundEncoder.lines(
				.nmea2000(pgn: 126993, data: data), format: .seaSmartNet))
		if case .nmea2000(let pgn, _, _, let parsed)? = SeaSmartParser.parse(lines[0]) {
			#expect(pgn == 126993)
			#expect(parsed == data)
		} else {
			Issue.record("encoded PCDIN line did not parse back")
		}
	}

	@Test func `interrogation messages target the four device PGNs`() {
		let messages = NMEA2000DeviceDirectory.interrogationMessages(destination: 0x42)
		#expect(messages.count == 4)
		for (message, requested) in zip(messages, [60928, 126996, 126998, 126464] as [UInt32]) {
			guard case .nmea2000(let pgn, let destination, _, let data) = message else {
				Issue.record("expected an NMEA 2000 message")
				continue
			}
			#expect(pgn == 59904)
			#expect(destination == 0x42)
			let carried = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16
			#expect(carried == requested)
		}
	}
}

/// The multiplexer's outbound routing over session-backed sources.
@MainActor
@Suite("Multiplexer routing")
struct MultiplexerRoutingTests {

	/// A transmit-capable session whose sends are captured into `sent`.
	private static func stubSession(sent: SentBox) -> NMEASession {
		let session = NMEASession(format: .yachtDevicesRaw)
		session.attachSender { text in sent.append(text) }
		return session
	}

	private final class SentBox: @unchecked Sendable {
		// @unchecked: appends and reads are serialised by `lock`.
		private let lock = NSLock()
		private var lines: [String] = []
		func append(_ line: String) { lock.withLock { lines.append(line) } }
		var count: Int { lock.withLock { lines.count } }
	}

	@Test func `a message routes to the session that heard the device`() async {
		let multiplexer = ConnectionMultiplexer(store: BoatMetricStore())
		let heardBox = SentBox()
		let deafBox = SentBox()
		let heard = Self.stubSession(sent: heardBox)
		let deaf = Self.stubSession(sent: deafBox)
		// Only `heard` has seen a claim from address 35.
		heard.observeDevice(pgn: 60928, source: 35, data: [UInt8](repeating: 0, count: 8))
		multiplexer.add(label: "heard", session: heard) { _ in Task {} }
		multiplexer.add(label: "deaf", session: deaf) { _ in Task {} }

		let sent = await multiplexer.send(
			.nmea2000(pgn: 59904, destination: 35, data: [0, 0xEE, 0]), toDeviceAt: 35)
		#expect(sent == 1)
		#expect(heardBox.count == 1)
		#expect(deafBox.count == 0)
	}

	@Test func `an unlocated device broadcasts on every capable session`() async {
		let multiplexer = ConnectionMultiplexer(store: BoatMetricStore())
		let first = SentBox()
		let second = SentBox()
		multiplexer.add(label: "a", session: Self.stubSession(sent: first)) { _ in Task {} }
		multiplexer.add(label: "b", session: Self.stubSession(sent: second)) { _ in Task {} }
		// A receive-only session never participates.
		multiplexer.add(label: "udp", session: NMEASession(format: .yachtDevicesRaw)) { _ in Task {} }

		let sent = await multiplexer.send(
			.nmea2000(pgn: 59904, data: [0, 0xEE, 0]), toDeviceAt: 99)
		#expect(sent == 2)
		#expect(first.count == 1)
		#expect(second.count == 1)
	}
}
