public import Foundation
public import Observation  // `@Observable` on the public BoatMetricStore exposes the Observable conformance


// MARK: - TimedSample

/// A timestamped scalar sample stored in a history ring buffer.
public struct TimedSample: Sendable, Codable {
    /// Time the sample was recorded.
    public let timestamp: Date
    /// The measured value (SI or nautical units, same convention as ``BoatMetric``).
    public let value: Double

    /// Creates a sample.
    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value     = value
    }
}


// MARK: - RingBuffer

/// A generic fixed-capacity circular buffer.
///
/// Elements are stored in insertion order until the buffer is full;
/// thereafter each new element overwrites the oldest. The ``chronological``
/// accessor always returns elements oldest-first regardless of internal layout.
public struct RingBuffer<T: Sendable>: Sendable {

    private var storage:    [T] = []
    private var writeIndex: Int = 0

    /// Maximum number of elements the buffer holds.
    public let capacity: Int

    /// Number of elements currently stored.
    public var count: Int { storage.count }

    /// `true` when no elements have been stored yet.
    public var isEmpty: Bool { storage.isEmpty }

    /// Creates an empty ring buffer with the given `capacity`.
    public init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    /// Appends `element`, evicting the oldest element when the buffer is full.
    public mutating func append(_ element: T) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[writeIndex] = element
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    /// All elements in chronological order (oldest first).
    public var chronological: [T] {
        guard storage.count == capacity else { return storage }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    /// Removes all elements, resetting the buffer to empty.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
    }
}


// MARK: - TieredHistory

/// A two-tier ring-buffer history for a single metric.
///
/// | Tier   | Sample interval | Smoothing window | Retention | Samples |
/// |--------|----------------|-----------------|-----------|---------|
/// | Recent | 5 s            | last 5 s (raw)  | 1 h       | 720     |
/// | Long   | 1 min          | last 60 s (raw) | 6 h       | 360     |
///
/// Angular values (wind direction, COG, …) are smoothed using a **circular
/// mean** so that wrapping through 0°/360° does not corrupt averages.
public struct TieredHistory: Sendable {

    /// 5-second samples — up to 720 samples covering 1 hour.
    public private(set) var recent = RingBuffer<TimedSample>(capacity: 720)

    /// 1-minute samples — up to 360 samples covering 6 hours.
    public private(set) var long   = RingBuffer<TimedSample>(capacity: 360)

    /// Whether values are angles in degrees. Circular mean is used when `true`.
    public let isAngle: Bool

    private var recentAcc:       [Double] = []
    private var longAcc:         [Double] = []
    private var recentLastFlush: Date     = .distantPast
    private var longLastFlush:   Date     = .distantPast

    /// Creates a tiered history.
    ///
    /// - Parameter isAngle: Pass `true` for angular metrics (e.g. TWD, COG, AWA).
    public init(isAngle: Bool = false) {
        self.isAngle = isAngle
    }

    /// Records a raw value at `now`, flushing a smoothed sample to each tier
    /// when its interval has elapsed.
    public mutating func add(_ value: Double, at now: Date) {
        recentAcc.append(value)
        longAcc.append(value)

        if now.timeIntervalSince(recentLastFlush) >= 5 {
            recent.append(TimedSample(timestamp: now, value: circularMeanIfNeeded(recentAcc)))
            recentAcc.removeAll()
            recentLastFlush = now
        }

        if now.timeIntervalSince(longLastFlush) >= 60 {
            long.append(TimedSample(timestamp: now, value: circularMeanIfNeeded(longAcc)))
            longAcc.removeAll()
            longLastFlush = now
        }
    }

    // MARK: Private

