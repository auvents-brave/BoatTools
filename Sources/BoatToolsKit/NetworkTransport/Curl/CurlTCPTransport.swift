#if os(Windows)
	internal import CCurl
	internal import Foundation

	// MARK: - CurlTCPTransport

	/// libcurl-backed ``TCPTransport`` for Windows.
	///
	/// Uses `CURLOPT_CONNECT_ONLY = 1` so libcurl stops after the TCP handshake
	/// and exposes the raw socket through `curl_easy_send`/`curl_easy_recv`.
	/// Each connection owns one easy handle and one reader thread.
	struct CurlTCPTransport: TCPTransport {

		func connect(host: String, port: Int) async throws -> any TCPConnection {
			guard CurlGlobal.initialized else {
				throw TransportError.connect("libcurl global initialisation failed")
			}
			// curl_easy_perform blocks during the handshake — run it off the
			// cooperative pool.
			let state = try await withCheckedThrowingContinuation {
				(connected: CheckedContinuation<CurlConnectionState, any Error>) in
				Thread.detachNewThread {
					do {
						connected.resume(returning: try Self.open(host: host, port: port))
					} catch {
						connected.resume(throwing: error)
					}
				}
			}

			let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
			Self.startReader(state: state, continuation: continuation)
			continuation.onTermination = { _ in state.close() }
			return CurlTCPConnection(state: state, incoming: stream)
		}

		private static func open(host: String, port: Int) throws -> CurlConnectionState {
			guard let handle = curl_easy_init() else {
				throw TransportError.connect("curl_easy_init failed")
			}
			// The scheme only sets the default port; CONNECT_ONLY stops right
			// after the TCP handshake, no HTTP is spoken.
			_ = boattools_curl_setopt_string(handle, CURLOPT_URL, "http://\(host):\(port)/")
			_ = boattools_curl_setopt_long(handle, CURLOPT_CONNECT_ONLY, 1)
			_ = boattools_curl_setopt_long(handle, CURLOPT_CONNECTTIMEOUT_MS, 15_000)
			let result = curl_easy_perform(handle)
			guard result == CURLE_OK else {
				curl_easy_cleanup(handle)
				throw TransportError.connect(curlMessage(result))
			}
			var socket = curl_socket_t(bitPattern: -1)
			_ = boattools_curl_getinfo_socket(handle, CURLINFO_ACTIVESOCKET, &socket)
			return CurlConnectionState(handle: handle, socket: socket)
		}

		/// Reads the socket on a dedicated thread, yielding chunks into the
		/// stream until the peer closes, an error occurs, or the consumer
		/// terminates the stream.
		private static func startReader(
			state: CurlConnectionState,
			continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
		) {
			Thread.detachNewThread {
				var buffer = [UInt8](repeating: 0, count: 64 * 1024)
				loop: while true {
					var received = 0
					let result = state.withHandle { handle in
						curl_easy_recv(handle, &buffer, buffer.count, &received)
					}
					guard let result else { break }  // closed by the consumer
					switch result {
					case CURLE_OK where received > 0:
						continuation.yield(Array(buffer[..<received]))
					case CURLE_OK:
						// A successful zero-byte read is an orderly shutdown.
						continuation.finish()
						break loop
					case CURLE_AGAIN:
						curlWaitSocket(state.socket, forRead: true, timeoutMilliseconds: 200)
					default:
						continuation.finish(throwing: TransportError.receive(curlMessage(result)))
						break loop
					}
				}
			}
		}
	}

	// MARK: - CurlTCPConnection

	/// One libcurl-backed TCP connection.
	struct CurlTCPConnection: TCPConnection {
		let state: CurlConnectionState
		let incoming: AsyncThrowingStream<[UInt8], any Error>

		func send(_ bytes: [UInt8]) async throws {
			var offset = 0
			while offset < bytes.count {
				var sent = 0
				let result = state.withHandle { handle in
					bytes[offset...].withUnsafeBytes { raw in
						curl_easy_send(handle, raw.baseAddress, raw.count, &sent)
					}
				}
				guard let result else { throw TransportError.send("connection closed") }
				switch result {
				case CURLE_OK:
					offset += sent
				case CURLE_AGAIN:
					// Brief blocking wait; sends are rare and small on this path.
					curlWaitSocket(state.socket, forRead: false, timeoutMilliseconds: 200)
				default:
					throw TransportError.send(curlMessage(result))
				}
			}
		}

		func close() async {
			state.close()
		}
	}

#endif  // os(Windows)
