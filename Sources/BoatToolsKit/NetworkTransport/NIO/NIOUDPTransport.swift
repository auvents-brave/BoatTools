#if !os(Windows)
	internal import Foundation
	internal import NIOCore
	internal import NIOPosix

	// MARK: - NIOUDPTransport

	/// SwiftNIO-backed ``UDPTransport`` for Apple platforms and Linux.
	///
	/// Binds `0.0.0.0` on the requested port with `SO_REUSEADDR`,
	/// `SO_REUSEPORT` and `SO_BROADCAST` so several listeners can share a
	/// broadcast feed, and optionally joins a multicast group.
	struct NIOUDPTransport: UDPTransport {

		func listen(port: Int, multicastGroup: String?) async throws
			-> AsyncThrowingStream<[UInt8], any Error>
		{
			let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
			let channel: any Channel
			do {
				channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
					.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
					.channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
					.channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
					.channelInitializer { channel in
						channel.eventLoop.makeCompletedFuture {
							try channel.pipeline.syncOperations
								.addHandler(DatagramStreamHandler(continuation: continuation))
						}
					}
					.bind(host: "0.0.0.0", port: port)
					.get()

				if let group = multicastGroup, let multicast = channel as? (any MulticastChannel) {
					let address = try SocketAddress(ipAddress: group, port: port)
					try await multicast.joinGroup(address).get()
				}
			} catch {
				continuation.finish()
				throw TransportError.connect("\(error)")
			}
			channel.closeFuture.whenComplete { _ in continuation.finish() }
			continuation.onTermination = { _ in channel.close(promise: nil) }
			return stream
		}
	}

	// MARK: - DatagramStreamHandler

	/// Forwards every inbound datagram payload to an `AsyncThrowingStream`
	/// continuation. Confined to a single NIO event loop.
	private final class DatagramStreamHandler: ChannelInboundHandler, @unchecked Sendable {
		typealias InboundIn = AddressedEnvelope<ByteBuffer>

		private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

		init(continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
			self.continuation = continuation
		}

		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var envelope = Self.unwrapInboundIn(data)
			guard let bytes = envelope.data.readBytes(length: envelope.data.readableBytes) else { return }
			continuation.yield(bytes)
		}

		func errorCaught(context: ChannelHandlerContext, error: any Error) {
			continuation.finish(throwing: TransportError.receive("\(error)"))
			context.close(promise: nil)
		}
	}

#endif  // !os(Windows)
