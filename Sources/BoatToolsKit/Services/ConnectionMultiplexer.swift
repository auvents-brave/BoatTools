public import Observation  // `@Observable` exposes the Observable conformance publicly

// MARK: - ConnectionMultiplexer

/// Feeds several live sources into a single ``BoatMetricStore`` at once.
///
/// The store already merges any number of piped streams, resolving conflicts by
/// source priority. This multiplexer adds the lifecycle on top: it owns one
/// consuming task per source, tracks each source's liveness, and tears them all
/// down together. Use it for the "multiplexer" connection mode, where the app
/// listens to every enabled source simultaneously.
///
/// Each source is added with a closure that pipes its stream into the store —
/// typically a call to ``BoatMetricStore/pipe(_:)``, ``BoatMetricStore/pipeSignalK(_:)``
/// or ``BoatMetricStore/pipeMetrics(_:)`` — keeping this type agnostic of the
/// stream's element type.
@MainActor
@Observable
public final class ConnectionMultiplexer {

	/// The liveness of a single multiplexed source.
	public enum SourceState: Sendable, Equatable {
		/// The source task is running and has not ended.
		case connecting
		/// The source's stream finished without error.
		case ended
		/// The source's stream threw; carries a human-readable message.
		case failed(String)
	}

	/// A source registered with the multiplexer.
	public struct Source: Identifiable, Sendable {
		/// Stable identifier assigned when the source was added.
		public let id: Int
		/// Display label for diagnostics and status read-outs.
		public let label: String
		/// The source's current liveness.
		public var state: SourceState
	}

	/// The registered sources, in the order they were added.
	public private(set) var sources: [Source] = []

	private let store: BoatMetricStore
	private var tasks: [Int: Task<Void, any Error>] = [:]
	private var monitors: [Int: Task<Void, Never>] = [:]
	private var sessions: [Int: NMEASession] = [:]
	private var nextID = 0

	/// Creates a multiplexer feeding the given store.
	/// - Parameter store: The shared metric store every source feeds into.
	public init(store: BoatMetricStore) {
		self.store = store
	}

	/// Adds a source and starts consuming it immediately.
	/// - Parameters:
	///   - label: A display label for the source.
	///   - connect: A closure that pipes the source's stream into the supplied
	///     store and returns the consuming task (e.g. `{ $0.pipe(stream) }`).
	/// - Returns: The new source's identifier.
	@discardableResult
	public func add(label: String, connect: (BoatMetricStore) -> Task<Void, any Error>) -> Int {
		let id = nextID
		nextID += 1
		let task = connect(store)
		tasks[id] = task
		sources.append(Source(id: id, label: label, state: .connecting))
		monitors[id] = Task { [weak self] in
			let outcome: SourceState
			do {
				try await task.value
				outcome = .ended
			} catch is CancellationError {
				return
			} catch {
				outcome = .failed(error.localizedDescription)
			}
			self?.setState(outcome, for: id)
		}
		return id
	}

	/// Adds a session-backed source: consumed into the store like any other,
	/// and additionally available for transmission — ``send(_:toDeviceAt:)``
	/// routes outbound messages through the registered sessions.
	///
	/// - Parameters:
	///   - label: A display label for the source.
	///   - session: The live session whose ``NMEASession/frames`` the closure
	///     consumes.
	///   - connect: A closure that pipes the session's stream into the
	///     supplied store and returns the consuming task
	///     (e.g. `{ $0.pipe(session.frames) }`).
	/// - Returns: The new source's identifier.
	@discardableResult
	public func add(
		label: String, session: NMEASession, connect: (BoatMetricStore) -> Task<Void, any Error>
	) -> Int {
		let id = add(label: label, connect: connect)
		sessions[id] = session
		return id
	}

	/// Sends a message towards a device on the network.
	///
	/// When `address` is given and some sessions have heard that source
	/// address, the message goes out on those connections alone — the device
	/// lives on their bus. Otherwise it is sent on every transmit-capable
	/// session: a device may be reachable through only one of them, and
	/// duplicate deliveries are harmless for idempotent commands.
	///
	/// - Parameters:
	///   - message: The message to transmit.
	///   - address: The target device's source address, when known.
	/// - Returns: The number of sessions the message was sent on.
	@discardableResult
	public func send(_ message: OutboundMessage, toDeviceAt address: UInt8? = nil) async -> Int {
		let capable = sessions.values.filter(\.isTransmitCapable)
		let heard = address.map { address in capable.filter { $0.device(at: address) != nil } } ?? []
		let targets = heard.isEmpty ? capable : heard
		var sent = 0
		for session in targets {
			if (try? await session.send(message)) != nil { sent += 1 }
		}
		return sent
	}

	/// Cancels every source and clears the source list. The store itself is left
	/// untouched — clear it separately if a clean slate is wanted.
	public func removeAll() {
		for task in tasks.values { task.cancel() }
		for monitor in monitors.values { monitor.cancel() }
		tasks.removeAll()
		monitors.removeAll()
		sessions.removeAll()
		sources.removeAll()
	}

	private func setState(_ state: SourceState, for id: Int) {
		guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
		sources[index].state = state
	}
}
