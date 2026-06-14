public import Foundation

/// Coordinates exclusive connection ownership across multiple processes sharing the same AppGroup.
///
/// Exactly one process at a time holds the active connection (*primary*); all others operate in
/// *secondary* mode, consuming data written to the shared container.  If the primary crashes or
/// disconnects, a secondary automatically takes over.
///
/// ## How it works
///
/// Two timestamps in a shared `UserDefaults` entry act as a two-phase semaphore:
///
/// | `claimedAt` | `lastHeartbeat` | State | Secondary action |
/// |---|---|---|---|
/// | absent | absent | Unclaimed | Claim → connect |
/// | recent | `nil` | Claiming in progress | Wait |
/// | recent | recent | Active | Use AppGroup data |
/// | recent | stale | Dead | Claim → connect |
/// | old | `nil` | Claim expired (crashed mid-connect) | Claim → connect |
///
/// The primary writes `claimedAt` *before* connecting, acting as a lock that prevents
/// simultaneous connection attempts.  Once connected it starts a heartbeat loop.
/// Secondaries poll the shared entry and attempt a takeover whenever the primary's
/// heartbeat goes stale.
///
/// ## Usage
///
/// ```swift
/// let manager = ConnectionOwnershipManager(groupID: "group.com.example.app")
/// let role = await manager.start { try await device.connect() }
/// switch role {
/// case .primary:   // we're connected
/// case .secondary: // read from shared AppGroup container
/// }
/// ```
public actor ConnectionOwnershipManager {

	// MARK: Types

	/// The operational role assigned to this process.
	public enum Role: Sendable {
		/// This process owns the connection and drives the device.
		case primary
		/// Another process is connected; consume data from the shared AppGroup container.
		case secondary
	}

	private struct Token: Codable, Sendable {
		var ownerID: String
		var claimedAt: Date
		var lastHeartbeat: Date?  // nil while the connection attempt is in progress
	}

	private enum OwnershipState {
		case unclaimed
		case claimInProgress  // semaphore raised, connection not yet established
		case active  // heartbeat fresh — owner is alive
		case claimExpired  // claimed too long ago with no heartbeat (crashed mid-connect)
		case dead  // had a heartbeat that went stale
	}

	// MARK: Configuration

	/// How often the primary writes a liveness heartbeat.  Default: 5 s.
	public var heartbeatInterval: Duration = .seconds(5)
	/// Age at which a heartbeat is considered stale.  Default: 15 s.
	public var heartbeatStaleness: Duration = .seconds(15)
	/// Maximum time allowed between a claim and the first heartbeat before it is
	/// treated as a crashed mid-connect attempt.  Default: 30 s.
	public var claimingTimeout: Duration = .seconds(30)
	/// Delay after writing a claim before reading it back to resolve write races.
	/// Default: 150 ms.
	public var raceJitter: Duration = .milliseconds(150)

	// MARK: Private

	private let defaults: UserDefaults
	private let ownerID: String
	private static let storageKey = "connectionOwnership"

	private var heartbeatTask: Task<Void, Never>?
	private var watcherTask: Task<Void, Never>?

	// MARK: Initialisation

	/// Creates a manager backed by the given AppGroup container.
	///
	/// - Parameters:
	///   - groupID: AppGroup identifier shared across all participating processes.
	///   - ownerID: A string uniquely identifying this process instance.
	///              Defaults to a fresh UUID.
	public init(groupID: String, ownerID: String = UUID().uuidString) {
		guard let ud = UserDefaults(suiteName: groupID) else {
			preconditionFailure("Invalid or inaccessible AppGroup identifier: \(groupID)")
		}
		self.defaults = ud
		self.ownerID = ownerID
	}

	// MARK: Public API

	/// Starts the ownership process.
	///
	/// Waits if another process is currently connecting, then either wins primary
	/// and calls `connect`, or takes the secondary role and starts a background watcher.
	/// If `connect` throws, ownership is released and the secondary role is returned.
	///
	/// - Parameter connect: The connection work, invoked only when this process becomes primary.
	/// - Returns: The role assigned to this process.
	@discardableResult
	public func start(
		connect: @escaping @Sendable () async throws -> Void
	) async -> Role {
		let role = await acquireRole()

		switch role {
		case .primary:
			do {
				try await connect()
				startHeartbeat()
			} catch {
				releaseOwnership()
				startWatcher(connect: connect)
				return .secondary
			}

		case .secondary:
			startWatcher(connect: connect)
		}

		return role
	}

	/// Releases ownership and cancels all background tasks.  Call on graceful shutdown.
	public func stop() {
		heartbeatTask?.cancel()
		watcherTask?.cancel()
		releaseOwnership()
	}

	// MARK: Role acquisition

	private func acquireRole() async -> Role {
		while true {
			switch readState() {
			case .unclaimed, .claimExpired, .dead:
				if await tryClaim() { return .primary }
			// Lost the race — re-evaluate immediately

			case .claimInProgress:
				// Another process is mid-connect; wait before re-checking
				try? await Task.sleep(for: .seconds(3))

			case .active:
				return .secondary
			}
		}
	}

	/// Writes a claim, waits for `raceJitter`, then reads back to verify we won.
	///
	/// Returns `true` if this process's `ownerID` is still in the store.
	private func tryClaim() async -> Bool {
		write(Token(ownerID: ownerID, claimedAt: .now, lastHeartbeat: nil))
		try? await Task.sleep(for: raceJitter)
		return read()?.ownerID == ownerID
	}

	// MARK: State machine

	private func readState() -> OwnershipState {
		guard let token = read() else { return .unclaimed }

		let now = Date.now

		if let heartbeat = token.lastHeartbeat {
			return now.timeIntervalSince(heartbeat) < heartbeatStaleness.seconds
				? .active
				: .dead
		}

		// No heartbeat yet — classify by how long ago the claim was written
		return now.timeIntervalSince(token.claimedAt) < claimingTimeout.seconds
			? .claimInProgress
			: .claimExpired
	}

	// MARK: Heartbeat (primary)

	private func startHeartbeat() {
		heartbeatTask?.cancel()
		heartbeatTask = Task {
			while !Task.isCancelled {
				self.writeHeartbeat()
				try? await Task.sleep(for: self.heartbeatInterval)
			}
		}
	}

	private func writeHeartbeat() {
		guard var token = read(), token.ownerID == ownerID else {
			// Ownership was taken by another process
			heartbeatTask?.cancel()
			return
		}
		token.lastHeartbeat = .now
		write(token)
	}

	// MARK: Watcher (secondary → primary takeover)

	private func startWatcher(connect: @escaping @Sendable () async throws -> Void) {
		watcherTask?.cancel()
		watcherTask = Task {
			while !Task.isCancelled {
				try? await Task.sleep(for: self.heartbeatInterval)
				guard !Task.isCancelled else { break }

				let state = self.readState()
				guard state == .dead || state == .unclaimed || state == .claimExpired else {
					continue
				}

				guard await self.tryClaim() else { continue }  // lost the race, keep watching

				do {
					try await connect()
					self.startHeartbeat()
					return  // now primary, watcher's job is done
				} catch {
					self.releaseOwnership()
					// Connection failed — keep watching for the next opportunity
				}
			}
		}
	}

	// MARK: Persistence

	private func write(_ token: Token) {
		defaults.set(try? JSONEncoder().encode(token), forKey: Self.storageKey)
	}

	private func read() -> Token? {
		defaults.data(forKey: Self.storageKey)
			.flatMap { try? JSONDecoder().decode(Token.self, from: $0) }
	}

	private func releaseOwnership() {
		guard read()?.ownerID == ownerID else { return }
		defaults.removeObject(forKey: Self.storageKey)
	}
}

// MARK: - Helpers

extension Duration {
	/// `TimeInterval` equivalent of this duration.
	fileprivate var seconds: TimeInterval {
		let (s, attoseconds) = components
		return TimeInterval(s) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
	}
}
