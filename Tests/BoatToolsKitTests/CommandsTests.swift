import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for ``NMEA2000Commands`` — autopilot identification and the
/// pilot / windlass command recipes.
@Suite("NMEA 2000 commands")
struct CommandsTests {

	/// A claim for the given manufacturer / class / function trio.
	private static func claim(manufacturer: UInt16, deviceClass: UInt8, function: UInt8) -> [UInt8] {
		var name: UInt64 = 1
		name |= UInt64(manufacturer & 0x7FF) << 21
		name |= UInt64(function) << 40
		name |= UInt64(deviceClass & 0x7F) << 49
		name |= UInt64(4) << 60
		return withUnsafeBytes(of: name.littleEndian) { Array($0) }
	}

	private static func inventory(_ claims: [(UInt8, [UInt8])]) -> [NMEA2000Device] {
		var directory = NMEA2000DeviceDirectory()
		for (address, data) in claims {
			directory.apply(pgn: 60928, source: address, data: data)
		}
		return directory.devices
	}

	@Test func `the autopilot is identified by class, function and brand`() throws {
		let devices = Self.inventory([
			(35, Self.claim(manufacturer: 229, deviceClass: 60, function: 145)),  // a GPS
			(204, Self.claim(manufacturer: 1851, deviceClass: 40, function: 150)),  // the pilot
		])
		let pilot = try #require(NMEA2000Commands.autopilot(in: devices))
		#expect(pilot.device.address == 204)
		#expect(pilot.brand == .raymarineEvolution)
	}

	@Test func `brands map to dialects, B&G included`() {
		#expect(AutopilotBrand(manufacturerCode: 1851) == .raymarineEvolution)
		#expect(AutopilotBrand(manufacturerCode: 381) == .navico)
		#expect(AutopilotBrand(manufacturerCode: 1857) == .navico)
		#expect(AutopilotBrand(manufacturerCode: 229) == .garmin)
		#expect(AutopilotBrand(manufacturerCode: 999) == .other(manufacturerCode: 999))
	}

