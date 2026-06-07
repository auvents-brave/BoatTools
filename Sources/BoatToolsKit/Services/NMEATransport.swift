// The NMEA transport relies on swift-nio (NIOPosix) for TCP/UDP, which does not
// build on Windows. The entire transport is compiled out there; Signal K / NMEA
// decoding, the simulator and the metric store remain available.
#if !os(Windows)
public import NIOCore
internal import NIOPosix
internal import Foundation


// MARK: - Public configuration types

/// Addressing mode for an ``NMEATransport`` connection.
public enum NMEATransportMode: Sendable {
    /// TCP client connecting to a host and port.
    case tcp(host: String, port: Int)
    /// UDP receiver bound to a local port, optionally joining a multicast group.
    case udp(listenPort: Int, multicastGroup: String? = nil)
}

/// Wire format for incoming marine data.
public enum NMEAInputFormat: Sendable {
    /// Auto-detect from the first recognisable line.
    case auto
    /// NMEA 0183 sentences (`$`/`!` prefix).
    case nmea0183
    /// Yacht Devices RAW hex format.
    case yachtDevicesRaw
    /// SeaSmart.Net `$PCDIN` encapsulation.
    case seaSmartNet
    /// Signal K NDJSON deltas (one JSON object per line).
    case signalK
    /// Canboat "PLAIN" CSV (`TIMESTAMP,PRIO,PGN,SRC,DST,LEN,D0,…`).
    case canboatPlain
    /// Digital Yacht iKonvert (`!PDGY,PGN,PRIO,SRC,DST,timer,base64`).
    case iKonvert
}

/// Configuration for an ``NMEATransport`` instance.
public struct NMEATransportConfig: Sendable {
    /// Transport addressing mode.
    public var mode: NMEATransportMode
    /// Expected wire format. Defaults to `.auto` for format detection.
    public var format: NMEAInputFormat
    /// Whether to decode NMEA 2000 PGNs into ``BoatMetric`` values alongside raw frames.
    public var decodePGNs: Bool
    /// Optional sink called with every raw line before parsing.
    ///
    /// Use this to write a capture file for later replay with `boattools file`.
    /// Called on the NIO event loop thread — the closure must be `@Sendable`.
    public var rawLogger: (@Sendable (String) -> Void)?

    /// Creates a transport configuration.
    public init(mode: NMEATransportMode,
                format: NMEAInputFormat = .auto,
                decodePGNs: Bool = true,
                rawLogger: (@Sendable (String) -> Void)? = nil) {
        self.mode = mode
        self.format = format
        self.decodePGNs = decodePGNs
        self.rawLogger = rawLogger
    }
}


// MARK: - NMEATransport

/// SwiftNIO-based TCP/UDP transport for NMEA 0183, NMEA 2000, and Signal K data.
///
/// All mutable state (``LineAggregator``, ``FrameDispatcher``, NIO handlers) is
/// confined to the NIO event loop — no locks are needed. The handlers are marked
/// `@unchecked Sendable` because isolation is guaranteed by the NIO pipeline.
///
/// ## Usage
/// ```swift
/// let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
/// let config = NMEATransportConfig(mode: .tcp(host: "192.168.1.16", port: 10110))
/// let transport = NMEATransport(config: config, group: group)
/// for try await frame in transport.stream() {
///     print(frame)
/// }
/// ```
public struct NMEATransport: Sendable {
    private let config: NMEATransportConfig
    private let group: any EventLoopGroup

    /// Creates a transport with the given configuration and NIO event loop group.
    public init(config: NMEATransportConfig, group: any EventLoopGroup) {
        self.config = config
        self.group = group
    }

    /// Opens a connection using the shared NIO event loop, so callers need no
    /// NIO. Pipe with ``BoatMetricStore/pipe(_:)``.
    public static func frameStream(config: NMEATransportConfig) -> AsyncThrowingStream<NMEAFrame, any Error> {
        NMEATransport(config: config, group: MultiThreadedEventLoopGroup.singleton).stream()
    }

