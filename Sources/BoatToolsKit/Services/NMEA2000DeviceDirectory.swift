public import Foundation

// MARK: - NMEA2000Device

/// Everything learnt about one device on the NMEA 2000 network, keyed by its
/// source address and accumulated from the device-information PGNs:
///
/// - 60928 — ISO Address Claim: the 64-bit NAME (manufacturer, function,
///   class, instances, unique number).
/// - 126996 — Product Information: model, serial, versions, certification,
///   load equivalency.
/// - 126998 — Configuration Information: installation notes and manufacturer
///   information free text.
/// - 126464 — PGN List: the PGNs the device transmits and receives.
/// - 126993 — Heartbeat: presence and update interval.
public struct NMEA2000Device: Identifiable, Sendable, Equatable {

	/// The device's source address (0–251), its identity on the bus.
	public var address: UInt8

	/// Stable identity for collections.
	public var id: UInt8 { address }

	// MARK: ISO Address Claim (PGN 60928)

	/// The raw 64-bit ISO NAME, when an address claim was seen.
	public var name: UInt64?
	/// Manufacturer-assigned unique number (21 bits of the NAME).
	public var uniqueNumber: UInt32?
	/// NMEA-registered manufacturer code.
	public var manufacturerCode: UInt16?
	/// Device instance (ECU instance and function instance combined).
	public var deviceInstance: UInt8?
	/// ISO device function code (meaning depends on ``deviceClass``).
	public var deviceFunction: UInt8?
	/// ISO device class code.
	public var deviceClass: UInt8?
	/// System instance (ISO "device class instance").
	public var systemInstance: UInt8?
	/// Industry group (4 = marine).
	public var industryGroup: UInt8?
	/// Whether the device can negotiate a new address when its claim loses.
	public var arbitraryAddressCapable: Bool?

	// MARK: Product Information (PGN 126996)

	/// NMEA 2000 database version the device certifies against (e.g. 2.101).
	public var nmea2000Version: Double?
	/// Manufacturer's product code.
	public var productCode: UInt16?
	/// Model identification, as printed on the box.
	public var modelID: String?
	/// Software version code.
	public var softwareVersion: String?
	/// Model version (hardware revision).
	public var modelVersion: String?
	/// Model serial code.
	public var serialNumber: String?
	/// NMEA certification level.
	public var certificationLevel: UInt8?
	/// Load equivalency number — bus load in units of 50 mA at 9 V.
	public var loadEquivalency: UInt8?

	// MARK: Configuration Information (PGN 126998)

	/// Installation description, field one (free text set by the installer).
	public var installationDescription1: String?
	/// Installation description, field two.
	public var installationDescription2: String?
	/// Manufacturer information free text.
	public var manufacturerInformation: String?

	// MARK: PGN List (PGN 126464)

	/// PGNs the device declares it transmits.
	public var transmittedPGNs: [UInt32]?
	/// PGNs the device declares it receives.
	public var receivedPGNs: [UInt32]?

	// MARK: Heartbeat (PGN 126993)

	/// Declared heartbeat interval in seconds, when heartbeats were seen.
	public var heartbeatInterval: Double?

	/// When any frame was last received from this address.
	public var lastSeen: Date

	/// Creates an empty record for a source address.
	/// - Parameters:
	///   - address: The device's source address on the bus.
	///   - lastSeen: Timestamp of the first frame observed.
	public init(address: UInt8, lastSeen: Date) {
		self.address = address
		self.lastSeen = lastSeen
	}

	// MARK: Derived labels

	/// The registered manufacturer name for ``manufacturerCode``, or a numeric
	/// fallback (`manufacturer 999`) for codes outside the known table.
	public var manufacturerName: String? {
		guard let code = manufacturerCode else { return nil }
		return NMEA2000DeviceDirectory.manufacturers[code] ?? "manufacturer \(code)"
	}