	@Test func `an unsupported dialect is refused by name`() {
		let devices = Self.inventory([
			(9, Self.claim(manufacturer: 1855, deviceClass: 40, function: 150))
		])
		let pilot = NMEA2000Commands.autopilot(in: devices)
		#expect(pilot?.brand == .furuno)
		#expect {
			try NMEA2000Commands.messages(for: .engage, brand: .furuno, destination: 9)
		} throws: { error in
			error as? CommandError == .unsupportedAutopilot("Furuno")
		}
	}

	@Test func `Raymarine modes write the 65379 pilot-mode group`() throws {
		func modeBytes(_ command: AutopilotCommand) throws -> [UInt8] {
			let messages = try NMEA2000Commands.messages(
				for: command, brand: .raymarineEvolution, destination: 204)
			guard case .nmea2000(let pgn, let destination, let priority, let data) = try #require(messages.first)
			else { throw CommandError.noAutopilot }
			#expect(pgn == 126208)
			#expect(destination == 204)
			#expect(priority == 3)
			return data
		}
		let prefix: [UInt8] = [0x01, 0x63, 0xFF, 0x00, 0xF8, 0x04, 0x01, 0x3B, 0x07, 0x03, 0x04, 0x04]
		let suffix: [UInt8] = [0x05, 0xFF, 0xFF]
		#expect(try modeBytes(.standby) == prefix + [0x00, 0x00] + suffix)
		#expect(try modeBytes(.engage) == prefix + [0x40, 0x00] + suffix)
		#expect(try modeBytes(.windVane) == prefix + [0x00, 0x01] + suffix)
		#expect(try modeBytes(.track) == prefix + [0x80, 0x01] + suffix)
	}

	@Test func `a heading adjustment decomposes into ten and one degree keys`() throws {
		let messages = try NMEA2000Commands.messages(
			for: .adjustHeading(degrees: -23), brand: .raymarineEvolution, destination: 204)
		#expect(messages.count == 5)  // two −10 presses, three −1 presses
		let keys = messages.compactMap { message -> UInt8? in
			guard case .nmea2000(let pgn, _, let priority, let data) = message else { return nil }
			#expect(pgn == 126720)
			#expect(priority == 7)
			#expect(data.count == 22)
			#expect(data[7] == ~data[6])  // the key rides with its complement
			return data[6]
		}
		#expect(keys == [0x06, 0x06, 0x05, 0x05, 0x05])
	}

	@Test func `a locked heading writes 65360 in ten-thousandths of a radian`() throws {
		let messages = try NMEA2000Commands.messages(
			for: .lockHeading(degrees: 90), brand: .raymarineEvolution, destination: 204)
		guard case .nmea2000(let pgn, _, _, let data)? = messages.first else {
			Issue.record("expected an NMEA 2000 message")
			return
		}
		#expect(pgn == 126208)
		#expect(Array(data.prefix(12)) == [0x01, 0x50, 0xFF, 0x00, 0xF8, 0x03, 0x01, 0x3B, 0x07, 0x03, 0x04, 0x06])
		let value = UInt16(data[12]) | UInt16(data[13]) << 8
		#expect(value == 15708)  // π/2 × 10 000
	}

	@Test func `the windlass command writes the standard 128776 direction field`() {
		let message = NMEA2000Commands.message(for: .up, windlassID: 1, destination: 12)
		guard case .nmea2000(let pgn, let destination, _, let data) = message else {
			Issue.record("expected an NMEA 2000 message")
			return
		}
		#expect(pgn == 126208)
		#expect(destination == 12)
		#expect(data == [0x01, 0x08, 0xF7, 0x01, 0xF8, 0x02, 0x02, 0x01, 0x03, 0x02])
		// Down and off drive the direction-control values of PGN 128776.
		if case .nmea2000(_, _, _, let down) = NMEA2000Commands.message(for: .down) {
			#expect(down.suffix(1) == [1])
		}
		if case .nmea2000(_, _, _, let off) = NMEA2000Commands.message(for: .off) {
			#expect(off.suffix(1) == [0])
		}
	}

	@Test func `Navico modes ride the Simnet AP command group`() throws {
		func bytes(_ command: AutopilotCommand) throws -> [UInt8] {
			let messages = try NMEA2000Commands.messages(for: command, brand: .navico, destination: 3)
			guard case .nmea2000(let pgn, let destination, _, let data) = try #require(messages.first)
			else { throw CommandError.noAutopilot }
			#expect(pgn == 130850)
			#expect(destination == 255)  // Simnet commands ride broadcast
			return data
		}
		let prefix: [UInt8] = [0x41, 0x9F, 0x03, 0xFF, 0xFF, 0x0A]
		#expect(try bytes(.standby) == prefix + [6, 0x00, 0xFF, 0xFF, 0xFF])
		#expect(try bytes(.engage) == prefix + [9, 0x00, 0xFF, 0xFF, 0xFF])
		#expect(try bytes(.windVane) == prefix + [15, 0x00, 0xFF, 0xFF, 0xFF])
		#expect(try bytes(.track) == prefix + [10, 0x00, 0xFF, 0xFF, 0xFF])
		// A 10° turn to starboard: event 26, direction 3, angle in 1e-4 rad.
		#expect(try bytes(.adjustHeading(degrees: 10)) == prefix + [26, 0x00, 3, 0xD1, 0x06, 0xFF])
		#expect {
			try NMEA2000Commands.messages(for: .lockHeading(degrees: 200), brand: .navico, destination: 3)
		} throws: { error in
			error as? CommandError == .unsupportedCommand("lockHeading", dialect: "Navico")
		}
	}

	@Test func `Garmin states and steps ride proprietary 126720`() throws {
		let messages = try NMEA2000Commands.messages(for: .engage, brand: .garmin, destination: 9)
		guard case .nmea2000(let pgn, let destination, _, let data)? = messages.first else {
			Issue.record("expected an NMEA 2000 message")
			return
		}
		#expect(pgn == 126720)
		#expect(destination == 9)
		#expect(data == [0x0B, 0xE5, 0x98, 0x10, 0x17, 0x04, 0x04, 0x05, 0x0A, 0x00, 0x05, 0x00, 0xFF, 0xFF])
		// −17° decomposes into one −15 step and two −1 steps.
		let steps = try NMEA2000Commands.messages(
			for: .adjustHeading(degrees: -17), brand: .garmin, destination: 9)
		let codes = steps.compactMap { message -> UInt8? in
			guard case .nmea2000(_, _, _, let data) = message else { return nil }
			return data[8]
		}
		#expect(codes == [0x01, 0x00, 0x00])
	}

	@Test func `Seatalk keystroke sentences carry the key and its complement`() throws {
		func first(_ command: AutopilotCommand) throws -> String {
			guard case .nmea0183(let body)? = try NMEA2000Commands.seatalkSentences(for: command).first
			else { throw CommandError.noAutopilot }
			return body
		}
		#expect(try first(.engage) == "STALK,86,11,01,FE")
		#expect(try first(.standby) == "STALK,86,11,02,FD")
		#expect(try first(.track) == "STALK,86,11,03,FC")
		#expect(try first(.windVane) == "STALK,86,11,23,DC")
		let bodies = try NMEA2000Commands.seatalkSentences(for: .adjustHeading(degrees: 11))
		#expect(bodies.count == 2)
		#expect(try first(.adjustHeading(degrees: 11)) == "STALK,86,11,08,F7")
		// The encoder wraps the body into a checksummed sentence.
		let lines = OutboundEncoder.lines(.nmea0183(body: "STALK,86,11,01,FE"), format: .nmea0183)
		#expect(lines?.first?.hasPrefix("$STALK,86,11,01,FE*") == true)
	}

	@Test func `Signal K orders map to the autopilot API paths`() {
		#expect(
			SignalKClient.autopilotPut(for: .engage)
				== ("steering.autopilot.state", .string("auto")))
		#expect(
			SignalKClient.autopilotPut(for: .standby)
				== ("steering.autopilot.state", .string("standby")))
		#expect(
			SignalKClient.autopilotPut(for: .windVane)
				== ("steering.autopilot.state", .string("wind")))
		#expect(
			SignalKClient.autopilotPut(for: .track)
				== ("steering.autopilot.state", .string("route")))
		#expect(
			SignalKClient.autopilotPut(for: .adjustHeading(degrees: -10))
				== ("steering.autopilot.actions.adjustHeading", .number(-10)))
		#expect(
			SignalKClient.autopilotPut(for: .lockHeading(degrees: 235))
				== ("steering.autopilot.target.headingMagnetic", .number(235)))
	}

	@Test func `tack rides the key chords, the Simnet event and the Signal K action`() throws {
		let port = try NMEA2000Commands.messages(
			for: .tack(toPort: true), brand: .raymarineEvolution, destination: 204)
		if case .nmea2000(let pgn, _, _, let data)? = port.first {
			#expect(pgn == 126720)
			#expect(data[6] == 0x21)
			#expect(data[7] == 0xDE)
		} else {
			Issue.record("expected a keystroke")
		}
		let navico = try NMEA2000Commands.messages(for: .tack(toPort: false), brand: .navico, destination: 3)
		if case .nmea2000(let pgn, _, _, let data)? = navico.first {
			#expect(pgn == 130850)
			#expect(data[6] == 17)  // Simnet event: Tack
		} else {
			Issue.record("expected a Simnet event")
		}
		if case .nmea0183(let body)? = try NMEA2000Commands.seatalkSentences(for: .tack(toPort: false)).first {
			#expect(body == "STALK,86,11,22,DD")
		}
		#expect(
			SignalKClient.autopilotPut(for: .tack(toPort: true))
				== ("steering.autopilot.actions.tack", .string("port")))
	}

	@Test func `Raymarine pilot mode and target heading decode into autopilot metrics`() throws {
		// 65379: manufacturer field 0x9F3B (1851 + marine), mode 64 = auto.
		let mode = NMEA2000Decoder.decode(pgn: 65379, data: [0x3B, 0x9F, 64, 0, 0, 0, 0, 0xFF])
		#expect(mode?.first?.name == "autopilot.mode")
		#expect(mode?.first?.value == 1)
		// 384 = track → 3; a foreign manufacturer field is ignored.
		let track = NMEA2000Decoder.decode(pgn: 65379, data: [0x3B, 0x9F, 0x80, 0x01, 0, 0, 0, 0xFF])
		#expect(track?.first?.value == 3)
		#expect(NMEA2000Decoder.decode(pgn: 65379, data: [0x41, 0x9F, 64, 0, 0, 0, 0, 0xFF]) == nil)

		// 65360: SID then true/magnetic targets in 1e-4 rad — π/2 each way.
		let target = try #require(
			NMEA2000Decoder.decode(pgn: 65360, data: [0x3B, 0x9F, 0, 0x5C, 0x3D, 0x5C, 0x3D, 0xFF]))
		#expect(target.count == 2)
		#expect(target[0].name == "autopilot.target")
		#expect(abs(target[0].value - 90) < 0.01)
		#expect(target[1].name == "autopilot.target.magnetic")
	}

	@Test func `the windlass is located by its declared PGNs`() {
		var directory = NMEA2000DeviceDirectory()
		directory.apply(
			pgn: 60928, source: 12,
			data: Self.claim(manufacturer: 644, deviceClass: 30, function: 140))
		directory.apply(
			pgn: 126464, source: 12,
			data: [0] + [UInt8(128777 & 0xFF), UInt8((128777 >> 8) & 0xFF), UInt8(128777 >> 16)])
		let windlass = NMEA2000Commands.windlass(in: directory.devices)
		#expect(windlass?.address == 12)
	}
}
