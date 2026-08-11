// Set up an outgoing DSC call on a networked VHF radio — an individual routine
// (voice) call to a station's MMSI, e.g. an AIS target.
//
// The frame is PGN 129808 (DSC Call Information), whose structure is documented
// (canboat decodes it); this encodes it as an individual / routine call. Both
// Garmin and Simrad/Navico MFDs set up a call to their networked radio via
// 129808, so one encoder serves both.
//
// ⚠️ UNVERIFIED on hardware. There is NO published standard for a plotter to
// *command* a radio to place a call, and no open-source example emits 129808 to
// initiate one — only to decode it. The frame here is spec-grounded but whether a
// given radio ACTS on receiving it (vs merely logging it) is brand-specific and
// undocumented. Some fields (proposed channel coding, end-of-sequence symbol,
// whether Navico needs its proprietary companion PGN 130842) are best guesses,
// marked below. Confirm against a bus capture of the boat's own MFD placing a
// call before relying on it.

import Foundation

/// A DSC call could not be set up on the network.
public enum VHFCallError: Error, Equatable {
	/// No DSC-capable VHF radio was heard on the network — interrogate the bus
	/// first, or the radio does not announce PGN 129808 / 129799.
	case noRadio
}

/// Builds the ``OutboundMessage`` that sets up a DSC call on a networked VHF.
public enum VHFCommands {

	// MARK: Device identification

	/// The DSC VHF radio among the given devices — the one declaring the DSC
	/// PGNs (129808 Call Information, 129799 Radio Frequency/Mode/Power) in its
	/// PGN lists, or claiming the Communication device class (25).
	///
	/// - Parameter devices: A device inventory, e.g. ``NMEASession/devices()``.
	/// - Returns: The radio, or `nil` when none was heard.
	public static func dscRadio(in devices: [NMEA2000Device]) -> NMEA2000Device? {
		devices.first { device in
			let declared = (device.transmittedPGNs ?? []) + (device.receivedPGNs ?? [])
			return declared.contains(129808) || declared.contains(129799) || device.deviceClass == 25
		}
	}

	// MARK: Encoding

	/// A DSC 10-digit address as five bytes — each byte a two-digit group, most
	/// significant first (canboat DECIMAL, 40 bits). A ship MMSI is nine digits;
	/// DSC carries it as ten by appending a trailing 0 (MMSI × 10), so 235076393
	/// → 2350763930 → `17 32 4C 27 1E`.
	static func decimalAddress(mmsi: UInt32) -> [UInt8] {
		var value = UInt64(mmsi) * 10
		var pairs = [UInt8](repeating: 0, count: 5)
		for index in stride(from: 4, through: 0, by: -1) {
			pairs[index] = UInt8(value % 100)
			value /= 100
		}
		return pairs
	}

	/// A DSC frequency/channel field — six fixed ASCII bytes. A simplex/duplex
	/// channel is coded `"9000"` + the two-digit channel (matching the canboat
	/// sample, e.g. channel 72 → `"900072"`). ⚠️ Coding assumed; only two-digit
	/// channels are supported.
	static func channelField(_ channel: Int) -> [UInt8] {
		Array(String(format: "9000%02d", max(0, min(99, channel))).utf8)
	}

	/// Sets up an **individual routine** (voice) DSC call to `mmsi`, proposing a
	/// working `channel`.
	///
	/// - Parameters:
	///   - mmsi: The called station's MMSI (e.g. an AIS target's).
	///   - channel: The proposed working channel. Defaults to 72 (ship-to-ship).
	///   - destination: The radio's node address (see ``dscRadio(in:)``), or 255
	///     to broadcast.
	/// - Returns: The message to ``NMEASession/send(_:)`` — PGN 129808, priority
	///   4, sent Fast Packet.
	public static func individualRoutineCall(
		toMMSI mmsi: UInt32, channel: Int = 72, destination: UInt8 = 255
	) -> OutboundMessage {
		var data: [UInt8] = []
		data.append(120)  // DSC Format: Individual stations
		data.append(100)  // DSC Category: Routine
		data += decimalAddress(mmsi: mmsi)  // DSC Message Address (called MMSI)
		data.append(100)  // 1st Telecommand: F3E/G3E All modes TP (telephony)
		data.append(126)  // 2nd Telecommand: No information
		data += channelField(channel)  // Proposed Rx frequency/channel
		data += channelField(channel)  // Proposed Tx frequency/channel
		data += [0x02, 0x01]  // Telephone Number: empty (STRING_LAU: len 2, ASCII)
		data += [0xFF, 0xFF, 0xFF, 0x7F]  // Latitude of Vessel Reported: null
		data += [0xFF, 0xFF, 0xFF, 0x7F]  // Longitude of Vessel Reported: null
		data += [0xFF, 0xFF, 0xFF, 0xFF]  // Time of Position: null
		data += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF]  // MMSI of Ship In Distress: null
		data.append(0x7F)  // DSC EOS Symbol (⚠️ 127, from the spec sample)
		data.append(0xFC)  // Expansion Enabled = No (2 bits) + reserved (6 bits = 1)
		data += [UInt8](repeating: 0xFF, count: 6)  // Calling Rx channel: null
		data += [UInt8](repeating: 0xFF, count: 6)  // Calling Tx channel: null
		data += [0xFF, 0xFF, 0xFF, 0xFF]  // Time of Receipt: null
		data += [0xFF, 0xFF]  // Date of Receipt: null
		data += [0xFF, 0xFF]  // DSC Equipment Assigned Message ID: null
		return .nmea2000(pgn: 129808, destination: destination, priority: 4, data: data)
	}
}

// MARK: - Session sugar

extension NMEASession {

	/// The DSC VHF radio heard on this connection. Interrogate the bus first
	/// when the inventory is empty (``interrogateDevices(destination:)``).
	public func dscRadio() -> NMEA2000Device? {
		VHFCommands.dscRadio(in: devices())
	}

	/// Sets up an individual routine DSC call to `mmsi` on the connection's VHF
	/// radio (addressed to the radio when heard, else broadcast).
	///
	/// - Parameters:
	///   - mmsi: The called station's MMSI.
	///   - channel: The proposed working channel. Defaults to 72.
	/// - Throws: ``VHFCallError/noRadio`` when no radio was heard, or the
	///   ``send(_:)`` transport errors.
	/// - Note: NMEA 2000 only — DSC call set-up has no NMEA 0183 sentence. See
	///   the file header: UNVERIFIED on hardware.
	public func sendDSCCall(toMMSI mmsi: UInt32, channel: Int = 72) async throws {
		guard let radio = dscRadio() else { throw VHFCallError.noRadio }
		try await send(
			VHFCommands.individualRoutineCall(toMMSI: mmsi, channel: channel, destination: radio.address))
	}
}