    /// Opens the connection and returns an asynchronous frame stream.
    ///
    /// The stream terminates when the remote peer closes the connection or when
    /// the caller discards the `AsyncThrowingStream` (which cancels the channel).
    public func stream() -> AsyncThrowingStream<NMEAFrame, any Error> {
        let cfg = config
        let elg = group

        return AsyncThrowingStream { continuation in
            let emit: @Sendable (NMEAFrame) -> Void = { continuation.yield($0) }

            let future: EventLoopFuture<any Channel>
            switch cfg.mode {
            case .tcp(let host, let port):
                future = Self.bootstrapTCP(group: elg, host: host, port: port,
                                           config: cfg, emit: emit)
            case .udp(let port, let mc):
                future = Self.bootstrapUDP(group: elg, port: port,
                                           multicastGroup: mc,
                                           config: cfg, emit: emit)
            }

            future.whenComplete { result in
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

    // MARK: TCP bootstrap

    private static func bootstrapTCP(group: any EventLoopGroup,
                                     host: String, port: Int,
                                     config: NMEATransportConfig,
                                     emit: @escaping @Sendable (NMEAFrame) -> Void
    ) -> EventLoopFuture<any Channel> {
        ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations
                        .addHandler(NMEAHandlerTCP(config: config, emit: emit))
                }
            }
            .connect(host: host, port: port)
    }

    // MARK: UDP bootstrap

    private static func bootstrapUDP(group: any EventLoopGroup,
                                     port: Int,
                                     multicastGroup: String?,
                                     config: NMEATransportConfig,
                                     emit: @escaping @Sendable (NMEAFrame) -> Void
    ) -> EventLoopFuture<any Channel> {
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations
                        .addHandler(NMEAHandlerUDP(config: config, emit: emit))
                }
            }
        let bound = bootstrap.bind(host: "0.0.0.0", port: port)

        guard let groupAddr = multicastGroup else { return bound }

