#if os(Windows)
	internal import CCurl
	internal import Foundation

	// MARK: - CurlWebSocketTransport

	/// libcurl-backed ``WebSocketTransport`` for Windows.
	///
	/// Uses `CURLOPT_CONNECT_ONLY = 2`: libcurl performs the HTTP upgrade
	/// handshake, then exposes the connection through `curl_ws_send` /
	/// `curl_ws_recv`. Requires libcurl ≥ 8.0 built with the `websockets`
	/// feature (vcpkg: `curl[websockets]`) — without it the connection fails
	/// with ``TransportError/unsupported(_:)``.
	struct CurlWebSocketTransport: WebSocketTransport {

		func connect(url: String, headers: [(name: String, value: String)]) async throws
			-> any WebSocketConnection
		{
			guard CurlGlobal.initialized else {
				throw TransportError.connect("libcurl global initialisation failed")
			}
			let state = try await withCheckedThrowingContinuation {
				(connected: CheckedContinuation<CurlConnectionState, any Error>) in
				Thread.detachNewThread {
					do {
						connected.resume(returning: try Self.open(url: url, headers: headers))
					} catch {
						connected.resume(throwing: error)
					}
				}
			}

			let (stream, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
			Self.startReader(state: state, continuation: continuation)
			continuation.onTermination = { _ in state.close() }
			return CurlWebSocketConnection(state: state, messages: stream)
		}

		private static func open(
			url: String, headers: [(name: String, value: String)]
		) throws -> CurlConnectionState {
			guard let handle = curl_easy_init() else {
				throw TransportError.connect("curl_easy_init failed")
			}
			_ = boattools_curl_setopt_string(handle, CURLOPT_URL, url)
			_ = boattools_curl_setopt_long(handle, CURLOPT_CONNECT_ONLY, 2)
			_ = boattools_curl_setopt_long(handle, CURLOPT_CONNECTTIMEOUT_MS, 15_000)

			// The header list must stay alive for the whole connection — it is
			// owned (and eventually freed) by the connection state.
			var headerList: UnsafeMutablePointer<curl_slist>?
			for header in headers {
				headerList = curl_slist_append(headerList, "\(header.name): \(header.value)")
			}
			if let headerList {
				_ = boattools_curl_setopt_pointer(
					handle, CURLOPT_HTTPHEADER, UnsafeMutableRawPointer(headerList))
			}

			let result = curl_easy_perform(handle)
			guard result == CURLE_OK else {
				curl_easy_cleanup(handle)
				curl_slist_free_all(headerList)
				if result == CURLE_UNSUPPORTED_PROTOCOL {
					throw TransportError.unsupported(
						"this libcurl build has no WebSocket support — install curl[websockets]")
				}
				throw TransportError.connect(curlMessage(result))
			}
			var socket = curl_socket_t(bitPattern: -1)
			_ = boattools_curl_getinfo_socket(handle, CURLINFO_ACTIVESOCKET, &socket)
			return CurlConnectionState(handle: handle, socket: socket, headerList: headerList)
		}

		/// Reads WebSocket frames on a dedicated thread, reassembling
		/// fragmented messages, and yields complete messages into the stream.
		private static func startReader(
			state: CurlConnectionState,
			continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
		) {
			Thread.detachNewThread {
				var buffer = [UInt8](repeating: 0, count: 64 * 1024)
				var pending: [UInt8] = []
				var pendingIsText = true

				loop: while true {
					var received = 0
					var flags: Int32 = 0
					var frameComplete = false
					var closeFrame = false

					let result = state.withHandle {
						(handle: UnsafeMutableRawPointer) -> CURLcode in
						var meta: UnsafePointer<curl_ws_frame>?
						let code = curl_ws_recv(handle, &buffer, buffer.count, &received, &meta)
						if let frame = meta {
							flags = frame.pointee.flags
							frameComplete = frame.pointee.bytesleft == 0
							closeFrame = (flags & boattools_curlws_close) != 0
						}
						return code
					}
					guard let result else { break }  // closed by the consumer

					switch result {
					case CURLE_OK:
						if closeFrame {
							continuation.finish()
							break loop
						}
						if (flags & boattools_curlws_text) != 0 { pendingIsText = true }
						if (flags & boattools_curlws_binary) != 0 { pendingIsText = false }
						if received > 0 { pending += buffer[..<received] }
						// A message is complete once the current frame has no
						// bytes left and no continuation frame follows.
						if frameComplete && (flags & boattools_curlws_cont) == 0 {
							if pendingIsText {
								continuation.yield(.text(String(decoding: pending, as: UTF8.self)))
							} else {
								continuation.yield(.binary(pending))
							}
							pending = []
						}
					case CURLE_AGAIN:
						curlWaitSocket(state.socket, forRead: true, timeoutMilliseconds: 200)
					case CURLE_GOT_NOTHING:
						// The peer closed the connection without a CLOSE frame.
						continuation.finish()
						break loop
					default:
						continuation.finish(throwing: TransportError.receive(curlMessage(result)))
						break loop
					}
				}
			}
		}
	}

	// MARK: - CurlWebSocketConnection

	/// One libcurl-backed WebSocket connection.
	struct CurlWebSocketConnection: WebSocketConnection {
		let state: CurlConnectionState
		let messages: AsyncThrowingStream<WebSocketMessage, any Error>

		func send(text: String) async throws {
			let bytes = Array(text.utf8)
			while true {
				var sent = 0
				let result = state.withHandle { handle in
					bytes.withUnsafeBytes { raw in
						curl_ws_send(
							handle, raw.baseAddress, raw.count, &sent, 0,
							UInt32(boattools_curlws_text))
					}
				}
				guard let result else { throw TransportError.send("connection closed") }
				switch result {
				case CURLE_OK:
					// curl_ws_send buffers a whole frame — OK means fully queued.
					return
				case CURLE_AGAIN:
					curlWaitSocket(state.socket, forRead: false, timeoutMilliseconds: 200)
				default:
					throw TransportError.send(curlMessage(result))
				}
			}
		}

		func close() async {
			// Best-effort CLOSE frame, then release the handle.
			var sent = 0
			_ = state.withHandle { handle in
				curl_ws_send(handle, nil, 0, &sent, 0, UInt32(boattools_curlws_close))
			}
			state.close()
		}
	}

#endif  // os(Windows)
