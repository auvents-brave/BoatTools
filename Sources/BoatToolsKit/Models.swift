public import Foundation


// MARK: - JSONValue

/// A type-safe, ``Sendable`` replacement for `Any` in Signal K JSON payloads.
///
/// Signal K REST snapshots contain dynamically-typed JSON. ``JSONValue`` wraps
/// every JSON type as an enum case so values can cross Swift concurrency
/// boundaries without `@unchecked Sendable`.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Creates a ``JSONValue`` from a raw Foundation JSON object.
    public init(_ raw: Any) {
        if raw is NSNull { self = .null; return }
        if let b = raw as? Bool { self = .bool(b); return }
        if let n = raw as? Double { self = .number(n); return }
        if let n = raw as? Int { self = .number(Double(n)); return }
        if let s = raw as? String { self = .string(s); return }
        if let a = raw as? [Any] { self = .array(a.map(JSONValue.init)); return }
        if let o = raw as? [String: Any] {
            self = .object(o.mapValues(JSONValue.init)); return
        }
        self = .null
    }

    /// Parses raw JSON data into a ``JSONValue`` tree.
    ///
    /// - Throws: `DecodingError` or a `JSONSerialization` error if the data is invalid JSON.
    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(raw)
    }

    /// Traverses the tree using a dotted key path, e.g. `"navigation.speedOverGround"`.
    ///
    /// - Returns: The node at the path, or `nil` if any key is missing.
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue = self
        for key in path.split(separator: ".") {
            guard case .object(let dict) = current,
                  let next = dict[String(key)] else { return nil }
            current = next
        }
        return current
    }

    /// Unwraps a Signal K `{ "value": x, … }` leaf object, returning `x` directly.
    public var unwrappedValue: JSONValue {
        if case .object(let dict) = self, let v = dict["value"] { return v }
        return self
    }

    /// The numeric value of this node after unwrapping, or `nil`.
    public var doubleValue: Double? {
        switch unwrappedValue {
        case .number(let n): return n
        default: return nil
        }
    }

    /// Walks the tree and collects every numeric leaf with its dotted path.
    ///
    /// Array indices are formatted as `parent[i]`. Useful for enumerating all
    /// measurements in a Signal K snapshot without hardcoding paths.
    ///
    /// - Parameter prefix: Dotted path prefix for recursive calls; leave empty for root.
    /// - Returns: An array of `(path, value)` pairs in depth-first order.
    public func numericLeaves(prefix: String = "") -> [(path: String, value: Double)] {
        var out: [(String, Double)] = []
        switch self {
        case .number(let n):
            out.append((prefix, n))
        case .object(let dict):
            for (k, v) in dict {
                let p = prefix.isEmpty ? k : "\(prefix).\(k)"
                out.append(contentsOf: v.numericLeaves(prefix: p))
            }
        case .array(let arr):
            for (i, v) in arr.enumerated() {
                out.append(contentsOf: v.numericLeaves(prefix: "\(prefix)[\(i)]"))
            }
        default:
            break
        }
        return out
    }
}


// MARK: - BoatMetric

/// A single named measurement from any marine data source.
///
/// Every parser and decoder in BoatToolsKit ultimately produces ``BoatMetric``
/// values, wrapped inside ``NMEAFrame/metric(_:)``. Consumers that only care
/// about processed data can filter for that case and ignore raw frames.
public struct BoatMetric: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Measurement name, e.g. `"SOG"` or `"navigation.speedOverGround"`.
    public let name: String
    /// Measurement value in SI or nautical units (see ``unit``).
    public let value: Double
    /// Unit string, e.g. `"kn"`, `"m"`, `"°"`. `nil` when the unit is unknown.
    public let unit: String?
    /// Capture timestamp. Defaults to `Date()` when the source provides none.
    public let timestamp: Date

    /// Creates a metric.
    public init(name: String, value: Double, unit: String? = nil, timestamp: Date = Date()) {
        self.name = name
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
    }

    public var description: String {
        unit.map { "\(name) = \(value) \($0)" } ?? "\(name) = \(value)"
    }
}


// MARK: - SatelliteInfo