    private func circularMeanIfNeeded(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        guard isAngle else {
            return values.reduce(0.0, +) / Double(values.count)
        }
        let rad  = values.map { $0 * .pi / 180 }
        let sinS = rad.reduce(0.0) { $0 + sin($1) }
        let cosS = rad.reduce(0.0) { $0 + cos($1) }
        let deg  = atan2(sinS, cosS) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}


// MARK: - PressureHistory

/// Single-tier 30-minute-sample history, covering 48 hours (96 samples).
///
/// Used exclusively for `pressure.atmospheric`. The 30-minute resolution is
/// sufficient to detect rapid pressure falls (storm-warning threshold ≈ 3 hPa
/// per 3 h = 1.5 hPa per sample).
public struct PressureHistory: Sendable {

    /// 30-minute samples — up to 96 samples covering 48 hours.
    public private(set) var samples = RingBuffer<TimedSample>(capacity: 96)

    private var acc:       [Double] = []
    private var lastFlush: Date     = .distantPast

    /// Creates an empty pressure history.
    public init() {}

    /// Records a raw value at `now`, flushing an averaged sample every 30 minutes.
    public mutating func add(_ value: Double, at now: Date) {
        acc.append(value)
        if now.timeIntervalSince(lastFlush) >= 1800 {   // 30 min
            let avg = acc.reduce(0.0, +) / Double(acc.count)
            samples.append(TimedSample(timestamp: now, value: avg))
            acc.removeAll()
            lastFlush = now
        }
    }
}


// ============================================================
// MARK: - Private plumbing: source tagging & priority resolver
// ============================================================

// MARK: - SourceKind

private enum SourceKind: Sendable, Equatable {
    case nmea0183(talker: String, type: String)
    case nmea2000(pgn: UInt32)
    case signalK
    case unknown
}

// MARK: - TaggedMetric

private struct TaggedMetric: Sendable {
    let metric: BoatMetric
    let source: SourceKind
}

// MARK: - FrameCollector

/// Accumulates all frames within a 1-second window.
private struct FrameCollector: Sendable {

    struct Candidate: Sendable {
        let metric: BoatMetric
        let source: SourceKind
        let rank:   Int
    }

    var candidates:  [String: Candidate]     = [:]
    var aisTargets:  [AISTarget]             = []
    var gsvReports:  [(constellation: String, inView: Int, satellites: [SatelliteInfo])] = []

    /// HDOP observed per NMEA talker this window — used to tie-break GPS sources.
    var hdopByTalker: [String: Double] = [:]

    mutating func reset() {
        candidates.removeAll()
        aisTargets.removeAll()
        gsvReports.removeAll()
        hdopByTalker.removeAll()
    }

    mutating func add(_ tagged: TaggedMetric) {
        let name = tagged.metric.name

        // Track HDOP per NMEA talker for position tie-breaking.
        if name == "gps.hdop", case .nmea0183(let talker, _) = tagged.source {
            hdopByTalker[talker] = tagged.metric.value
        }

        let rank = PriorityResolver.rank(for: name, source: tagged.source)

        if let existing = candidates[name] {
            if rank < existing.rank {
                candidates[name] = Candidate(metric: tagged.metric, source: tagged.source, rank: rank)
            } else if rank == existing.rank,
                      let winner = tieBreak(new: tagged, existing: existing, name: name) {
                candidates[name] = winner
            }
        } else {
            candidates[name] = Candidate(metric: tagged.metric, source: tagged.source, rank: rank)
        }
    }

    // MARK: Tie-breaking

    private func tieBreak(new: TaggedMetric, existing: Candidate, name: String) -> Candidate? {
        if isPositionMetric(name) {
            return positionTieBreak(new: new, existing: existing)
        }
        if isSOGCOGMetric(name) {
            let newOrder = talkerOrder(talker(of: new.source))
            let exOrder  = talkerOrder(talker(of: existing.source))
            return newOrder < exOrder
                ? Candidate(metric: new.metric, source: new.source, rank: existing.rank)
                : nil
        }
        // Default: first seen wins.
        return nil
    }