        return bound.flatMap { channel -> EventLoopFuture<any Channel> in
            guard let mc = channel as? (any MulticastChannel) else {
                return channel.eventLoop.makeSucceededFuture(channel)
            }
            do {
                let socketAddr = try SocketAddress(ipAddress: groupAddr, port: port)
                return mc.joinGroup(socketAddr).map { _ in channel }
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
}


// MARK: - NIO handlers (event-loop-confined)

// MARK: - Multipart assembler

/// Assembles multi-sentence NMEA payloads (VDM/VDO, and any other multipart sentences).
///
/// Each sentence carries: total parts, part number (1-based), sequential message ID (0 = no ID),
/// payload fragment, and fill bits on the last part. Parts with the same sequential ID
/// are accumulated until complete, then the combined payload is returned.
///
/// Not thread-safe — confined to a single NIO event loop (same as ``FrameDispatcher``).
fileprivate final class MultipartAssembler: @unchecked Sendable {

    private struct Accumulator {
        var totalParts: Int
        var parts: [Int: String]  // part number (1-based) → payload fragment
        var fillBits: Int         // from the last part
        var channel: Character
    }

    // Key: sequential message ID (1–9) → accumulator. ID 0 is treated as single-part.
    private var pending: [Int: Accumulator] = [:]

    /// Feeds one VDM/VDO fields array.
    ///
    /// - Parameter fields: comma-split fields including the `$xxVDM` header at [0].
    /// - Returns: `(payload, fillBits, channel)` when all parts have arrived, else `nil`.
    func feed(fields: [String]) -> (payload: String, fillBits: Int, channel: Character)? {
        // fields: [0]=$..VDM [1]=totalCount [2]=partNum [3]=seqId [4]=channel [5]=payload [6]=fillBits*CS
        guard fields.count >= 7,
              let total   = Int(fields[1]),
              let partNum = Int(fields[2]),
              total >= 1, partNum >= 1, partNum <= total
        else { return nil }

        let seqId   = Int(fields[3]) ?? 0
        let channel = fields[4].first ?? "A"
        let payload = fields[5]
        // fill bits may have checksum appended: "0*1C" → split on "*"
        let fillStr = fields[6].split(separator: "*", maxSplits: 1).first.map(String.init) ?? fields[6]
        let fillBits = Int(fillStr) ?? 0

        // Single-part shortcut
        if total == 1 {
            return (payload, fillBits, channel)
        }

        // Multi-part: accumulate, keyed by sequential ID. The ID is frequently
        // absent (field 3 empty → 0); since a message's fragments are transmitted
        // consecutively, a single slot per ID is enough as long as we (re)start it
        // whenever the first part arrives.
        let key = seqId
        if partNum == 1 || pending[key]?.totalParts != total {
            pending[key] = Accumulator(totalParts: total, parts: [:], fillBits: 0, channel: channel)
        }
        pending[key]?.parts[partNum] = payload
        if partNum == total { pending[key]?.fillBits = fillBits }

        guard let acc = pending[key], acc.parts.count == total else { return nil }

        // All parts received — assemble in order.
        pending.removeValue(forKey: key)
        var assembled = ""
        for i in 1 ... total {
            assembled += acc.parts[i] ?? ""
        }
        return (assembled, acc.fillBits, acc.channel)
    }
}


// MARK: - AIS target tracker

/// Maintains a per-MMSI database of AIS static info (name, callsign, ship type,
/// IMO, destination, draught), so that subsequent position reports — which carry
/// no identity by AIS spec — can be enriched with the most recently observed
/// static data for the same MMSI.
///
/// Real AIS displays (OpenCPN, ECDIS, chartplotters) do this routinely: a Class A
/// vessel transmits its name/type every ~6 minutes (message type 5), and its
/// position every few seconds (types 1/2/3). Without correlation the position
/// reports would all show "MMSI 123456789" with no name.
///
/// Not thread-safe — confined to the NIO event loop alongside ``FrameDispatcher``.
fileprivate final class AISTargetTracker: @unchecked Sendable {

    private struct StaticInfo {
        var shipName: String?
        var callsign: String?
        var shipType: ShipType?
        var imoNumber: Int?
        var destination: String?
        var draught: Double?
    }

    private var byMMSI: [Int: StaticInfo] = [:]

    /// Updates the database with any static info present in `target`, then returns
    /// an enriched target where missing static fields are backfilled from history.
    func enrich(_ target: AISTarget) -> AISTarget {
        var info = byMMSI[target.mmsi] ?? StaticInfo()
        if let v = target.shipName    { info.shipName    = v }
        if let v = target.callsign    { info.callsign    = v }
        if let v = target.shipType    { info.shipType    = v }
        if let v = target.imoNumber   { info.imoNumber   = v }
        if let v = target.destination { info.destination = v }
        if let v = target.draught     { info.draught     = v }
        byMMSI[target.mmsi] = info

        return AISTarget(
            mmsi: target.mmsi,
            messageType: target.messageType,
            channel: target.channel,
            latitude: target.latitude,
            longitude: target.longitude,
            speedOverGround: target.speedOverGround,
            courseOverGround: target.courseOverGround,
            trueHeading: target.trueHeading,
            rateOfTurn: target.rateOfTurn,
            positionAccuracy: target.positionAccuracy,
            raim: target.raim,
            navigationStatus: target.navigationStatus,
            maneuverIndicator: target.maneuverIndicator,
            shipName:    target.shipName    ?? info.shipName,
            callsign:    target.callsign    ?? info.callsign,
            shipType:    target.shipType    ?? info.shipType,
            imoNumber:   target.imoNumber   ?? info.imoNumber,
            destination: target.destination ?? info.destination,
            draught:     target.draught     ?? info.draught,
            navAidType:  target.navAidType,
            altitude:    target.altitude)
    }
}


// MARK: - NMEA 2000 fast-packet assembler

/// Reassembles multi-CAN-frame NMEA 2000 fast-packet PGNs back into their
/// logical payload.
///
/// NMEA 2000 fast-packet protocol — each logical PGN payload is split across
/// multiple 8-byte CAN frames:
///
///   First frame:
///     byte 0 = (sequence_counter[3 bits] << 5) | (frame_number[5 bits] = 0)
///     byte 1 = total payload length in bytes
///     bytes 2-7 = first 6 bytes of payload
///
///   Continuation frame (frame_number 1, 2, 3, …):
///     byte 0 = (sequence_counter[3 bits] << 5) | frame_number[5 bits]
///     bytes 1-7 = next 7 bytes of payload
///
/// Accumulators are keyed by (source-address, PGN, sequence_counter) so
/// concurrent series from different sources don't interleave. Out-of-order
/// frames reset the accumulator. Confined to the NIO event loop alongside
/// ``FrameDispatcher`` — not thread-safe.
fileprivate final class FastPacketAssembler: @unchecked Sendable {

    private struct Key: Hashable {
        let source: UInt8
        let pgn: UInt32
    }

    private struct Acc {
        let sequenceCounter: UInt8
        var totalLength: Int
        var data: [UInt8]
        var nextFrameNumber: UInt8
    }

    private var pending: [Key: Acc] = [:]

    /// Feeds one CAN frame's data bytes for a fast-packet PGN.
    ///
    /// - Returns: The reassembled payload when complete, else `nil` (still accumulating
    ///   or frame dropped).
    func feed(pgn: UInt32, source: UInt8, frameData: [UInt8]) -> [UInt8]? {
        guard frameData.count >= 1 else { return nil }
        let firstByte       = frameData[0]
        let sequenceCounter = (firstByte >> 5) & 0x07
        let frameNumber     =  firstByte       & 0x1F
        let key = Key(source: source, pgn: pgn)

        if frameNumber == 0 {
            // First frame: byte 1 = total length, bytes 2-7 = initial payload.
            guard frameData.count >= 2 else { return nil }
            let totalLen = Int(frameData[1])
            let initial  = Array(frameData.dropFirst(2))
            let acc = Acc(
                sequenceCounter: sequenceCounter,
                totalLength: totalLen,
                data: initial,
                nextFrameNumber: 1)

            if acc.data.count >= acc.totalLength {
                return Array(acc.data.prefix(acc.totalLength))
            }
            pending[key] = acc
            return nil
        }

        // Continuation frame.
        guard var acc = pending[key],
              acc.sequenceCounter == sequenceCounter,
              acc.nextFrameNumber == frameNumber
        else {
            // Out-of-order or missing prior fragments — drop and start over on next first frame.
            pending.removeValue(forKey: key)
            return nil
        }

        acc.data.append(contentsOf: frameData.dropFirst(1))
        acc.nextFrameNumber += 1

        if acc.data.count >= acc.totalLength {
            pending.removeValue(forKey: key)
            return Array(acc.data.prefix(acc.totalLength))
        }
        pending[key] = acc
        return nil
    }
}


// MARK: - GSV assembler

/// Accumulates a multi-message $..GSV (Satellites in View) burst per talker, then emits
/// summary metrics (total visible, SNR min/avg/max) on completion of the series.
///
/// GSV has no explicit sequential ID: messages are grouped by talker, the series starts
/// at `msgNum == 1` and ends at `msgNum == totalMsgs`. Not thread-safe — confined to the
/// NIO event loop alongside ``FrameDispatcher``.
fileprivate final class GSVAssembler: @unchecked Sendable {

    private struct Acc {
        var totalMsgs: Int
        var totalInView: Int
        var sats: [SatelliteInfo]
    }

    private var pending: [String: Acc] = [:]  // keyed by talker

    /// Feeds one parsed `$..GSV` fields array.
    /// Returns frames on completion of the series: a ``NMEAFrame/gsvReport(_:_:_:)``
    /// followed by the summary ``NMEAFrame/metric(_:)`` frames.
    func feed(fields: [String]) -> [NMEAFrame]? {
        guard fields.count >= 4,
              let header = fields.first, header.count >= 4,
              let totalMsgs = Int(fields[1]),
              let msgNum    = Int(fields[2])
        else { return nil }

        let id     = String(header.dropFirst())
        let talker = String(id.prefix(id.count - 3))

        // 'satellites in view' may carry a *XX suffix when there are no sat blocks.
        let inViewStr = fields[3].split(separator: "*").first.map(String.init) ?? fields[3]
        guard let totalInView = Int(inViewStr) else { return nil }

        // Start fresh on msg 1; require an existing accumulator otherwise.
        var acc: Acc
        if msgNum == 1 {
            acc = Acc(totalMsgs: totalMsgs, totalInView: totalInView, sats: [])
        } else if let existing = pending[talker] {
            acc = existing
        } else {
            return nil   // missed msg 1, skip
        }

        // Parse satellite blocks: 4 fields each starting at f[4]
        var i = 4
        while i + 3 < fields.count {
            // The SNR field of the last sat block carries the *XX checksum.
            let snrRaw = fields[i + 3]
            let snrStr = snrRaw.split(separator: "*").first.map(String.init) ?? snrRaw
            if let prn = Int(fields[i]) {
                acc.sats.append(SatelliteInfo(
                    prn:       prn,
                    elevation: Int(fields[i + 1]),
                    azimuth:   Int(fields[i + 2]),
                    snr:       Int(snrStr)))
            }
            i += 4
        }

        if msgNum < totalMsgs {
            pending[talker] = acc
            return nil
        }
        pending.removeValue(forKey: talker)

        // Series complete — namespace per constellation.
        let prefix: String
        let constellation: String
        switch talker {
        case "GP":       prefix = "gps";     constellation = "GPS"
        case "GL":       prefix = "glonass"; constellation = "GLONASS"
        case "GA":       prefix = "galileo"; constellation = "Galileo"
        case "BD", "GB": prefix = "beidou";  constellation = "BeiDou"
        case "GQ", "QZ": prefix = "qzss";    constellation = "QZSS"
        case "GI":       prefix = "navic";   constellation = "NavIC"
        default:         prefix = "gnss";    constellation = "GNSS"
        }

        // gsvReport frame — carries the full per-satellite detail.
        var out: [NMEAFrame] = [
            .gsvReport(constellation: constellation,
                       inView:        acc.totalInView,
                       satellites:    acc.sats)
        ]

        // Summary metric frames — for consumers that only need aggregate values.
        out.append(.metric(.init(name: "\(prefix).satellites.inView",
                                 value: Double(acc.totalInView))))
        let snrs = acc.sats.compactMap(\.snr).filter { $0 > 0 }
        if !snrs.isEmpty {
            let avg = Double(snrs.reduce(0, +)) / Double(snrs.count)
            out.append(.metric(.init(name: "\(prefix).snr.avg", value: avg,                 unit: "dB")))
            out.append(.metric(.init(name: "\(prefix).snr.max", value: Double(snrs.max()!), unit: "dB")))
            out.append(.metric(.init(name: "\(prefix).snr.min", value: Double(snrs.min()!), unit: "dB")))
        }
        return out
    }
}


// MARK: - Line accumulator

/// Accumulates raw bytes into complete newline-terminated lines.
///
/// Confined to a single NIO event loop — `channelRead` calls are never concurrent
/// for the same handler instance.
fileprivate final class LineAggregator: @unchecked Sendable {
    private var buffer: [UInt8] = []

    func ingest(_ bytes: [UInt8], emit: (String) -> Void) {
        buffer.append(contentsOf: bytes)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let raw = Array(buffer[..<nl])
            buffer.removeSubrange(...nl)
            let trimmed = raw.filter { $0 != 0x0D }
            if let line = String(bytes: trimmed, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces),
               !line.isEmpty {
                emit(line)
            }
        }
    }
}

/// Auto-detects the wire format from the first line, then routes each line to
/// the appropriate parser and emits the resulting ``NMEAFrame``s.
///
/// Also confined to a single NIO event loop.
fileprivate final class FrameDispatcher: @unchecked Sendable {
    private let config: NMEATransportConfig
    private let emit: @Sendable (NMEAFrame) -> Void
    private var detectedFormat: NMEAInputFormat
    private let aisAssembler        = MultipartAssembler()
    private let gsvAssembler        = GSVAssembler()
    private let fastPacketAssembler = FastPacketAssembler()
    private let aisTracker          = AISTargetTracker()

    init(config: NMEATransportConfig, emit: @escaping @Sendable (NMEAFrame) -> Void) {
        self.config = config
        self.emit = emit
        self.detectedFormat = config.format
    }

    func process(_ line: String) {
        config.rawLogger?(line)
        // PCDIN is SeaSmart-encoded NMEA 2000 — route per-line regardless of the
        // dominant stream format, so a chartplotter forwarding both NMEA 0183
        // sentences and $PCDIN lines on the same socket is handled correctly.
        let perLineFormat: NMEAInputFormat
        if line.hasPrefix("$PCDIN") {
            perLineFormat = .seaSmartNet
        } else if line.hasPrefix("!PDGY") {
            // iKonvert received-data sentences carry their own self-describing
            // envelope, so route them per-line like $PCDIN.
            perLineFormat = .iKonvert
        } else {
            if detectedFormat == .auto { detectedFormat = Self.detect(line) }
            perLineFormat = detectedFormat
        }
        switch perLineFormat {
        case .nmea0183:
            if let frame = NMEA0183Parser.parse(line) {
                emit(frame)
                if case .nmea0183(_, _, let type, let fields) = frame {
                    if config.decodePGNs, let metrics = NMEA0183Parser.decode(fields) {
                        for m in metrics { emit(.metric(m)) }
                    }
                    // AIS sentences — assemble multipart, decode target, enrich with
                    // any previously-observed static data for this MMSI, then also
                    // extract IMO 289 IFM 11 meteorological metrics for type 8 broadcasts.
                    if type == "VDM" || type == "VDO",
                       let assembled = aisAssembler.feed(fields: fields) {
                        if let target = AISDecoder.decode(
                            payload: assembled.payload,
                            fillBits: assembled.fillBits,
                            channel: assembled.channel) {
                            var enriched = aisTracker.enrich(target)
                            // VDO is own vessel's own transponder report.
                            enriched.isOwnShip = (type == "VDO")
                            emit(.aisTarget(enriched))
                        }
                        if let metrics = AISDecoder.decodeMeteoMetrics(
                            payload: assembled.payload,
                            fillBits: assembled.fillBits) {
                            for m in metrics { emit(.metric(m)) }
                        }
                    }
                    // GSV sentences — assemble multi-message series, emit on the last one.
                    if type == "GSV",
                       let frames = gsvAssembler.feed(fields: fields) {
                        for f in frames { emit(f) }
                    }
                }
            } else {
                emit(.unknown(rawLine: line))
            }
        case .yachtDevicesRaw:
            // YD/RAW carries one CAN frame per line. For fast-packet PGNs we
            // accumulate fragments and only emit + decode the assembled payload
            // once the series is complete. Single-frame PGNs pass through.
            if let frame = YachtDevicesRawParser.parse(line),
               case .nmea2000(let pgn, let src, let pri, let data) = frame {
                if NMEA2000Decoder.isFastPacket(pgn) {
                    if let full = fastPacketAssembler.feed(pgn: pgn, source: src, frameData: data) {
                        let assembled: NMEAFrame = .nmea2000(pgn: pgn, source: src,
                                                             priority: pri, data: full)
                        emit(assembled)
                        dispatchN2K(pgn: pgn, source: src, data: full)
                    }
                    // else: partial frame — hold silently until series completes.
                } else {
                    emit(frame)
                    dispatchN2K(pgn: pgn, source: src, data: data)
                }
            } else {
                emit(.unknown(rawLine: line))
            }
        case .seaSmartNet:
            // SeaSmart $PCDIN already carries fully-reassembled payloads.
            if let frame = SeaSmartParser.parse(line),
               case .nmea2000(let pgn, let src, _, let data) = frame {
                emit(frame)
                dispatchN2K(pgn: pgn, source: src, data: data)
            } else {
                emit(.unknown(rawLine: line))
            }
        case .canboatPlain:
            // Canboat PLAIN CSV already carries fully-reassembled payloads.
            if let frame = CanboatPlainParser.parse(line),
               case .nmea2000(let pgn, let src, _, let data) = frame {
                emit(frame)
                dispatchN2K(pgn: pgn, source: src, data: data)
            } else {
                emit(.unknown(rawLine: line))
            }
        case .iKonvert:
            // iKonvert !PDGY carries a Base64 payload, already reassembled.
            if let frame = IKonvertParser.parse(line),
               case .nmea2000(let pgn, let src, _, let data) = frame {
                emit(frame)
                dispatchN2K(pgn: pgn, source: src, data: data)
            } else {
                emit(.unknown(rawLine: line))
            }
        case .signalK:
            for frame in SignalKClient.parseFrames(line) { emit(frame) }
        case .auto:
            break
        }
    }

    /// Routes a fully-reassembled NMEA 2000 payload to the right decoder —
    /// AIS PGNs produce ``AISTarget`` frames, other PGNs produce metric frames.
    private func dispatchN2K(pgn: UInt32, source: UInt8, data: [UInt8]) {
        guard config.decodePGNs else { return }
        if NMEA2000Decoder.isAISPGN(pgn),
           let target = AISDecoder.decodeN2K(pgn: pgn, source: source, data: data) {
            // Same per-MMSI static enrichment as the NMEA 0183 path — a 129794
            // (Class A static) gives the name; subsequent 129038 positions inherit it.
            emit(.aisTarget(aisTracker.enrich(target)))
            return
        }
        // PGNs that emit composite frames (e.g. 129540 → gsvReport + metrics).
        if let frames = NMEA2000Decoder.decodeFrames(pgn: pgn, data: data) {
            for f in frames { emit(f) }
            return
        }
        if let metrics = NMEA2000Decoder.decode(pgn: pgn, data: data) {
            for m in metrics { emit(.metric(m)) }
        }
    }

    static func detect(_ line: String) -> NMEAInputFormat {
        if line.hasPrefix("$PCDIN") { return .seaSmartNet }
        if line.hasPrefix("!PDGY")  { return .iKonvert }
        if line.hasPrefix("$") || line.hasPrefix("!") { return .nmea0183 }
        if line.hasPrefix("{") || line.hasPrefix("[") { return .signalK }

        // Canboat PLAIN CSV: TIMESTAMP,PRIO,PGN,SRC,DST,LEN,bytes…
        // ($/!/{ sentences are already handled above, so a comma-delimited line
        // with a numeric PGN field is unambiguous here.)
        let csv = line.split(separator: ",", omittingEmptySubsequences: false)
        if csv.count >= 7, UInt32(csv[2]) != nil, UInt8(csv[1]) != nil, UInt8(csv[3]) != nil {
            return .canboatPlain
        }

        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        // Bare YD RAW: every token is hex.
        if tokens.count >= 2, tokens.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) {
            return .yachtDevicesRaw
        }
        // YD RAW with a "<timestamp> <R|T> <CAN-ID> …" logging prefix.
        if tokens.count >= 3,
           tokens[1] == "R" || tokens[1] == "T" || tokens[1] == "r" || tokens[1] == "t",
           UInt32(tokens[2], radix: 16) != nil {
            return .yachtDevicesRaw
        }
        return .nmea0183
    }
}

