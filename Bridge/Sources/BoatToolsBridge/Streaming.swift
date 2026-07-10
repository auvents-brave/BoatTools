// Streaming connections for the C ABI: open a TCP / UDP / simulator NMEA
// source, poll the decoded metrics from C#, close. The C# side polls rather
// than registering callbacks — the FFI stays one-directional, so no managed
// delegate ever has to survive a native thread.

internal import BoatToolsKit
internal import Foundation
internal import Synchronization

// MARK: - Poll payloads

/// One decoded metric, as serialised to the C# side.
struct MetricPayload: Encodable {
	let name: String
	let value: Double
	let unit: String?
	/// Seconds since the Unix epoch.
	let t: Double
}

/// One AIS target, as serialised to the C# side. `kind` mirrors the Swift
/// app's classification: `vessel`, `aid`, `base`, `sar` or `distress`.
struct AisPayload: Encodable {
	let mmsi: Int
	let lat: Double
	let lon: Double
	let heading: Double?
	let sog: Double?
	let name: String?
	let kind: String
	let stale: Bool
}

/// What one `boattools_bridge_poll` call returns.
struct PollPayload: Encodable {
	/// `running`, `ended` (stream finished), `failed` (see `error`) or
	/// `unknown` (bad handle).
	let status: String
	let error: String?
	let metrics: [MetricPayload]
	/// The AIS picture as of this poll — the latest state per target, not a
	/// delta; targets quiet for over ten minutes are flagged stale.
	let ais: [AisPayload]
}

/// One NMEA 2000 network device, as serialised to the C# side. Labels come
/// pre-resolved (manufacturer, class and function names) so the host needs no
/// tables of its own.
struct DevicePayload: Encodable {
	let address: Int
	let name: String
	let manufacturer: String?
	let manufacturerCode: Int?
	let uniqueNumber: Int?
	let deviceClass: String?
	let deviceFunction: String?
	let deviceInstance: Int?
	let systemInstance: Int?
	let industryGroup: String?
	let selfAddressing: Bool?
	let model: String?
	let productCode: Int?
	let nmea2000Version: Double?
	let software: String?
	let modelVersion: String?
	let serial: String?
	let certification: Int?
	let len: Int?
	let installation1: String?
	let installation2: String?
	let manufacturerInfo: String?
	let transmits: [Int]?
	let receives: [Int]?
	/// Heartbeat interval in seconds.
	let heartbeat: Double?
	/// Seconds since the Unix epoch.
	let lastSeen: Double

	init(_ device: NMEA2000Device) {
		address = Int(device.address)
		name = device.displayName
		manufacturer = device.manufacturerName
		manufacturerCode = device.manufacturerCode.map(Int.init)
		uniqueNumber = device.uniqueNumber.map(Int.init)
		deviceClass = device.deviceClassName
		deviceFunction = device.deviceFunctionName
		deviceInstance = device.deviceInstance.map(Int.init)
		systemInstance = device.systemInstance.map(Int.init)
		industryGroup = device.industryGroupName
		selfAddressing = device.arbitraryAddressCapable
		model = device.modelID
		productCode = device.productCode.map(Int.init)
		nmea2000Version = device.nmea2000Version
		software = device.softwareVersion
		modelVersion = device.modelVersion
		serial = device.serialNumber
		certification = device.certificationLevel.map(Int.init)
		len = device.loadEquivalency.map(Int.init)
		installation1 = device.installationDescription1
		installation2 = device.installationDescription2
		manufacturerInfo = device.manufacturerInformation
		transmits = device.transmittedPGNs.map { $0.map(Int.init) }
		receives = device.receivedPGNs.map { $0.map(Int.init) }
		heartbeat = device.heartbeatInterval
		lastSeen = device.lastSeen.timeIntervalSince1970
	}
}

/// What one `boattools_bridge_devices` call returns.
struct DevicesPayload: Encodable {
	/// Same values as ``PollPayload/status``.
	let status: String
	let devices: [DevicePayload]
}

// MARK: - Connection

/// One live connection: the consuming task appends, `drain()` empties the
/// buffer into a poll payload.
final class BridgeConnection: Sendable {
	private struct State {
		var status = "running"
		var error: String?
		var metrics: [MetricPayload] = []
		var targets: [Int: (target: AISTarget, seen: Date)] = [:]
		var devices = NMEA2000DeviceDirectory()
	}

	private let state = Mutex(State())

