internal import Foundation  // for String.trimmingCharacters

// MARK: - AISTarget

/// A decoded AIS target from VDM/VDO sentences.
public struct AISTarget: Sendable, Equatable {
  /// Raw MMSI number.
  public let mmsi: Int
  /// AIS message type.
  public let messageType: AisMessageType
  /// VHF channel the message was received on (`A` or `B`).
  public let channel: Character

  // Position
  /// Latitude in decimal degrees. `nil` when not available.
  public let latitude: Double?
  /// Longitude in decimal degrees. `nil` when not available.
  public let longitude: Double?

  // Kinematics
  /// Speed over ground in knots. `nil` when not available.
  public let speedOverGround: Double?
  /// Course over ground in degrees true. `nil` when not available.
  public let courseOverGround: Double?
  /// True heading in degrees. `nil` when not available (511 = not available).
  public let trueHeading: Int?
  /// Rate of turn in degrees/minute (+/- 720 = turning right/left at > 5°/30s). `nil` when not available.
  public let rateOfTurn: Int?

  // Quality
  /// Whether position is high-accuracy DGNSS (true) or GNSS/other (false).
  public let positionAccuracy: Bool
  /// Whether RAIM is in use.
  public let raim: Bool

  // Navigation status
  /// Navigation status (types 1/2/3).
  public let navigationStatus: NavigationStatus?
  /// Special manoeuvre indicator (types 1/2/3).
  public let maneuverIndicator: ManeuverIndicator?

  // Vessel identity
  /// Ship name from static/voyage data (type 5, 24B) or AtoN report (type 21).
  public let shipName: String?
  /// Call sign from static/voyage data.
  public let callsign: String?
  /// Ship/cargo type.
  public let shipType: ShipType?
  /// IMO number (type 5).
  public let imoNumber: Int?
  /// Destination (type 5).
  public let destination: String?
  /// Maximum static draught in metres (type 5).
  public let draught: Double?
  /// Aid-to-navigation type (type 21).
  public let navAidType: NavigationalAidType?
  /// Altitude in metres — populated by SAR aircraft reports (msg type 9).
  public let altitude: Double?
  /// Free text carried by the message — the safety text of an addressed (12) or
  /// broadcast (14) safety message, when present.
  public let text: String?

  /// `true` when the report describes own vessel — a VDO sentence, or a VDM
  /// echoing own MMSI. Set by the transport after decoding; defaults to `false`.
  public var isOwnShip: Bool = false

  /// Creates an AIS target from decoded message fields.
  ///
  /// Memberwise initialiser — see each property for the meaning of its argument.
  /// `mmsi`, `messageType` and `channel` are always present; every other field is
  /// `nil`/`false` by default and is only populated when the source message carries
  /// it (e.g. `shipName` from type 5/24, `altitude` from type 9).
  public init(
    mmsi: Int, messageType: AisMessageType, channel: Character,
    latitude: Double? = nil, longitude: Double? = nil,
    speedOverGround: Double? = nil, courseOverGround: Double? = nil,
    trueHeading: Int? = nil, rateOfTurn: Int? = nil,
    positionAccuracy: Bool = false, raim: Bool = false,
    navigationStatus: NavigationStatus? = nil,
    maneuverIndicator: ManeuverIndicator? = nil,
    shipName: String? = nil, callsign: String? = nil,
    shipType: ShipType? = nil, imoNumber: Int? = nil,
    destination: String? = nil, draught: Double? = nil,
    navAidType: NavigationalAidType? = nil,
    altitude: Double? = nil,
    text: String? = nil
  ) {
    self.mmsi = mmsi
    self.messageType = messageType
    self.channel = channel
    self.latitude = latitude
    self.longitude = longitude
    self.speedOverGround = speedOverGround
    self.courseOverGround = courseOverGround
    self.trueHeading = trueHeading
    self.rateOfTurn = rateOfTurn
    self.positionAccuracy = positionAccuracy
    self.raim = raim
    self.navigationStatus = navigationStatus
    self.maneuverIndicator = maneuverIndicator
    self.shipName = shipName
    self.callsign = callsign
    self.shipType = shipType
    self.imoNumber = imoNumber
    self.destination = destination
    self.draught = draught
    self.navAidType = navAidType
    self.altitude = altitude
    self.text = text
  }
}

// MARK: - AISBitBuffer

/// A read-only bit-level accessor over an AIS 6-bit ASCII payload.
///
/// AIS payload characters are encoded as 6 bits each, packed big-endian
/// (MSB of each character is the earliest bit in the stream).
private struct AISBitBuffer {
  private let bits: [UInt8]  // one element per bit (0 or 1), length = chars × 6 − fillBits

