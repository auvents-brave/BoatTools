public import NIOCore
internal import Foundation
internal import AsyncHTTPClient


// MARK: - VictronVRMClient

/// Victron VRM cloud client.
///
/// Reads installation metadata and live diagnostic data from the Victron VRM API
/// (`vrmapi.victronenergy.com`). All requests are authenticated with a personal
/// access token via the `X-Authorization` header.
///
/// No mutable state — `@unchecked Sendable` is safe here.
public final class VictronVRMClient: @unchecked Sendable {

    // MARK: - Config

    /// Authentication and endpoint configuration.
    public struct Config: Sendable {
        /// Personal access token from the VRM portal.
        public let accessToken: String
        /// VRM API base URL. Override for staging/testing environments.
        public var baseURL: String = "https://vrmapi.victronenergy.com/v2"

        /// Creates a VRM client configuration with a personal access token.
        public init(accessToken: String) { self.accessToken = accessToken }
    }

    // MARK: - Data types

    /// A Victron installation (site) from a VRM user account.
    public struct Installation: Sendable, Decodable {
        /// Unique site identifier.
        public let idSite: Int
        /// Human-readable site name.
        public let name: String
        /// Whether the authenticated user owns this installation.
        public let owner: Bool?
    }

    /// A single diagnostic reading from a VRM site.
    public struct DiagnosticRecord: Sendable, Decodable {
        /// VRM data attribute identifier.
        public let idDataAttribute: Int?
        /// Human-readable measurement name (e.g. `"Battery voltage"`).
        public let description: String?
        /// Pre-formatted value string including unit (e.g. `"26.2 V"`).
        public let formattedValue: String?
        /// Raw numeric value.
        public let rawValue: Double?
        /// Physical device name (e.g. `"Battery Monitor"`, `"MPPT"`, `"Gateway"`).
        ///
        /// The VRM JSON uses a capitalised `Device` key.
        public let device: String?
        /// Device instance index when multiple identical devices exist (0, 1, 2, …).
        public let instance: Int?
        /// printf-style format string with unit (e.g. `"%.1f V"`, `"%.0f %%"`).
        public let formatWithUnit: String?

        enum K: String, CodingKey {
            case idDataAttribute, description, formattedValue, rawValue
            case device = "Device"
            case instance, formatWithUnit
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            idDataAttribute = try? c.decodeIfPresent(Int.self,    forKey: .idDataAttribute)
            description     = try? c.decodeIfPresent(String.self, forKey: .description)
            formattedValue  = try? c.decodeIfPresent(String.self, forKey: .formattedValue)
            if let d = try? c.decodeIfPresent(Double.self, forKey: .rawValue) {
                rawValue = d
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .rawValue) {
                rawValue = Double(s)
            } else {
                rawValue = nil
            }
            device          = try? c.decodeIfPresent(String.self, forKey: .device)
            instance        = try? c.decodeIfPresent(Int.self,    forKey: .instance)
            formatWithUnit  = try? c.decodeIfPresent(String.self, forKey: .formatWithUnit)
        }

        /// Human-readable device label including instance index,
        /// e.g. `"Battery Monitor [0]"` or `"MPPT [1]"`. Empty when device is unknown.
        public var deviceTag: String {
            guard let dev = device else { return "" }
            if let inst = instance { return "\(dev) [\(inst)]" }
            return dev
        }

        /// Unit string extracted from ``formatWithUnit`` by stripping the printf specifier.
        ///
        /// `"%.1f V"` → `"V"`, `"%.0f %%"` → `"%"`, `nil` when no unit is present.
        public var unit: String? {
            guard let f = formatWithUnit, !f.isEmpty else { return nil }
            var s = f
            if let r = s.range(
                of: #"%[-+ #0]*[0-9]*\.?[0-9]*[lhLqjzt]*[diouxXeEfgGsaAcCpn%]"#,
                options: .regularExpression
            ) { s.removeSubrange(r) }
            s = s.trimmingCharacters(in: .whitespaces)
                 .replacingOccurrences(of: "%%", with: "%")
            return s.isEmpty ? nil : s
        }
    }

