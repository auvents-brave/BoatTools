internal import Foundation  // Locale, for localised country names

// MARK: - Country

/// A country or territory derived from a vessel's MMSI, identified by its
/// ISO 3166-1 alpha-2 region code.
///
/// The human-readable ``name`` is resolved from the current locale, so it is
/// automatically localised, and the ``flag`` emoji is derived from the same
/// region code.
public struct Country: Sendable, Hashable {
	/// ISO 3166-1 alpha-2 region code, e.g. `"FR"`.
	public let code: String

	/// Creates a country from an ISO 3166-1 alpha-2 region code.
	/// - Parameter code: A two-letter region code; it is upper-cased.
	public init(code: String) {
		self.code = code.uppercased()
	}

	/// The localised country name for the current locale, falling back to the
	/// raw region code when no localised name is available.
	public var name: String {
		Locale.current.localizedString(forRegionCode: code) ?? code
	}

	/// The flag emoji built from the region code's regional indicator symbols,
	/// or an empty string when the code is not a valid two-letter code.
	public var flag: String {
		let base: UInt32 = 0x1F1E6  // 🇦
		var scalars = String.UnicodeScalarView()
		for scalar in code.unicodeScalars {
			guard (0x41...0x5A).contains(scalar.value),
				let indicator = Unicode.Scalar(base + scalar.value - 0x41)
			else { return "" }
			scalars.append(indicator)
		}
		return String(scalars)
	}
}

// MARK: - MaritimeIdentificationDigits

/// Resolves the country encoded in a vessel's MMSI from its Maritime
/// Identification Digits (MID).
///
/// The MID is a three-digit code assigned by the ITU. Its position inside the
/// MMSI depends on the station category (ship, coast station, group of ships,
/// SAR aircraft, aid to navigation, …), which ``mid(forMMSI:)`` accounts for.
public enum MaritimeIdentificationDigits {
	/// Returns the country of registration for an MMSI.
	/// - Parameter mmsi: The 9-digit MMSI.
	/// - Returns: The matching ``Country``, or `nil` when the MMSI carries no
	///   country (AIS-SART, MOB or EPIRB-AIS devices) or the MID is unknown.
	public static func country(forMMSI mmsi: Int) -> Country? {
		guard let mid = mid(forMMSI: mmsi), let code = table[mid] else { return nil }
		return Country(code: code)
	}

	/// Extracts the three-digit MID from an MMSI, accounting for the MMSI
	/// category prefixes.
	/// - Parameter mmsi: The MMSI to inspect.
	/// - Returns: The MID, or `nil` for SART/MOB/EPIRB-AIS identities or when
	///   the MMSI cannot be parsed.
	public static func mid(forMMSI mmsi: Int) -> Int? {
		guard mmsi > 0 else { return nil }
		// An MMSI is conceptually nine digits; `Int` drops any leading zeros
		// (coast stations and groups start with `0`), so pad them back.
		let raw = String(mmsi)
		guard raw.count <= 9 else { return nil }
		let digits = String(repeating: "0", count: 9 - raw.count) + raw

		func threeDigits(from index: Int) -> Int? {
			Int(digits.dropFirst(index).prefix(3))
		}

		if digits.hasPrefix("111") { return threeDigits(from: 3) }  // SAR aircraft
		if digits.hasPrefix("970") || digits.hasPrefix("972")
			|| digits.hasPrefix("974")
		{
			return nil
		}  // AIS-SART / MOB / EPIRB-AIS
		if digits.hasPrefix("98") || digits.hasPrefix("99") {
			return threeDigits(from: 2)  // craft assoc. w/ parent ship / aid to navigation
		}
		if digits.hasPrefix("00") { return threeDigits(from: 2) }  // coast station
		if digits.hasPrefix("0") { return threeDigits(from: 1) }  // group of ships
		return threeDigits(from: 0)  // ship station
	}

