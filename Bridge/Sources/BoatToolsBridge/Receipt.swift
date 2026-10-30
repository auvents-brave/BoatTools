import BoatToolsKit

/// Lays a logbook out for a thermal roll printer.
///
/// The arithmetic lives in `BoatToolsKit.ReceiptLayout`; this carries it across
/// the C boundary, so a host that drives its own Bluetooth still sends exactly
/// the bytes the Apple app sends. Every function here returns a buffer the
/// caller owns and must release with ``boattools_bridge_bytes_free``.

/// Copies `bytes` into a caller-owned buffer and reports its length.
private func buffer(_ bytes: [UInt8], _ outLength: UnsafeMutablePointer<Int32>?)
	-> UnsafeMutablePointer<UInt8>?
{
	let out = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
	out.update(from: bytes, count: bytes.count)
	outLength?.pointee = Int32(bytes.count)
	return out
}

/// Releases a byte buffer returned by any `boattools_bridge_receipt_*` function.
/// - Parameter pointer: The buffer; a null pointer is ignored.
@_cdecl("boattools_bridge_bytes_free")
public func boattools_bridge_bytes_free(_ pointer: UnsafeMutablePointer<UInt8>?) {
	pointer?.deallocate()
}

/// How many characters of Font B fit across a roll.
/// - Parameter paperWidthMM: The roll's width in millimetres.
/// - Returns: 64 on 80 mm paper, 42 on anything narrower.
@_cdecl("boattools_bridge_receipt_columns")
public func boattools_bridge_receipt_columns(_ paperWidthMM: Int32) -> Int32 {
	Int32(ReceiptLayout.columns(paperWidthMM: Int(paperWidthMM)))
}

/// One line, truncated to the paper's width, with a line feed.
/// - Parameters:
///   - text: The line, UTF-8.
///   - columns: How many characters fit across.
///   - outLength: Filled with the buffer's length in bytes.
/// - Returns: The bytes to send, to release with `boattools_bridge_bytes_free`.
@_cdecl("boattools_bridge_receipt_line")
public func boattools_bridge_receipt_line(
	_ text: UnsafePointer<CChar>?, _ columns: Int32, _ outLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
	guard let text else { return buffer([], outLength) }
	return buffer(ReceiptLayout.line(String(cString: text), columns: Int(columns)), outLength)
}

/// A block whose lines wrap to the paper's width, with no framing. An empty
/// line feeds blank.
/// - Parameters:
///   - text: The block, UTF-8, newline-separated.
///   - columns: How many characters fit across.
///   - outLength: Filled with the buffer's length in bytes.
/// - Returns: The bytes to send, to release with `boattools_bridge_bytes_free`.
@_cdecl("boattools_bridge_receipt_block")
public func boattools_bridge_receipt_block(
	_ text: UnsafePointer<CChar>?, _ columns: Int32, _ outLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
	guard let text else { return buffer([], outLength) }
	return buffer(ReceiptLayout.block(String(cString: text), columns: Int(columns)), outLength)
}

/// The voyage header, framed with a rule above and below.
/// - Parameters:
///   - text: The header, UTF-8, newline-separated.
///   - columns: How many characters fit across.
///   - outLength: Filled with the buffer's length in bytes.
/// - Returns: The bytes to send, printer reset and font included.
@_cdecl("boattools_bridge_receipt_voyage_header")
public func boattools_bridge_receipt_voyage_header(
	_ text: UnsafePointer<CChar>?, _ columns: Int32, _ outLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
	guard let text else { return buffer([], outLength) }
	return buffer(ReceiptLayout.voyageHeader(String(cString: text), columns: Int(columns)), outLength)
}

/// A table's column names followed by a dashed rule.
/// - Parameters:
///   - text: The column names, UTF-8.
///   - columns: How many characters fit across.
///   - outLength: Filled with the buffer's length in bytes.
/// - Returns: The bytes to send, printer reset and font included.
@_cdecl("boattools_bridge_receipt_column_header")
public func boattools_bridge_receipt_column_header(
	_ text: UnsafePointer<CChar>?, _ columns: Int32, _ outLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
	guard let text else { return buffer([], outLength) }
	return buffer(ReceiptLayout.columnHeader(String(cString: text), columns: Int(columns)), outLength)
}
