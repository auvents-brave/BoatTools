// Command builders for the devices a sailor actually drives: the autopilot
// and the anchor windlass. The windlass command is standard NMEA 2000; the
// autopilot has no standard — each brand speaks its own proprietary dialect,
// so the pilot must first be identified (see ``NMEA2000Commands/autopilot(in:)``)
// and its dialect selected from the manufacturer code of its address claim.

// MARK: - AutopilotBrand

/// The command dialect an autopilot speaks, derived from the manufacturer
/// code of its ISO address claim.
public enum AutopilotBrand: Sendable, Equatable {
	/// Raymarine Evolution (EV-1/EV-2, SeaTalk NG) — commands ride PGN 126208
	/// writes of the proprietary groups 65379 (mode) and 65360 (locked
	/// heading), and PGN 126720 SeaTalk keystrokes for stepwise changes.
	case raymarineEvolution
	/// Navico family (Simrad, B&G, Lowrance) — NAC-2/NAC-3 and predecessors.
	case navico
	case garmin
	case furuno
	/// An autopilot whose dialect is not recognised; carries the raw
	/// manufacturer code when known.
	case other(manufacturerCode: UInt16?)

	/// A display name for status read-outs and error messages.
	public var label: String {
		switch self {
		case .raymarineEvolution: return "Raymarine Evolution"
		case .navico: return "Navico (Simrad / B&G)"
		case .garmin: return "Garmin"
		case .furuno: return "Furuno"
		case .other(let code):
			guard let code else { return "unknown" }
			return NMEA2000DeviceDirectory.manufacturers[code] ?? "manufacturer \(code)"
		}
	}

	/// Maps an address claim's manufacturer code to the dialect family.
	init(manufacturerCode: UInt16?) {
		switch manufacturerCode {
		case 1851: self = .raymarineEvolution
		case 275, 381, 140, 1857: self = .navico
		case 229: self = .garmin
		case 1855: self = .furuno
		default: self = .other(manufacturerCode: manufacturerCode)
		}
	}
}

/// An autopilot found on the network: the device record and its dialect.
public struct AutopilotUnit: Sendable {
	/// The pilot's device record — its address is the command destination.
	public let device: NMEA2000Device
	/// The command dialect selected from the manufacturer code.
	public let brand: AutopilotBrand
}

// MARK: - Commands

/// An order for the autopilot, expressed brand-neutrally; encoding picks the
/// identified pilot's dialect.
public enum AutopilotCommand: Sendable, Equatable {
	/// Disengage — the helm is yours.
	case standby
	/// Engage in heading-hold mode.
	case engage
	/// Engage in wind-vane mode.
	case windVane
	/// Engage in track (route-following) mode.
	case track
	/// Alter course by the given signed number of degrees (decomposed into
	/// the pilot's ±10° / ±1° steps).
	case adjustHeading(degrees: Int)
	/// Set the locked heading to an absolute magnetic value, in degrees.
	case lockHeading(degrees: Double)
}

/// An order for the anchor windlass — standard NMEA 2000 (a command of
/// PGN 128776, Windlass Control Status), understood across brands.
///
/// NMEA 2000 is the only network carrying a standard windlass order: NMEA
/// 0183 defines no windlass sentence, and Signal K has no standard control
/// path for it.
public enum WindlassCommand: Sendable, Equatable {
	/// Haul the anchor up.
	case up
	/// Pay the anchor down.
	case down
	/// Stop the motor.
	case off

	var directionControl: UInt8 {
		switch self {
		case .off: return 0
		case .down: return 1
		case .up: return 2
		}
	}
}

/// A command could not be encoded for the network.
public enum CommandError: Error, Equatable {
	/// No autopilot was heard on the network — interrogate the bus first.
	case noAutopilot
	/// An autopilot was found, but its command dialect is not implemented;
	/// carries the brand label.
	case unsupportedAutopilot(String)
	/// The dialect exists but cannot express this particular command;
	/// carries the command and the dialect labels.
	case unsupportedCommand(String, dialect: String)
}

// MARK: - NMEA2000Commands

/// Builds the ``OutboundMessage``s for autopilot and windlass orders, and
/// locates their target devices in a ``NMEA2000DeviceDirectory`` inventory.
public enum NMEA2000Commands {

	// MARK: Device identification