  init(_ payload: String, fillBits: Int) {
    var b: [UInt8] = []
    b.reserveCapacity(payload.count * 6)
    for ch in payload.unicodeScalars {
      var v = Int(ch.value) - 48
      if v < 0 { v = 0 }
      if v >= 40 { v -= 8 }
      if v < 0 { v = 0 }
      if v > 63 { v = 63 }
      for shift in stride(from: 5, through: 0, by: -1) {
        b.append(UInt8((v >> shift) & 1))
      }
    }
    let total = max(0, b.count - fillBits)
    bits = Array(b.prefix(total))
  }

  var bitCount: Int { bits.count }

  /// Reads `len` bits starting at `start` as an unsigned integer.
  func uint(_ start: Int, _ len: Int) -> Int {
    guard start >= 0, len > 0, start + len <= bits.count else { return 0 }
    var v = 0
    for i in 0..<len { v = (v << 1) | Int(bits[start + i]) }
    return v
  }

  /// Reads `len` bits starting at `start` as a signed two's-complement integer.
  func int(_ start: Int, _ len: Int) -> Int {
    let u = uint(start, len)
    guard len > 0, (u >> (len - 1)) == 1 else { return u }
    return u - (1 << len)
  }

  /// Reads `len` bits (must be a multiple of 6) as a 6-bit ASCII string, trimming trailing `@`.
  func text(_ start: Int, _ len: Int) -> String {
    let table = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?"
    let chars = Array(table)
    var s = ""
    var i = start
    while i + 6 <= start + len && i + 6 <= bits.count {
      let idx = uint(i, 6)
      if idx < chars.count { s.append(chars[idx]) }
      i += 6
    }
    while s.last == "@" { s.removeLast() }
    return s.trimmingCharacters(in: .whitespaces)
  }
}

// MARK: - AISDecoder

/// Stateless AIS payload decoder — call ``decode(payload:fillBits:channel:messageType:)``.
internal enum AISDecoder {

  /// Decodes an assembled AIS payload into an ``AISTarget``.
  ///
  /// The message type is read from the first 6 bits of the payload.
  ///
  /// - Parameters:
  ///   - payload: Concatenated 6-bit ASCII payload characters.
  ///   - fillBits: Number of pad bits at the end of the last sentence.
  ///   - channel: VHF channel (`A` or `B`).
  /// - Returns: A decoded target, or `nil` if the payload is too short or unrecognised.
  static func decode(
    payload: String,
    fillBits: Int,
    channel: Character
  ) -> AISTarget? {
    let buf = AISBitBuffer(payload, fillBits: fillBits)
    guard buf.bitCount >= 6,
      let messageType = AisMessageType(rawValue: buf.uint(0, 6))
    else { return nil }
    return decode(payload: payload, fillBits: fillBits, channel: channel, messageType: messageType)
  }

  /// Decodes an assembled AIS payload into an ``AISTarget``.
  ///
  /// - Parameters:
  ///   - payload: Concatenated 6-bit ASCII payload characters.
  ///   - fillBits: Number of pad bits at the end of the last sentence.
  ///   - channel: VHF channel (`A` or `B`).
  ///   - messageType: Pre-parsed AIS message type.
  /// - Returns: A decoded target, or `nil` if the payload is too short or unrecognised.
  static func decode(
    payload: String,
    fillBits: Int,
    channel: Character,
    messageType: AisMessageType
  ) -> AISTarget? {
    let buf = AISBitBuffer(payload, fillBits: fillBits)
    switch messageType {
    case .positionReportClassA,
      .positionReportClassAAssigned,
      .positionReportClassAResponse:
      return decodeType123(buf: buf, channel: channel, msgType: messageType)
    case .baseStationReport:
      return decodeType4(buf: buf, channel: channel)
    case .staticAndVoyageData:
      return decodeType5(buf: buf, channel: channel)
    case .binaryBroadcastMessage:
      return decodeType8(buf: buf, channel: channel)
    case .standardSARAircraftReport:
      return decodeType9(buf: buf, channel: channel)
    case .standardClassBReport:
      return decodeType18(buf: buf, channel: channel)
    case .aidToNavigationReport:
      return decodeType21(buf: buf, channel: channel)
    case .classAStaticData:
      return decodeType24(buf: buf, channel: channel)
    case .addressedSafetyMessage:
      return decodeSafetyText(
        buf: buf, channel: channel,
        msgType: messageType, textStart: 72)
    case .safetyBroadcastMessage:
      return decodeSafetyText(
        buf: buf, channel: channel,
        msgType: messageType, textStart: 40)
    default:
      // We can still yield a minimal target with just MMSI from the header.
      guard buf.bitCount >= 38 else { return nil }
      let mmsi = buf.uint(8, 30)
      return AISTarget(mmsi: mmsi, messageType: messageType, channel: channel)
    }
  }