    private func positionTieBreak(new: TaggedMetric, existing: Candidate) -> Candidate? {
        let newTalker = talker(of: new.source)
        let exTalker  = talker(of: existing.source)
        let newHDOP   = hdopByTalker[newTalker] ?? .infinity
        let exHDOP    = hdopByTalker[exTalker]  ?? .infinity

        if newHDOP < exHDOP {
            return Candidate(metric: new.metric, source: new.source, rank: existing.rank)
        }
        if newHDOP == exHDOP && talkerOrder(newTalker) < talkerOrder(exTalker) {
            return Candidate(metric: new.metric, source: new.source, rank: existing.rank)
        }
        return nil
    }

    // MARK: Helpers

    private func isPositionMetric(_ name: String) -> Bool {
        name == "lat" || name == "lon" || name == "altitude"
    }

    private func isSOGCOGMetric(_ name: String) -> Bool {
        name == "SOG" || name == "COG"
    }

    private func talker(of source: SourceKind) -> String {
        guard case .nmea0183(let t, _) = source else { return "" }
        return t
    }

    /// Talker priority: GP=0 (best) … GI=6, others=7 (worst).
    private func talkerOrder(_ talker: String) -> Int {
        switch talker {
        case "GP": return 0
        case "GN": return 1
        case "GA": return 2
        case "GL": return 3
        case "GB": return 4
        case "GQ": return 5
        case "GI": return 6
        default:   return 7
        }
    }
}

// MARK: - PriorityResolver

/// Maps (metric name, source) → priority rank. Lower = higher priority.
private enum PriorityResolver {

    static func rank(for metricName: String, source: SourceKind) -> Int {
        switch metricName {

        // --- 1. Position ---
        case "lat", "lon", "altitude":
            return positionRank(source)

        // --- 2. SOG / COG ---
        case "SOG", "COG":
            return sogCogRank(source)

        // --- 3. Speed through water ---
        case "STW":
            return stwRank(source)

        // --- 4. Heading ---
        case "HDG.true", "HDG.magnetic", "magneticVariation", "magneticDeviation":
            return headingRank(source)

        // --- 5. Rate of turn ---
        case "ROT":
            return rotRank(source)

        // --- 6a. Apparent wind ---
        case "AWA", "AWS":
            return apparentWindRank(source)

        // --- 6b. True wind ---
        case "TWA", "TWD", "TWS":
            return trueWindRank(source)

        // --- 7. Depth ---
        case "depth", "depth.offset":
            return depthRank(source)

        // --- 8. Autopilot / XTE ---
        case "navigation.xte":
            return autopilotRank(source)

        // --- 9. Navigation / routing ---
        case "navigation.bearingToDest",
             "navigation.distanceToWaypoint",
             "navigation.vmg",
             "waypoint.lat", "waypoint.lon":
            return navRank(source)

        // --- 10. Atmosphere ---
        case "pressure.atmospheric":
            return atmosphereRank(pgns: [130310, 130311, 130314],
                                  nmea0183Types: ["MDA"],
                                  source: source)

        case "temperature.air":
            return atmosphereRank(pgns: [130310, 130311],
                                  nmea0183Types: ["MDA"],
                                  source: source)

        case "temperature.water":
            return atmosphereRank(pgns: [130310, 130311, 130312],
                                  nmea0183Types: ["MTW", "MDA"],
                                  source: source)

        case "humidity":
            return atmosphereRank(pgns: [130311],
                                  nmea0183Types: ["MDA"],
                                  source: source)

        // --- 11. Everything else (engines, tanks, batteries, AIS, radar, …) ---
        default:
            return defaultRank(source)
        }
    }

    // MARK: Per-group rank functions

