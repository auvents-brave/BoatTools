#if !os(Windows)
	internal import NIOCore
	internal import NIOPosix

	// MARK: - NIOTCPTransport

	/// SwiftNIO-backed ``TCPTransport`` for Apple platforms and Linux.
	///
	/// Connections run on the shared singleton event loop group; each
	/// connection owns its channel and nothing else.
	struct NIOTCPTransport: TCPTransport {

		func connect(host: String, port: Int) async throws -> any TCPConnection {
			let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
			let channel: any Channel
			do {
				channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
					.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
					.channelInitializer { channel in
						channel.eventLoop.makeCompletedFuture {
							try channel.pipeline.syncOperations
								.addHandler(ByteStreamHandler(continuation: continuation))
						}
					}
					.connect(host: host, port: port)
					.get()
			} catch {
				continuation.finish()
				throw TransportError.connect("\(error)")
			}
			channel.closeFuture.whenComplete { _ in continuation.finish() }
			continuation.onTermination = { _ in channel.close(promise: nil) }
			return NIOTCPConnection(channel: channel, incoming: stream)
		}
	}

	// MARK: - NIOTCPConnection

	/// One NIO-backed TCP connection.
	struct NIOTCPConnection: TCPConnection {
		let channel: any Channel
		let incoming: AsyncThrowingStream<[UInt8], any Error>

		func send(_ bytes: [UInt8]) async throws {
			do {
				try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
			} catch {
				throw TransportError.send("\(error)")
			}
		}

		func close() async {
			try? await channel.close().get()
		}
	}

	// MARK: - ByteStreamHandler

	/// Forwards every inbound chunk to an `AsyncThrowingStream` continuation.
	///
	/// Confined to a single NIO event loop — `channelRead` calls are never
	/// concurrent for the same handler instance; the continuation itself is
	/// thread-safe.
	final class ByteStreamHandler: ChannelInboundHandler, @unchecked Sendable {
		typealias InboundIn = ByteBuffer

		private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

		init(continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
			self.continuation = continuation
		}

		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var buffer = Self.unwrapInboundIn(data)
			guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
			continuation.yield(bytes)
		}

		func errorCaught(context: ChannelHandlerContext, error: any Error) {
			continuation.finish(throwing: TransportError.receive("\(error)"))
			context.close(promise: nil)
		}
	}

#endif  // !os(Windows)
