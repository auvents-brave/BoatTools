/// Lays a logbook out for a thermal roll printer, and encodes it as ESC/POS.
///
/// Everything here is arithmetic on text and bytes: how many columns a paper
/// width gives, where a line wraps, which byte stands for an accented letter.
/// None of it touches a printer, so every app that drives one lays the roll out
/// the same way — and it can be tested without one, which matters for a feature
/// whose hardware is rarely to hand.
///
/// The transport is the host's business: Core Bluetooth on Apple platforms,
/// whatever the companion uses elsewhere. This only says what to send.
public enum ReceiptLayout {

	// MARK: Paper

	/// How many characters of Font B fit across a roll.
	///
	/// - Parameter paperWidthMM: The roll's width in millimetres, as the crew
	///   set it — 58 and 80 are the two sizes sold.
	/// - Returns: 64 columns on 80 mm paper, 42 on anything narrower.
	public static func columns(paperWidthMM: Int) -> Int { paperWidthMM >= 80 ? 64 : 42 }

	/// Breaks a line to the paper's width, on spaces where it can and mid-word
	/// where a single word is longer than the roll.
	///
	/// - Parameters:
	///   - line: The text to break.
	///   - columns: How many characters fit across.
	/// - Returns: The pieces, in order. A line that already fits comes back whole.
	public static func wrap(_ line: String, columns: Int) -> [String] {
		guard columns > 0 else { return [line] }
		guard line.count > columns else { return [line] }
		var result: [String] = []
		var current = ""
		for word in line.split(separator: " ", omittingEmptySubsequences: false) {
			let piece = String(word)
			if current.isEmpty {
				current = piece
			} else if current.count + 1 + piece.count <= columns {
				current += " " + piece
			} else {
				result.append(current)
				current = piece
			}
			while current.count > columns {
				result.append(String(current.prefix(columns)))
				current = String(current.dropFirst(columns))
			}
		}
		if !current.isEmpty { result.append(current) }
		return result
	}

	// MARK: ESC/POS

	/// The control sequences the layout emits.
	public enum Control {
		/// `ESC @` — reset to defaults.
		public static let initialise: [UInt8] = [0x1B, 0x40]
		/// `ESC ! 1` — select Font B, the smaller and denser of the two.
		public static let fontB: [UInt8] = [0x1B, 0x21, 0x01]
		/// `ESC t 16` — code page WPC1252 (Windows Latin-1), so accents survive.
		public static let codePageLatin1: [UInt8] = [0x1B, 0x74, 16]
		public static let lineFeed: [UInt8] = [0x0A]
		/// `GS I 1` — ask the printer for its model id. Best-effort.
		public static let printerID: [UInt8] = [0x1D, 0x49, 0x01]

		/// Feeds `count` blank lines.
		/// - Parameter count: How many; a negative count feeds none.
		public static func feed(_ count: Int) -> [UInt8] {
			Array(repeating: 0x0A, count: max(0, count))
		}
	}

	/// The characters Windows-1252 puts in 0x80–0x9F, where Latin-1 has
	/// controls. Curly quotes and dashes belong here, and French copy is full
	/// of them.
	private static let cp1252Highs: [Unicode.Scalar: UInt8] = [
		"\u{20AC}": 0x80, "\u{201A}": 0x82, "\u{0192}": 0x83, "\u{201E}": 0x84,
		"\u{2026}": 0x85, "\u{2020}": 0x86, "\u{2021}": 0x87, "\u{02C6}": 0x88,
		"\u{2030}": 0x89, "\u{0160}": 0x8A, "\u{2039}": 0x8B, "\u{0152}": 0x8C,
		"\u{017D}": 0x8E, "\u{2018}": 0x91, "\u{2019}": 0x92, "\u{201C}": 0x93,
		"\u{201D}": 0x94, "\u{2022}": 0x95, "\u{2013}": 0x96, "\u{2014}": 0x97,
		"\u{02DC}": 0x98, "\u{2122}": 0x99, "\u{0161}": 0x9A, "\u{203A}": 0x9B,
		"\u{0153}": 0x9C, "\u{017E}": 0x9E, "\u{0178}": 0x9F,
	]

