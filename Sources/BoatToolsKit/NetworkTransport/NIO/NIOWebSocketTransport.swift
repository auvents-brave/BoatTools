#if !os(Windows)
	internal import NIOCore
	internal import NIOHTTP1
	internal import NIOPosix
	internal import WebSocketKit

	// MARK: - NIOWebSocketTransport

	/// WebSocketKit-backed ``WebSocketTransport`` for Apple platforms and Linux.
	struct NIOWebSocketTransport: WebSocketTransport {

		func connect(url: String, headers: [(name: String, value: String)]) async throws
			-> any WebSocketConnection
		{
			var httpHeaders = HTTPHeaders()
			for header in headers {
				httpHeaders.add(name: header.name, value: header.value)
			}

			let (stream, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()

			// The message handlers are registered inside the upgrade callback,
			// synchronously on the event loop, so no early frame can be missed
			// (Signal K servers send a hello immediately after the upgrade).
			let ws: WebSocket = try await withCheckedThrowingContinuation { connected in
				let future = WebSocket.connect(
					to: url,
					headers: httpHeaders,
					on: MultiThreadedEventLoopGroup.singleton
				) { ws in
					ws.onText { _, text in continuation.yield(.text(text)) }
					ws.onBinary { _, buffer in
						var buffer = buffer
						if let bytes = buffer.readBytes(length: buffer.readableBytes) {
							continuation.yield(.binary(bytes))
						}
					}
					ws.onClose.whenComplete { _ in continuation.finish() }
					connected.resume(returning: ws)
				}
				// `whenFailure` only fires when the upgrade callback never ran,
				// so the continuation is resumed exactly once either way.
				future.whenFailure { error in
					continuation.finish()
					connected.resume(throwing: TransportError.connect("\(error)"))
				}
			}

			continuation.onTermination = { _ in _ = ws.close(code: .goingAway) }
			return NIOWebSocketConnection(ws: ws, messages: stream)
		}
	}

	// MARK: - NIOWebSocketConnection

	/// One WebSocketKit-backed connection.
	struct NIOWebSocketConnection: WebSocketConnection {
		let ws: WebSocket
		let messages: AsyncThrowingStream<WebSocketMessage, any Error>

		func send(text: String) async throws {
			do {
				try await ws.send(text)
			} catch {
				throw TransportError.send("\(error)")
			}
		}

		func close() async {
			try? await ws.close(code: .goingAway)
		}
	}

#endif  // !os(Windows)
