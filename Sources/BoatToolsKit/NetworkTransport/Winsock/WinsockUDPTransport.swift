#if os(Windows)
	internal import Foundation
	import WinSDK

	// MARK: - WinsockUDPTransport

	/// Winsock-backed ``UDPTransport`` for Windows.
	///
	/// libcurl has no UDP receive path, so this transport talks to Winsock
	/// directly: bind `0.0.0.0` on the requested port with `SO_REUSEADDR` and
	/// `SO_BROADCAST`, optionally join a multicast group, then read datagrams
	/// on a dedicated thread (`recvfrom` is blocking; closing the socket from
	/// the stream's termination handler unblocks it).
	struct WinsockUDPTransport: UDPTransport {

		/// One-time Winsock initialisation (version 2.2).
		private static let winsockReady: Bool = {
			var data = WSADATA()
			return WSAStartup(0x0202, &data) == 0
		}()

		func listen(port: Int, multicastGroup: String?) async throws
			-> AsyncThrowingStream<[UInt8], any Error>
		{
			guard Self.winsockReady else {
				throw TransportError.connect("WSAStartup failed")
			}

			let socketHandle = WinSDK.socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP.rawValue))
			guard socketHandle != INVALID_SOCKET else {
				throw TransportError.connect("socket() failed: WSA error \(WSAGetLastError())")
			}

			func setOption(_ level: Int32, _ name: Int32, _ value: inout Int32) -> Bool {
				withUnsafeBytes(of: &value) { raw in
					setsockopt(
						socketHandle, level, name,
						raw.baseAddress!.assumingMemoryBound(to: CChar.self),
						Int32(MemoryLayout<Int32>.size)) == 0
				}
			}

			var enable: Int32 = 1
			_ = setOption(SOL_SOCKET, SO_REUSEADDR, &enable)
			_ = setOption(SOL_SOCKET, SO_BROADCAST, &enable)

			var address = sockaddr_in()
			address.sin_family = ADDRESS_FAMILY(AF_INET)
			address.sin_port = UInt16(port).bigEndian
			address.sin_addr = IN_ADDR()  // INADDR_ANY

			let bound = withUnsafePointer(to: &address) { pointer in
				pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					WinSDK.bind(socketHandle, $0, Int32(MemoryLayout<sockaddr_in>.size))
				}
			}
			guard bound == 0 else {
				let code = WSAGetLastError()
				closesocket(socketHandle)
				throw TransportError.connect("bind(:\(port)) failed: WSA error \(code)")
			}

			if let group = multicastGroup {
				var membership = ip_mreq()
				guard inet_pton(AF_INET, group, &membership.imr_multiaddr) == 1 else {
					closesocket(socketHandle)
					throw TransportError.invalidURL("invalid multicast group address: \(group)")
				}
				membership.imr_interface = IN_ADDR()  // default interface
				// Unlike IPPROTO_UDP (an IPPROTO enum case), WinSDK surfaces
				// IPPROTO_IP as a plain Int32.
				let joined = withUnsafeBytes(of: &membership) { raw in
					setsockopt(
						socketHandle, IPPROTO_IP, IP_ADD_MEMBERSHIP,
						raw.baseAddress!.assumingMemoryBound(to: CChar.self),
						Int32(MemoryLayout<ip_mreq>.size))
				}
				guard joined == 0 else {
					let code = WSAGetLastError()
					closesocket(socketHandle)
					throw TransportError.connect(
						"joining multicast group \(group) failed: WSA error \(code)")
				}
			}

			let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
			Thread.detachNewThread {
				var buffer = [UInt8](repeating: 0, count: 64 * 1024)
				while true {
					let count = buffer.withUnsafeMutableBytes { raw in
						recvfrom(
							socketHandle,
							raw.baseAddress!.assumingMemoryBound(to: CChar.self),
							Int32(raw.count), 0, nil, nil)
					}
					guard count > 0 else {
						// 0 or SOCKET_ERROR — the socket was closed (consumer
						// terminated the stream) or is unusable; stop quietly.
						continuation.finish()
						break
					}
					continuation.yield(Array(buffer[..<Int(count)]))
				}
			}
			continuation.onTermination = { _ in _ = closesocket(socketHandle) }
			return stream
		}
	}

#endif  // os(Windows)