	/// Encodes text as Windows-1252, the code page the printer is put into.
	///
	/// Written out rather than taken from Foundation, whose encodings differ
	/// away from Apple's platforms and which this library must build on.
	/// A character the code page has no room for is dropped rather than
	/// replaced, so a stray emoji costs a glyph and not a garbled line.
	///
	/// - Parameter string: The text to encode.
	/// - Returns: The bytes, with no control sequence around them.
	public static func encode(_ string: String) -> [UInt8] {
		var out: [UInt8] = []
		out.reserveCapacity(string.unicodeScalars.count)
		for scalar in string.unicodeScalars {
			if scalar.value < 0x80 || (scalar.value >= 0xA0 && scalar.value <= 0xFF) {
				out.append(UInt8(scalar.value))
			} else if let byte = cp1252Highs[scalar] {
				out.append(byte)
			}
		}
		return out
	}

	/// Text in the printer's code page, ready to send.
	/// - Parameter string: The text to render.
	/// - Returns: The code-page selector followed by the encoded bytes.
	public static func text(_ string: String) -> [UInt8] {
		Control.codePageLatin1 + encode(string)
	}

	// MARK: The pieces of a roll

	/// One line, truncated to the paper's width, with a line feed — the
	/// append-as-you-go use.
	/// - Parameters:
	///   - text: The line.
	///   - columns: How many characters fit across.
	/// - Returns: The bytes to send.
	public static func line(_ text: String, columns: Int) -> [UInt8] {
		let trimmed = text.count > columns ? String(text.prefix(columns)) : text
		return self.text(trimmed) + Control.lineFeed
	}

	/// A block whose lines wrap to the paper's width, with no framing — an
	/// entry whose data spans several lines. An empty line feeds blank.
	/// - Parameters:
	///   - text: The block, newline-separated.
	///   - columns: How many characters fit across.
	/// - Returns: The bytes to send.
	public static func block(_ text: String, columns: Int) -> [UInt8] {
		var out: [UInt8] = []
		for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = String(raw)
			if line.isEmpty {
				out += Control.lineFeed
				continue
			}
			for chunk in wrap(line, columns: columns) {
				out += self.text(chunk) + Control.lineFeed
			}
		}
		return out
	}

	/// The voyage header at the top of a roll, framed with a rule above and
	/// below so the start of a journal stands out.
	/// - Parameters:
	///   - text: The header, newline-separated.
	///   - columns: How many characters fit across.
	/// - Returns: The bytes to send, printer reset and font included.
	public static func voyageHeader(_ text: String, columns: Int) -> [UInt8] {
		let rule = String(repeating: "=", count: columns)
		var out = Control.initialise + Control.fontB
		out += self.text(rule) + Control.lineFeed
		for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
			for chunk in wrap(String(raw), columns: columns) {
				out += self.text(chunk) + Control.lineFeed
			}
		}
		out += self.text(rule) + Control.lineFeed
		return out
	}

	/// A table's column names followed by a dashed rule — emitted before the
	/// first fix and again whenever the column set grows, so the roll stays as
	/// readable as the table on screen.
	/// - Parameters:
	///   - text: The column names.
	///   - columns: How many characters fit across.
	/// - Returns: The bytes to send, printer reset and font included.
	public static func columnHeader(_ text: String, columns: Int) -> [UInt8] {
		var out = Control.initialise + Control.fontB
		for chunk in wrap(text, columns: columns) {
			out += self.text(chunk) + Control.lineFeed
		}
		out += self.text(String(repeating: "-", count: columns)) + Control.lineFeed
		return out
	}
}