  /// Decodes a safety message (addressed type 12, broadcast type 14): the
  /// source MMSI plus the 6-bit ASCII free text.
  ///
  /// - Parameter textStart: First text bit — 72 for type 12 (after the
  ///   destination MMSI / retransmit / spare), 40 for type 14 (after the spare).
  private static func decodeSafetyText(
    buf: AISBitBuffer, channel: Character,
    msgType: AisMessageType, textStart: Int
  ) -> AISTarget? {
    guard buf.bitCount >= 40 else { return nil }
    let mmsi = buf.uint(8, 30)
    let text =
      buf.bitCount > textStart
      ? buf.text(textStart, buf.bitCount - textStart)
      : ""
    return AISTarget(
      mmsi: mmsi, messageType: msgType, channel: channel,
      text: text.isEmpty ? nil : text
    )
  }

  /// For ``AisMessageType/binaryBroadcastMessage`` (type 8) carrying the IMO 289
  /// IFM 11 "Meteorological and Hydrological Data" payload (DAC=1 FI=11),
  /// extracts the embedded weather data as ``BoatMetric`` values.
  ///
  /// Returns `nil` if the payload is too short, the DAC/FI doesn't match, or the
  /// message type isn't 8.
  static func decodeMeteoMetrics(payload: String, fillBits: Int) -> [BoatMetric]? {
    let buf = AISBitBuffer(payload, fillBits: fillBits)
    guard buf.bitCount >= 56,
      buf.uint(0, 6) == 8,  // type 8 Binary Broadcast
      buf.uint(40, 10) == 1  // DAC = 1 (international)
    else { return nil }
    switch buf.uint(50, 6) {  // FI
    case 11: return decodeMeteoIFM11(buf: buf)  // IMO 236
    case 31: return decodeMeteoIFM31(buf: buf)  // IMO 289 (current)
    default: return nil
    }
  }

  // MARK: Type 1/2/3 — Class A position report

  private static func decodeType123(
    buf: AISBitBuffer,
    channel: Character,
    msgType: AisMessageType
  ) -> AISTarget? {
    guard buf.bitCount >= 168 else { return nil }
    let mmsi = buf.uint(8, 30)
    let status = NavigationStatus(rawValue: buf.uint(38, 4))
    let rot = buf.int(42, 8)  // -128 = no info sentinel
    let sogRaw = buf.uint(50, 10)  // 1/10 knot; 1023 = not available
    let posAcc = buf.uint(60, 1) == 1
    let lonRaw = buf.int(61, 28)  // 1/10000 min; 0x6791AC0 = not available
    let latRaw = buf.int(89, 27)
    let cogRaw = buf.uint(116, 12)  // 1/10 deg; 3600 = not available
    let hdg = buf.uint(128, 9)  // valid 0–359; 511 = N/A; 360–510 = spec-illegal
    let raim = buf.uint(148, 1) == 1
    let maneuver = ManeuverIndicator(rawValue: buf.uint(143, 2))

    let lon = lonRaw != 0x6791AC0 ? Double(lonRaw) / 600_000.0 : nil
    let lat = latRaw != 0x3412140 ? Double(latRaw) / 600_000.0 : nil
    let sog = sogRaw != 1023 ? Double(sogRaw) / 10.0 : nil
    let cog = cogRaw != 3600 ? Double(cogRaw) / 10.0 : nil
    // Filter spec-illegal heading values (360..510) along with the N/A sentinel.
    let heading = (hdg <= 359) ? hdg : nil
    let rotVal = rot != -128 ? rot : nil

    return AISTarget(
      mmsi: mmsi, messageType: msgType, channel: channel,
      latitude: lat, longitude: lon,
      speedOverGround: sog, courseOverGround: cog,
      trueHeading: heading, rateOfTurn: rotVal,
      positionAccuracy: posAcc, raim: raim,
      navigationStatus: status,
      maneuverIndicator: maneuver
    )
  }

  // MARK: Type 4 — Base Station Report (UTC time of day + position)

  private static func decodeType4(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 168 else { return nil }
    let mmsi = buf.uint(8, 30)
    // UTC date/time fields skipped here — they describe the base station's clock.
    let posAcc = buf.uint(78, 1) == 1
    let lonRaw = buf.int(79, 28)
    let latRaw = buf.int(107, 27)
    let raim = buf.uint(148, 1) == 1
    return AISTarget(
      mmsi: mmsi, messageType: .baseStationReport, channel: channel,
      latitude: latRaw != 0x3412140 ? Double(latRaw) / 600_000.0 : nil,
      longitude: lonRaw != 0x6791AC0 ? Double(lonRaw) / 600_000.0 : nil,
      positionAccuracy: posAcc, raim: raim)
  }

  // MARK: Type 8 — Binary Broadcast Message
  //
  // We extract the basic envelope (MMSI, DAC, FI) into the target so the CLI can
  // surface the call type. The application-specific payload (e.g. IMO 289 IFM 11
  // meteorological data) is decoded separately via ``decodeMeteoMetrics``.

  private static func decodeType8(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 56 else { return nil }
    let mmsi = buf.uint(8, 30)
    return AISTarget(
      mmsi: mmsi, messageType: .binaryBroadcastMessage, channel: channel)
  }

  // MARK: Type 9 — Standard SAR Aircraft Position Report