    private static func positionRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 129029):        return 10   // GNSS Position Data — full quality
        case .nmea0183(_, type: "GGA"):     return 20   // HDOP + fix quality
        case .nmea0183(_, type: "GNS"):     return 30   // multi-constellation GGA variant
        case .nmea2000(pgn: 129025):        return 40   // Position Rapid Update — no quality
        case .nmea0183(_, type: "RMC"):     return 50   // no quality field
        case .nmea0183(_, type: "GLL"):     return 60   // lat/lon only
        case .signalK:                      return 70
        default:                            return 100
        }
    }

    private static func sogCogRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 129026):        return 10   // COG & SOG Rapid Update
        case .nmea0183(_, type: "VTG"):     return 20
        case .nmea0183(_, type: "RMC"):     return 30
        case .signalK:                      return 40
        default:                            return 100
        }
    }

    private static func stwRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 128259):        return 10   // Speed
        case .nmea0183(_, type: "VHW"):     return 20
        case .signalK:                      return 30
        default:                            return 100
        }
    }

    private static func headingRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 127250):        return 10   // Vessel Heading — most complete
        case .nmea0183(_, type: "HDT"):     return 20
        case .nmea0183(_, type: "HDG"):     return 30
        case .nmea0183(_, type: "HDM"):     return 40
        case .signalK:                      return 50
        default:                            return 100
        }
    }

    private static func rotRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 127251):        return 10
        case .nmea0183(_, type: "ROT"):     return 20
        case .signalK:                      return 30
        default:                            return 100
        }
    }

    private static func apparentWindRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 130306):        return 10   // Wind Data (apparent reference)
        case .nmea0183(_, type: "MWV"):     return 20   // reference = R
        case .nmea0183(_, type: "VWR"):     return 30   // older relative wind
        case .signalK:                      return 40
        default:                            return 100
        }
    }

    private static func trueWindRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 130306):        return 10   // Wind Data (true/ground reference)
        case .nmea0183(_, type: "MWD"):     return 20   // dedicated true wind
        case .nmea0183(_, type: "MWV"):     return 30   // reference = T
        case .nmea0183(_, type: "MDA"):     return 40   // composite; wind is secondary
        case .signalK:                      return 50
        default:                            return 100
        }
    }

    private static func depthRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 128267):        return 10   // Water Depth
        case .nmea0183(_, type: "DPT"):     return 20
        case .nmea0183(_, type: "DBT"):     return 30
        case .signalK:                      return 40
        default:                            return 100
        }
    }

    /// Autopilot / cross-track error. APB is preferred over APA (backward-compat pattern).
    private static func autopilotRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea0183(_, type: "APB"):     return 10   // most complete autopilot sentence
        case .nmea0183(_, type: "APA"):     return 20   // legacy; only when APB absent
        case .nmea0183(_, type: "XTE"):     return 30   // XTE only
        case .nmea2000(pgn: 129283):        return 40   // Cross Track Error
        case .signalK:                      return 50
        default:                            return 100
        }
    }

    private static func navRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000(pgn: 129284):            return 10   // Navigation Data
        case .nmea0183(_, type: "APB"):         return 20
        case .nmea0183(_, type: "RMB"):         return 30
        case .nmea0183(_, type: "BWC"),
             .nmea0183(_, type: "BWR"):         return 40
        case .signalK:                          return 50
        default:                                return 100
        }
    }

    /// Atmosphere rank — caller specifies which PGNs and NMEA sentence types are rank-1 and rank-2.
    private static func atmosphereRank(pgns: [UInt32], nmea0183Types: [String], source: SourceKind) -> Int {
        switch source {
        case .nmea2000(let pgn) where pgns.contains(pgn):       return 10
        case .nmea0183(_, let type) where nmea0183Types.contains(type): return 20
        case .signalK:                                          return 30
        default:                                                return 100
        }
    }

    /// Pass-through rank for metrics with no conflict (engines, tanks, batteries, etc.).
    private static func defaultRank(_ s: SourceKind) -> Int {
        switch s {
        case .nmea2000:  return 10
        case .nmea0183:  return 20
        case .signalK:   return 30
        default:         return 100
        }
    }
}


// ============================================================
// MARK: - BoatMetricStore
// ============================================================