fileprivate final class NMEAHandlerTCP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let aggregator = LineAggregator()
    private let dispatcher: FrameDispatcher

    init(config: NMEATransportConfig, emit: @escaping @Sendable (NMEAFrame) -> Void) {
        self.dispatcher = FrameDispatcher(config: config, emit: emit)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        aggregator.ingest(bytes) { dispatcher.process($0) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

fileprivate final class NMEAHandlerUDP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let aggregator = LineAggregator()
    private let dispatcher: FrameDispatcher

    init(config: NMEATransportConfig, emit: @escaping @Sendable (NMEAFrame) -> Void) {
        self.dispatcher = FrameDispatcher(config: config, emit: emit)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var env = Self.unwrapInboundIn(data)
        guard let bytes = env.data.readBytes(length: env.data.readableBytes) else { return }
        aggregator.ingest(bytes) { dispatcher.process($0) }
    }
}


// MARK: - File stream

/// Mutable-state cell used to pass the per-line timestamp into the `@Sendable`
/// emit closure without capturing a mutable local variable.
///
/// `fileStream` sets `.value` synchronously before each `dispatcher.process()` call
/// and the emit closure reads it in the same synchronous context — no data race.
fileprivate final class _Cell<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ initial: T) { value = initial }
}

extension NMEATransport {

