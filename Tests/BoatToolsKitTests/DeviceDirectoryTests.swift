import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for ``NMEA2000DeviceDirectory`` — the NMEA 2000 network device
/// inventory built from address claims, product information, configuration
/// information, PGN lists and heartbeats.
@Suite("NMEA 2000 device directory")
struct DeviceDirectoryTests {

	/// Builds a 60928 ISO Address Claim payload from its NAME fields.
	private static func addressClaim(
		uniqueNumber: UInt32, manufacturer: UInt16, deviceInstance: UInt8,
		function: UInt8, deviceClass: UInt8, systemInstance: UInt8,
		industryGroup: UInt8, arbitrary: Bool
	) -> [UInt8] {
		var name: UInt64 = UInt64(uniqueNumber & 0x1F_FFFF)
		name |= UInt64(manufacturer & 0x7FF) << 21
		name |= UInt64(deviceInstance) << 32
		name |= UInt64(function) << 40
		name |= UInt64(deviceClass & 0x7F) << 49
		name |= UInt64(systemInstance & 0x0F) << 56
		name |= UInt64(industryGroup & 0x07) << 60
		if arbitrary { name |= 1 << 63 }
		return withUnsafeBytes(of: name.littleEndian) { Array($0) }
	}

	/// Builds a 126996 Product Information payload (134 bytes).
	private static func productInformation(
		version: UInt16, code: UInt16, model: String, software: String,
		modelVersion: String, serial: String, certification: UInt8, len: UInt8
	) -> [UInt8] {
		func fixed(_ s: String) -> [UInt8] {
			Array(s.utf8.prefix(32)) + [UInt8](repeating: 0xFF, count: max(0, 32 - s.utf8.count))
		}
		var data: [UInt8] = []
		data += withUnsafeBytes(of: version.littleEndian) { Array($0) }
		data += withUnsafeBytes(of: code.littleEndian) { Array($0) }
		data += fixed(model) + fixed(software) + fixed(modelVersion) + fixed(serial)
		data += [certification, len]
		return data
	}

	@Test func `an address claim decodes every NAME field`() throws {
		var directory = NMEA2000DeviceDirectory()
		let claim = Self.addressClaim(
			uniqueNumber: 123_456, manufacturer: 229, deviceInstance: 5,
			function: 145, deviceClass: 60, systemInstance: 2,
			industryGroup: 4, arbitrary: true)

		let changed1 = directory.apply(pgn: 60928, source: 35, data: claim)
		#expect(changed1)

		let device = try #require(directory[35])
		#expect(device.uniqueNumber == 123_456)
		#expect(device.manufacturerCode == 229)
		#expect(device.manufacturerName == "Garmin")
		#expect(device.deviceInstance == 5)
		#expect(device.deviceFunction == 145)
		#expect(device.deviceFunctionName == "Ownship Position (GNSS)")
		#expect(device.deviceClass == 60)
		#expect(device.deviceClassName == "Navigation")
		#expect(device.systemInstance == 2)
		#expect(device.industryGroupName == "Marine")
		#expect(device.arbitraryAddressCapable == true)
	}

	@Test func `product information fills model, versions and load`() throws {
		var directory = NMEA2000DeviceDirectory()
		let info = Self.productInformation(
			version: 2101, code: 9876, model: "GPS 24xd", software: "2.60",
			modelVersion: "A", serial: "SN-0042", certification: 1, len: 3)

		let changed2 = directory.apply(pgn: 126996, source: 35, data: info)
		#expect(changed2)

		let device = try #require(directory[35])
		let version = try #require(device.nmea2000Version)
		#expect(abs(version - 2.101) < 0.000001)
		#expect(device.productCode == 9876)
		#expect(device.modelID == "GPS 24xd")
		#expect(device.softwareVersion == "2.60")
		#expect(device.modelVersion == "A")
		#expect(device.serialNumber == "SN-0042")
		#expect(device.certificationLevel == 1)
		#expect(device.loadEquivalency == 3)
		#expect(device.displayName == "GPS 24xd")
	}