  private static func decodeType9(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 168 else { return nil }
    let mmsi = buf.uint(8, 30)
    let altRaw = buf.uint(38, 12)  // metres, 4095 = N/A, 4094 = >4094 m
    let sogRaw = buf.uint(50, 10)  // 1 knot resolution (not 0.1), 1023 = N/A, 1022 = >1022
    let posAcc = buf.uint(60, 1) == 1
    let lonRaw = buf.int(61, 28)
    let latRaw = buf.int(89, 27)
    let cogRaw = buf.uint(116, 12)
    let raim = buf.uint(147, 1) == 1

    return AISTarget(
      mmsi: mmsi, messageType: .standardSARAircraftReport, channel: channel,
      latitude: latRaw != 0x3412140 ? Double(latRaw) / 600_000.0 : nil,
      longitude: lonRaw != 0x6791AC0 ? Double(lonRaw) / 600_000.0 : nil,
      speedOverGround: sogRaw != 1023 ? Double(sogRaw) : nil,  // already kn
      courseOverGround: cogRaw != 3600 ? Double(cogRaw) / 10.0 : nil,
      positionAccuracy: posAcc, raim: raim,
      altitude: altRaw == 4095 ? nil : Double(altRaw))
  }

  // MARK: IFM 11 — Meteorological and Hydrological Data (IMO 289)
  //
  // Field layout (bit offsets relative to the start of payload — the 56-bit type-8
  // header is already accounted for):
  //   bit  56 → longitude  (24 bits signed, 1/1000 minute resolution)
  //   bit  80 → latitude   (23 bits signed, 1/1000 minute resolution)
  //   bit 103 → day, hour, minute UTC
  //   bit 119 → average wind speed (7 bits, knots, 127 = N/A)
  //   bit 126 → gust wind speed    (7 bits, knots, 127 = N/A)
  //   bit 133 → wind direction     (9 bits, degrees, 360 = N/A)
  //   bit 142 → gust direction     (9 bits, degrees)
  //   bit 151 → air temperature    (11 bits signed, 0.1 °C, sentinel ≥ 1024)
  //   bit 162 → relative humidity  (7 bits, %, 101 = N/A)
  //   bit 169 → dew point          (10 bits signed, 0.1 °C, sentinel ≥ 501)
  //   bit 179 → air pressure       (9 bits, hPa offset by 800, 511 = N/A)
  private static func decodeMeteoIFM11(buf: AISBitBuffer) -> [BoatMetric]? {
    guard buf.bitCount >= 188 else { return nil }
    var out: [BoatMetric] = []

    // Position — special "1/1000 minute" resolution distinct from standard AIS positions.
    let lonRaw = buf.int(56, 24)
    let latRaw = buf.int(80, 23)
    // Sentinels: longitude = 181° unavailable → 181 × 60_000 = 10_860_000;
    //            latitude  = 91°  unavailable → 91  × 60_000 = 5_460_000.
    if lonRaw != 10_860_000 {
      out.append(.init(name: "lon", value: Double(lonRaw) / 60_000.0, unit: "°"))
    }
    if latRaw != 5_460_000 {
      out.append(.init(name: "lat", value: Double(latRaw) / 60_000.0, unit: "°"))
    }

    // Wind
    let avgWind = buf.uint(119, 7)
    let gustWind = buf.uint(126, 7)
    let windDir = buf.uint(133, 9)
    let gustDir = buf.uint(142, 9)
    if avgWind < 127 { out.append(.init(name: "TWS", value: Double(avgWind), unit: "kn")) }
    if gustWind < 127 { out.append(.init(name: "TWS.gust", value: Double(gustWind), unit: "kn")) }
    if windDir < 360 { out.append(.init(name: "TWD", value: Double(windDir), unit: "°")) }
    if gustDir < 360 { out.append(.init(name: "TWD.gust", value: Double(gustDir), unit: "°")) }

    // Temperature
    let tempRaw = buf.int(151, 11)  // signed
    if tempRaw > -601, tempRaw < 601 {  // valid: -60.0..60.0 °C
      out.append(.init(name: "temperature.air", value: Double(tempRaw) * 0.1, unit: "°C"))
    }

    // Humidity
    let humidity = buf.uint(162, 7)
    if humidity <= 100 {
      out.append(.init(name: "humidity", value: Double(humidity), unit: "%"))
    }

    // Dew point
    let dewRaw = buf.int(169, 10)
    if dewRaw > -201, dewRaw < 501 {  // valid: -20.0..50.0 °C
      out.append(.init(name: "temperature.dewPoint", value: Double(dewRaw) * 0.1, unit: "°C"))
    }

    // Air pressure — encoded with offset 800.
    let pressRaw = buf.uint(179, 9)
    if pressRaw != 511, pressRaw <= 402 {
      out.append(.init(name: "pressure.atmospheric", value: Double(pressRaw + 800), unit: "hPa"))
    }

    return out.isEmpty ? nil : out
  }