	/// The autopilot among the given devices, with its command dialect.
	///
	/// A pilot claims ISO device class 40 (Steering and Control Surfaces)
	/// with function 150 (Autopilot); some computers claim neighbouring
	/// steering functions, accepted as fallback.
	///
	/// - Parameter devices: A device inventory, e.g. ``NMEASession/devices()``.
	/// - Returns: The pilot and its dialect, or `nil` when none was heard.
	public static func autopilot(in devices: [NMEA2000Device]) -> AutopilotUnit? {
		let steering = devices.filter { $0.deviceClass == 40 }
		let pilot =
			steering.first { $0.deviceFunction == 150 }
			?? steering.first { [130, 140].contains($0.deviceFunction.map(Int.init) ?? -1) }
		return pilot.map { AutopilotUnit(device: $0, brand: .init(manufacturerCode: $0.manufacturerCode)) }
	}

	/// The windlass among the given devices — the one that declares the
	/// windlass PGNs (128776–128778) in its PGN lists, or claims the
	/// deck-equipment device class.
	///
	/// - Parameter devices: A device inventory, e.g. ``NMEASession/devices()``.
	/// - Returns: The windlass device, or `nil` when none was heard (the
	///   command can still be broadcast — the windlass ID field selects).
	public static func windlass(in devices: [NMEA2000Device]) -> NMEA2000Device? {
		devices.first { device in
			let declared = (device.transmittedPGNs ?? []) + (device.receivedPGNs ?? [])
			return declared.contains { (128776...128778).contains($0) } || device.deviceClass == 100
		}
	}

	// MARK: Windlass

	/// The standard windlass order — a PGN 126208 Command Group Function
	/// writing the Windlass Direction Control field of PGN 128776.
	///
	/// - Parameters:
	///   - command: Up, down or off.
	///   - windlassID: The windlass identifier on installations with more
	///     than one. Defaults to 0.
	///   - destination: The windlass's address when known (see
	///     ``windlass(in:)``), else 255 to broadcast.
	/// - Returns: The message to ``NMEASession/send(_:)``.
	public static func message(
		for command: WindlassCommand, windlassID: UInt8 = 0, destination: UInt8 = 255
	) -> OutboundMessage {
		// Command Group Function: function 1 (command), target PGN 128776
		// little-endian, priority unchanged (0xF8), two parameter pairs —
		// field 2 (Windlass ID) and field 3 (Windlass Direction Control).
		.nmea2000(
			pgn: 126208, destination: destination, priority: 3,
			data: [
				0x01, 0x08, 0xF7, 0x01, 0xF8, 0x02,
				0x02, windlassID,
				0x03, command.directionControl,
			])
	}

	// MARK: Autopilot

	/// The messages carrying an autopilot order in the given brand's dialect.
	///
	/// - Parameters:
	///   - command: The brand-neutral order.
	///   - brand: The pilot's dialect (see ``autopilot(in:)``).
	///   - destination: The pilot's claimed address.
	/// - Returns: The messages to send, in order.
	/// - Throws: ``CommandError/unsupportedAutopilot(_:)`` when the brand's
	///   dialect is not implemented.
	public static func messages(
		for command: AutopilotCommand, brand: AutopilotBrand, destination: UInt8
	) throws -> [OutboundMessage] {
		switch brand {
		case .raymarineEvolution:
			return raymarine(command, destination: destination)
		case .navico:
			return try navico(command, address: destination)
		case .garmin:
			return try garmin(command, destination: destination)
		case .furuno, .other:
			throw CommandError.unsupportedAutopilot(brand.label)
		}
	}

	/// The Seatalk 1 keystroke sentences (`$STALK,86,11,…`) for a Raymarine
	/// pilot reached through an NMEA 0183 converter (ShipModul, Digital
	/// Yacht, Yacht Devices…) — ``NMEASession/send(_:)-swift.method`` selects
	/// them automatically on an 0183 connection.
	///
	/// - Parameter command: The brand-neutral order.
	/// - Returns: The sentences to send, in order.
	/// - Throws: ``CommandError/unsupportedCommand(_:dialect:)`` — Seatalk 1
	///   keystrokes cannot express an absolute locked heading.
	public static func seatalkSentences(for command: AutopilotCommand) throws -> [OutboundMessage] {
		func key(_ code: UInt8) -> OutboundMessage {
			.nmea0183(body: String(format: "STALK,86,11,%02X,%02X", code, ~code))
		}
		switch command {
		case .engage: return [key(0x01)]
		case .standby: return [key(0x02)]
		case .track: return [key(0x03)]
		case .windVane: return [key(0x23)]
		case .adjustHeading(let degrees):
			let (ten, one): (UInt8, UInt8) = degrees < 0 ? (0x06, 0x05) : (0x08, 0x07)
			return [UInt8](repeating: ten, count: abs(degrees) / 10).map(key)
				+ [UInt8](repeating: one, count: abs(degrees) % 10).map(key)
		case .lockHeading:
			throw CommandError.unsupportedCommand("lockHeading", dialect: "SeaTalk 1")
		}
	}

