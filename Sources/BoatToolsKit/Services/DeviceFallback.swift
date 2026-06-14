#if canImport(CoreLocation)

	public import Foundation

	// MARK: - DeviceFallback

	/// Automatically bridges device sensors into a ``BoatMetricStore`` whenever
	/// the equivalent data is absent from the network source.
	///
	/// Attach one instance to a running store right after calling
	/// ``BoatMetricStore/start()``:
	///
	/// ```swift
	/// let store = BoatMetricStore()
	/// store.start()
	/// store.pipe(nmeaTransport.connect(url: url))
	///
	/// #if canImport(CoreLocation)
	/// let fallback = DeviceFallback(store: store)
	/// fallback.start()
	/// #endif
	/// ```
	///
	/// ## How it works
	///
	/// Once per second `DeviceFallback` inspects the age of three metric families
	/// in the store:
	///
	/// | Capability | Store key checked | Default absence threshold |
	/// |------------|-------------------|--------------------------|
	/// | GPS        | `lat`             | 3 s                      |
	/// | Compass    | `HDG.true` / `HDG.magnetic` | 3 s             |
	/// | Barometer  | `pressure.atmospheric` | 180 s (3 min)       |
	///
	/// When a metric has been absent longer than its threshold, the corresponding
	/// on-device sensor (``DeviceSensors``) is started and its output is piped
	/// into the store via ``BoatMetricStore/pipeMetrics(_:)`` (Signal K priority,
	/// so any returning NMEA data takes precedence automatically).
	///
	/// As soon as the network metric reappears the sensor is stopped — the device
	/// GPS, compass, or barometer is never kept running unnecessarily.
	///
	/// ## Barometer threshold
	///
	/// GPS and compasses on a marine bus typically transmit every second.
	/// Dedicated barometric sensors vary widely: modern NMEA 2000 units
	/// broadcast at 0.5–1 Hz, but older NMEA 0183 instruments may only send once
	/// per minute. The default `barometerAbsenceThreshold` of 180 s (3 minutes)
	/// covers these slower devices; lower it if your setup is known to be fast.
	///
	/// ## Future: write-back to the bus
	///
	/// A logical next step is to *inject* the device readings back onto the NMEA
	/// bus so that the chartplotter and other instruments also see the fallback
	/// data. This requires:
	///   - NMEA 0183 sentence *formatters* (we only have parsers today).
	///   - A bidirectional ``NMEATransport`` write path (NIO channels already
	///     support full-duplex; it needs a public API surface).
	///   - Loop-prevention: the transport must not re-ingest sentences it
	///     just wrote (source-tag filtering).
	///   - For Signal K: a WebSocket `put` request to the server.
	///
	/// These are well-defined tasks but out of scope for now. The same
	/// bidirectional channel will also be needed for autopilot commands
	/// (heading set, MOB trigger, etc.).
	@MainActor
	public final class DeviceFallback {

		// MARK: Config

		/// Thresholds that control when each device sensor activates.
		public struct Config: Sendable {
			/// Seconds without a `lat` update before starting device GPS.
			///
			/// GPS sentences arrive every second on a healthy bus; 3 s means
			/// two or three missed frames before the device GPS kicks in.
			public var gpsAbsenceThreshold: TimeInterval = 3

			/// Seconds without a heading update (`HDG.true` or `HDG.magnetic`)
			/// before starting the device compass (iOS only).
			public var headingAbsenceThreshold: TimeInterval = 3

			/// Seconds without a `pressure.atmospheric` update before starting
			/// the device barometer (iOS only).
			///
			/// Default is 180 s (3 min) because some NMEA barometers are slow.
			/// Set to `0` if you always want the device barometer as a supplement.
			public var barometerAbsenceThreshold: TimeInterval = 180

			/// Creates a config with default thresholds.
			public init() {}
		}

		// MARK: Observable state

		/// `true` while the device GPS is supplying position data.
		public private(set) var isGPSActive: Bool = false
		/// `true` while the device compass is supplying heading data.
		public private(set) var isHeadingActive: Bool = false
		/// `true` while the device barometer is supplying pressure data.
		public private(set) var isBarometerActive: Bool = false

		// MARK: Private state

		private let store: BoatMetricStore
		/// Configuration controlling the device-sensor fallback behaviour.
		public var config: Config

		private var gpsSensors: DeviceSensors?
		private var headingSensors: DeviceSensors?
		private var baroSensors: DeviceSensors?

		private var gpsTask: (any Sendable)?  // Task<Void, any Error>
		private var headingTask: (any Sendable)?
		private var baroTask: (any Sendable)?

		private var monitorTask: Task<Void, Never>?

		// MARK: Init

		/// Creates a fallback controller attached to `store`.
		///
		/// - Parameters:
		///   - store: The ``BoatMetricStore`` to observe and feed device data into.
		///   - config: Absence thresholds. Uses defaults when omitted.
		public init(store: BoatMetricStore, config: Config = .init()) {
			self.store = store
			self.config = config
		}

		// MARK: Lifecycle

		/// Starts the 1-second evaluation loop.
		///
		/// Safe to call multiple times; subsequent calls are no-ops.
		public func start() {
			guard monitorTask == nil else { return }
			monitorTask = Task { [weak self] in
				while !Task.isCancelled {
					try? await Task.sleep(for: .seconds(1))
					guard !Task.isCancelled, let self else { break }
					self.evaluate()
				}
			}
		}

		/// Stops the evaluation loop and shuts down any active device sensors.
		public func stop() {
			monitorTask?.cancel()
			monitorTask = nil
			stopGPS()
			stopHeading()
			stopBaro()
		}

		// MARK: Evaluation (runs every second on the main actor)

		private func evaluate() {
			let now = Date()

			// GPS: key metric is `lat`
			if age(of: "lat", at: now) > config.gpsAbsenceThreshold {
				startGPS()
			} else {
				stopGPS()
			}

			// Heading: true heading preferred, fall back to magnetic
			let hdgAge = min(
				age(of: "HDG.true", at: now),
				age(of: "HDG.magnetic", at: now))
			if hdgAge > config.headingAbsenceThreshold {
				startHeading()
			} else {
				stopHeading()
			}

			// Barometer
			if age(of: "pressure.atmospheric", at: now) > config.barometerAbsenceThreshold {
				startBaro()
			} else {
				stopBaro()
			}
		}

		/// Returns seconds since `metricName` was last seen, or `.infinity` if
		/// the metric has never appeared in the store.
		private func age(of metricName: String, at now: Date) -> TimeInterval {
			guard let m = store.metrics[metricName] else { return .infinity }
			return now.timeIntervalSince(m.timestamp)
		}

		// MARK: Per-capability start / stop

		private func startGPS() {
			guard gpsSensors == nil else { return }
			let s = DeviceSensors(config: .init(gps: true, heading: false, barometer: false))
			gpsSensors = s
			let task = store.pipeMetrics(s.stream())
			gpsTask = task
			isGPSActive = true
		}

		private func stopGPS() {
			guard gpsSensors != nil else { return }
			(gpsTask as? Task<Void, any Error>)?.cancel()
			gpsTask = nil
			gpsSensors = nil
			isGPSActive = false
		}

		private func startHeading() {
			guard headingSensors == nil else { return }
			let s = DeviceSensors(config: .init(gps: false, heading: true, barometer: false))
			headingSensors = s
			let task = store.pipeMetrics(s.stream())
			headingTask = task
			isHeadingActive = true
		}

		private func stopHeading() {
			guard headingSensors != nil else { return }
			(headingTask as? Task<Void, any Error>)?.cancel()
			headingTask = nil
			headingSensors = nil
			isHeadingActive = false
		}

		private func startBaro() {
			guard baroSensors == nil else { return }
			let s = DeviceSensors(config: .init(gps: false, heading: false, barometer: true))
			baroSensors = s
			let task = store.pipeMetrics(s.stream())
			baroTask = task
			isBarometerActive = true
		}

		private func stopBaro() {
			guard baroSensors != nil else { return }
			(baroTask as? Task<Void, any Error>)?.cancel()
			baroTask = nil
			baroSensors = nil
			isBarometerActive = false
		}
	}

#endif  // canImport(CoreLocation)