  // MARK: IFM 31 — Meteorological and Hydrological Data (IMO 289, current)
  //
  // Same fields as IFM 11 but with the wider position encoding (longitude 25
  // bits, latitude 24 bits — every later field shifts by +2 bits) and the air
  // pressure offset of 799 instead of 800.
  private static func decodeMeteoIFM31(buf: AISBitBuffer) -> [BoatMetric]? {
    guard buf.bitCount >= 191 else { return nil }
    var out: [BoatMetric] = []

    // Position — 1/1000 minute, sentinels 181°/91°.
    let lonRaw = buf.int(56, 25)
    let latRaw = buf.int(81, 24)
    if lonRaw != 10_860_000 {
      out.append(.init(name: "lon", value: Double(lonRaw) / 60_000.0, unit: "°"))
    }
    if latRaw != 5_460_000 {
      out.append(.init(name: "lat", value: Double(latRaw) / 60_000.0, unit: "°"))
    }

    // Wind
    let avgWind = buf.uint(122, 7)
    let gustWind = buf.uint(129, 7)
    let windDir = buf.uint(136, 9)
    let gustDir = buf.uint(145, 9)
    if avgWind < 127 { out.append(.init(name: "TWS", value: Double(avgWind), unit: "kn")) }
    if gustWind < 127 { out.append(.init(name: "TWS.gust", value: Double(gustWind), unit: "kn")) }
    if windDir < 360 { out.append(.init(name: "TWD", value: Double(windDir), unit: "°")) }
    if gustDir < 360 { out.append(.init(name: "TWD.gust", value: Double(gustDir), unit: "°")) }

    // Temperature
    let tempRaw = buf.int(154, 11)
    if tempRaw > -601, tempRaw < 601 {
      out.append(.init(name: "temperature.air", value: Double(tempRaw) * 0.1, unit: "°C"))
    }

    // Humidity
    let humidity = buf.uint(165, 7)
    if humidity <= 100 {
      out.append(.init(name: "humidity", value: Double(humidity), unit: "%"))
    }

    // Dew point
    let dewRaw = buf.int(172, 10)
    if dewRaw > -201, dewRaw < 501 {
      out.append(.init(name: "temperature.dewPoint", value: Double(dewRaw) * 0.1, unit: "°C"))
    }

    // Air pressure — offset 799; 0 = ≤799 hPa, 403 = N/A.
    let pressRaw = buf.uint(182, 9)
    if pressRaw > 0, pressRaw <= 402 {
      out.append(.init(name: "pressure.atmospheric", value: Double(pressRaw + 799), unit: "hPa"))
    }

    return out.isEmpty ? nil : out
  }

  // MARK: Type 5 — Static and voyage data

  private static func decodeType5(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    // Real transmitters often truncate the trailing destination / DTE / spare
    // fields, so a type 5 can be shorter than the nominal 424–426 bits. Only
    // require the bits up to and including the name (ends at bit 232); the
    // bit buffer zero-pads any fields read beyond the end.
    guard buf.bitCount >= 232 else { return nil }
    let mmsi = buf.uint(8, 30)
    let imo = buf.uint(40, 30)
    let callsign = buf.text(70, 42)
    let name = buf.text(112, 120)
    let shipTypeRaw = buf.uint(232, 8)
    let draught = Double(buf.uint(294, 8)) / 10.0
    let dest = buf.text(302, 120)

    return AISTarget(
      mmsi: mmsi, messageType: .staticAndVoyageData, channel: channel,
      positionAccuracy: false, raim: false,
      shipName: name.isEmpty ? nil : name,
      callsign: callsign.isEmpty ? nil : callsign,
      shipType: ShipType(rawValue: shipTypeRaw),
      imoNumber: imo > 0 ? imo : nil,
      destination: dest.isEmpty ? nil : dest,
      draught: draught > 0 ? draught : nil
    )
  }

  // MARK: Type 18 — Standard Class B position report

  private static func decodeType18(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 168 else { return nil }
    let mmsi = buf.uint(8, 30)
    let sogRaw = buf.uint(46, 10)
    let posAcc = buf.uint(56, 1) == 1
    let lonRaw = buf.int(57, 28)
    let latRaw = buf.int(85, 27)
    let cogRaw = buf.uint(112, 12)
    let hdg = buf.uint(124, 9)
    let raim = buf.uint(147, 1) == 1

    let lon = lonRaw != 0x6791AC0 ? Double(lonRaw) / 600_000.0 : nil
    let lat = latRaw != 0x3412140 ? Double(latRaw) / 600_000.0 : nil
    let sog = sogRaw != 1023 ? Double(sogRaw) / 10.0 : nil
    let cog = cogRaw != 3600 ? Double(cogRaw) / 10.0 : nil
    let heading = hdg != 511 ? hdg : nil

    return AISTarget(
      mmsi: mmsi, messageType: .standardClassBReport, channel: channel,
      latitude: lat, longitude: lon,
      speedOverGround: sog, courseOverGround: cog,
      trueHeading: heading,
      positionAccuracy: posAcc, raim: raim
    )
  }