/// Central store that aggregates, deduplicates, and exposes all live marine
/// data for use in SwiftUI views and widgets.
///
/// ## Overview
///
/// `BoatMetricStore` solves the multi-source conflict problem inherent in
/// marine instrumentation: a single GPS burst produces `RMC`, `GGA`, `VTG`
/// and more — all within the same second — and two GPS receivers may
/// broadcast competing values.
///
/// It works in three stages:
///
/// 1. **Collection** — every ``NMEAFrame`` fed via ``feed(_:)`` (or piped
///    via ``pipe(_:)``) is accumulated into a 1-second window.
/// 2. **Resolution** — when the 1-second timer fires, ``PriorityResolver``
///    picks one value per canonical metric name using the source-priority
///    tables described in `METRIC_STORE.md`.
/// 3. **Publication** — the winning values update ``metrics``,
///    ``aisTargets``, ``satellites``, and the history ring buffers.
///
/// ## Usage
///
/// ```swift
/// let store = BoatMetricStore()
/// store.start()
///
/// let transport = NMEATransport()
/// store.pipe(transport.connect(url: url))
///
/// // In a SwiftUI view:
/// Text(store.metrics["SOG"]?.value.formatted() ?? "—")
/// ```
///
/// ## AppGroup / widget sharing
///
/// Initialise with a non-nil `appGroupID` to have the store write a compact
/// JSON snapshot to `UserDefaults(suiteName:)` after each flush. Your widget
/// reads the same suite to display live data.
///
/// > Note: AppGroup sharing is compiled only on Darwin platforms
/// > (`#if canImport(Darwin)`).
@Observable
@MainActor
public final class BoatMetricStore {

    // MARK: Published state

    /// All resolved numeric metrics, keyed by canonical name (e.g. `"SOG"`, `"lat"`).
    public private(set) var metrics: [String: BoatMetric] = [:]

    /// AIS targets keyed by MMSI.
    ///
    /// Targets not updated for 10 minutes are considered stale (check with
    /// ``isStale(_:)``); targets not updated for 30 minutes are removed.
    public private(set) var aisTargets: [Int: AISTarget] = [:]

    /// Satellite lists keyed by constellation name.
    ///
    /// Keys: `"GPS"`, `"GLONASS"`, `"Galileo"`, `"BeiDou"`, `"QZSS"`,
    /// `"NavIC"`, `"GNSS"`. Replaced wholesale on each GSV report.
    public private(set) var satellites: [String: [SatelliteInfo]] = [:]

    // Wind histories
    /// True wind speed — 5 s / 1 min two-tier history.
    public private(set) var windTWS     = TieredHistory(isAngle: false)
    /// True wind direction — circular mean, 5 s / 1 min two-tier history.
    public private(set) var windTWD     = TieredHistory(isAngle: true)
    /// Apparent wind speed — 5 s / 1 min two-tier history.
    public private(set) var windAWS     = TieredHistory(isAngle: false)
    /// Apparent wind angle — circular mean, 5 s / 1 min two-tier history.
    public private(set) var windAWA     = TieredHistory(isAngle: true)

    // Navigation histories
    /// Speed over ground — 5 s / 1 min two-tier history.
    public private(set) var sog         = TieredHistory(isAngle: false)
    /// Course over ground — circular mean, 5 s / 1 min two-tier history.
    public private(set) var cog         = TieredHistory(isAngle: true)
    /// Water depth — 5 s / 1 min two-tier history.
    public private(set) var depthHist   = TieredHistory(isAngle: false)
    /// Water temperature — 5 s / 1 min two-tier history.
    public private(set) var waterTemp   = TieredHistory(isAngle: false)

    // Pressure history
    /// Atmospheric pressure — 30 min samples over 48 hours.
    public private(set) var pressure    = PressureHistory()

    // MARK: Private state

    private let appGroupID: String?
    private var collector     = FrameCollector()
    private var currentSource = SourceKind.unknown
    private var aisLastSeen:  [Int: Date] = [:]
    private var timerTask:    Task<Void, Never>?

    // MARK: Init

    /// Creates a `BoatMetricStore`.
    ///
    /// - Parameter appGroupID: An App Group identifier. When non-nil,
    ///   a compact JSON snapshot is written to `UserDefaults(suiteName:)`
    ///   after every flush so that a widget or extension can read live data.
    ///   Has no effect on non-Darwin platforms.
    public init(appGroupID: String? = nil) {
        self.appGroupID = appGroupID
    }

