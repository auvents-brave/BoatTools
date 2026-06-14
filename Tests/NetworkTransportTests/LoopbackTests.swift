import NIOCore
import NIOPosix
import Testing

@testable import BoatToolsKit

/// Loopback round-trips for the NIO-backed transports, using a SwiftNIO peer
/// on the other side of the wire.
@Suite("NetworkTransport loopback")
struct LoopbackTests {

	@Test func `TCP transport round-trips bytes through a loopback echo server`() async throws {
		let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer { channel in
				channel.eventLoop.makeCompletedFuture {
					try channel.pipeline.syncOperations.addHandler(EchoHandler())
				}
			}
			.bind(host: "127.0.0.1", port: 0)
			.get()
		let port = try #require(server.localAddress?.port)

		let connection = try await NetworkStack.tcp.connect(host: "127.0.0.1", port: port)
		let payload = Array("ping\n".utf8)
		try await connection.send(payload)

		var received: [UInt8] = []
		for try await chunk in connection.incoming {
			received += chunk
			if received.count >= payload.count { break }
		}
		#expect(received == payload)

		await connection.close()
		try await server.close()
	}

	@Test func `TCP connect to a closed port throws TransportError.connect`() async throws {
		// Bind then immediately close a listener so the port is known-dead.
		let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
			.bind(host: "127.0.0.1", port: 0)
			.get()
		let port = try #require(server.localAddress?.port)
		try await server.close()

		await #expect(throws: TransportError.self) {
			_ = try await NetworkStack.tcp.connect(host: "127.0.0.1", port: port)
		}
	}

	@Test func `UDP transport yields datagrams sent to the bound port`() async throws {
		// `listen` takes a caller-chosen port (marine feeds use fixed ports),
		// so probe for a free one instead of binding port 0.
		var datagrams: AsyncThrowingStream<[UInt8], any Error>?
		var boundPort = 0
		for candidate in 29_000..<29_050 {
			if let stream = try? await NetworkStack.udp.listen(port: candidate, multicastGroup: nil) {
				datagrams = stream
				boundPort = candidate
				break
			}
		}
		let stream = try #require(datagrams)

		let payload = Array("$GPRMC,123519,A*6A\r\n".utf8)
		// Re-send periodically until the listener observes one datagram, so the
		// test does not race the listener setup.
		let port = boundPort
		let sender = Task {
			let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
				.bind(host: "127.0.0.1", port: 0)
				.get()
			do {
				let destination = try SocketAddress(ipAddress: "127.0.0.1", port: port)
				while !Task.isCancelled {
					let envelope = AddressedEnvelope(
						remoteAddress: destination, data: ByteBuffer(bytes: payload))
					try await channel.writeAndFlush(envelope).get()
					try await Task.sleep(for: .milliseconds(20))
				}
			} catch {
				// Cancellation lands here; fall through to close the channel.
			}
			try? await channel.close().get()
		}

		var first: [UInt8]?
		for try await datagram in stream {
			first = datagram
			break
		}
		sender.cancel()
		_ = try? await sender.value

		#expect(first == payload)
	}
}

/// Writes every inbound chunk straight back to the peer.
private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		context.writeAndFlush(data, promise: nil)
	}
}
