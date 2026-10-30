// Pins how a logbook is laid out for a thermal roll: the column count a paper
// width gives, where a line breaks, and which byte stands for an accent.
//
// This matters more than most: the printer itself is rarely to hand, and the
// recipe has never been confirmed against one. What can be checked without
// hardware is checked here.

import Testing

@testable import BoatToolsKit

@Suite("Receipt layout")
struct ReceiptLayoutTests {

	// MARK: Paper width

	@Test("Eighty-millimetre paper takes sixty-four columns, narrower rolls forty-two")
	func columnsPerWidth() {
		#expect(ReceiptLayout.columns(paperWidthMM: 80) == 64)
		#expect(ReceiptLayout.columns(paperWidthMM: 112) == 64)
		#expect(ReceiptLayout.columns(paperWidthMM: 58) == 42)
		#expect(ReceiptLayout.columns(paperWidthMM: 0) == 42)
	}

	// MARK: Wrapping

	@Test("A line that fits comes back whole")
	func shortLine() {
		#expect(ReceiptLayout.wrap("12:04 cap 145", columns: 42) == ["12:04 cap 145"])
	}

	@Test("A long line breaks on spaces, never mid-word where it can be helped")
	func wrapsOnSpaces() {
		let pieces = ReceiptLayout.wrap("ris pris dans la grand-voile vent fraichissant", columns: 20)
		#expect(pieces.allSatisfy { $0.count <= 20 })
		#expect(pieces.joined(separator: " ") == "ris pris dans la grand-voile vent fraichissant")
	}

	@Test("A word longer than the roll is cut rather than lost")
	func wrapsLongWord() {
		let pieces = ReceiptLayout.wrap(String(repeating: "A", count: 50), columns: 20)
		#expect(pieces == [String(repeating: "A", count: 20), String(repeating: "A", count: 20),
			String(repeating: "A", count: 10)])
	}

	// MARK: The code page

	@Test("Accented letters survive as Windows-1252 bytes")
	func encodesAccents() {
		// é is 0xE9 in Latin-1 and in Windows-1252 alike.
		#expect(ReceiptLayout.encode("relevé") == [0x72, 0x65, 0x6C, 0x65, 0x76, 0xE9])
	}

	@Test("A curly apostrophe takes the Windows-1252 byte Latin-1 has not got")
	func encodesCurlyQuote() {
		// U+2019 lives at 0x92, in the block Latin-1 leaves to controls — and
		// French copy is full of it.
		#expect(ReceiptLayout.encode("l\u{2019}ancre") == [0x6C, 0x92, 0x61, 0x6E, 0x63, 0x72, 0x65])
	}

	@Test("A character the code page has no room for is dropped, not garbled")
	func dropsUnencodable() {
		#expect(ReceiptLayout.encode("cap \u{1F6A2} 145") == ReceiptLayout.encode("cap  145"))
	}

	// MARK: The pieces of a roll

	@Test("A line is truncated to the paper and ends in a feed")
	func lineTruncates() {
		let bytes = ReceiptLayout.line(String(repeating: "x", count: 50), columns: 42)
		#expect(bytes.last == 0x0A)
		// Code-page selector (3 bytes) + 42 characters + the feed.
		#expect(bytes.count == 3 + 42 + 1)
	}

	@Test("An empty line in a block feeds blank rather than printing nothing")
	func blockKeepsBlankLines() {
		let bytes = ReceiptLayout.block("un\n\ndeux", columns: 42)
		#expect(bytes.filter { $0 == 0x0A }.count == 3)
	}

	@Test("The voyage header is framed above and below, and resets the printer")
	func voyageHeaderIsFramed() {
		let bytes = ReceiptLayout.voyageHeader("Thoôsa", columns: 42)
		#expect(bytes.starts(with: ReceiptLayout.Control.initialise + ReceiptLayout.Control.fontB))
		// Three lines: the rule, the name, the rule.
		#expect(bytes.filter { $0 == 0x0A }.count == 3)
		// '=' is 0x3D; both rules are full width.
		#expect(bytes.filter { $0 == 0x3D }.count == 84)
	}

	@Test("A column header is followed by a dashed rule the width of the paper")
	func columnHeaderIsRuled() {
		let bytes = ReceiptLayout.columnHeader("UTC  COG  SOG", columns: 42)
		#expect(bytes.filter { $0 == 0x2D }.count == 42)  // '-'
		#expect(bytes.filter { $0 == 0x0A }.count == 2)
	}

	@Test("Feeding a negative number of lines feeds none")
	func feedGuardsNegative() {
		#expect(ReceiptLayout.Control.feed(-3).isEmpty)
		#expect(ReceiptLayout.Control.feed(2) == [0x0A, 0x0A])
	}
}
