internal import Foundation

// MARK: - OutboundMessage

/// A message to transmit onto the boat's network — an autopilot command, a
/// windlass order, an ISO request…
///
/// The message is protocol-neutral: ``NMEASession/send(_:)`` encodes it in the
/// wire format its connection speaks (an NMEA 0183 sentence, or an NMEA 2000
/// frame in the gateway's RAW / iKonvert / SeaSmart envelope, fast-packets
/// fragmented as needed).
public enum OutboundMessage: Sendable, Equatable {

	/// An NMEA 0183 sentence body — talker, type and fields, without the
	/// leading `$` and without the checksum (e.g. `"ECAPB,A,A,0.10,R,N,…"`).
	/// The encoder adds both.
	case nmea0183(body: String)

	/// An NMEA 2000 parameter group. Payloads over 8 bytes are fragmented
	/// into fast-packet frames on RAW gateways; self-framing envelopes
	/// (iKonvert) carry them whole.
	/// - Parameters:
	///   - pgn: The parameter group number.
	///   - destination: The target address — 255 broadcasts. Only meaningful
	///     for destination-specific (PDU1) groups.
	///   - priority: CAN priority, 0 (highest) to 7. Commands usually ride
	///     at 2–3, requests at 6.
	///   - data: The (unfragmented) payload.
	case nmea2000(pgn: UInt32, destination: UInt8 = 255, priority: UInt8 = 6, data: [UInt8])
}

// MARK: - OutboundEncoder

/// Encodes an ``OutboundMessage`` into the transmit lines of a given wire
/// format. Line terminators are the sender's business.
internal enum OutboundEncoder {

	/// The formats whose gateways accept transmissions from a client.
	static func canTransmit(_ format: NMEAInputFormat) -> Bool {
		switch format {
		case .nmea0183, .yachtDevicesRaw, .seaSmartNet, .iKonvert: return true
		case .auto, .canboatPlain, .signalK: return false
		}
	}

	/// Encodes one message for the given wire format.
	///
	/// - Parameters:
	///   - message: The message to transmit.
	///   - format: The connection's (resolved) wire format.
	///   - source: The claimed source address stamped on NMEA 2000 frames.
	///     Defaults to 254, the ISO null address.
	///   - sequence: The fast-packet sequence counter (0–7), rolled by the
	///     caller between multi-frame messages so interleaved transmissions
	///     stay reassemblable.
	/// - Returns: The lines to send, or `nil` when the format cannot carry
	///   the message (receive-only formats, or an 0183 sentence on an NMEA
	///   2000 envelope and vice versa).
	static func lines(
		_ message: OutboundMessage,
		format: NMEAInputFormat,
		source: UInt8 = 254,
		sequence: UInt8 = 0
	) -> [String]? {
		switch (message, format) {
		case (.nmea0183(let body), .nmea0183):
			return [sentence(body)]
		case (.nmea2000(let pgn, let destination, let priority, let data), .yachtDevicesRaw):
			return rawFrames(
				pgn: pgn, destination: destination, priority: priority,
				data: data, source: source, sequence: sequence)
		case (.nmea2000(let pgn, let destination, _, let data), .iKonvert):
			// iKonvert frames and fragments on the gateway: `!PDGY,<pgn>,<dst>,<base64>`.
			return ["!PDGY,\(pgn),\(destination),\(Data(data).base64EncodedString())"]
		case (.nmea2000(let pgn, _, _, let data), .seaSmartNet):
			// SeaSmart carries whole payloads: `$PCDIN,<pgn>,<time>,<src>,<data>*hh`.
			let hex = data.map { String(format: "%02X", $0) }.joined()
			let body = String(format: "PCDIN,%06X,00000000,%02X,%@", pgn, source, hex)
			return [sentence(body)]
		default:
			return nil
		}
	}

	// MARK: NMEA 0183

	/// Wraps a sentence body with the leading `$` and the XOR checksum.
	static func sentence(_ body: String) -> String {
		let checksum = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
		return String(format: "$%@*%02X", body, checksum)
	}

	// MARK: NMEA 2000 over RAW

	/// The 29-bit CAN identifier for a frame — J1939 addressing: PDU1 groups
	/// (PF < 240) put the destination in PS, PDU2 groups are broadcast-only.
	static func canID(pgn: UInt32, destination: UInt8, priority: UInt8, source: UInt8) -> UInt32 {
		let dataPage = (pgn >> 16) & 0x01
		let pduFormat = (pgn >> 8) & 0xFF
		let pduSpecific = pduFormat < 240 ? UInt32(destination) : pgn & 0xFF
		return UInt32(priority & 0x07) << 26 | dataPage << 24 | pduFormat << 16
			| pduSpecific << 8 | UInt32(source)
	}

	/// Encodes a payload as Yacht Devices RAW transmit lines (`canid data…`),
	/// fragmenting payloads over 8 bytes into fast-packet frames.
	private static func rawFrames(
		pgn: UInt32, destination: UInt8, priority: UInt8,
		data: [UInt8], source: UInt8, sequence: UInt8
	) -> [String] {
		let id = String(
			format: "%08X", canID(pgn: pgn, destination: destination, priority: priority, source: source))
		func line(_ bytes: [UInt8]) -> String {
			id + " " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
		}
		guard data.count > 8 else { return [line(data)] }

		// Fast packet: frame 0 carries the sequence tag, the total byte count
		// and the first 6 bytes; every following frame carries the tag plus 7
		// bytes, the last one padded with 0xFF.
		let tag = (sequence & 0x07) << 5
		var frames: [[UInt8]] = [[tag, UInt8(min(data.count, 223))] + data.prefix(6)]
		var at = 6
		var index: UInt8 = 1
		while at < data.count {
			let chunk = data[at..<min(at + 7, data.count)]
			frames.append([tag | index] + chunk + [UInt8](repeating: 0xFF, count: 7 - chunk.count))
			at += 7
			index += 1
		}
		return frames.map(line)
	}
}