	/// A human-readable device class name (`Navigation`, `Communication`…), or
	/// a numeric fallback for unknown codes.
	public var deviceClassName: String? {
		guard let code = deviceClass else { return nil }
		return NMEA2000DeviceDirectory.deviceClasses[code] ?? "class \(code)"
	}

	/// A human-readable device function name within the device class
	/// (`Ownship Position (GNSS)`, `Autopilot`…), or a numeric fallback.
	public var deviceFunctionName: String? {
		guard let function = deviceFunction else { return nil }
		if let deviceClass,
			let label = NMEA2000DeviceDirectory.deviceFunctions[UInt16(deviceClass) << 8 | UInt16(function)]
		{
			return label
		}
		return "function \(function)"
	}

	/// The industry group name (`Marine`, `Global`…), or a numeric fallback.
	public var industryGroupName: String? {
		guard let group = industryGroup else { return nil }
		let names = ["Global", "Highway", "Agriculture", "Construction", "Marine", "Industrial"]
		return Int(group) < names.count ? names[Int(group)] : "group \(group)"
	}

	/// The most specific display name available: model, else function, else
	/// class, else the bare address.
	public var displayName: String {
		modelID ?? deviceFunctionName ?? deviceClassName ?? "device @\(address)"
	}
}

// MARK: - NMEA2000DeviceDirectory

/// Builds an inventory of the devices present on an NMEA 2000 network by
/// accumulating the device-information PGNs from a frame stream.
///
/// Feed every `.nmea2000` frame through ``apply(pgn:source:data:at:)`` — the
/// directory keeps one ``NMEA2000Device`` per source address and enriches it
/// as claims, product information and heartbeats arrive. Devices announce
/// their address claim on power-up and in response to an ISO Request; use
/// ``interrogationLines(destination:)`` on a transmit-capable gateway to
/// trigger a full roll call.
///
/// ```swift
/// var directory = NMEA2000DeviceDirectory()
/// for try await frame in NMEATransport.frameStream(config: cfg) {
///     if case .nmea2000(let pgn, let src, _, let data) = frame {
///         directory.apply(pgn: pgn, source: src, data: data)
///     }
/// }
/// print(directory.devices.map(\.displayName))
/// ```
public struct NMEA2000DeviceDirectory: Sendable {

	/// The PGNs carrying device information, in the order they are usually
	/// requested. Payloads over 8 bytes must be fast-packet reassembled before
	/// ``apply(pgn:source:data:at:)`` — ``NMEATransport`` streams do this.
	public static let deviceInformationPGNs: [UInt32] = [60928, 126996, 126998, 126464, 126993]

	private var byAddress: [UInt8: NMEA2000Device] = [:]

	/// Creates an empty directory.
	public init() {}

	/// The known devices, ordered by source address.
	public var devices: [NMEA2000Device] {
		byAddress.values.sorted { $0.address < $1.address }
	}

	/// The device claiming the given source address, if seen.
	/// - Parameter address: The source address to look up.
	public subscript(address: UInt8) -> NMEA2000Device? {
		byAddress[address]
	}

	/// Feeds one NMEA 2000 frame into the directory.
	///
	/// Frames whose PGN carries no device information only refresh the
	/// address's last-seen date (when the address is already known).
	///
	/// - Parameters:
	///   - pgn: The frame's parameter group number.
	///   - source: The frame's source address.
	///   - data: The reassembled payload.
	///   - date: The observation date. Defaults to now.
	/// - Returns: `true` when the frame added or changed device information.
	@discardableResult
	public mutating func apply(
		pgn: UInt32, source: UInt8, data: [UInt8], at date: Date = Date()
	) -> Bool {
		// Address 255 is the broadcast destination, 254 the null address —
		// neither identifies a device.
		guard source < 252 else { return false }

		guard Self.deviceInformationPGNs.contains(pgn) else {
			if byAddress[source] != nil { byAddress[source]!.lastSeen = date }
			return false
		}

		var device = byAddress[source] ?? NMEA2000Device(address: source, lastSeen: date)
		device.lastSeen = date
		let before = device

		switch pgn {
		case 60928: Self.applyAddressClaim(&device, data)
		case 126996: Self.applyProductInformation(&device, data)
		case 126998: Self.applyConfigurationInformation(&device, data)
		case 126464: Self.applyPGNList(&device, data)
		case 126993: Self.applyHeartbeat(&device, data)
		default: break
		}

		let isNew = byAddress[source] == nil
		byAddress[source] = device
		return isNew || device != before
	}