	func append(_ metric: BoatMetric) {
		state.withLock { s in
			s.metrics.append(
				MetricPayload(
					name: metric.name,
					value: metric.value,
					unit: metric.unit,
					t: metric.timestamp.timeIntervalSince1970
				))
			// Cap the buffer so a stalled poller cannot grow it unbounded.
			if s.metrics.count > 1024 {
				s.metrics.removeFirst(s.metrics.count - 1024)
			}
		}
	}

	/// Remembers the latest state of an AIS target (keyed by MMSI).
	func update(_ target: AISTarget) {
		guard target.latitude != nil, target.longitude != nil else { return }
		state.withLock { s in
			s.targets[target.mmsi] = (target, Date())
			// Bound memory: forget targets gone for over an hour.
			if s.targets.count > 512 {
				let horizon = Date().addingTimeInterval(-3600)
				s.targets = s.targets.filter { $0.value.seen > horizon }
			}
		}
	}

	/// Feeds one raw NMEA 2000 frame into the connection's device directory.
	func observeDevice(pgn: UInt32, source: UInt8, data: [UInt8]) {
		state.withLock { s in
			s.devices.apply(pgn: pgn, source: source, data: data)
		}
	}

	/// The network device inventory as of now.
	func devicesPayload() -> DevicesPayload {
		state.withLock { s in
			DevicesPayload(status: s.status, devices: s.devices.devices.map(DevicePayload.init))
		}
	}

	func finish(error: String?) {
		state.withLock { s in
			s.status = error == nil ? "ended" : "failed"
			s.error = error
		}
	}

	func drain() -> PollPayload {
		state.withLock { s in
			let now = Date()
			let ais = s.targets.values.compactMap { entry -> AisPayload? in
				guard let lat = entry.target.latitude, let lon = entry.target.longitude else {
					return nil
				}
				// Heading falls back to the course, out-of-range values dropped —
				// the same rule as the Swift app's AIS mapping.
				var heading = entry.target.trueHeading.map(Double.init) ?? entry.target.courseOverGround
				if let value = heading, !(0..<360).contains(value) { heading = nil }
				return AisPayload(
					mmsi: entry.target.mmsi,
					lat: lat, lon: lon,
					heading: heading,
					sog: entry.target.speedOverGround,
					name: entry.target.shipName,
					kind: Self.kind(for: entry.target),
					stale: now.timeIntervalSince(entry.seen) > 600
				)
			}
			.sorted { $0.mmsi < $1.mmsi }
			let payload = PollPayload(status: s.status, error: s.error, metrics: s.metrics, ais: ais)
			s.metrics.removeAll(keepingCapacity: true)
			return payload
		}
	}

	/// The full latest record for one target, with when it was last heard.
	func target(mmsi: Int) -> (target: AISTarget, seen: Date)? {
		state.withLock { $0.targets[mmsi] }
	}

	/// Classifies a target the way the Swift app does: a SART/EPIRB MMSI range
	/// means distress; otherwise the message type tells aids to navigation,
	/// base stations and SAR aircraft apart from ordinary vessels.
	static func kind(for target: AISTarget) -> String {
		if (970_000_000...974_999_999).contains(target.mmsi) { return "distress" }
		switch target.messageType {
		case .aidToNavigationReport: return "aid"
		case .baseStationReport: return "base"
		case .standardSARAircraftReport: return "sar"
		default: return "vessel"
		}
	}
}

// MARK: - Registry

/// The open connections, keyed by the opaque handle handed to C#.
final class ConnectionRegistry: Sendable {
	private struct Entry {
		let connection: BridgeConnection
		let task: Task<Void, Never>
		/// The transport session behind the stream, when the connection can
		/// also transmit (TCP) — nil for simulator and device-feed handles.
		let session: NMEASession?
	}

	private struct State {
		var nextHandle: Int64 = 1
		var entries: [Int64: Entry] = [:]
	}

	private let state = Mutex(State())

	/// Starts consuming `stream` and returns the handle for poll / close.
	func open(
		_ stream: AsyncThrowingStream<NMEAFrame, any Error>, session: NMEASession? = nil
	) -> Int64 {
		let connection = BridgeConnection()
		let task = Task {
			do {
				for try await frame in stream {
					switch frame {
					case .metric(let metric): connection.append(metric)
					case .aisTarget(let target): connection.update(target)
					case .nmea2000(let pgn, let source, _, let data):
						connection.observeDevice(pgn: pgn, source: source, data: data)
					default: break
					}
				}
				connection.finish(error: nil)
			} catch {
				connection.finish(error: "\(error)")
			}
		}
		return state.withLock { s in
			let handle = s.nextHandle
			s.nextHandle += 1
			s.entries[handle] = Entry(connection: connection, task: task, session: session)
			return handle
		}
	}

