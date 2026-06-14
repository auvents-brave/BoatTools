internal import Foundation

// MARK: - SignalKClient

/// Signal K client supporting REST snapshots, WebSocket live streams, and raw
/// NDJSON over TCP or UDP.
///
/// Authentication is optional — provide a bearer token via ``Config/initialToken``
/// or username/password via ``Config/username`` and ``Config/password``.
/// When credentials are present they are sent as a `Bearer` or `Basic`
/// `Authorization` header depending on whether a token is available.
///
/// Built on the portable transport layer (``NetworkStack``), so the whole client is
/// available on every supported platform, Windows included. The only mutable
/// state is the bearer token, managed by the internal `TokenStore` actor.
public final class SignalKClient: Sendable {

	// MARK: Config

	/// Connection configuration for a ``SignalKClient``.
	public struct Config: Sendable {
		/// Base URL of the Signal K server, e.g. `"http://192.168.1.16:3000"`.
		public var baseURL: String
		/// Pre-existing bearer token. Skip ``login(username:password:)`` when set.
		public var initialToken: String?
		/// Username for password-based login or HTTP Basic fallback.
		public var username: String?
		/// Password for password-based login or HTTP Basic fallback.
		public var password: String?

		/// Creates a Signal K client configuration.
		public init(
			baseURL: String,
			token: String? = nil,
			username: String? = nil,
			password: String? = nil
		) {
			self.baseURL = baseURL
			self.initialToken = token
			self.username = username
			self.password = password
		}
	}

	// MARK: TokenStore

	private actor TokenStore {
		private var token: String?
		init(initial: String?) { self.token = initial }
		func get() -> String? { token }
		func set(_ t: String?) { token = t }
	}

	// MARK: Properties

	private let config: Config
	private let http: any HTTPTransport
	private let tokens: TokenStore

	// MARK: Init / shutdown

	/// Creates a Signal K client.
	///
	/// - Parameter config: Connection and authentication configuration.
	public init(config: Config) {
		self.config = config
		self.http = NetworkStack.makeHTTPTransport()
		self.tokens = TokenStore(initial: config.initialToken)
	}

	/// Shuts down the underlying HTTP transport. Call this when done with the client.
	public func shutdown() async throws {
		try await http.shutdown()
	}

	// MARK: Authentication

	/// Authenticates with the Signal K server and stores the returned bearer token.
	///
	/// After a successful login, subsequent ``snapshot()`` and ``liveStream(rawLogger:)``
	/// calls automatically include the token.
	///
	/// - Throws: ``BoatCloudError/http(status:body:)`` for non-2xx responses.
	public func login(username: String, password: String) async throws {
		let url = Self.trimmedBase(config.baseURL) + "/signalk/v1/auth/login"
		let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
		let request = HTTPRequest(
			method: "POST",
			url: url,
			headers: [(name: "Content-Type", value: "application/json")],
			body: Array(body),
			maxResponseBytes: 1024 * 1024)
		let response = try await http.execute(request)
		guard (200..<300).contains(response.status) else {
			throw BoatCloudError.http(
				status: response.status, body: String(bytes: response.body, encoding: .utf8))
		}
		struct R: Decodable { let token: String }
		let parsed = try JSONDecoder().decode(R.self, from: Data(response.body))
		await tokens.set(parsed.token)
	}

	// MARK: REST snapshot

	/// Fetches the full Signal K vessel snapshot via `GET /signalk/v1/api/vessels/self`.
	///
	/// - Returns: The parsed JSON tree as a ``JSONValue``.
	/// - Throws: ``BoatCloudError`` on network or HTTP errors.
	public func snapshot() async throws -> JSONValue {
		let url = Self.trimmedBase(config.baseURL) + "/signalk/v1/api/vessels/self"
		let request = HTTPRequest(url: url, headers: await authHeaders())
		let response = try await http.execute(request)
		guard (200..<300).contains(response.status) else {
			throw BoatCloudError.http(
				status: response.status, body: String(bytes: response.body, encoding: .utf8))
		}
		return try JSONValue.parse(Data(response.body))
	}

	// MARK: WebSocket live stream

