// MARK: - TransportError

/// Errors thrown by the ``NetworkStack`` transports.
///
/// Each case carries a human-readable message from the underlying platform
/// layer (SwiftNIO, libcurl or Winsock). Higher layers typically wrap these
/// into their own domain errors.
public enum TransportError: Error, Sendable {
	/// The supplied URL or address could not be parsed.
	case invalidURL(String)
	/// Establishing the connection (or binding the socket) failed.
	case connect(String)
	/// Sending data on an established connection failed.
	case send(String)
	/// Receiving data on an established connection failed.
	case receive(String)
	/// The requested feature is unavailable on this platform or build
	/// (e.g. libcurl compiled without the `websockets` feature).
	case unsupported(String)
}

extension TransportError: CustomStringConvertible {
	/// A short human-readable description of the failure.
	public var description: String {
		switch self {
		case .invalidURL(let detail): return "Invalid URL: \(detail)"
		case .connect(let detail): return "Connection failed: \(detail)"
		case .send(let detail): return "Send failed: \(detail)"
		case .receive(let detail): return "Receive failed: \(detail)"
		case .unsupported(let detail): return "Unsupported: \(detail)"
		}
	}
}
