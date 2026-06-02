public import NIOCore
internal import NIOPosix
internal import Foundation
internal import AsyncHTTPClient
internal import WebSocketKit
internal import NIOHTTP1


// MARK: - SignalKClient

/// Signal K client supporting REST snapshots, WebSocket live streams, and raw
/// NDJSON over TCP or UDP.
///
/// Authentication is optional — provide a bearer token via ``Config/initialToken``
/// or username/password via ``Config/username`` and ``Config/password``.
/// When credentials are present they are sent as a `Bearer` or `Basic`
/// `Authorization` header depending on whether a token is available.
///
/// `SignalKClient` is `final class @unchecked Sendable`. The only mutable state
/// is the bearer token, managed by the internal `TokenStore` actor.
public final class SignalKClient: @unchecked Sendable {

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
        public init(baseURL: String,
                    token: String? = nil,
                    username: String? = nil,
                    password: String? = nil) {
            self.baseURL    = baseURL
            self.initialToken = token
            self.username   = username
            self.password   = password
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
    private let httpClient: HTTPClient
    private let tokens: TokenStore

    // MARK: Init / shutdown

    /// Creates a Signal K client.
    ///
    /// - Parameters:
    ///   - config: Connection and authentication configuration.
    ///   - eventLoopGroup: Shared NIO event loop group (e.g. `MultiThreadedEventLoopGroup`).
    public init(config: Config, eventLoopGroup: any EventLoopGroup) {
        self.config     = config
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        self.tokens     = TokenStore(initial: config.initialToken)
    }

    /// Shuts down the underlying HTTP client. Call this when done with the client.
    public func shutdown() async throws {
        try await httpClient.shutdown()
    }

    // MARK: Authentication

    /// Authenticates with the Signal K server and stores the returned bearer token.
    ///
    /// After a successful login, subsequent ``snapshot()`` and ``liveStream(on:rawLogger:)``
    /// calls automatically include the token.
    ///
    /// - Throws: ``BoatCloudError/http(status:body:)`` for non-2xx responses.
    public func login(username: String, password: String) async throws {
        let url  = Self.trimmedBase(config.baseURL) + "/signalk/v1/auth/login"
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        var req  = HTTPClientRequest(url: url)
        req.method = .POST
        req.headers.add(name: "Content-Type", value: "application/json")
        req.body   = .bytes(body)
        let resp = try await httpClient.execute(req, timeout: .seconds(15))
        let data = try await resp.body.collect(upTo: 1024 * 1024)
        guard (200..<300).contains(resp.status.code) else {
            throw BoatCloudError.http(status: resp.status.code, body: String(buffer: data))
        }
        struct R: Decodable { let token: String }
        let parsed = try JSONDecoder().decode(R.self, from: Data(buffer: data))
        await tokens.set(parsed.token)
    }

    // MARK: REST snapshot

    /// Fetches the full Signal K vessel snapshot via `GET /signalk/v1/api/vessels/self`.
    ///
    /// - Returns: The parsed JSON tree as a ``JSONValue``.
    /// - Throws: ``BoatCloudError`` on network or HTTP errors.
    public func snapshot() async throws -> JSONValue {
        let url = Self.trimmedBase(config.baseURL) + "/signalk/v1/api/vessels/self"
        var req = HTTPClientRequest(url: url)
        await addAuth(to: &req)
        let resp = try await httpClient.execute(req, timeout: .seconds(15))
        let data = try await resp.body.collect(upTo: 10 * 1024 * 1024)
        guard (200..<300).contains(resp.status.code) else {
            throw BoatCloudError.http(status: resp.status.code, body: String(buffer: data))
        }
        return try JSONValue.parse(Data(buffer: data))
    }

    // MARK: WebSocket live stream

    /// Streams real-time Signal K deltas via WebSocket.
    ///
    /// Connects to `<baseURL>/signalk/v1/stream?subscribe=self` (upgrading `http`→`ws`,
    /// `https`→`wss`). The stream ends when the server closes the WebSocket.
    ///
    /// - Parameters:
    ///   - eventLoopGroup: NIO event loop group to run the WebSocket on.
    ///   - rawLogger: Optional sink for every raw text frame before parsing.
    /// Opens a Signal K live WebSocket stream, managing the network event loop
    /// internally so callers need no NIO. The returned stream retains the client
    /// for its lifetime. Pipe with ``BoatMetricStore/pipeSignalK(_:)``.
    public static func liveStream(config: Config) async -> AsyncThrowingStream<NMEAFrame, any Error> {
        let client = SignalKClient(config: config, eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        let inner = await client.liveStream(on: MultiThreadedEventLoopGroup.singleton)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in inner { continuation.yield(frame) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                _ = client // keep the client alive for the stream's lifetime
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func liveStream(
        on eventLoopGroup: any EventLoopGroup,
        rawLogger: (@Sendable (String) -> Void)? = nil
    ) async -> AsyncThrowingStream<NMEAFrame, any Error> {
        let token   = await tokens.get()
        let baseURL = config.baseURL

        return AsyncThrowingStream { continuation in
            var wsURL = Self.trimmedBase(baseURL)
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://",  with: "ws://")
            wsURL += "/signalk/v1/stream?subscribe=self"

            var headers = HTTPHeaders()
            if let t = token {
                headers.add(name: "Authorization", value: "Bearer \(t)")
            } else if let user = config.username, let pass = config.password {
                let basic = "\(user):\(pass)".data(using: .utf8)?.base64EncodedString() ?? ""
                headers.add(name: "Authorization", value: "Basic \(basic)")
            }

            let emit: @Sendable (NMEAFrame) -> Void = { continuation.yield($0) }
            let future = WebSocket.connect(to: wsURL, headers: headers, on: eventLoopGroup) { ws in
                ws.onText { _, text in
                    rawLogger?(text)
                    Self.handleText(text, emit: emit)
                }
                ws.onClose.whenComplete { _ in continuation.finish() }
            }
            future.whenFailure { err in
                continuation.finish(throwing: BoatCloudError.transport("\(err)"))
            }
        }
    }

    // MARK: TCP / UDP streaming (no auth)

    /// Streams raw Signal K NDJSON deltas from a TCP connection.
    ///
    /// Each newline-terminated JSON object is parsed as a Signal K delta.
    /// No authentication — use ``liveStream(on:rawLogger:)`` for authenticated access.
    ///
    /// - Parameters:
    ///   - host: Remote hostname or IP address.
    ///   - port: Remote TCP port.
    ///   - eventLoopGroup: NIO event loop group.
    ///   - rawLogger: Optional sink for raw lines before parsing.
    public static func tcpStream(
        host: String, port: Int,
        on eventLoopGroup: any EventLoopGroup,
        rawLogger: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<NMEAFrame, any Error> {
        AsyncThrowingStream { continuation in
            let emit: @Sendable (NMEAFrame) -> Void = { continuation.yield($0) }
            ClientBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations
                            .addHandler(SignalKHandlerTCP(emit: emit, rawLogger: rawLogger))
                    }
                }
                .connect(host: host, port: port)
                .whenComplete { result in
                    switch result {
                    case .failure(let err):
                        continuation.finish(throwing: BoatCloudError.transport("\(err)"))
                    case .success(let channel):
                        continuation.onTermination = { _ in channel.close(promise: nil) }
                        channel.closeFuture.whenComplete { _ in continuation.finish() }
                    }
                }
        }
    }

    /// Listens for Signal K NDJSON datagrams on a UDP port.
    ///
    /// Each UDP datagram is expected to contain a complete Signal K delta JSON object.
    ///
    /// - Parameters:
    ///   - listenPort: Local UDP port to bind.
    ///   - eventLoopGroup: NIO event loop group.
    ///   - rawLogger: Optional sink for raw datagrams before parsing.
    public static func udpStream(
        listenPort: Int,
        on eventLoopGroup: any EventLoopGroup,
        rawLogger: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<NMEAFrame, any Error> {
        AsyncThrowingStream { continuation in
            let emit: @Sendable (NMEAFrame) -> Void = { continuation.yield($0) }
            DatagramBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
                .channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations
                            .addHandler(SignalKHandlerUDP(emit: emit, rawLogger: rawLogger))
                    }
                }
                .bind(host: "0.0.0.0", port: listenPort)
                .whenComplete { result in
                    switch result {
                    case .failure(let err):
                        continuation.finish(throwing: BoatCloudError.transport("\(err)"))
                    case .success(let channel):
                        continuation.onTermination = { _ in channel.close(promise: nil) }
                        channel.closeFuture.whenComplete { _ in continuation.finish() }
                    }
                }
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
    /// Used by the NIO handlers and by ``FrameDispatcher`` in the file stream path.
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
                    if case .number(let lat) = pos["latitude"]  ?? .null {
                        out.append(.metric(BoatMetric(name: "lat", value: lat, unit: "°")))
                    }
                    if case .number(let lon) = pos["longitude"] ?? .null {
                        out.append(.metric(BoatMetric(name: "lon", value: lon, unit: "°")))
                    }
                    if case .number(let alt) = pos["altitude"]  ?? .null {
                        out.append(.metric(BoatMetric(name: "altitude", value: alt, unit: "m")))
                    }
                    continue
                }

                // Next-waypoint position: `navigation.courseRhumbline.nextPoint.position`
                // or `navigation.courseGreatCircle.nextPoint.position`.
                if path.hasSuffix(".nextPoint.position"), case .object(let pos) = raw {
                    if case .number(let lat) = pos["latitude"]  ?? .null {
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
    internal static func mapSignalKMetric(path: String, value: Double) -> (name: String, value: Double, unit: String?) {
        // Constants
        let radToDeg     = 180.0 / .pi
        let msToKnots    = 1.94384
        let kelvinToC    = -273.15
        let metersToNM   = 1.0 / 1852.0

        switch path {
        // Navigation — kinematics
        case "navigation.speedOverGround":      return ("SOG",          value * msToKnots,  "kn")
        case "navigation.speedThroughWater":    return ("STW",          value * msToKnots,  "kn")
        case "navigation.courseOverGroundTrue", "navigation.courseOverGround":
                                                return ("COG",          value * radToDeg,   "°")
        case "navigation.headingTrue":          return ("HDG.true",     value * radToDeg,   "°")
        case "navigation.headingMagnetic":      return ("HDG.magnetic", value * radToDeg,   "°")
        case "navigation.rateOfTurn":           return ("ROT",          value * radToDeg * 60, "°/min")

        // Navigation — attitude
        case "navigation.attitude.pitch":       return ("pitch",        value * radToDeg,   "°")
        case "navigation.attitude.roll":        return ("roll",         value * radToDeg,   "°")
        case "navigation.attitude.yaw":         return ("yaw",          value * radToDeg,   "°")

        // Navigation — log distance
        case "navigation.log":                  return ("log.total",    value * metersToNM, "NM")
        case "navigation.logTrip":              return ("log.trip",     value * metersToNM, "NM")

        // Navigation — GNSS
        case "navigation.gnss.satellites":      return ("gps.satellites",      value,        nil)
        case "navigation.gnss.satellitesInView": return ("gps.satellites.inView", value,      nil)
        case "navigation.gnss.horizontalDilution": return ("gps.hdop",          value,        nil)
        case "navigation.gnss.positionDilution":   return ("gps.pdop",          value,        nil)
        case "navigation.gnss.verticalDilution":   return ("gps.vdop",          value,        nil)
        case "navigation.gnss.timeDilution":        return ("gps.tdop",          value,        nil)
        case "navigation.gnss.methodQuality":   return ("gps.quality",         value,        nil)
        case "navigation.gnss.antennaAltitude": return ("altitude",            value,        "m")

        // Environment — wind
        case "environment.wind.angleApparent":   return ("AWA",        value * radToDeg,  "°")
        case "environment.wind.angleTrueWater":  return ("TWA",        value * radToDeg,  "°")
        case "environment.wind.angleTrueGround": return ("TWA",        value * radToDeg,  "°")
        case "environment.wind.directionTrue":   return ("TWD",        value * radToDeg,  "°")
        case "environment.wind.speedApparent":   return ("AWS",        value * msToKnots, "kn")
        case "environment.wind.speedTrue":       return ("TWS",        value * msToKnots, "kn")
        case "environment.wind.speedOverGround": return ("TWS",        value * msToKnots, "kn")

        // Environment — depth
        case "environment.depth.belowKeel",
             "environment.depth.belowSurface",
             "environment.depth.belowTransducer":
                                                 return ("depth",      value,             "m")

        // Environment — temperature / pressure / humidity
        case "environment.water.temperature":    return ("temperature.water",     value + kelvinToC, "°C")
        case "environment.outside.temperature":  return ("temperature.air",       value + kelvinToC, "°C")
        case "environment.inside.temperature":   return ("temperature.inside",    value + kelvinToC, "°C")
        case "environment.outside.dewPointTemperature":
                                                 return ("temperature.dewPoint",  value + kelvinToC, "°C")
        case "environment.outside.pressure",
             "environment.outside.atmosphericPressure":
                                                 return ("pressure.atmospheric",  value * 0.01,      "hPa")
        case "environment.outside.humidity",
             "environment.outside.relativeHumidity":
                                                 return ("humidity",              value * 100,       "%")

        // Steering
        case "steering.rudderAngle":                  return ("rudder",         value * radToDeg, "°")
        case "steering.autopilot.target.rudderAngle": return ("rudder.target",  value * radToDeg, "°")

        // GNSS extras
        case "navigation.gnss.geoidalSeparation":     return ("gps.geoidalSeparation", value, "m")

        // Navigation — autopilot / route
        case "navigation.courseRhumbline.crossTrackError",
             "navigation.courseGreatCircle.crossTrackError":
                                                 return ("navigation.xte",                    value / 1852.0,    "NM")
        case "navigation.courseRhumbline.bearingTrackTrue",
             "navigation.courseGreatCircle.bearingTrackTrue":
                                                 return ("navigation.bearingOriginToDest",    value * radToDeg, "°")
        case "navigation.courseRhumbline.bearingToDestinationTrue",
             "navigation.courseGreatCircle.bearingToDestinationTrue":
                                                 return ("navigation.bearingToDest",          value * radToDeg, "°")
        case "steering.autopilot.target.headingTrue":
                                                 return ("navigation.headingToSteer",         value * radToDeg, "°")
        case "navigation.courseRhumbline.nextPoint.distance",
             "navigation.courseGreatCircle.nextPoint.distance":
                                                 return ("navigation.distanceToWaypoint",     value / 1852.0,   "NM")
        case "navigation.courseRhumbline.nextPoint.velocityMadeGood",
             "navigation.courseGreatCircle.nextPoint.velocityMadeGood":
                                                 return ("navigation.vmg",                    value * msToKnots, "kn")

        // Time
        case "navigation.datetime":              return ("utc.timestamp", value, "s")

        default:
            break
        }

        // Pattern-based mappings for indexed paths (batteries, engines, tanks).
        //
        // - electrical.batteries.<id>.voltage / .current / .temperature
        if path.hasPrefix("electrical.batteries.") {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count >= 4 {
                let id   = parts[2]
                let leaf = parts[3]
                switch leaf {
                case "voltage":     return ("battery.\(id).voltage",     value,                  "V")
                case "current":     return ("battery.\(id).current",     value,                  "A")
                case "temperature": return ("battery.\(id).temperature", value + kelvinToC,      "°C")
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
                case "revolutions":         return ("engine.\(id).rpm",                value * 60, "rpm")
                case "oilPressure":         return ("engine.\(id).oilPressure",        value,      "Pa")
                case "oilTemperature":      return ("engine.\(id).oilTemperature",     value + kelvinToC, "°C")
                case "coolantTemperature",
                     "temperature":         return ("engine.\(id).coolantTemperature", value + kelvinToC, "°C")
                case "alternatorVoltage":   return ("engine.\(id).alternatorVoltage",  value,      "V")
                case "fuel.rate":           return ("engine.\(id).fuelRate",           value * 3600 * 1000, "L/h")  // m³/s → L/h
                case "runTime":             return ("engine.\(id).runtime",            value,      "s")
                case "engineLoad":          return ("engine.\(id).load",               value * 100, "%")            // ratio → %
                case "engineTorque":        return ("engine.\(id).torque",             value * 100, "%")
                case "boostPressure":       return ("engine.\(id).boostPressure",      value,      "Pa")
                case "coolantPressure":     return ("engine.\(id).coolantPressure",    value,      "Pa")
                case "fuelPressure":        return ("engine.\(id).fuelPressure",       value,      "Pa")
                default: break
                }
            }
        }

        // - electrical.generators.<id>.{voltage,current,acIsOn,…} (Signal K canonical)
        //   electrical.inverters.<id>.{ac.voltage,dc.voltage,acIsOn,…}
        //   electrical.chargers.<id>.{voltage,current,…}
        if path.hasPrefix("electrical.generators.") ||
           path.hasPrefix("electrical.inverters.")  ||
           path.hasPrefix("electrical.chargers.") {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count >= 4 {
                let category = parts[1]   // "generators" → "genset", others kept singular
                let device: String
                switch category {
                case "generators": device = "genset"
                case "inverters":  device = "inverter"
                case "chargers":   device = "charger"
                default:           device = category
                }
                let tail = parts.dropFirst(3).joined(separator: ".")
                switch tail {
                case "voltage", "ac.voltage", "dc.voltage":
                    return ("power.\(device).voltage", value,                       "V")
                case "current", "ac.current", "dc.current":
                    return ("power.\(device).current", value,                       "A")
                case "power", "ac.power":
                    return ("power.\(device).power",   value,                       "W")
                case "acIsOn", "isOn":
                    return ("power.\(device).state",   value != 0 ? 1 : 0,         nil)
                case "stateOfCharge":
                    return ("power.\(device).level",   value * 100,                 "%")
                default: break
                }
            }
        }

        // - tanks.<type>.<id>.currentLevel (ratio 0..1 → %)
        if path.hasPrefix("tanks.") {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count >= 4, parts[3] == "currentLevel" {
                let type = parts[1], id = parts[2]
                let bucket: String
                switch type {
                case "fuel":          bucket = "fuel"
                case "freshWater":    bucket = "water"
                case "wasteWater",
                     "blackWater":    bucket = "blackwater"
                case "greyWater":     bucket = "graywater"
                case "liveWell":      bucket = "livewell"
                default:              bucket = type
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

    private func addAuth(to req: inout HTTPClientRequest) async {
        if let t = await tokens.get() {
            req.headers.add(name: "Authorization", value: "Bearer \(t)")
        } else if let user = config.username, let pass = config.password {
            let basic = "\(user):\(pass)".data(using: .utf8)?.base64EncodedString() ?? ""
            req.headers.add(name: "Authorization", value: "Basic \(basic)")
        }
    }
}


// MARK: - NIO handlers (event-loop-confined)

/// Aggregates a TCP byte stream into newline-delimited Signal K JSON objects
/// and parses each one. Confined to a single NIO event loop.
fileprivate final class SignalKHandlerTCP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let emit: @Sendable (NMEAFrame) -> Void
    private let rawLogger: (@Sendable (String) -> Void)?
    private var buffer = ""

    init(emit: @escaping @Sendable (NMEAFrame) -> Void,
         rawLogger: (@Sendable (String) -> Void)? = nil) {
        self.emit      = emit
        self.rawLogger = rawLogger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = Self.unwrapInboundIn(data)
        guard let chunk = buf.readString(length: buf.readableBytes) else { return }
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...nl)
            guard !line.isEmpty else { continue }
            rawLogger?(line)
            SignalKClient.handleText(line, emit: emit)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Parses each UDP datagram as a complete Signal K JSON delta.
/// Confined to a single NIO event loop.
fileprivate final class SignalKHandlerUDP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let emit: @Sendable (NMEAFrame) -> Void
    private let rawLogger: (@Sendable (String) -> Void)?

    init(emit: @escaping @Sendable (NMEAFrame) -> Void,
         rawLogger: (@Sendable (String) -> Void)? = nil) {
        self.emit      = emit
        self.rawLogger = rawLogger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = Self.unwrapInboundIn(data)
        var buf = envelope.data
        guard let text = buf.readString(length: buf.readableBytes) else { return }
        rawLogger?(text)
        SignalKClient.handleText(text, emit: emit)
    }
}