	@Test func `configuration information reads the three variable strings`() throws {
		func varString(_ s: String) -> [UInt8] {
			[UInt8(s.utf8.count + 2), 1] + Array(s.utf8)
		}
		var directory = NMEA2000DeviceDirectory()
		let data = varString("Mast head") + varString("Port side") + varString("Contact: Airmar")

		let changed3 = directory.apply(pgn: 126998, source: 12, data: data)
		#expect(changed3)

		let device = try #require(directory[12])
		#expect(device.installationDescription1 == "Mast head")
		#expect(device.installationDescription2 == "Port side")
		#expect(device.manufacturerInformation == "Contact: Airmar")
	}

	@Test func `PGN lists split transmitted and received`() throws {
		func pgnList(function: UInt8, _ pgns: [UInt32]) -> [UInt8] {
			[function]
				+ pgns.flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8(($0 >> 16) & 0xFF)] }
		}
		var directory = NMEA2000DeviceDirectory()
		let changed4 = directory.apply(pgn: 126464, source: 9, data: pgnList(function: 0, [129025, 129026]))
		#expect(changed4)
		let changed5 = directory.apply(pgn: 126464, source: 9, data: pgnList(function: 1, [59904]))
		#expect(changed5)

		let device = try #require(directory[9])
		#expect(device.transmittedPGNs == [129025, 129026])
		#expect(device.receivedPGNs == [59904])
	}

	@Test func `heartbeats record the interval and refresh last seen`() throws {
		var directory = NMEA2000DeviceDirectory()
		let early = Date(timeIntervalSince1970: 1000)
		let late = Date(timeIntervalSince1970: 2000)

		let changed6 = directory.apply(pgn: 126993, source: 7, data: [0x60, 0xEA, 0, 0xFF], at: early)
		#expect(changed6)
		let device = try #require(directory[7])
		#expect(device.heartbeatInterval == 60)

		// A plain data PGN from a known address refreshes lastSeen only.
		let changed7 = directory.apply(pgn: 129025, source: 7, data: [0, 0, 0, 0, 0, 0, 0, 0], at: late)
		#expect(changed7 == false)
		#expect(directory[7]?.lastSeen == late)
	}

	@Test func `broadcast and null addresses are never devices`() {
		var directory = NMEA2000DeviceDirectory()
		let claim = Self.addressClaim(
			uniqueNumber: 1, manufacturer: 137, deviceInstance: 0, function: 130,
			deviceClass: 25, systemInstance: 0, industryGroup: 4, arbitrary: false)
		let changed8 = directory.apply(pgn: 60928, source: 254, data: claim)
		#expect(changed8 == false)
		let changed9 = directory.apply(pgn: 60928, source: 255, data: claim)
		#expect(changed9 == false)
		#expect(directory.devices.isEmpty)
	}

	@Test func `devices are ordered by address and removeAll empties`() {
		var directory = NMEA2000DeviceDirectory()
		let claim = Self.addressClaim(
			uniqueNumber: 1, manufacturer: 717, deviceInstance: 0, function: 137,
			deviceClass: 25, systemInstance: 0, industryGroup: 4, arbitrary: false)
		directory.apply(pgn: 60928, source: 80, data: claim)
		directory.apply(pgn: 60928, source: 3, data: claim)
		#expect(directory.devices.map(\.address) == [3, 80])
		#expect(directory[3]?.manufacturerName == "Yacht Devices")
		#expect(directory[3]?.deviceFunctionName == "NMEA 2000 Wireless Gateway")
		directory.removeAll()
		#expect(directory.devices.isEmpty)
	}

	@Test func `interrogation lines encode ISO requests in YD RAW transmit format`() {
		let lines = NMEA2000DeviceDirectory.interrogationLines()
		// Priority 6, PF 0xEA, global destination, null source; PGN little-endian.
		#expect(
			lines == [
				"18EAFFFE 00 EE 00",  // 60928 address claim
				"18EAFFFE 14 F0 01",  // 126996 product information
				"18EAFFFE 16 F0 01",  // 126998 configuration information
				"18EAFFFE 00 EE 01",  // 126464 PGN list
			])
		// A round trip through the YD RAW parser lands on the ISO Request PGN.
		if case .nmea2000(let pgn, let source, _, let data)? = YachtDevicesRawParser.parse(lines[0]) {
			#expect(pgn == 59904)
			#expect(source == 0xFE)
			#expect(data == [0x00, 0xEE, 0x00])
		} else {
			Issue.record("interrogation line did not parse back as a frame")
		}
	}
}
