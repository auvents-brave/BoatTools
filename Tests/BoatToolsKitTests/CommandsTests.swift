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
			(9, Self.claim(manufacturer: 275, deviceClass: 40, function: 150))
		])
		let pilot = NMEA2000Commands.autopilot(in: devices)
		#expect(pilot?.brand == .navico)
		#expect {
			try NMEA2000Commands.messages(for: .engage, brand: .navico, destination: 9)
		} throws: { error in
			error as? CommandError == .unsupportedAutopilot("Navico (Simrad / B&G)")
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
