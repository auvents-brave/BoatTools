#if !os(Windows)
	internal import AsyncHTTPClient
	internal import NIOCore
	internal import NIOHTTP1
	internal import NIOPosix

	// MARK: - NIOHTTPTransport

	/// AsyncHTTPClient-backed ``HTTPTransport`` for Apple platforms and Linux.
	///
	/// Owns one `HTTPClient` on the shared singleton event loop group. The
	/// client pools connections, so ``shutdown()`` must be called before the
	/// transport is discarded (`HTTPClient` traps when deinitialised live).
	final class NIOHTTPTransport: HTTPTransport {

		private let client: HTTPClient

		init() {
			self.client = HTTPClient(
				eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
		}

		func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
			var req = HTTPClientRequest(url: request.url)
			req.method = HTTPMethod(rawValue: request.method)
			for header in request.headers {
				req.headers.add(name: header.name, value: header.value)
			}
			if let body = request.body {
				req.body = .bytes(ByteBuffer(bytes: body))
			}

			let nanoseconds =
				request.timeout.components.seconds * 1_000_000_000
				+ request.timeout.components.attoseconds / 1_000_000_000
			let response = try await client.execute(req, timeout: .nanoseconds(nanoseconds))
			let buffer = try await response.body.collect(upTo: request.maxResponseBytes)

			return HTTPResponse(
				status: response.status.code,
				headers: response.headers.map { (name: $0.name, value: $0.value) },
				body: Array(buffer.readableBytesView))
		}

		func shutdown() async throws {
			try await client.shutdown()
		}
	}

#endif  // !os(Windows)