    /// Reads a local log file and yields one ``FileFrame`` per parsed result.
    ///
    /// Uses the same ``FrameDispatcher`` (format auto-detection, PGN decoding) as
    /// the live network transports — parsing behaviour is identical.
    ///
    /// ``FileFrame/timestamp`` is populated when the source line embeds a timestamp:
    /// - Signal K NDJSON: `updates[n].timestamp` (ISO 8601)
    /// - NMEA 0183 RMC: sentence date (DDMMYY) + time (HHMMSS.ss) fields
    ///
    /// Pass the stream to the CLI's `--realtime` replay logic to drive inter-frame
    /// delays from the embedded timestamps.
    ///
    /// - Parameters:
    ///   - path: Absolute or relative path to the log file.
    ///   - format: Override the auto-detected wire format. Default is `.auto`.
    ///   - decodePGNs: Whether to emit decoded ``BoatMetric`` frames alongside raw frames.
    public static func fileStream(
        path: String,
        format: NMEAInputFormat = .auto,
        decodePGNs: Bool = true
    ) -> AsyncThrowingStream<FileFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url  = URL(fileURLWithPath: path)
                    let text = try String(contentsOf: url, encoding: .utf8)

                    // Dummy mode — FrameDispatcher only reads .format and .decodePGNs.
                    let cfg = NMEATransportConfig(
                        mode: .tcp(host: "localhost", port: 0),
                        format: format,
                        decodePGNs: decodePGNs)