  // MARK: Type 21 — Aid-to-Navigation report

  private static func decodeType21(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 272 else { return nil }
    let mmsi = buf.uint(8, 30)
    let aidType = NavigationalAidType(rawValue: buf.uint(38, 5))
    let name = buf.text(43, 120)
    let posAcc = buf.uint(163, 1) == 1
    let lonRaw = buf.int(164, 28)
    let latRaw = buf.int(192, 27)
    let raim = buf.uint(269, 1) == 1

    let lon = lonRaw != 0x6791AC0 ? Double(lonRaw) / 600_000.0 : nil
    let lat = latRaw != 0x3412140 ? Double(latRaw) / 600_000.0 : nil

    return AISTarget(
      mmsi: mmsi, messageType: .aidToNavigationReport, channel: channel,
      latitude: lat, longitude: lon,
      positionAccuracy: posAcc, raim: raim,
      shipName: name.isEmpty ? nil : name,
      navAidType: aidType
    )
  }

  // MARK: NMEA 2000 AIS PGN decoding

  /// Decodes an NMEA 2000 AIS-related PGN payload into an ``AISTarget``.
  ///
  /// Supports:
  /// - 129038 — Class A Position Report (msg type 1/2/3)
  /// - 129039 — Class B Position Report (msg type 18)
  /// - 129040 — Class B Extended Position Report (msg type 19)
  /// - 129041 — Aids to Navigation Report (msg type 21)
  /// - 129793 — UTC and Date Report (msg type 4)
  /// - 129794 — Class A Static and Voyage Related Data (msg type 5)
  /// - 129809 — Class B "CS" Static Data Report, Part A (msg type 24A)
  /// - 129810 — Class B "CS" Static Data Report, Part B (msg type 24B)
  ///
  /// Layouts follow the Canboat reference. Field strings are extracted from
  /// fixed-length ASCII (padded with `@`) or STRINGLAU (length + encoding header).
  static func decodeN2K(pgn: UInt32, source: UInt8, data: [UInt8]) -> AISTarget? {
    switch pgn {
    case 129038: return decodeN2KPosA(data)
    case 129039: return decodeN2KPosB(data, ext: false)
    case 129040: return decodeN2KPosB(data, ext: true)
    case 129041: return decodeN2KAtoN(data)
    case 129793: return decodeN2KUTC(data)
    case 129794: return decodeN2KStaticA(data)
    case 129809: return decodeN2KStaticB_PartA(data)
    case 129810: return decodeN2KStaticB_PartB(data)
    default: return nil
    }
  }

  // MARK: N2K AIS PGN decoders

  /// PGN 129038 — Class A Position Report (≈ 28 bytes)
  private static func decodeN2KPosA(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 26 else { return nil }
    let msgTypeRaw = Int(d[0] & 0x0F)
    let msgType = AisMessageType(rawValue: msgTypeRaw) ?? .positionReportClassA
    let mmsi = Int(n2kU32(d, 1))
    let lonRaw = n2kI32(d, 5)
    let latRaw = n2kI32(d, 9)
    let accByte = d[13]
    let posAcc = (accByte & 0x01) != 0
    let raim = ((accByte >> 1) & 0x01) != 0
    let cogRaw = n2kU16(d, 14)
    let sogRaw = n2kU16(d, 16)
    let hdgRaw = n2kU16(d, 21)
    let rotRaw = n2kI16(d, 23)
    let navStatus = NavigationStatus(rawValue: Int(d[25] & 0x0F))
    let maneuver: ManeuverIndicator? = ManeuverIndicator(rawValue: Int((d[25] >> 4) & 0x03))

    return AISTarget(
      mmsi: mmsi, messageType: msgType, channel: "A",
      latitude: latRaw != Int32.max ? Double(latRaw) * 1e-7 : nil,
      longitude: lonRaw != Int32.max ? Double(lonRaw) * 1e-7 : nil,
      speedOverGround: sogRaw != 0xFFFF ? Double(sogRaw) * 0.01 * 1.94384 : nil,
      courseOverGround: cogRaw != 0xFFFF ? Double(cogRaw) * 1e-4 * 180 / .pi : nil,
      trueHeading: hdgRaw != 0xFFFF ? Int((Double(hdgRaw) * 1e-4 * 180 / .pi).rounded()) : nil,
      rateOfTurn: rotRaw != Int16.max
        ? Int((Double(rotRaw) * 3.125e-5 * 180 / .pi * 60).rounded()) : nil,
      positionAccuracy: posAcc, raim: raim,
      navigationStatus: navStatus,
      maneuverIndicator: maneuver)
  }

