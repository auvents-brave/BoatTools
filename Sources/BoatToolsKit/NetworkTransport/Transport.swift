// MARK: - TCP

/// One established bidirectional TCP connection.
///
/// Obtained from ``TCPTransport/connect(host:port:)``. The connection is
/// closed when ``close()`` is called, when the remote peer disconnects, or
/// when the ``incoming`` stream is discarded by its consumer.
public protocol TCPConnection: Sendable {
	/// Incoming bytes, chunked as delivered by the platform layer.
	///
	/// The stream finishes when the peer closes the connection and throws on
	/// transport errors. Discarding the stream closes the connection.
	var incoming: AsyncThrowingStream<[UInt8], any Error> { get }

	/// Sends bytes to the peer.
	///
	/// - Parameter bytes: The raw bytes to write.
	/// - Throws: ``TransportError/send(_:)`` when the write fails.
	func send(_ bytes: [UInt8]) async throws

	/// Closes the connection. Idempotent.
	func close() async
}

/// A TCP client transport.
///
/// Use ``NetworkStack/tcp`` to obtain the platform implementation
/// (SwiftNIO on Apple/Linux, libcurl on Windows).
public protocol TCPTransport: Sendable {
	/// Opens a TCP connection to a remote host.
	///
	/// - Parameters:
	///   - host: Remote hostname or IP address.
	///   - port: Remote TCP port.
	/// - Returns: The established connection.
	/// - Throws: ``TransportError/connect(_:)`` when the connection fails.
	func connect(host: String, port: Int) async throws -> any TCPConnection
}

// MARK: - UDP

/// A UDP receive transport.
///
/// Use ``NetworkStack/udp`` to obtain the platform implementation
/// (SwiftNIO on Apple/Linux, Winsock on Windows).
public protocol UDPTransport: Sendable {
	/// Binds a local UDP port and yields each received datagram.
	///
	/// - Parameters:
	///   - port: Local port to bind on all interfaces.
	///   - multicastGroup: Optional multicast group address to join.
	/// - Returns: A stream of datagram payloads. Discarding the stream
	///   releases the socket.
	/// - Throws: ``TransportError/connect(_:)`` when binding or joining fails.
	func listen(port: Int, multicastGroup: String?) async throws
		-> AsyncThrowingStream<[UInt8], any Error>
}

// MARK: - HTTP

/// A platform-independent HTTP request.
public struct HTTPRequest: Sendable {
	/// HTTP method, e.g. `"GET"` or `"POST"`.
	public var method: String
	/// Absolute request URL (`http://` or `https://`).
	public var url: String
	/// Header fields, sent in order. Repeated names are allowed.
	public var headers: [(name: String, value: String)]
	/// Optional request body.
	public var body: [UInt8]?
	/// Total request timeout.
	public var timeout: Duration
	/// Upper bound on the collected response body size.
	public var maxResponseBytes: Int

	/// Creates an HTTP request.
	///
	/// - Parameters:
	///   - method: HTTP method. Defaults to `"GET"`.
	///   - url: Absolute request URL.
	///   - headers: Header fields. Defaults to none.
	///   - body: Optional request body.
	///   - timeout: Total request timeout. Defaults to 15 seconds.
	///   - maxResponseBytes: Response body size cap. Defaults to 10 MiB.
	public init(
		method: String = "GET",
		url: String,
		headers: [(name: String, value: String)] = [],
		body: [UInt8]? = nil,
		timeout: Duration = .seconds(15),
		maxResponseBytes: Int = 10 * 1024 * 1024
	) {
		self.method = method
		self.url = url
		self.headers = headers
		self.body = body
		self.timeout = timeout
		self.maxResponseBytes = maxResponseBytes
	}
}

/// A platform-independent HTTP response with a fully collected body.
public struct HTTPResponse: Sendable {
	/// HTTP status code (e.g. 200).
	public let status: UInt
	/// Response header fields, in wire order.
	public let headers: [(name: String, value: String)]
	/// Collected response body.
	public let body: [UInt8]

	/// Creates an HTTP response.
	///
	/// - Parameters:
	///   - status: HTTP status code.
	///   - headers: Response header fields.
	///   - body: Collected response body.
	public init(status: UInt, headers: [(name: String, value: String)] = [], body: [UInt8] = []) {
		self.status = status
		self.headers = headers
		self.body = body
	}
}

/// An HTTP client transport executing one request at a time.
///
/// Use ``NetworkStack/makeHTTPTransport()`` to obtain the platform
/// implementation (AsyncHTTPClient on Apple/Linux, libcurl on Windows).
/// Call ``shutdown()`` once the transport is no longer needed.
public protocol HTTPTransport: Sendable {
	/// Executes a request and collects the full response.
	///
	/// - Parameter request: The request to perform.
	/// - Returns: The response with its collected body. Non-2xx statuses are
	///   returned, not thrown — status handling belongs to the caller.
	/// - Throws: ``TransportError`` on connection or protocol failures.
	func execute(_ request: HTTPRequest) async throws -> HTTPResponse

	/// Releases the transport's resources. Must be called before discarding
	/// implementations that pool connections. Idempotent.
	func shutdown() async throws
}

// MARK: - WebSocket

/// A single WebSocket message.
public enum WebSocketMessage: Sendable {
	/// A text frame, UTF-8 decoded.
	case text(String)
	/// A binary frame.
	case binary([UInt8])
}

/// One established WebSocket connection.
public protocol WebSocketConnection: Sendable {
	/// Incoming messages.
	///
	/// The stream finishes when the peer closes the connection and throws on
	/// transport errors. Discarding the stream closes the connection.
	var messages: AsyncThrowingStream<WebSocketMessage, any Error> { get }

	/// Sends a text message.
	///
	/// - Parameter text: The message payload.
	/// - Throws: ``TransportError/send(_:)`` when the write fails.
	func send(text: String) async throws

	/// Closes the connection. Idempotent.
	func close() async
}

/// A WebSocket client transport.
///
/// Use ``NetworkStack/webSocket`` to obtain the platform implementation
/// (WebSocketKit on Apple/Linux, libcurl on Windows — requires curl ≥ 7.86
/// built with the `websockets` feature).
public protocol WebSocketTransport: Sendable {
	/// Opens a WebSocket connection.
	///
	/// - Parameters:
	///   - url: Absolute `ws://` or `wss://` URL.
	///   - headers: Additional handshake headers (e.g. `Authorization`).
	/// - Returns: The established connection.
	/// - Throws: ``TransportError/connect(_:)`` when the handshake fails.
	func connect(url: String, headers: [(name: String, value: String)]) async throws
		-> any WebSocketConnection
}
