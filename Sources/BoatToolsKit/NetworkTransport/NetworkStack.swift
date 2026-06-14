// MARK: - NetworkStack

/// Platform-selected default transport implementations.
///
/// On Apple platforms and Linux the transports are backed by SwiftNIO,
/// AsyncHTTPClient and WebSocketKit; on Windows by libcurl (TCP, HTTP,
/// WebSocket) and Winsock (UDP). Callers never see the underlying stack —
/// only the portable protocols.
///
/// ## Usage
/// ```swift
/// let connection = try await NetworkStack.tcp.connect(host: "192.168.1.16", port: 11102)
/// for try await chunk in connection.incoming { … }
/// ```
public enum NetworkStack {

	/// The platform TCP client transport. Stateless — connections own their
	/// resources.
	public static var tcp: any TCPTransport {
		#if os(Windows)
			CurlTCPTransport()
		#else
			NIOTCPTransport()
		#endif
	}

	/// The platform UDP receive transport. Stateless — each ``UDPTransport/listen(port:multicastGroup:)``
	/// call owns its socket.
	public static var udp: any UDPTransport {
		#if os(Windows)
			WinsockUDPTransport()
		#else
			NIOUDPTransport()
		#endif
	}

	/// The platform WebSocket client transport. Stateless — connections own
	/// their resources.
	public static var webSocket: any WebSocketTransport {
		#if os(Windows)
			CurlWebSocketTransport()
		#else
			NIOWebSocketTransport()
		#endif
	}

	/// Creates a new HTTP transport instance.
	///
	/// Unlike the other transports an HTTP transport may pool connections, so
	/// each instance must be released with ``HTTPTransport/shutdown()`` once
	/// its owner is done with it.
	public static func makeHTTPTransport() -> any HTTPTransport {
		#if os(Windows)
			CurlHTTPTransport()
		#else
			NIOHTTPTransport()
		#endif
	}
}