	// MARK: Raymarine Evolution dialect

	/// Encodes an order for a Raymarine Evolution pilot. The recipes are the
	/// SeaTalk NG sequences in common community use (Signal K, OpenCPN):
	/// modes are a 126208 write of proprietary PGN 65379, the locked heading
	/// a write of PGN 65360, and stepwise course changes SeaTalk keystrokes
	/// carried by PGN 126720.
	private static func raymarine(_ command: AutopilotCommand, destination: UInt8) -> [OutboundMessage] {
		switch command {
		case .standby: return [raymarineMode(0x00, 0x00, destination: destination)]
		case .engage: return [raymarineMode(0x40, 0x00, destination: destination)]
		case .windVane: return [raymarineMode(0x00, 0x01, destination: destination)]
		case .track: return [raymarineMode(0x80, 0x01, destination: destination)]
		case .adjustHeading(let degrees):
			// Decompose into the pilot's ±10° / ±1° key presses.
			let tens = abs(degrees) / 10
			let ones = abs(degrees) % 10
			let (ten, one): (UInt8, UInt8) = degrees < 0 ? (0x06, 0x05) : (0x08, 0x07)
			let keys = [UInt8](repeating: ten, count: tens) + [UInt8](repeating: one, count: ones)
			return keys.map { raymarineKeystroke($0, destination: destination) }
		case .lockHeading(let degrees):
			// A 126208 write of PGN 65360's target-heading field, in 1e-4 rad.
			let radians = degrees.truncatingRemainder(dividingBy: 360) * .pi / 180
			let value = UInt16((radians * 10000).rounded())
			return [
				.nmea2000(
					pgn: 126208, destination: destination, priority: 3,
					data: [
						0x01, 0x50, 0xFF, 0x00, 0xF8, 0x03,
						0x01, 0x3B, 0x07,  // manufacturer 1851
						0x03, 0x04,  // industry group: marine
						0x06, UInt8(value & 0xFF), UInt8(value >> 8),
					])
			]
		}
	}

	/// A 126208 write of Raymarine's pilot-mode group (PGN 65379).
	private static func raymarineMode(_ mode: UInt8, _ submode: UInt8, destination: UInt8)
		-> OutboundMessage
	{
		.nmea2000(
			pgn: 126208, destination: destination, priority: 3,
			data: [
				0x01, 0x63, 0xFF, 0x00, 0xF8, 0x04,
				0x01, 0x3B, 0x07,  // manufacturer 1851
				0x03, 0x04,  // industry group: marine
				0x04, mode, submode,
				0x05, 0xFF, 0xFF,  // pilot sub-state: leave unchanged
			])
	}

	// MARK: Navico dialect

	/// Encodes an order for a Navico pilot (Simrad NAC-2/NAC-3, B&G) — the
	/// Simnet AP command, proprietary PGN 130850 (canboat layout; the same
	/// sequences the Signal K autopilot plugin drives a NAC-3 with). Mode
	/// events: 6 standby, 9 heading, 10 nav, 15 wind; course changes are
	/// event 26 with a direction and a relative angle. The dialect has no
	/// absolute locked-heading command.
	private static func navico(_ command: AutopilotCommand, address: UInt8) throws -> [OutboundMessage] {
		// 130850 carries the pilot's Simnet address in-payload and rides
		// broadcast on the bus.
		func event(_ event: UInt8, tail: [UInt8] = [0xFF, 0xFF, 0xFF]) -> OutboundMessage {
			.nmea2000(
				pgn: 130850, destination: 255, priority: 3,
				data: [0x41, 0x9F, address, 0xFF, 0xFF, 0x0A, event, 0x00] + tail)
		}
		switch command {
		case .standby: return [event(6)]
		case .engage: return [event(9)]
		case .windVane: return [event(15)]
		case .track: return [event(10)]
		case .adjustHeading(let degrees):
			let radians = Double(abs(degrees)) * .pi / 180
			let angle = UInt16((radians * 10000).rounded())
			let direction: UInt8 = degrees < 0 ? 2 : 3  // Simnet: 2 port, 3 starboard
			return [event(26, tail: [direction, UInt8(angle & 0xFF), UInt8(angle >> 8), 0xFF])]
		case .lockHeading:
			throw CommandError.unsupportedCommand("lockHeading", dialect: "Navico")
		}
	}

	// MARK: Garmin dialect