	func connection(_ handle: Int64) -> BridgeConnection? {
		state.withLock { $0.entries[handle]?.connection }
	}

	func session(_ handle: Int64) -> NMEASession? {
		state.withLock { $0.entries[handle]?.session }
	}

	func close(_ handle: Int64) {
		let entry = state.withLock { $0.entries.removeValue(forKey: handle) }
		entry?.task.cancel()
	}
}

let registry = ConnectionRegistry()

// MARK: - C ABI

/// Opens a TCP client connection to an NMEA 0183 / NMEA 2000 / Signal K
/// source (wire format auto-detected by BoatToolsKit).
/// - Returns: A handle (> 0) for `boattools_bridge_poll` / `boattools_bridge_close`,
///   or 0 when the arguments are invalid.
@_cdecl("boattools_bridge_open_tcp")
public func boattools_bridge_open_tcp(_ host: UnsafePointer<CChar>?, _ port: Int32) -> Int64 {
	guard let host, port > 0 else { return 0 }
	let config = NMEATransportConfig(mode: .tcp(host: String(cString: host), port: Int(port)))
	let session = NMEATransport.session(config: config)
	return registry.open(session.frames, session: session)
}

/// Opens a UDP receiver bound to `port`, optionally joining a multicast group
/// (pass NULL or an empty string for plain unicast/broadcast).
/// - Returns: A handle (> 0), or 0 when the arguments are invalid.
@_cdecl("boattools_bridge_open_udp")
public func boattools_bridge_open_udp(_ port: Int32, _ multicastGroup: UnsafePointer<CChar>?) -> Int64 {
	guard port > 0 else { return 0 }
	let group = multicastGroup.map { String(cString: $0) }
	let config = NMEATransportConfig(
		mode: .udp(listenPort: Int(port), multicastGroup: (group?.isEmpty ?? true) ? nil : group))
	return registry.open(NMEATransport.frameStream(config: config))
}

/// Opens BoatToolsKit's synthetic passage (Monaco → La Maddalena) — live data
/// with no boat attached. `speedKnots` ≤ 0 defaults to 6 kn; `timeMultiplier`
/// fast-forwards the movement (clamped to ≥ 1).
/// - Returns: A handle (> 0).
@_cdecl("boattools_bridge_open_simulator")
public func boattools_bridge_open_simulator(_ speedKnots: Double, _ timeMultiplier: Double) -> Int64 {
	registry.open(
		NMEASimulator.frameStream(
			route: .monacoToMaddalena,
			speedKnots: speedKnots > 0 ? speedKnots : 6,
			timeMultiplier: max(1, timeMultiplier)
		))
}