  /// PGN 129039 — Class B Position Report (≈ 26 bytes)
  /// PGN 129040 — Class B Extended Position Report (≈ 33+ bytes, adds ship type and name)
  private static func decodeN2KPosB(_ d: [UInt8], ext: Bool) -> AISTarget? {
    guard d.count >= 23 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let lonRaw = n2kI32(d, 5)
    let latRaw = n2kI32(d, 9)
    let accByte = d[13]
    let posAcc = (accByte & 0x01) != 0
    let raim = ((accByte >> 1) & 0x01) != 0
    let cogRaw = n2kU16(d, 14)
    let sogRaw = n2kU16(d, 16)
    let hdgRaw = n2kU16(d, 21)

    let lat = latRaw != Int32.max ? Double(latRaw) * 1e-7 : nil
    let lon = lonRaw != Int32.max ? Double(lonRaw) * 1e-7 : nil
    let sog = sogRaw != 0xFFFF ? Double(sogRaw) * 0.01 * 1.94384 : nil
    let cog = cogRaw != 0xFFFF ? Double(cogRaw) * 1e-4 * 180 / .pi : nil
    let hdg = hdgRaw != 0xFFFF ? Int((Double(hdgRaw) * 1e-4 * 180 / .pi).rounded()) : nil

    if ext, d.count >= 53 {
      // Extended variant — ship type at byte 20, name STRINGLAU at byte 24 or fixed ASCII at byte 33.
      let shipTypeRaw = Int(d[20])
      let name = n2kAsciiOrStringLAU(d, at: 33, fixedLen: 20)
      return AISTarget(
        mmsi: mmsi, messageType: .extendedClassBReport, channel: "A",
        latitude: lat, longitude: lon,
        speedOverGround: sog, courseOverGround: cog,
        trueHeading: hdg,
        positionAccuracy: posAcc, raim: raim,
        shipName: name,
        shipType: ShipType(rawValue: shipTypeRaw))
    }

    return AISTarget(
      mmsi: mmsi, messageType: .standardClassBReport, channel: "A",
      latitude: lat, longitude: lon,
      speedOverGround: sog, courseOverGround: cog,
      trueHeading: hdg,
      positionAccuracy: posAcc, raim: raim)
  }

  /// PGN 129041 — AIS Aids to Navigation Report
  private static func decodeN2KAtoN(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 23 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let lonRaw = n2kI32(d, 5)
    let latRaw = n2kI32(d, 9)
    let accByte = d[13]
    let posAcc = (accByte & 0x01) != 0
    let raim = ((accByte >> 1) & 0x01) != 0
    let aidType = NavigationalAidType(rawValue: Int(d[22] & 0x1F))
    // AtoN name is STRINGLAU starting at byte 25.
    let name = d.count >= 27 ? n2kStringLAU(d, at: 25) : nil

    return AISTarget(
      mmsi: mmsi, messageType: .aidToNavigationReport, channel: "A",
      latitude: latRaw != Int32.max ? Double(latRaw) * 1e-7 : nil,
      longitude: lonRaw != Int32.max ? Double(lonRaw) * 1e-7 : nil,
      positionAccuracy: posAcc, raim: raim,
      shipName: name,
      navAidType: aidType)
  }

  /// PGN 129793 — AIS UTC and Date Report (msg type 4)
  /// Fields: User ID, Longitude, Latitude, Position accuracy, RAIM, Date, Time, …
  private static func decodeN2KUTC(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 14 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let lonRaw = n2kI32(d, 5)
    let latRaw = n2kI32(d, 9)
    let accByte = d[13]
    return AISTarget(
      mmsi: mmsi, messageType: .baseStationReport, channel: "A",
      latitude: latRaw != Int32.max ? Double(latRaw) * 1e-7 : nil,
      longitude: lonRaw != Int32.max ? Double(lonRaw) * 1e-7 : nil,
      positionAccuracy: (accByte & 0x01) != 0,
      raim: ((accByte >> 1) & 0x01) != 0)
  }

  /// PGN 129794 — Class A Static and Voyage Related Data
  /// Layout: User ID, IMO Number, Call Sign (7 bytes ASCII), Name (20 bytes ASCII),
  /// Type of Ship, dimensions, ETA, Draft, Destination (20 bytes ASCII), …
  private static func decodeN2KStaticA(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 55 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let imo = Int(n2kU32(d, 5))
    let cs = n2kFixedAscii(d, at: 9, len: 7)
    let name = n2kFixedAscii(d, at: 16, len: 20)
    let shipTypeRaw = Int(d[36])
    let draughtRaw = n2kU16(d, 53)
    let dest = d.count >= 75 ? n2kFixedAscii(d, at: 55, len: 20) : nil

    let draught = draughtRaw != 0xFFFF ? Double(draughtRaw) * 0.01 : nil

    return AISTarget(
      mmsi: mmsi, messageType: .staticAndVoyageData, channel: "A",
      positionAccuracy: false, raim: false,
      shipName: name, callsign: cs,
      shipType: ShipType(rawValue: shipTypeRaw),
      imoNumber: imo > 0 ? imo : nil,
      destination: dest,
      draught: (draught ?? 0) > 0 ? draught : nil)
  }