	/// MID → ISO 3166-1 alpha-2 region code (ITU MID assignments).
	///
	/// Territories without their own region code map to the appropriate
	/// sovereign or umbrella code (e.g. Azores/Madeira → `PT`, the French
	/// Southern and Antarctic islands → `TF`).
	static let table: [Int: String] = [
		// Europe
		201: "AL", 202: "AD", 203: "AT", 204: "PT", 205: "BE", 206: "BY",
		207: "BG", 208: "VA", 209: "CY", 210: "CY", 211: "DE", 212: "CY",
		213: "GE", 214: "MD", 215: "MT", 216: "AM", 218: "DE", 219: "DK",
		220: "DK", 224: "ES", 225: "ES", 226: "FR", 227: "FR", 228: "FR",
		230: "FI", 231: "FO", 232: "GB", 233: "GB", 234: "GB", 235: "GB",
		236: "GI", 237: "GR", 238: "HR", 239: "GR", 240: "GR", 241: "GR",
		242: "MA", 243: "HU", 244: "NL", 245: "NL", 246: "NL", 247: "IT",
		248: "MT", 249: "MT", 250: "IE", 251: "IS", 252: "LI", 253: "LU",
		254: "MC", 255: "PT", 256: "MT", 257: "NO", 258: "NO", 259: "NO",
		261: "PL", 262: "ME", 263: "PT", 264: "RO", 265: "SE", 266: "SE",
		267: "SK", 268: "SM", 269: "CH", 270: "CZ", 271: "TR", 272: "UA",
		273: "RU", 274: "MK", 275: "LV", 276: "EE", 277: "LT", 278: "SI",
		279: "RS",

		// North & Central America, Caribbean
		301: "AI", 303: "US", 304: "AG", 305: "AG", 306: "CW", 307: "AW",
		308: "BS", 309: "BS", 310: "BM", 311: "BS", 312: "BZ", 314: "BB",
		316: "CA", 319: "KY", 321: "CR", 323: "CU", 325: "DM", 327: "DO",
		329: "GP", 330: "GD", 331: "GL", 332: "GT", 334: "HN", 336: "HT",
		338: "US", 339: "JM", 341: "KN", 343: "LC", 345: "MX", 347: "MQ",
		348: "MS", 350: "NI", 351: "PA", 352: "PA", 353: "PA", 354: "PA",
		358: "PR", 359: "SV", 361: "PM", 362: "TT", 364: "TC", 366: "US",
		367: "US", 368: "US", 369: "US", 370: "PA", 371: "PA", 372: "PA",
		375: "VC", 376: "VC", 377: "VC", 378: "VG", 379: "VI",

		// Asia & Middle East
		401: "AF", 403: "SA", 405: "BD", 408: "BH", 410: "BT", 412: "CN",
		413: "CN", 416: "TW", 417: "LK", 419: "IN", 422: "IR", 423: "AZ",
		425: "IQ", 428: "IL", 431: "JP", 432: "JP", 434: "TM", 436: "KZ",
		437: "UZ", 438: "JO", 440: "KR", 441: "KR", 443: "PS", 445: "KP",
		447: "KW", 450: "LB", 451: "KG", 453: "MO", 455: "MV", 457: "MN",
		459: "NP", 461: "OM", 463: "PK", 466: "QA", 468: "SY", 470: "AE",
		473: "YE", 475: "YE", 477: "HK", 478: "BA",

		// Oceania & South-East Asia
		501: "TF", 503: "AU", 506: "MM", 508: "BN", 510: "FM", 511: "PW",
		512: "NZ", 514: "KH", 515: "KH", 516: "CX", 518: "CK", 520: "FJ",
		523: "CC", 525: "ID", 529: "KI", 531: "LA", 533: "MY", 536: "MP",
		538: "MH", 540: "NC", 542: "NU", 544: "NR", 546: "PF", 548: "PH",
		553: "PG", 555: "PN", 557: "SB", 559: "AS", 561: "WS", 563: "SG",
		564: "SG", 565: "SG", 567: "TH", 570: "TO", 572: "TV", 574: "VN",
		576: "VU", 578: "WF",

		// Africa
		601: "ZA", 603: "AO", 605: "DZ", 607: "TF", 608: "SH", 609: "BI",
		610: "BJ", 611: "BW", 612: "CF", 613: "CM", 615: "CG", 616: "KM",
		617: "CV", 618: "TF", 619: "CI", 621: "DJ", 622: "EG", 624: "ET",
		625: "ER", 626: "GA", 627: "GH", 629: "GM", 630: "GW", 631: "GQ",
		632: "GN", 633: "BF", 634: "KE", 635: "TF", 636: "LR", 637: "LR",
		642: "LY", 644: "LS", 645: "MU", 647: "MG", 649: "ML", 650: "MZ",
		654: "MR", 655: "MW", 656: "NE", 657: "NG", 659: "NA", 660: "RE",
		661: "RW", 662: "SD", 663: "SN", 664: "SC", 665: "SH", 666: "SO",
		667: "SL", 668: "ST", 669: "SZ", 670: "TD", 671: "TG", 672: "TN",
		674: "TZ", 675: "UG", 676: "CD", 677: "TZ", 678: "ZM", 679: "ZW",

		// South America
		701: "AR", 710: "BR", 720: "BO", 725: "CL", 730: "CO", 735: "EC",
		740: "FK", 745: "GF", 750: "GY", 755: "PY", 760: "PE", 765: "SR",
		770: "UY", 775: "VE",
	]
}

// MARK: - AISTarget country

extension AISTarget {
	/// The country of registration derived from the target's MMSI.
	///
	/// `nil` when the MMSI carries no country (AIS-SART, MOB or EPIRB-AIS
	/// devices) or the MID is unknown. Use ``Country/name`` for the localised
	/// country name and ``Country/flag`` for the flag emoji.
	public var country: Country? {
		MaritimeIdentificationDigits.country(forMMSI: mmsi)
	}
}