	/// Removes every known device — e.g. before replaying a capture.
	public mutating func removeAll() {
		byAddress.removeAll()
	}

	// MARK: Interrogation

	/// The ISO Requests (PGN 59904) that make every device announce itself —
	/// one ``OutboundMessage`` per requested PGN (address claim, product
	/// information, configuration information, PGN list). Send them with
	/// ``NMEASession/send(_:)`` — or ``NMEASession/interrogateDevices(destination:)``,
	/// which does exactly this — then collect the answers with
	/// ``apply(pgn:source:data:at:)``.
	///
	/// - Parameter destination: The queried address. Defaults to 255, the
	///   global address — every device answers.
	public static func interrogationMessages(destination: UInt8 = 255) -> [OutboundMessage] {
		let requested: [UInt32] = [60928, 126996, 126998, 126464]
		return requested.map { pgn -> OutboundMessage in
			let data: [UInt8] = [
				UInt8(pgn & 0xFF), UInt8((pgn >> 8) & 0xFF), UInt8((pgn >> 16) & 0xFF),
			]
			return .nmea2000(pgn: 59904, destination: destination, priority: 6, data: data)
		}
	}

	/// The ISO Request transmit lines in the Yacht Devices RAW gateway format
	/// (`canid data…`, one per line) — ``interrogationMessages(destination:)``
	/// pre-encoded for callers that talk to a RAW gateway directly.
	///
	/// - Parameter destination: The queried address. Defaults to 255, the
	///   global address — every device answers.
	public static func interrogationLines(destination: UInt8 = 255) -> [String] {
		interrogationMessages(destination: destination).flatMap { message in
			OutboundEncoder.lines(message, format: .yachtDevicesRaw) ?? []
		}
	}

	// MARK: PGN decoders

	private static func applyAddressClaim(_ device: inout NMEA2000Device, _ d: [UInt8]) {
		guard d.count >= 8 else { return }
		var name: UInt64 = 0
		for k in 0..<8 { name |= UInt64(d[k]) << (8 * k) }
		device.name = name
		device.uniqueNumber = UInt32(name & 0x1F_FFFF)
		device.manufacturerCode = UInt16((name >> 21) & 0x7FF)
		// ECU instance (3 bits) and function instance (5 bits) combine into
		// the NMEA 2000 "device instance".
		device.deviceInstance = UInt8((name >> 32) & 0xFF)
		device.deviceFunction = UInt8((name >> 40) & 0xFF)
		device.deviceClass = UInt8((name >> 49) & 0x7F)
		device.systemInstance = UInt8((name >> 56) & 0x0F)
		device.industryGroup = UInt8((name >> 60) & 0x07)
		device.arbitraryAddressCapable = (name >> 63) & 0x01 == 1
	}

	private static func applyProductInformation(_ device: inout NMEA2000Device, _ d: [UInt8]) {
		guard d.count >= 134 else { return }
		let version = UInt16(d[0]) | UInt16(d[1]) << 8
		if version != 0xFFFF { device.nmea2000Version = Double(version) / 1000 }
		let code = UInt16(d[2]) | UInt16(d[3]) << 8
		if code != 0xFFFF { device.productCode = code }
		device.modelID = fixedString(d, 4)
		device.softwareVersion = fixedString(d, 36)
		device.modelVersion = fixedString(d, 68)
		device.serialNumber = fixedString(d, 100)
		if d[132] != 0xFF { device.certificationLevel = d[132] }
		if d[133] != 0xFF { device.loadEquivalency = d[133] }
	}