  /// PGN 129809 — Class B "CS" Static Data Report, Part A (name)
  /// Layout: User ID, Name STRINGLAU (or fixed ASCII)
  private static func decodeN2KStaticB_PartA(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 7 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let name = n2kAsciiOrStringLAU(d, at: 5, fixedLen: 20)
    return AISTarget(
      mmsi: mmsi, messageType: .classAStaticData, channel: "A",
      positionAccuracy: false, raim: false,
      shipName: name)
  }

  /// PGN 129810 — Class B "CS" Static Data Report, Part B
  /// Layout: User ID, Type of Ship, Vendor ID (7 bytes), Callsign (7 bytes), dimensions, mothership ID
  private static func decodeN2KStaticB_PartB(_ d: [UInt8]) -> AISTarget? {
    guard d.count >= 20 else { return nil }
    let mmsi = Int(n2kU32(d, 1))
    let shipTypeRaw = Int(d[5])
    // Vendor ID at bytes 6-12 (7 bytes), Callsign at bytes 13-19 (7 bytes).
    let cs = n2kFixedAscii(d, at: 13, len: 7)
    return AISTarget(
      mmsi: mmsi, messageType: .classAStaticData, channel: "A",
      positionAccuracy: false, raim: false,
      callsign: cs,
      shipType: ShipType(rawValue: shipTypeRaw))
  }

  // MARK: NMEA 2000 byte-reading helpers

  private static func n2kU16(_ d: [UInt8], _ at: Int) -> UInt16 {
    guard at + 1 < d.count else { return 0xFFFF }
    return UInt16(d[at]) | UInt16(d[at + 1]) << 8
  }
  private static func n2kI16(_ d: [UInt8], _ at: Int) -> Int16 { Int16(bitPattern: n2kU16(d, at)) }
  private static func n2kU32(_ d: [UInt8], _ at: Int) -> UInt32 {
    guard at + 3 < d.count else { return 0xFFFF_FFFF }
    return UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3])
      << 24
  }
  private static func n2kI32(_ d: [UInt8], _ at: Int) -> Int32 { Int32(bitPattern: n2kU32(d, at)) }

  /// Reads a fixed-length ASCII string padded with `@`. Returns nil for empty results.
  private static func n2kFixedAscii(_ d: [UInt8], at: Int, len: Int) -> String? {
    let end = min(at + len, d.count)
    guard at < end else { return nil }
    let bytes = Array(d[at..<end])
    guard let s = String(bytes: bytes, encoding: .ascii) else { return nil }
    let cleaned =
      s
      .replacingOccurrences(of: "@", with: " ")
      .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// Reads an NMEA 2000 STRINGLAU at byte `at`:
  ///   byte 0 = total length (incl. these 2 header bytes)
  ///   byte 1 = encoding (0=Unicode, 1=ASCII)
  ///   rest   = string data
  private static func n2kStringLAU(_ d: [UInt8], at: Int) -> String? {
    guard at + 1 < d.count else { return nil }
    let totalLen = Int(d[at])
    guard totalLen >= 2, at + totalLen <= d.count else { return nil }
    let encoding = d[at + 1]
    let bytes = Array(d[(at + 2)..<(at + totalLen)])
    let s: String?
    switch encoding {
    case 0: s = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii)
    default: s = String(bytes: bytes, encoding: .ascii)
    }
    let cleaned = s?.trimmingCharacters(in: .whitespaces)
    return (cleaned?.isEmpty ?? true) ? nil : cleaned
  }

  /// Tries STRINGLAU first; falls back to fixed-length ASCII if the LAU header is invalid.
  private static func n2kAsciiOrStringLAU(_ d: [UInt8], at: Int, fixedLen: Int) -> String? {
    if at + 1 < d.count, d[at] >= 2, d[at + 1] <= 1,
      let s = n2kStringLAU(d, at: at)
    {
      return s
    }
    return n2kFixedAscii(d, at: at, len: fixedLen)
  }

  // MARK: Type 24 — Class A static data (parts A & B)

  private static func decodeType24(buf: AISBitBuffer, channel: Character) -> AISTarget? {
    guard buf.bitCount >= 160 else { return nil }
    let mmsi = buf.uint(8, 30)
    let part = buf.uint(38, 2)

    if part == 0 {
      // Part A: name only (168 bits)
      let name = buf.text(40, 120)
      return AISTarget(
        mmsi: mmsi, messageType: .classAStaticData, channel: channel,
        positionAccuracy: false, raim: false,
        shipName: name.isEmpty ? nil : name
      )
    } else {
      // Part B: type, callsign (168 bits)
      guard buf.bitCount >= 168 else { return nil }
      let shipTypeRaw = buf.uint(40, 8)
      let callsign = buf.text(90, 42)
      return AISTarget(
        mmsi: mmsi, messageType: .classAStaticData, channel: channel,
        positionAccuracy: false, raim: false,
        callsign: callsign.isEmpty ? nil : callsign,
        shipType: ShipType(rawValue: shipTypeRaw)
      )
    }
  }
}