/// One satellite entry from a GSV (Satellites in View) series.
public struct SatelliteInfo: Sendable, Equatable {
    /// PRN (pseudo-random noise) identifier used to distinguish satellites.
    public let prn: Int
    /// Elevation above the horizon in degrees (0–90). `nil` if not provided.
    public let elevation: Int?
    /// Azimuth from true north in degrees (0–359). `nil` if not provided.
    public let azimuth: Int?
    /// Signal-to-noise ratio in dB-Hz. `nil` means the satellite is in view
    /// but not currently tracked (no signal lock).
    public let snr: Int?

    /// Creates a satellite info entry.
    public init(prn: Int, elevation: Int?, azimuth: Int?, snr: Int?) {
        self.prn       = prn
        self.elevation = elevation
        self.azimuth   = azimuth
        self.snr       = snr
    }
}


// MARK: - NMEAFrame

/// A frame produced by any BoatToolsKit transport or file parser.
///
/// The name is historical (NMEA 0183 origins). The type covers NMEA 0183,
/// NMEA 2000, Signal K metrics, and two diagnostic cases for malformed or
/// unrecognised data. The CLI renders the diagnostic cases in colour when
/// stdout is a TTY.
public enum NMEAFrame: Sendable, Equatable {
    /// A successfully parsed NMEA 0183 sentence.
    case nmea0183(sentence: String, talker: String, type: String, fields: [String])
    /// A successfully parsed NMEA 2000 frame.
    case nmea2000(pgn: UInt32, source: UInt8, priority: UInt8, data: [UInt8])
    /// A decoded metric value from any source.
    case metric(BoatMetric)
    /// A fully decoded AIS target from assembled VDM/VDO sentences.
    case aisTarget(AISTarget)
    /// A complete GSV (Satellites in View) series, emitted once per talker per burst.
    ///
    /// Accompanies the summary ``metric(_:)`` frames (`<constellation>.satellites.inView`,
    /// `<constellation>.snr.avg/max/min`) that are emitted at the same time.
    /// Consumers that only need the aggregate values can ignore this case.
    case gsvReport(constellation: String, inView: Int, satellites: [SatelliteInfo])
    /// A syntactically valid NMEA 0183 sentence whose XOR checksum does not match.
    case invalidChecksum(rawLine: String)
    /// A line that no parser recognised, or Signal K JSON that is not a valid delta.
    case unknown(rawLine: String)
}


// MARK: - FileFrame

/// A ``NMEAFrame`` from a local log file, carrying an optional source-line
/// timestamp for realtime replay.
///
/// Produced by ``NMEATransport/fileStream(path:format:decodePGNs:)``.
public struct FileFrame: Sendable {
    /// The parsed frame.
    public let frame: NMEAFrame
    /// Timestamp extracted from the source line, when available.
    ///
    /// Recognised sources:
    /// - Signal K NDJSON: `updates[n].timestamp` (ISO 8601)
    /// - NMEA 0183 RMC: sentence date (DDMMYY) + time (HHMMSS.ss) fields
    ///
    /// `nil` for formats that carry no inline timestamp (YD RAW, SeaSmart, …).
    public let timestamp: Date?

    /// 1-based index of the source line that produced this frame.
    ///
    /// A single input line (one NMEA sentence, one CAN frame, one Signal K delta)
    /// can decode into multiple frames — the raw `.nmea0183`/`.nmea2000` plus one
    /// `.metric` per extracted value, plus possibly `.aisTarget`. All of those
    /// share the same `lineIndex`, so a rate-limited consumer can throttle per
    /// source line rather than per emitted frame.
    public let lineIndex: Int

    /// Creates a ``FileFrame``.
    public init(frame: NMEAFrame, timestamp: Date? = nil, lineIndex: Int = 0) {
        self.frame = frame
        self.timestamp = timestamp
        self.lineIndex = lineIndex
    }
}


// MARK: - BoatCloudError

/// Errors thrown by ``SignalKClient`` and ``VictronVRMClient``.
public enum BoatCloudError: Error, Sendable {
    /// The supplied URL string could not be parsed.
    case invalidURL
    /// Authentication is required but no credentials were provided.
    case notAuthenticated
    /// The server returned a non-2xx HTTP status.
    case http(status: UInt, body: String?)
    /// The response body could not be decoded into the expected type.
    case decoding(String)
    /// A low-level transport error (connection refused, NIO failure, …).
    case transport(String)
}