    // MARK: Lifecycle

    /// Starts the 1-second flush timer.
    ///
    /// Call this once after creating the store. Calling it again while the
    /// timer is already running has no effect.
    public func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                self.tick()   // Task inherits @MainActor from start(); no hop needed
            }
        }
    }

    /// Stops the flush timer.
    ///
    /// In-flight frames accumulated since the last flush are discarded.
    /// Call ``start()`` to resume.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: Feeding data

    /// Feeds a single frame into the current 1-second window.
    ///
    /// Frames accumulate until the next timer tick, at which point the
    /// priority resolver picks winners and publishes results.
    /// Prefer ``pipe(_:)`` when consuming an async stream.
    public func feed(_ frame: NMEAFrame) {
        switch frame {
        case .nmea0183(_, let talker, let type, _):
            currentSource = .nmea0183(talker: talker, type: type)

        case .nmea2000(let pgn, _, _, _):
            currentSource = .nmea2000(pgn: pgn)

        case .metric(let m):
            collector.add(TaggedMetric(metric: m, source: currentSource))

        case .aisTarget(let t):
            collector.aisTargets.append(t)

        case .gsvReport(let constellation, let inView, let sats):
            collector.gsvReports.append((constellation, inView, sats))

        case .invalidChecksum, .unknown:
            currentSource = .unknown
        }
    }

    /// Feeds a frame, tagging any `.metric` case as a **Signal K** source
    /// (always lowest priority in the resolution tables).
    ///
    /// Use this when piping the output of a ``SignalKClient``:
    ///
    /// ```swift
    /// store.pipeSignalK(signalKClient.subscribe())
    /// ```
    public func feedSignalK(_ frame: NMEAFrame) {
        if case .metric(let m) = frame {
            collector.add(TaggedMetric(metric: m, source: .signalK))
        } else {
            feed(frame)
        }
    }

    /// Feeds a single ``BoatMetric`` directly into the current window.
    ///
    /// The metric is tagged as a Signal K source (lowest priority), so any
    /// NMEA 0183 or NMEA 2000 value for the same metric name takes precedence.
    /// Intended for on-device sensor data (``DeviceSensors``) or one-off VRM
    /// REST responses:
    ///
    /// ```swift
    /// let batch = try await vrmClient.metrics(siteId: id)
    /// store.feedMetrics(batch)
    /// ```
    public func feedMetric(_ metric: BoatMetric) {
        collector.add(TaggedMetric(metric: metric, source: .signalK))
    }

    /// Feeds a batch of ``BoatMetric`` values into the current window.
    ///
    /// Convenience wrapper around ``feedMetric(_:)`` — useful for one VRM poll
    /// tick inside a manual poll loop.
    public func feedMetrics(_ metrics: [BoatMetric]) {
        for m in metrics { feedMetric(m) }
    }

    // MARK: Async stream piping

    /// Consumes an async stream of frames, feeding each into the store.
    ///
    /// The returned `Task` runs until the stream ends or is cancelled.
    /// The store's flush timer is independent — call ``start()`` separately.
    ///
    /// - Returns: A `Task` that you can cancel to stop consumption.
    @discardableResult
    public nonisolated func pipe<S: AsyncSequence & Sendable>(_ stream: S) -> Task<Void, any Error>
        where S.Element == NMEAFrame
    {
        // nonisolated so the Task runs in the generic executor and iterates the
        // stream without pinning the main actor. Each frame hops to MainActor
        // only for the feed() call.
        Task { [weak self] in
            for try await frame in stream {
                guard let store = self else { break }
                await store.feed(frame)
            }
        }
    }

    /// Consumes an async stream of frames, tagging all `.metric` frames as
    /// Signal K (lowest priority). Use this for ``SignalKClient`` streams.
    ///
    /// - Returns: A `Task` that you can cancel to stop consumption.
    @discardableResult
    public nonisolated func pipeSignalK<S: AsyncSequence & Sendable>(_ stream: S) -> Task<Void, any Error>
        where S.Element == NMEAFrame
    {
        Task { [weak self] in
            for try await frame in stream {
                guard let store = self else { break }
                await store.feedSignalK(frame)
            }
        }
    }

    /// Consumes an async stream of raw ``BoatMetric`` values, feeding each
    /// into the store as a Signal K source (lowest priority).
    ///
    /// Use this for ``DeviceSensors``, which emits `BoatMetric` directly
    /// rather than `NMEAFrame`:
    ///
    /// ```swift
    /// let sensors = DeviceSensors()
    /// store.pipeMetrics(sensors.stream())
    /// ```
    ///
    /// - Returns: A `Task` that you can cancel to stop consumption.
    @discardableResult
    public nonisolated func pipeMetrics<S: AsyncSequence & Sendable>(_ stream: S) -> Task<Void, any Error>
        where S.Element == BoatMetric
    {
        Task { [weak self] in
            for try await metric in stream {
                guard let store = self else { break }
                await store.feedMetric(metric)
            }
        }
    }

    // MARK: AIS staleness

    /// Returns `true` if `mmsi` has not been updated for 10 minutes.
    public func isStale(_ mmsi: Int) -> Bool {
        guard let date = aisLastSeen[mmsi] else { return true }
        return Date().timeIntervalSince(date) > 600
    }

    // MARK: Internal flush

    private func tick() {
        let now = Date()
        flush(at: now)
        pruneAISTargets(now: now)
    }

    /// Whether `metrics["HDG.true"]` currently holds a COG-derived fallback
    /// heading (used as a last resort when no NMEA/NMEA 2000 heading and no
    /// device compass are available).
    private var headingDerivedFromCOG = false

    private func flush(at now: Date) {
        let (newMetrics, newAIS, newGSV) = (
            collector.candidates.values.map(\.metric),
            collector.aisTargets,
            collector.gsvReports
        )
        collector.reset()
        currentSource = .unknown

        // Drop the previous flush's COG-derived heading so it can never mask a
        // real heading source resolved this flush.
        if headingDerivedFromCOG {
            metrics["HDG.true"] = nil
            headingDerivedFromCOG = false
        }

        // Merge metrics and feed histories.
        for m in newMetrics {
            metrics[m.name] = m
            feedHistory(name: m.name, value: m.value, at: now)
        }

        // Last-resort heading: when neither a NMEA/NMEA 2000 heading nor the
        // device compass provides HDG, fall back to COG (course over ground) so
        // consumers always have a heading. It is refreshed on every flush and is
        // automatically superseded as soon as a real heading source appears.
        if metrics["HDG.true"] == nil,
           metrics["HDG.magnetic"] == nil,
           let cog = metrics["COG"], cog.value >= 0 {
            metrics["HDG.true"] = BoatMetric(
                name: "HDG.true", value: cog.value, unit: cog.unit, timestamp: cog.timestamp
            )
            headingDerivedFromCOG = true
        }

        // Merge AIS targets (preserve static fields from older reports).
        for target in newAIS {
            mergeAIS(target, at: now)
        }

        // Replace satellite lists wholesale.
        for report in newGSV {
            satellites[report.constellation] = report.satellites
        }

#if canImport(Darwin)
        writeAppGroupSnapshot(at: now)
#endif
    }

    private func feedHistory(name: String, value: Double, at now: Date) {
        switch name {
        case "TWS":                 windTWS.add(value, at: now)
        case "TWD":                 windTWD.add(value, at: now)
        case "AWS":                 windAWS.add(value, at: now)
        case "AWA":                 windAWA.add(value, at: now)
        case "SOG":                 sog.add(value, at: now)
        case "COG":                 cog.add(value, at: now)
        case "depth":               depthHist.add(value, at: now)
        case "temperature.water":   waterTemp.add(value, at: now)
        case "pressure.atmospheric": pressure.add(value, at: now)
        default:                    break
        }
    }

    private func mergeAIS(_ incoming: AISTarget, at now: Date) {
        aisLastSeen[incoming.mmsi] = now

        guard let existing = aisTargets[incoming.mmsi] else {
            aisTargets[incoming.mmsi] = incoming
            return
        }

        // Position reports (msg 1/2/3/18) carry no static data — preserve it
        // from the last static/voyage report (msg 5/24).
        aisTargets[incoming.mmsi] = AISTarget(
            mmsi:              incoming.mmsi,
            messageType:       incoming.messageType,
            channel:           incoming.channel,
            latitude:          incoming.latitude          ?? existing.latitude,
            longitude:         incoming.longitude         ?? existing.longitude,
            speedOverGround:   incoming.speedOverGround   ?? existing.speedOverGround,
            courseOverGround:  incoming.courseOverGround  ?? existing.courseOverGround,
            trueHeading:       incoming.trueHeading       ?? existing.trueHeading,
            rateOfTurn:        incoming.rateOfTurn        ?? existing.rateOfTurn,
            positionAccuracy:  incoming.positionAccuracy,
            raim:              incoming.raim,
            navigationStatus:  incoming.navigationStatus  ?? existing.navigationStatus,
            maneuverIndicator: incoming.maneuverIndicator ?? existing.maneuverIndicator,
            shipName:          incoming.shipName          ?? existing.shipName,
            callsign:          incoming.callsign          ?? existing.callsign,
            shipType:          incoming.shipType          ?? existing.shipType,
            imoNumber:         incoming.imoNumber         ?? existing.imoNumber,
            destination:       incoming.destination       ?? existing.destination,
            draught:           incoming.draught           ?? existing.draught,
            navAidType:        incoming.navAidType        ?? existing.navAidType,
            altitude:          incoming.altitude          ?? existing.altitude
        )
    }

    private func pruneAISTargets(now: Date) {
        let removeBefore = now.addingTimeInterval(-1800)  // 30 min
        for mmsi in aisLastSeen.keys {
            guard let date = aisLastSeen[mmsi], date < removeBefore else { continue }
            aisTargets.removeValue(forKey: mmsi)
            aisLastSeen.removeValue(forKey: mmsi)
        }
    }

    // MARK: AppGroup / widget sharing (Darwin only)