                    let tsCell   = _Cell<Date?>(nil)
                    let lineCell = _Cell<Int>(0)
                    let dispatcher = FrameDispatcher(config: cfg) { @Sendable frame in
                        continuation.yield(FileFrame(frame: frame,
                                                     timestamp: tsCell.value,
                                                     lineIndex: lineCell.value))
                    }

                    for rawLine in text.components(separatedBy: .newlines) {
                        try Task.checkCancellation()
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { continue }
                        tsCell.value    = lineTimestamp(line)
                        lineCell.value += 1
                        dispatcher.process(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Replays a local log file as a paced stream of ``NMEAFrame`` values, ready
    /// to pipe into a ``BoatMetricStore``.
    ///
    /// Wraps ``fileStream(path:format:decodePGNs:)`` and inserts inter-line delays
    /// according to `pacing`, so a recorded session plays back like a live source
    /// (AIS targets, GPS fixes and all). The stream ends when the file is fully
    /// replayed or the task is cancelled.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the log file.
    ///   - pacing: Timing strategy — embedded timestamps or a fixed line rate.
    ///   - loop: When `true`, restart from the top once the file is exhausted, so
    ///     the recording plays continuously like a live source.
    ///   - format: Override the auto-detected wire format. Default is `.auto`.
    ///   - decodePGNs: Whether to emit decoded ``BoatMetric`` frames alongside raw frames.
    public static func replayStream(
        path: String,
        pacing: ReplayPacing,
        loop: Bool = false,
        format: NMEAInputFormat = .auto,
        decodePGNs: Bool = true
    ) -> AsyncThrowingStream<NMEAFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    repeat {
                        var lastLine = -1
                        var lastTimestamp: Date?
                        // A fresh pass each loop — a new file stream re-reads the log.
                        for try await fileFrame in fileStream(
                            path: path, format: format, decodePGNs: decodePGNs
                        ) {
                            try Task.checkCancellation()
                            // One delay per source line (a line can yield several frames).
                            if fileFrame.lineIndex != lastLine {
                                switch pacing {
                                case .framesPerSecond(let rate):
                                    if rate > 0 { try await Task.sleep(for: .seconds(1.0 / rate)) }
                                case .respectTimestamps:
                                    if let ts = fileFrame.timestamp, let last = lastTimestamp {
                                        let delta = ts.timeIntervalSince(last)
                                        // Clamp gaps so a long pause in the log doesn't stall replay.
                                        if delta > 0 { try await Task.sleep(for: .seconds(min(delta, 10))) }
                                    }
                                }
                                if let ts = fileFrame.timestamp { lastTimestamp = ts }
                                lastLine = fileFrame.lineIndex
                            }
                            continuation.yield(fileFrame.frame)
                        }
                    } while loop && !Task.isCancelled
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Tries to extract an absolute `Date` from a raw log line.
    private static func lineTimestamp(_ line: String) -> Date? {
        if line.hasPrefix("{") { return signalKLineTimestamp(line) }
        if line.hasPrefix("$") || line.hasPrefix("!") { return nmeaRMCTimestamp(line) }
        if let ts = canboatLineTimestamp(line) { return ts }
        return ydRawLineTimestamp(line)
    }

    /// Extracts the time of day from a Yacht Devices RAW logging prefix
    /// (`<HH:MM:SS.mmm> R/T …`). The prefix carries no date, so a fixed
    /// reference day is used — replay only relies on the interval between
    /// successive lines.
    private static func ydRawLineTimestamp(_ line: String) -> Date? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 3,
              tokens[1] == "R" || tokens[1] == "T" || tokens[1] == "r" || tokens[1] == "t",
              tokens[0].contains(":")
        else { return nil }
        let iso = "2000-01-01T\(tokens[0])Z"
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// Extracts the leading ISO 8601 timestamp from a Canboat PLAIN CSV line.
    ///
    /// Returns `nil` when the first comma-separated field is not an ISO 8601
    /// date-time, so non-Canboat lines fall through unaffected.
    private static func canboatLineTimestamp(_ line: String) -> Date? {
        guard let firstField = line.split(separator: ",", maxSplits: 1).first else { return nil }
        let ts = String(firstField)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: ts) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: ts)
    }