	/// Opens a Signal K live WebSocket stream, managing the underlying client
	/// internally. The returned stream retains the client for its lifetime.
	/// Pipe with ``BoatMetricStore/pipeSignalK(_:)``.
	public static func liveStream(config: Config) async -> AsyncThrowingStream<NMEAFrame, any Error> {
		let client = SignalKClient(config: config)
		let inner = await client.liveStream()
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await frame in inner { continuation.yield(frame) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
				// Release the pooled HTTP transport before the client goes away.
				try? await client.shutdown()
			}
			continuation.onTermination = { @Sendable _ in task.cancel() }
		}
	}

	/// Streams real-time Signal K deltas via WebSocket.
	///
	/// Connects to `<baseURL>/signalk/v1/stream?subscribe=self` (upgrading `http`→`ws`,
	/// `https`→`wss`). The stream ends when the server closes the WebSocket.
	///
	/// - Parameter rawLogger: Optional sink for every raw text frame before parsing.
	public func liveStream(
		rawLogger: (@Sendable (String) -> Void)? = nil
	) async -> AsyncThrowingStream<NMEAFrame, any Error> {
		let token = await tokens.get()
		let baseURL = config.baseURL
		let username = config.username
		let password = config.password

		return AsyncThrowingStream { continuation in
			let task = Task {
				var wsURL = Self.trimmedBase(baseURL)
					.replacingOccurrences(of: "https://", with: "wss://")
					.replacingOccurrences(of: "http://", with: "ws://")
				wsURL += "/signalk/v1/stream?subscribe=self"

				var headers: [(name: String, value: String)] = []
				if let t = token {
					headers.append((name: "Authorization", value: "Bearer \(t)"))
				} else if let user = username, let pass = password {
					let basic = "\(user):\(pass)".data(using: .utf8)?.base64EncodedString() ?? ""
					headers.append((name: "Authorization", value: "Basic \(basic)"))
				}

				do {
					let connection = try await NetworkStack.webSocket.connect(
						url: wsURL, headers: headers)
					for try await message in connection.messages {
						guard case .text(let text) = message else { continue }
						rawLogger?(text)
						Self.handleText(text) { continuation.yield($0) }
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch {
					continuation.finish(throwing: BoatCloudError.transport("\(error)"))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	// MARK: TCP / UDP streaming (no auth)

	/// Streams raw Signal K NDJSON deltas from a TCP connection.
	///
	/// Each newline-terminated JSON object is parsed as a Signal K delta.
	/// No authentication — use ``liveStream(rawLogger:)`` for authenticated access.
	///
	/// - Parameters:
	///   - host: Remote hostname or IP address.
	///   - port: Remote TCP port.
	///   - rawLogger: Optional sink for raw lines before parsing.
	public static func tcpStream(
		host: String, port: Int,
		rawLogger: (@Sendable (String) -> Void)? = nil
	) -> AsyncThrowingStream<NMEAFrame, any Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				let aggregator = LineAggregator(encoding: .utf8)
				do {
					let connection = try await NetworkStack.tcp.connect(host: host, port: port)
					for try await chunk in connection.incoming {
						aggregator.ingest(chunk) { line in
							rawLogger?(line)
							handleText(line) { continuation.yield($0) }
						}
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch {
					continuation.finish(throwing: BoatCloudError.transport("\(error)"))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Listens for Signal K NDJSON datagrams on a UDP port.
	///
	/// Each UDP datagram is expected to contain a complete Signal K delta JSON object.
	///
	/// - Parameters:
	///   - listenPort: Local UDP port to bind.
	///   - rawLogger: Optional sink for raw datagrams before parsing.
	public static func udpStream(
		listenPort: Int,
		rawLogger: (@Sendable (String) -> Void)? = nil
	) -> AsyncThrowingStream<NMEAFrame, any Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let datagrams = try await NetworkStack.udp.listen(
						port: listenPort, multicastGroup: nil)
					for try await datagram in datagrams {
						guard let text = String(bytes: datagram, encoding: .utf8) else { continue }
						rawLogger?(text)
						handleText(text) { continuation.yield($0) }
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch {
					continuation.finish(throwing: BoatCloudError.transport("\(error)"))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	// MARK: Delta parsing

	/// Parses a Signal K JSON delta string into an array of ``NMEAFrame`` values.
	///
	/// - Invalid JSON or unrecognised structure (no `updates` array) → `[.unknown(rawLine:)]`
	/// - Valid delta with no numeric values → `[]` (not an error)
	///
	/// Signal K's canonical SI units are translated to BoatTools' canonical units so
	/// metrics align with those produced by NMEA 0183 and NMEA 2000 decoders:
	/// - angles: rad → °
	/// - speed:  m/s → kn
	/// - temperature: K → °C
	/// - pressure: Pa → hPa
	/// - distance log: m → NM
	/// - frequency: Hz → rpm (×60)
	///
	/// `navigation.position` objects are unpacked into `lat`, `lon` (and `altitude` if present).
	///
	/// Unknown paths fall through with their original Signal K path as the metric name —
	/// nothing is dropped silently.
	///
	/// Used by the TCP/UDP streaming paths and by ``FrameDispatcher`` in the
	/// file stream path.
	internal static func parseFrames(_ text: String) -> [NMEAFrame] {
		guard let data = text.data(using: .utf8),
			let json = try? JSONValue.parse(data),
			case .object(let root) = json
		else { return [.unknown(rawLine: text)] }

		guard case .array(let updates) = root["updates"] ?? .null else {
			return [.unknown(rawLine: text)]
		}

		var out: [NMEAFrame] = []
		for update in updates {
			guard case .object(let updateDict) = update,
				case .array(let values) = updateDict["values"] ?? .null
			else { continue }
			for v in values {
				guard case .object(let valDict) = v,
					case .string(let path) = valDict["path"] ?? .null
				else { continue }
				let raw = valDict["value"] ?? .null

				// Position objects: `navigation.position = {latitude, longitude, altitude?}`
				if path == "navigation.position", case .object(let pos) = raw {
					if case .number(let lat) = pos["latitude"] ?? .null {
						out.append(.metric(BoatMetric(name: "lat", value: lat, unit: "°")))
					}
					if case .number(let lon) = pos["longitude"] ?? .null {
						out.append(.metric(BoatMetric(name: "lon", value: lon, unit: "°")))
					}
					if case .number(let alt) = pos["altitude"] ?? .null {
						out.append(.metric(BoatMetric(name: "altitude", value: alt, unit: "m")))
					}
					continue
				}

				// Next-waypoint position: `navigation.courseRhumbline.nextPoint.position`
				// or `navigation.courseGreatCircle.nextPoint.position`.
				if path.hasSuffix(".nextPoint.position"), case .object(let pos) = raw {
					if case .number(let lat) = pos["latitude"] ?? .null {
						out.append(.metric(BoatMetric(name: "waypoint.lat", value: lat, unit: "°")))
					}
					if case .number(let lon) = pos["longitude"] ?? .null {
						out.append(.metric(BoatMetric(name: "waypoint.lon", value: lon, unit: "°")))
					}
					continue
				}

				// Numeric leaf: translate path + unit
				if case .number(let num) = raw {
					let (mappedName, mappedValue, mappedUnit) = mapSignalKMetric(path: path, value: num)
					out.append(.metric(BoatMetric(name: mappedName, value: mappedValue, unit: mappedUnit)))
				}
			}
		}
		return out
	}

	/// Maps a Signal K path + canonical-SI value to BoatTools' canonical metric name + unit.
	///
	/// Returns the raw path with no conversion when the path is unknown — preserves
	/// the data instead of dropping it.
	internal static func mapSignalKMetric(path: String, value: Double) -> (
		name: String, value: Double, unit: String?
	) {
		// Constants
		let radToDeg = 180.0 / .pi
		let msToKnots = 1.94384
		let kelvinToC = -273.15
		let metersToNM = 1.0 / 1852.0

		switch path {
		// Navigation — kinematics
		case "navigation.speedOverGround": return ("SOG", value * msToKnots, "kn")
		case "navigation.speedThroughWater": return ("STW", value * msToKnots, "kn")
		case "navigation.courseOverGroundTrue", "navigation.courseOverGround":
			return ("COG", value * radToDeg, "°")
		case "navigation.headingTrue": return ("HDG.true", value * radToDeg, "°")
		case "navigation.headingMagnetic": return ("HDG.magnetic", value * radToDeg, "°")
		case "navigation.rateOfTurn": return ("ROT", value * radToDeg * 60, "°/min")

		// Navigation — attitude
		case "navigation.attitude.pitch": return ("pitch", value * radToDeg, "°")
		case "navigation.attitude.roll": return ("roll", value * radToDeg, "°")
		case "navigation.attitude.yaw": return ("yaw", value * radToDeg, "°")

		// Navigation — log distance
		case "navigation.log": return ("log.total", value * metersToNM, "NM")
		case "navigation.logTrip": return ("log.trip", value * metersToNM, "NM")

		// Navigation — GNSS
		case "navigation.gnss.satellites": return ("gps.satellites", value, nil)
		case "navigation.gnss.satellitesInView": return ("gps.satellites.inView", value, nil)
		case "navigation.gnss.horizontalDilution": return ("gps.hdop", value, nil)
		case "navigation.gnss.positionDilution": return ("gps.pdop", value, nil)
		case "navigation.gnss.verticalDilution": return ("gps.vdop", value, nil)
		case "navigation.gnss.timeDilution": return ("gps.tdop", value, nil)
		case "navigation.gnss.methodQuality": return ("gps.quality", value, nil)
		case "navigation.gnss.antennaAltitude": return ("altitude", value, "m")

		// Environment — wind
		case "environment.wind.angleApparent": return ("AWA", value * radToDeg, "°")
		case "environment.wind.angleTrueWater": return ("TWA", value * radToDeg, "°")
		case "environment.wind.angleTrueGround": return ("TWA", value * radToDeg, "°")
		case "environment.wind.directionTrue": return ("TWD", value * radToDeg, "°")
		case "environment.wind.speedApparent": return ("AWS", value * msToKnots, "kn")
		case "environment.wind.speedTrue": return ("TWS", value * msToKnots, "kn")
		case "environment.wind.speedOverGround": return ("TWS", value * msToKnots, "kn")

		// Environment — depth
		case "environment.depth.belowKeel",
			"environment.depth.belowSurface",
			"environment.depth.belowTransducer":
			return ("depth", value, "m")

		// Environment — temperature / pressure / humidity
		case "environment.water.temperature": return ("temperature.water", value + kelvinToC, "°C")
		case "environment.outside.temperature": return ("temperature.air", value + kelvinToC, "°C")
		case "environment.inside.temperature": return ("temperature.inside", value + kelvinToC, "°C")
		case "environment.outside.dewPointTemperature":
			return ("temperature.dewPoint", value + kelvinToC, "°C")
		case "environment.outside.pressure",
			"environment.outside.atmosphericPressure":
			return ("pressure.atmospheric", value * 0.01, "hPa")
		case "environment.outside.humidity",
			"environment.outside.relativeHumidity":
			return ("humidity", value * 100, "%")

		// Steering
		case "steering.rudderAngle": return ("rudder", value * radToDeg, "°")
		case "steering.autopilot.target.rudderAngle": return ("rudder.target", value * radToDeg, "°")

		// GNSS extras
		case "navigation.gnss.geoidalSeparation": return ("gps.geoidalSeparation", value, "m")

		// Navigation — autopilot / route
		case "navigation.courseRhumbline.crossTrackError",
			"navigation.courseGreatCircle.crossTrackError":
			return ("navigation.xte", value / 1852.0, "NM")
		case "navigation.courseRhumbline.bearingTrackTrue",
			"navigation.courseGreatCircle.bearingTrackTrue":
			return ("navigation.bearingOriginToDest", value * radToDeg, "°")
		case "navigation.courseRhumbline.bearingToDestinationTrue",
			"navigation.courseGreatCircle.bearingToDestinationTrue":
			return ("navigation.bearingToDest", value * radToDeg, "°")
		case "steering.autopilot.target.headingTrue":
			return ("navigation.headingToSteer", value * radToDeg, "°")
		case "navigation.courseRhumbline.nextPoint.distance",
			"navigation.courseGreatCircle.nextPoint.distance":
			return ("navigation.distanceToWaypoint", value / 1852.0, "NM")
		case "navigation.courseRhumbline.nextPoint.velocityMadeGood",
			"navigation.courseGreatCircle.nextPoint.velocityMadeGood":
			return ("navigation.vmg", value * msToKnots, "kn")

		// Time
		case "navigation.datetime": return ("utc.timestamp", value, "s")

		default:
			break
		}

		// Pattern-based mappings for indexed paths (batteries, engines, tanks).
		//
		// - electrical.batteries.<id>.voltage / .current / .temperature
		if path.hasPrefix("electrical.batteries.") {
			let parts = path.split(separator: ".").map(String.init)
			if parts.count >= 4 {
				let id = parts[2]
				let leaf = parts[3]
				switch leaf {
				case "voltage": return ("battery.\(id).voltage", value, "V")
				case "current": return ("battery.\(id).current", value, "A")
				case "temperature": return ("battery.\(id).temperature", value + kelvinToC, "°C")
				case "capacity":
					if parts.count >= 5, parts[4] == "stateOfCharge" {
						return ("battery.\(id).soc", value * 100, "%")
					}
				default: break
				}
			}
		}

		// - propulsion.<id>.revolutions / .oilPressure / .oilTemperature / .coolantTemperature
		//   .alternatorVoltage / .fuel.rate / .runTime
		if path.hasPrefix("propulsion.") {
			let parts = path.split(separator: ".").map(String.init)
			if parts.count >= 3 {
				let id = parts[1]
				let tail = parts.dropFirst(2).joined(separator: ".")
				switch tail {
				case "revolutions": return ("engine.\(id).rpm", value * 60, "rpm")
				case "oilPressure": return ("engine.\(id).oilPressure", value, "Pa")
				case "oilTemperature": return ("engine.\(id).oilTemperature", value + kelvinToC, "°C")
				case "coolantTemperature",
					"temperature":
					return ("engine.\(id).coolantTemperature", value + kelvinToC, "°C")
				case "alternatorVoltage": return ("engine.\(id).alternatorVoltage", value, "V")
				case "fuel.rate": return ("engine.\(id).fuelRate", value * 3600 * 1000, "L/h")  // m³/s → L/h
				case "runTime": return ("engine.\(id).runtime", value, "s")
				case "engineLoad": return ("engine.\(id).load", value * 100, "%")  // ratio → %
				case "engineTorque": return ("engine.\(id).torque", value * 100, "%")
				case "boostPressure": return ("engine.\(id).boostPressure", value, "Pa")
				case "coolantPressure": return ("engine.\(id).coolantPressure", value, "Pa")
				case "fuelPressure": return ("engine.\(id).fuelPressure", value, "Pa")
				default: break
				}
			}
		}

		// - electrical.generators.<id>.{voltage,current,acIsOn,…} (Signal K canonical)
		//   electrical.inverters.<id>.{ac.voltage,dc.voltage,acIsOn,…}
		//   electrical.chargers.<id>.{voltage,current,…}
		if path.hasPrefix("electrical.generators.") || path.hasPrefix("electrical.inverters.")
			|| path.hasPrefix("electrical.chargers.")
		{
			let parts = path.split(separator: ".").map(String.init)
			if parts.count >= 4 {
				let category = parts[1]  // "generators" → "genset", others kept singular
				let device: String
				switch category {
				case "generators": device = "genset"
				case "inverters": device = "inverter"
				case "chargers": device = "charger"
				default: device = category
				}
				let tail = parts.dropFirst(3).joined(separator: ".")
				switch tail {
				case "voltage", "ac.voltage", "dc.voltage":
					return ("power.\(device).voltage", value, "V")
				case "current", "ac.current", "dc.current":
					return ("power.\(device).current", value, "A")
				case "power", "ac.power":
					return ("power.\(device).power", value, "W")
				case "acIsOn", "isOn":
					return ("power.\(device).state", value != 0 ? 1 : 0, nil)
				case "stateOfCharge":
					return ("power.\(device).level", value * 100, "%")
				default: break
				}
			}
		}

		// - tanks.<type>.<id>.currentLevel (ratio 0..1 → %)
		if path.hasPrefix("tanks.") {
			let parts = path.split(separator: ".").map(String.init)
			if parts.count >= 4, parts[3] == "currentLevel" {
				let type = parts[1]
				let id = parts[2]
				let bucket: String
				switch type {
				case "fuel": bucket = "fuel"
				case "freshWater": bucket = "water"
				case "wasteWater",
					"blackWater":
					bucket = "blackwater"
				case "greyWater": bucket = "graywater"
				case "liveWell": bucket = "livewell"
				default: bucket = type
				}
				return ("\(bucket).\(id).level", value * 100, "%")
			}
		}

		// Unknown path — keep as-is, no unit conversion.
		return (path, value, nil)
	}

	/// Calls ``parseFrames(_:)`` and emits each frame through the closure.
	internal static func handleText(_ text: String, emit: @Sendable (NMEAFrame) -> Void) {
		for frame in parseFrames(text) { emit(frame) }
	}

	// MARK: Helpers

	/// Strips trailing `/` and `/signalk` suffix so that a base URL returned by
	/// Bonjour TXT records (e.g. `http://host:3000/signalk`) doesn't produce a
	/// doubled path when REST endpoints are appended.
	private static func trimmedBase(_ raw: String) -> String {
		var s = raw
		while s.hasSuffix("/") { s.removeLast() }
		if s.hasSuffix("/signalk") { s.removeLast("/signalk".count) }
		return s
	}

	/// The `Authorization` header derived from the stored bearer token or the
	/// configured Basic credentials; empty when no credentials are available.
	private func authHeaders() async -> [(name: String, value: String)] {
		if let t = await tokens.get() {
			return [(name: "Authorization", value: "Bearer \(t)")]
		}
		if let user = config.username, let pass = config.password {
			let basic = "\(user):\(pass)".data(using: .utf8)?.base64EncodedString() ?? ""
			return [(name: "Authorization", value: "Basic \(basic)")]
		}
		return []
	}
}
