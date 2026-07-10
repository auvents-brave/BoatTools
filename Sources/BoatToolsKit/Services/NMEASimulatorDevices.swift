internal import Foundation

/// The simulated NMEA 2000 devices behind ``NMEASimulator/session(route:speedKnots:timeMultiplier:updateInterval:loop:)``:
/// a Raymarine Evolution autopilot and two windlasses (bow and stern) that
/// answer the ISO Request roll call, broadcast their status and obey the
/// commands sent back on the session — so remote-control panels can be
/// exercised with no boat attached.
final class SimulatedDevices: @unchecked Sendable {
	// @unchecked: every mutable member is only ever touched under `lock`.
	private let lock = NSLock()

	private struct Pilot {
		/// 0 standby · 1 auto · 2 wind · 3 track (the decoder's mapping).
		var mode: UInt8 = 0
		/// Locked heading, degrees magnetic.
		var target: Double = 0
	}

	private struct Windlass {
		var chainOut: Double
		/// 0 off · 1 down · 2 up (the 128776 direction-control values).
		var direction: UInt8 = 0
	}

	private var pilot = Pilot()
	private var windlasses = [Windlass(chainOut: 0), Windlass(chainOut: 18)]
	/// Claims and product information are (re)broadcast when `true` — on
	/// start-up and after every roll call.
	private var announce = true
	/// The vessel's current heading, refreshed each tick — the locked heading
	/// starts here when the pilot engages.
	private var heading: Double = 0

	let pilotAddress: UInt8 = 204
	let windlassAddresses: [UInt8] = [18, 19]

	// MARK: Commands

	/// Obeys one command sent on the simulator session.
	func handle(_ message: OutboundMessage) {
		guard case .nmea2000(let pgn, _, _, let data) = message else { return }
		lock.withLock {
			switch pgn {
			case 59904:
				// Any ISO Request re-announces the network.
				announce = true
			case 126208:
				handleCommandGroup(data)
			case 126720:
				handleKeystroke(data)
			default:
				break
			}
		}
	}

	/// PGN 126208 Command Group Function — the windlass order and the
	/// Raymarine mode / locked-heading writes.
	private func handleCommandGroup(_ d: [UInt8]) {
		guard d.count >= 6, d[0] == 0x01 else { return }
		let target = UInt32(d[1]) | UInt32(d[2]) << 8 | UInt32(d[3]) << 16
		switch target {
		case 128776:
			// Pairs: (field 2, windlass ID), (field 3, direction control).
			var id: UInt8 = 0
			var direction: UInt8?
			var at = 6
			while at + 1 < d.count {
				switch d[at] {
				case 2: id = d[at + 1]
				case 3: direction = d[at + 1]
				default: break
				}
				at += 2
			}
			if let direction, Int(id) < windlasses.count {
				windlasses[Int(id)].direction = direction
			}
		case 65379:
			// The Raymarine mode write — mode u16 rides bytes 12-13.
			guard d.count >= 14 else { return }
			switch UInt16(d[12]) | UInt16(d[13]) << 8 {
			case 0: pilot.mode = 0
			case 64:
				pilot.mode = 1
				pilot.target = heading
			case 256: pilot.mode = 2
			case 384, 385: pilot.mode = 3
			default: break
			}
		case 65360:
			// The Raymarine locked-heading write — u16, 1e-4 rad.
			guard d.count >= 14 else { return }
			let raw = UInt16(d[12]) | UInt16(d[13]) << 8
			pilot.target = Double(raw) * 1e-4 * 180 / .pi
		default:
			break
		}
	}

	/// PGN 126720 SeaTalk keystrokes — the ±1° / ±10° course keys.
	private func handleKeystroke(_ d: [UInt8]) {
		guard d.count >= 8, d[4] == 0x86 else { return }
		let step: Double
		switch d[6] {
		case 0x07: step = 1
		case 0x08: step = 10
		case 0x05: step = -1
		case 0x06: step = -10
		default: return
		}
		pilot.target = (pilot.target + step + 360).truncatingRemainder(dividingBy: 360)
	}

	// MARK: Status broadcast