    /// Extracts the first `updates[n].timestamp` (ISO 8601) from a Signal K delta line.
    private static func signalKLineTimestamp(_ line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONValue.parse(data),
              case .object(let root) = json,
              case .array(let updates) = root["updates"] ?? .null,
              let first = updates.first,
              case .object(let upd) = first,
              case .string(let ts) = upd["timestamp"] ?? .null
        else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: ts) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: ts)
    }

    /// Extracts a UTC `Date` from an NMEA 0183 RMC sentence (DDMMYY + HHMMSS.ss).
    private static func nmeaRMCTimestamp(_ line: String) -> Date? {
        guard line.contains("RMC"),
              let frame = NMEA0183Parser.parse(line),
              case .nmea0183(_, _, "RMC", let fields) = frame,
              fields.count >= 10, fields[2] == "A"
        else { return nil }
        let t = fields[1], d = fields[9]   // HHMMSS.ss  DDMMYY
        guard t.count >= 6, d.count == 6 else { return nil }
        let hh = t.prefix(2), mm = t.dropFirst(2).prefix(2), ss = t.dropFirst(4).prefix(2)
        let dd = d.prefix(2), mo = d.dropFirst(2).prefix(2), yy = d.suffix(2)
        return ISO8601DateFormatter().date(from: "20\(yy)-\(mo)-\(dd)T\(hh):\(mm):\(ss)Z")
    }
}

#endif  // !os(Windows)