    // MARK: - Init / shutdown

    private let config: Config
    private let httpClient: HTTPClient

    /// Creates a VRM client.
    ///
    /// - Parameters:
    ///   - config: Authentication and base URL configuration.
    ///   - eventLoopGroup: Shared NIO event loop group.
    public init(config: Config, eventLoopGroup: any EventLoopGroup) {
        self.config     = config
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
    }

    /// Shuts down the underlying HTTP client.
    public func shutdown() async throws {
        try await httpClient.shutdown()
    }

    // MARK: - API

    /// Lists all installations attached to a VRM user account.
    ///
    /// - Parameter userId: The VRM numeric user ID.
    public func installations(userId: Int) async throws -> [Installation] {
        struct W: Decodable { let records: [Installation] }
        let w: W = try await get(path: "/users/\(userId)/installations")
        return w.records
    }

    /// Fetches the latest diagnostic records for a site.
    ///
    /// - Parameter siteId: The VRM site (installation) ID.
    public func diagnostics(siteId: Int) async throws -> [DiagnosticRecord] {
        struct W: Decodable { let records: [DiagnosticRecord] }
        let w: W = try await get(path: "/installations/\(siteId)/diagnostics")
        return w.records
    }

    /// Returns all available measurements for a site as ``BoatMetric`` values.
    ///
    /// Maps each ``DiagnosticRecord`` with a numeric ``DiagnosticRecord/rawValue``
    /// and a non-nil ``DiagnosticRecord/description`` into a ``BoatMetric``.
    /// The metric name combines the device tag and description,
    /// e.g. `"Battery Monitor [0] — Battery voltage"`.
    ///
    /// - Parameter siteId: The VRM site ID.
    public func metrics(siteId: Int) async throws -> [BoatMetric] {
        let records = try await diagnostics(siteId: siteId)
        return records.compactMap { r in
            guard let v = r.rawValue, let n = r.description else { return nil }
            let tag = r.deviceTag
            let fullName = tag.isEmpty ? n : "\(tag) — \(n)"
            return BoatMetric(name: fullName, value: v, unit: r.unit)
        }
    }

    /// Continuously polls a VRM site and yields each batch as ``NMEAFrame``
    /// values, making the client directly compatible with ``BoatMetricStore``.
    ///
    /// Each poll fetches all site metrics and yields one ``NMEAFrame/metric(_:)``
    /// per value. Between polls the stream suspends for `pollInterval`.
    ///
    /// Use with ``BoatMetricStore/pipeSignalK(_:)`` so VRM values receive the
    /// lowest source priority (NMEA 0183 and NMEA 2000 sources win if present):
    ///
    /// ```swift
    /// store.pipeSignalK(vrmClient.frameStream(siteId: id, pollInterval: .seconds(60)))
    /// ```
    ///
    /// The stream ends when cancelled or when a network error occurs.
    ///
    /// - Parameters:
    ///   - siteId: VRM site (installation) identifier.
    ///   - pollInterval: Delay between consecutive polls. Defaults to 60 seconds.
    public func frameStream(
        siteId: Int,
        pollInterval: Duration = .seconds(60)
    ) -> AsyncThrowingStream<NMEAFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let batch = try await self.metrics(siteId: siteId)
                        for m in batch { continuation.yield(.metric(m)) }
                        try await Task.sleep(for: pollInterval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func get<T: Decodable & Sendable>(path: String) async throws -> T {
        let url = config.baseURL + path
        var req = HTTPClientRequest(url: url)
        req.headers.add(name: "X-Authorization", value: "Token \(config.accessToken)")
        req.headers.add(name: "Accept",           value: "application/json")
        let resp = try await httpClient.execute(req, timeout: .seconds(15))
        let data = try await resp.body.collect(upTo: 10 * 1024 * 1024)
        guard (200..<300).contains(resp.status.code) else {
            throw BoatCloudError.http(status: resp.status.code, body: String(buffer: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(buffer: data))
        } catch {
            throw BoatCloudError.decoding("\(error)")
        }
    }
}