	/// The device frames due this tick: claims and product information when
	/// (re)announcing, the pilot's mode and locked heading, and each
	/// windlass's operating status — the chain paying out or hauling in as
	/// long as its motor runs.
	///
	/// - Parameters:
	///   - heading: The vessel's current heading, degrees.
	///   - dt: Simulated seconds elapsed since the previous tick.
	/// - Returns: Frames as (pgn, source, data) triples.
	func statusFrames(heading: Double, dt: Double) -> [(pgn: UInt32, source: UInt8, data: [UInt8])] {
		lock.withLock {
			self.heading = heading
			var frames: [(UInt32, UInt8, [UInt8])] = []

			if announce {
				announce = false
				frames.append(
					(
						60928, pilotAddress,
						Self.claim(
							uniqueNumber: 771_851, manufacturer: 1851, function: 150, deviceClass: 40)
					))
				frames.append(
					(
						126996, pilotAddress,
						Self.productInformation(
							code: 3_100, model: "EV-1 Course Computer", software: "3.10", serial: "SIM-EV1")
					))
				let makers: [(UInt16, String, String)] = [
					(826, "V700 Windlass", "SIM-V700"),
					(1053, "RC8 Windlass", "SIM-RC8"),
				]
				for (index, address) in windlassAddresses.enumerated() {
					let (manufacturer, model, serial) = makers[index]
					frames.append(
						(
							60928, address,
							Self.claim(
								uniqueNumber: 820_000 + UInt32(index), manufacturer: manufacturer,
								function: 130, deviceClass: 100)
						))
					frames.append(
						(
							126996, address,
							Self.productInformation(
								code: 700 + UInt16(index), model: model, software: "1.4", serial: serial)
						))
					frames.append(
						(
							126464, address,
							Self.pgnList(
								function: 0, [128776, 128777, 128778])
						))
				}
			}

			// Pilot status: mode every tick, the locked heading when engaged.
			let mode: UInt16
			switch pilot.mode {
			case 1: mode = 64
			case 2: mode = 256
			case 3: mode = 384
			default: mode = 0
			}
			frames.append(
				(
					65379, pilotAddress,
					[
						0x3B, 0x9F, UInt8(mode & 0xFF), UInt8(mode >> 8), 0xFF, 0xFF, 0xFF, 0xFF,
					]
				))
			if pilot.mode != 0 {
				let raw = UInt16((pilot.target * .pi / 180 * 1e4).rounded())
				frames.append(
					(
						65360, pilotAddress,
						[
							0x3B, 0x9F, 0x00,
							UInt8(raw & 0xFF), UInt8(raw >> 8),
							UInt8(raw & 0xFF), UInt8(raw >> 8),
							0xFF,
						]
					))
			}

			// Windlasses: run the chain while the motor is on, stop at the ends.
			for index in windlasses.indices {
				let speed = 0.3  // metres of chain per simulated second
				switch windlasses[index].direction {
				case 1:
					windlasses[index].chainOut = min(60, windlasses[index].chainOut + speed * dt)
					if windlasses[index].chainOut >= 60 { windlasses[index].direction = 0 }
				case 2:
					windlasses[index].chainOut = max(0, windlasses[index].chainOut - speed * dt)
					if windlasses[index].chainOut <= 0 { windlasses[index].direction = 0 }
				default:
					break
				}
				frames.append(
					(
						128777, windlassAddresses[index],
						Self.operatingStatus(
							instance: UInt8(index),
							chainOut: windlasses[index].chainOut,
							chainSpeed: windlasses[index].direction == 0 ? 0 : speed,
							direction: windlasses[index].direction)
					))
			}
			return frames
		}
	}

	// MARK: Payload encoders (mirrors of the decoders)

	private static func claim(
		uniqueNumber: UInt32, manufacturer: UInt16, function: UInt8, deviceClass: UInt8
	) -> [UInt8] {
		var name: UInt64 = UInt64(uniqueNumber & 0x1F_FFFF)
		name |= UInt64(manufacturer & 0x7FF) << 21
		name |= UInt64(function) << 40
		name |= UInt64(deviceClass & 0x7F) << 49
		name |= UInt64(4) << 60  // marine
		name |= 1 << 63  // arbitrary address capable
		return withUnsafeBytes(of: name.littleEndian) { Array($0) }
	}

	private static func productInformation(
		code: UInt16, model: String, software: String, serial: String
	) -> [UInt8] {
		func fixed(_ s: String) -> [UInt8] {
			Array(s.utf8.prefix(32)) + [UInt8](repeating: 0xFF, count: max(0, 32 - s.utf8.count))
		}
		var data: [UInt8] = []
		data += withUnsafeBytes(of: UInt16(2101).littleEndian) { Array($0) }
		data += withUnsafeBytes(of: code.littleEndian) { Array($0) }
		data += fixed(model) + fixed(software) + fixed("1.0") + fixed(serial)
		data += [2, 1]  // certification level, LEN (50 mA)
		return data
	}

	private static func pgnList(function: UInt8, _ pgns: [UInt32]) -> [UInt8] {
		[function]
			+ pgns.flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8(($0 >> 16) & 0xFF)] }
	}

	/// PGN 128777 — Windlass Operating Status. `direction` uses the
	/// control values (0 off, 1 down, 2 up); the motion field encodes
	/// 1 stopped, 2 deploying, 3 retrieving; docking 1 = anchor docked.
	private static func operatingStatus(
		instance: UInt8, chainOut: Double, chainSpeed: Double, direction: UInt8
	) -> [UInt8] {
		let motion: UInt8 = direction == 0 ? 1 : (direction == 1 ? 2 : 3)
		let docking: UInt8 = chainOut <= 0 ? 1 : 2
		let length = UInt16((chainOut * 10).rounded())
		return [
			instance & 0x0F,
			UInt8(length & 0xFF), UInt8(length >> 8),
			UInt8((chainSpeed * 10).rounded()),
			motion | (docking << 4),
			0xFF, 0xFF, 0xFF,
		]
	}
}
