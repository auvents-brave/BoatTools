// The Network framework (NWListener / NWConnection) is Apple-only, so this
// integration test is skipped on Linux and Windows.
#if canImport(Network)

	import Foundation
	import Network
	import Testing

	@testable import BoatToolsKit

	/// Integration test for the TCP branch of ``NMEATransport`` — the transport an
	/// *address* connection (`.networkAddress(proto: "TCP", …)`) and a `tcp://` URL
	/// both open. A throwaway in-process listener streams a couple of NMEA sentences;
	/// the transport must connect and surface at least one decoded frame.
	@Suite("NMEA transport — TCP")
	struct NMEATransportTCPTests {

		/// A minimal TCP server that sends the given bytes to every client that
		/// connects, then keeps the socket open. Returns the port it bound to.
		private actor EchoOnceServer {
			private var listener: NWListener?
			private var connections: [NWConnection] = []

			func start(sending payload: [UInt8]) async throws -> UInt16 {
				let listener = try NWListener(using: .tcp, on: .any)
				self.listener = listener
				listener.newConnectionHandler = { [payload] connection in
					connection.start(queue: .global())
					connection.send(
						content: Data(payload),
						completion: .contentProcessed { _ in })
					Task { await self.retain(connection) }
				}
				listener.start(queue: .global())

				// Wait for the OS-assigned port.
				for _ in 0..<200 {
					if let port = listener.port?.rawValue, port != 0 { return port }
					try await Task.sleep(for: .milliseconds(10))
				}
				throw CancellationError()
			}

			private func retain(_ connection: NWConnection) { connections.append(connection) }

			func stop() {
				listener?.cancel()
				connections.forEach { $0.cancel() }
			}
		}

		@Test func `TCP transport connects and yields a frame`() async throws {
			let sentences =
				"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n"
				+ "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n"
			let server = EchoOnceServer()
			let port = try await server.start(sending: Array(sentences.utf8))
			defer { Task { await server.stop() } }

			let config = NMEATransportConfig(mode: .tcp(host: "127.0.0.1", port: Int(port)))

			// Take the first frame, giving the connection a few seconds to open.
			let firstFrame: NMEAFrame? = try await withThrowingTaskGroup(of: NMEAFrame?.self) { group in
				group.addTask {
					for try await frame in NMEATransport.frameStream(config: config) {
						return frame
					}
					return nil
				}
				group.addTask {
					try await Task.sleep(for: .seconds(5))
					return nil
				}
				let result = try await group.next() ?? nil
				group.cancelAll()
				return result
			}

			#expect(firstFrame != nil, "the TCP transport should surface a frame from the server")
		}
	}

#endif