#if canImport(Darwin)
    private func writeAppGroupSnapshot(at now: Date) {
        guard let id = appGroupID,
              let defaults = UserDefaults(suiteName: id) else { return }

        // Flat metric values dict (name → Double).
        var flat: [String: Double] = [:]
        for (k, m) in metrics { flat[k] = m.value }
        defaults.set(flat, forKey: "boattools.metrics")

        // History arrays encoded as JSON Data.
        let encoder = JSONEncoder()
        func encodeHistory(_ samples: [TimedSample]) -> Data? {
            try? encoder.encode(samples)
        }

        if let d = encodeHistory(windTWS.recent.chronological) {
            defaults.set(d, forKey: "boattools.wind.recent.tws")
        }
        if let d = encodeHistory(windTWD.recent.chronological) {
            defaults.set(d, forKey: "boattools.wind.recent.twd")
        }
        if let d = encodeHistory(windTWS.long.chronological) {
            defaults.set(d, forKey: "boattools.wind.long.tws")
        }
        if let d = encodeHistory(windTWD.long.chronological) {
            defaults.set(d, forKey: "boattools.wind.long.twd")
        }
        if let d = encodeHistory(sog.recent.chronological) {
            defaults.set(d, forKey: "boattools.nav.recent.sog")
        }
        if let d = encodeHistory(cog.recent.chronological) {
            defaults.set(d, forKey: "boattools.nav.recent.cog")
        }
        if let d = encodeHistory(pressure.samples.chronological) {
            defaults.set(d, forKey: "boattools.pressure")
        }

        // Flush timestamp in ISO 8601.
        defaults.set(ISO8601DateFormatter().string(from: now), forKey: "boattools.updatedAt")
    }
#endif
}