/// Drains the metrics decoded since the previous poll, as JSON:
/// `{"status","error","metrics":[{name,value,unit,t}]}` — `status` is
/// `running` / `ended` / `failed` / `unknown` (bad handle).
/// - Returns: A JSON string to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_poll")
public func boattools_bridge_poll(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
	guard let connection = registry.connection(handle) else {
		return cString(#"{"status":"unknown","metrics":[],"ais":[]}"#)
	}
	guard let data = try? JSONEncoder().encode(connection.drain()) else {
		return cString(#"{"status":"failed","error":"encoding failed","metrics":[],"ais":[]}"#)
	}
	return cString(String(decoding: data, as: UTF8.self))
}

/// The inventory of the devices heard on the NMEA 2000 network over this
/// connection, as JSON: `{"status","devices":[{address,name,manufacturer,
/// deviceClass,deviceFunction,model,serial,software,transmits,receives,
/// heartbeat,lastSeen,…}]}`. Labels come pre-resolved; absent fields were not
/// (yet) announced by the device — devices announce on power-up, on an ISO
/// Request, and via periodic heartbeats.
/// - Returns: A JSON string to release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_devices")
public func boattools_bridge_devices(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
	guard let connection = registry.connection(handle) else {
		return cString(#"{"status":"unknown","devices":[]}"#)
	}
	guard let data = try? JSONEncoder().encode(connection.devicesPayload()) else {
		return cString(#"{"status":"failed","devices":[]}"#)
	}
	return cString(String(decoding: data, as: UTF8.self))
}

/// Broadcasts the ISO Request roll call on the connection, so every device
/// on the NMEA 2000 network announces itself — collect the answers with
/// `boattools_bridge_devices`. Only TCP connections whose wire format accepts
/// transmissions can do this; format auto-detection needs at least one
/// received line first.
/// - Returns: 1 when the requests were dispatched, 0 when the connection
///   cannot transmit (unknown handle, UDP/simulator, or format unresolved).
@_cdecl("boattools_bridge_interrogate")
public func boattools_bridge_interrogate(_ handle: Int64) -> Int32 {
	guard let session = registry.session(handle), session.isTransmitCapable else { return 0 }
	Task { try? await session.interrogateDevices() }
	return 1
}

/// Sends an order to the autopilot heard on the connection, in its brand's
/// dialect. `action` is one of `standby`, `auto`, `wind`, `track`, `adjust`
/// (relative degrees in `value`) or `heading` (absolute magnetic degrees in
/// `value`).
/// - Returns: JSON `{"ok",...}` — on success with the pilot's identity
///   (`{"ok":true,"pilot":{"address","name","brand"}}`), else with an
///   `error` message (cannot transmit, no pilot heard, unknown action, or a
///   dialect not yet implemented). Release with `boattools_bridge_string_free`.
@_cdecl("boattools_bridge_autopilot")
public func boattools_bridge_autopilot(
	_ handle: Int64, _ action: UnsafePointer<CChar>?, _ value: Double
) -> UnsafeMutablePointer<CChar>? {
	func failure(_ message: String) -> UnsafeMutablePointer<CChar>? {
		cString(#"{"ok":false,"error":"\#(message)"}"#)
	}
	guard let session = registry.session(handle), session.isTransmitCapable else {
		return failure("connection cannot transmit")
	}
	let command: AutopilotCommand
	switch action.map({ String(cString: $0).lowercased() }) {
	case "standby": command = .standby
	case "auto", "engage": command = .engage
	case "wind": command = .windVane
	case "track", "route": command = .track
	case "adjust": command = .adjustHeading(degrees: Int(value.rounded()))
	case "heading": command = .lockHeading(degrees: value)
	default: return failure("unknown action")
	}
	// Seatalk 1 converters carry the order as $STALK keystrokes — 0183 has
	// no address claims, so no pilot identification is possible there.
	if session.resolvedFormat == .nmea0183 {
		guard let messages = try? NMEA2000Commands.seatalkSentences(for: command) else {
			return failure("SeaTalk 1 keystrokes cannot carry this command")
		}
		Task {
			for message in messages { try? await session.send(message) }
		}
		return cString(
			#"{"ok":true,"pilot":{"address":-1,"name":"SeaTalk 1 ($STALK)","brand":"Raymarine SeaTalk"}}"#)
	}
	guard let pilot = session.autopilot() else {
		return failure("no autopilot heard — interrogate first")
	}
	let messages: [OutboundMessage]
	do {
		messages = try NMEA2000Commands.messages(
			for: command, brand: pilot.brand, destination: pilot.device.address)
	} catch {
		return failure("the \(pilot.brand.label) dialect is not implemented yet")
	}
	Task {
		for message in messages { try? await session.send(message) }
	}
	let payload: [String: Any] = [
		"ok": true,
		"pilot": [
			"address": Int(pilot.device.address),
			"name": pilot.device.displayName,
			"brand": pilot.brand.label,
		],
	]
	guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
		return failure("encoding failed")
	}
	return cString(String(decoding: data, as: UTF8.self))
}

/// Drives the anchor windlass — the standard NMEA 2000 order, addressed to
/// the windlass heard on the connection or broadcast otherwise. `direction`
/// is 0 (off), 1 (down) or 2 (up).
/// - Returns: 1 when the order was dispatched, 0 when the connection cannot
///   transmit or the direction is invalid.
@_cdecl("boattools_bridge_windlass")
public func boattools_bridge_windlass(
	_ handle: Int64, _ direction: Int32, _ windlassID: Int32
) -> Int32 {
	guard let session = registry.session(handle), session.isTransmitCapable else { return 0 }
	let command: WindlassCommand
	switch direction {
	case 0: command = .off
	case 1: command = .down
	case 2: command = .up
	default: return 0
	}
	let id = UInt8(clamping: windlassID)
	Task { try? await session.send(command, windlassID: id) }
	return 1
}

/// Closes a connection and releases its handle. Safe on unknown handles.
@_cdecl("boattools_bridge_close")
public func boattools_bridge_close(_ handle: Int64) {
	registry.close(handle)
	removeDeviceFeed(handle)
}