	/// Encodes an order for a Garmin Reactor — proprietary PGN 126720
	/// sequences reverse-engineered by the community (alpha quality, tested
	/// against a Reactor 40 with a GHC-20). Modes: standby, heading-hold and
	/// wind; course changes step by ±15° and ±1°. Track engagement and the
	/// absolute locked heading are not known.
	private static func garmin(_ command: AutopilotCommand, destination: UInt8) throws -> [OutboundMessage] {
		func state(_ code: UInt8) -> OutboundMessage {
			.nmea2000(
				pgn: 126720, destination: destination, priority: 7,
				data: [0x0B, 0xE5, 0x98, 0x10, 0x17, 0x04, 0x04, 0x05, 0x0A, 0x00, code, 0x00, 0xFF, 0xFF])
		}
		func step(_ code: UInt8) -> OutboundMessage {
			.nmea2000(
				pgn: 126720, destination: destination, priority: 7,
				data: [0x09, 0xE5, 0x98, 0x10, 0x17, 0x04, 0x04, 0x26, code, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
		}
		switch command {
		case .standby: return [state(0x02)]
		case .engage: return [state(0x05)]
		case .windVane: return [state(0x11)]
		case .track:
			throw CommandError.unsupportedCommand("track", dialect: "Garmin")
		case .adjustHeading(let degrees):
			// The Reactor steps by 15° and 1°: +1 = 0x02, +15 = 0x03,
			// -1 = 0x00, -15 = 0x01.
			let (fifteen, one): (UInt8, UInt8) = degrees < 0 ? (0x01, 0x00) : (0x03, 0x02)
			return [UInt8](repeating: fifteen, count: abs(degrees) / 15).map(step)
				+ [UInt8](repeating: one, count: abs(degrees) % 15).map(step)
		case .lockHeading:
			throw CommandError.unsupportedCommand("lockHeading", dialect: "Garmin")
		}
	}

	/// A SeaTalk keystroke (PGN 126720): key code plus its complement, in the
	/// fixed envelope Evolution pilots expect.
	private static func raymarineKeystroke(_ key: UInt8, destination: UInt8) -> OutboundMessage {
		.nmea2000(
			pgn: 126720, destination: destination, priority: 7,
			data: [
				0x3B, 0x9F, 0xF0, 0x81,  // manufacturer 1851 + marine, proprietary id
				0x86, 0x21,  // SeaTalk datagram: keystroke
				key, ~key,
				0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
				0xC1, 0xC2, 0xCD, 0x66, 0x80, 0xD3, 0x42, 0xB1, 0xC8,
			])
	}
}

// MARK: - Session sugar

extension NMEASession {

	/// The autopilot heard on this connection, with its command dialect.
	/// Interrogate the bus first when the inventory is empty
	/// (``interrogateDevices(destination:)``).
	public func autopilot() -> AutopilotUnit? {
		NMEA2000Commands.autopilot(in: devices())
	}

	/// Sends an order to the connection's autopilot in its own dialect.
	///
	/// On an NMEA 0183 connection the order goes out as Seatalk 1 keystrokes
	/// (`$STALK`, for Raymarine pilots behind a converter — 0183 has no
	/// address claims to identify a pilot by). On an NMEA 2000 connection the
	/// pilot heard on the bus selects the dialect.
	///
	/// - Parameter command: The brand-neutral order.
	/// - Throws: ``CommandError/noAutopilot`` when no pilot was heard,
	///   ``CommandError/unsupportedAutopilot(_:)`` /
	///   ``CommandError/unsupportedCommand(_:dialect:)`` for dialect gaps,
	///   or the ``send(_:)`` transport errors.
	public func send(_ command: AutopilotCommand) async throws {
		if resolvedFormat == .nmea0183 {
			for message in try NMEA2000Commands.seatalkSentences(for: command) {
				try await send(message)
			}
			return
		}
		guard let pilot = autopilot() else { throw CommandError.noAutopilot }
		for message in try NMEA2000Commands.messages(
			for: command, brand: pilot.brand, destination: pilot.device.address)
		{
			try await send(message)
		}
	}

	/// Sends an order to the anchor windlass — addressed to the windlass
	/// heard on this connection, or broadcast when none was.
	///
	/// - Parameters:
	///   - command: Up, down or off.
	///   - windlassID: The windlass identifier. Defaults to 0.
	/// - Throws: The ``send(_:)`` transport errors.
	public func send(_ command: WindlassCommand, windlassID: UInt8 = 0) async throws {
		let destination = NMEA2000Commands.windlass(in: devices())?.address ?? 255
		try await send(
			NMEA2000Commands.message(
				for: command, windlassID: windlassID, destination: destination))
	}
}