	private static func applyConfigurationInformation(_ device: inout NMEA2000Device, _ d: [UInt8]) {
		var at = 0
		device.installationDescription1 = variableString(d, &at)
		device.installationDescription2 = variableString(d, &at)
		device.manufacturerInformation = variableString(d, &at)
	}

	private static func applyPGNList(_ device: inout NMEA2000Device, _ d: [UInt8]) {
		guard d.count >= 4 else { return }
		var pgns: [UInt32] = []
		var at = 1
		while at + 2 < d.count {
			pgns.append(UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16)
			at += 3
		}
		switch d[0] {
		case 0: device.transmittedPGNs = pgns
		case 1: device.receivedPGNs = pgns
		default: break
		}
	}

	private static func applyHeartbeat(_ device: inout NMEA2000Device, _ d: [UInt8]) {
		guard d.count >= 2 else { return }
		let interval = UInt16(d[0]) | UInt16(d[1]) << 8
		if interval != 0xFFFF { device.heartbeatInterval = Double(interval) / 1000 }
	}

	// MARK: String readers

	/// Reads a fixed 32-byte field, trimming the `0x00`/`0xFF`/space padding.
	/// Returns `nil` when the field is entirely padding.
	private static func fixedString(_ d: [UInt8], _ at: Int) -> String? {
		guard at + 32 <= d.count else { return nil }
		let bytes = d[at..<(at + 32)].prefix { $0 != 0x00 && $0 != 0xFF }
		let text = String(decoding: bytes, as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}

	/// Reads one variable-length string field (length byte inclusive of the
	/// two header bytes, type byte, characters) and advances the cursor.
	private static func variableString(_ d: [UInt8], _ at: inout Int) -> String? {
		guard at + 1 < d.count else { return nil }
		let length = Int(d[at])
		guard length >= 2, at + length <= d.count else { return nil }
		let bytes = d[(at + 2)..<(at + length)].prefix { $0 != 0x00 && $0 != 0xFF }
		at += length
		let text = String(decoding: bytes, as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}
}

// MARK: - Registered names

extension NMEA2000DeviceDirectory {

	/// NMEA-registered manufacturer codes — the marine industry's usual
	/// suspects. Unknown codes render as `manufacturer N`.
	static let manufacturers: [UInt16: String] = [
		69: "ARKS Enterprises",
		78: "FW Murphy",
		80: "Twin Disc",
		85: "Kohler",
		88: "Hemisphere GPS",
		116: "BEP Marine",
		135: "Airmar",
		137: "Maretron",
		140: "Lowrance",
		144: "Mercury Marine",
		147: "Nautibus",
		154: "Westerbeke",
		161: "Offshore Systems",
		163: "Evinrude / BRP",
		168: "Xantrex",
		172: "Yanmar",
		174: "Volvo Penta",
		176: "Carling Technologies",
		192: "FloScan",
		193: "Nobeltec",
		229: "Garmin",
		235: "Airmar",
		243: "Coelmo",
		273: "Actisense",
		275: "Navico",
		286: "SamwonIT",
		304: "EmpirBus",
		311: "Fischer Panda",
		315: "ICOM",
		341: "Böning Automationstechnologie",
		345: "Korean Maritime University",
		351: "Thrane & Thrane",
		355: "Mastervolt",
		358: "Victron Energy",
		370: "Rolls Royce Marine",
		373: "Electronic Design",
		374: "Northern Lights",
		378: "Glendinning",
		381: "B&G",
		385: "Johnson Outdoors (Humminbird)",
		394: "Capi 2",
		396: "Beyond Measure",
		400: "Livorsi Marine",
		404: "ComNav",
		409: "Chetco",
		419: "Fusion Electronics",
		421: "Standard Horizon",
		422: "True Heading",
		426: "Egersund Marine Electronics",
		427: "em-trak",
		431: "Tohatsu",
		437: "Digital Yacht",
		438: "Comar Systems",
		440: "Cummins",
		451: "Parker Hannifin",
		459: "Alltek Marine (AMEC)",
		460: "San Giorgio S.E.I.N.",
		466: "Veethree",
		470: "SI-TEX",
		471: "Sea Recovery",
		481: "GME / Standard Communications",
		493: "Watcheye",
		499: "LCJ Capteurs",
		502: "Attwood Marine",
		503: "Naviop",
		504: "Vesper Marine",
		510: "Marinesoft",
		517: "NoLand Engineering",
		518: "Transas",
		573: "Orolia (McMurdo)",
		578: "Advansea",
		579: "KVH",
		580: "San Jose Technology",
		583: "Yacht Control",
		586: "Suzuki Motor Corporation",
		591: "US Coast Guard",
		595: "Ship Module",
		600: "Aquatic AV",
		605: "Aventics",
		606: "Intellian",
		641: "Diverse Yacht Services",
		644: "KUS / Wema",
		658: "Himunication",
		688: "Rockford Corporation",
		704: "JL Audio",
		717: "Yacht Devices",
		826: "Lewmar",
		1053: "Vetus Maxwell",
		1070: "Quick-teck Electronics",
		1850: "Teleflex Marine",
		1851: "Raymarine",
		1852: "Navionics",
		1853: "Japan Radio Co (JRC)",
		1854: "Northstar Technologies",
		1855: "Furuno",
		1856: "Trimble",
		1857: "Simrad",
		1858: "Litton",
		1859: "Kvasar",
		1860: "MMP",
		1861: "Vector Cantech",
		1862: "Yamaha Marine",
		1863: "Faria Instruments",
	]

	/// ISO device class codes.
	static let deviceClasses: [UInt8: String] = [
		0: "Reserved",
		10: "System Tools",
		20: "Safety Systems",
		25: "Internetwork Device",
		30: "Electrical Distribution",
		35: "Electrical Generation",
		40: "Steering and Control Surfaces",
		50: "Propulsion",
		60: "Navigation",
		70: "Communication",
		75: "Sensor Communication Interface",
		80: "Instrumentation / General Systems",
		85: "External Environment",
		90: "Internal Environment",
		100: "Deck, Cargo and Fishing Equipment",
		110: "Human Interface",
		120: "Display",
		125: "Entertainment",
	]

	/// ISO device function codes, keyed by `class << 8 | function` (functions
	/// only have meaning within their device class).
	static let deviceFunctions: [UInt16: String] = [
		// System Tools (10)
		10 << 8 | 130: "Diagnostic",
		10 << 8 | 140: "Bus Traffic Logger",
		// Safety Systems (20)
		20 << 8 | 110: "Alarm Enunciator",
		20 << 8 | 130: "EPIRB",
		20 << 8 | 135: "Man Overboard",
		20 << 8 | 140: "Voyage Data Recorder",
		20 << 8 | 150: "Camera",
		// Internetwork Device (25)
		25 << 8 | 130: "PC Gateway",
		25 << 8 | 131: "NMEA 2000 to Analog Gateway",
		25 << 8 | 132: "Analog to NMEA 2000 Gateway",
		25 << 8 | 133: "NMEA 2000 to Serial Gateway",
		25 << 8 | 135: "NMEA 0183 Gateway",
		25 << 8 | 136: "NMEA Network Gateway",
		25 << 8 | 137: "NMEA 2000 Wireless Gateway",
		25 << 8 | 140: "Router",
		25 << 8 | 150: "Bridge",
		25 << 8 | 160: "Repeater",
		// Electrical Distribution (30)
		30 << 8 | 130: "Binary Event Monitor",
		30 << 8 | 140: "Load Controller",
		30 << 8 | 141: "AC/DC Input",
		30 << 8 | 150: "Function Controller",
		// Electrical Generation (35)
		35 << 8 | 140: "Engine",
		35 << 8 | 141: "DC Generator / Alternator",
		35 << 8 | 142: "Solar Panel",
		35 << 8 | 143: "Wind Generator",
		35 << 8 | 144: "Fuel Cell",
		35 << 8 | 145: "Network Power Supply",
		35 << 8 | 151: "Battery",
		35 << 8 | 152: "Engine Gateway",
		35 << 8 | 153: "Battery Charger",
		35 << 8 | 154: "Combined Charger / Inverter",
		35 << 8 | 160: "Inverter",
		// Steering and Control Surfaces (40)
		40 << 8 | 130: "Follow-up Controller",
		40 << 8 | 140: "Mode Controller",
		40 << 8 | 150: "Autopilot",
		40 << 8 | 155: "Rudder",
		40 << 8 | 160: "Heading Sensors",
		40 << 8 | 170: "Trim / Interceptors",
		40 << 8 | 180: "Attitude Control",
		// Propulsion (50)
		50 << 8 | 130: "Engineroom Monitoring",
		50 << 8 | 140: "Engine",
		50 << 8 | 150: "Engine Controller",
		50 << 8 | 155: "Motor",
		50 << 8 | 160: "Engine Gateway",
		50 << 8 | 165: "Transmission",
		50 << 8 | 170: "Throttle / Shift Control",
		50 << 8 | 180: "Actuator",
		50 << 8 | 190: "Gauge Interface",
		50 << 8 | 200: "Gauge Large",
		50 << 8 | 210: "Gauge Small",
		// Navigation (60)
		60 << 8 | 130: "Bottom Depth",
		60 << 8 | 135: "Bottom Depth / Speed",
		60 << 8 | 136: "Bottom Depth / Speed / Temperature",
		60 << 8 | 140: "Ownship Attitude",
		60 << 8 | 145: "Ownship Position (GNSS)",
		60 << 8 | 150: "Ownship Position (Loran C)",
		60 << 8 | 155: "Speed",
		60 << 8 | 160: "Turn Rate Indicator",
		60 << 8 | 170: "Integrated Navigation",
		60 << 8 | 175: "Integrated Navigation System",
		60 << 8 | 190: "Navigation Management",
		60 << 8 | 195: "AIS",
		60 << 8 | 200: "Radar",
		60 << 8 | 201: "Infrared Imaging",
		60 << 8 | 205: "ECDIS",
		60 << 8 | 210: "ECS",
		60 << 8 | 220: "Direction Finder",
		60 << 8 | 230: "Voyage Status",
		// Communication (70)
		70 << 8 | 130: "EPIRB",
		70 << 8 | 140: "AIS",
		70 << 8 | 150: "DSC",
		70 << 8 | 160: "Data Receiver / Transceiver",
		70 << 8 | 170: "Radiotelephone",
		70 << 8 | 180: "Satellite",
		70 << 8 | 190: "Radio-telephone (MF/HF)",
		70 << 8 | 200: "Radiotelephone (VHF)",
		// Sensor Communication Interface (75)
		75 << 8 | 130: "Temperature",
		75 << 8 | 140: "Pressure",
		75 << 8 | 150: "Fluid Level",
		75 << 8 | 160: "Flow",
		75 << 8 | 170: "Humidity",
		// Instrumentation / General (80)
		80 << 8 | 130: "Time / Date Systems",
		80 << 8 | 140: "VDR",
		80 << 8 | 150: "Integrated Instrumentation",
		80 << 8 | 160: "General Purpose Displays",
		80 << 8 | 170: "General Sensor Box",
		80 << 8 | 180: "Weather Instruments",
		80 << 8 | 190: "Transducer / General",
		80 << 8 | 200: "NMEA 0183 Converter",
		// External Environment (85)
		85 << 8 | 130: "Atmospheric",
		85 << 8 | 160: "Aquatic",
		// Internal Environment (90)
		90 << 8 | 130: "HVAC",
		// Deck, Cargo and Fishing (100)
		100 << 8 | 130: "Scale (Catch)",
		// Display (120)
		120 << 8 | 130: "Display",
		120 << 8 | 140: "Alarm Enunciator",
		// Entertainment (125)
		125 << 8 | 130: "Multimedia Player",
		125 << 8 | 140: "Multimedia Controller",
	]
}
