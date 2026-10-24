#if canImport(CoreLocation)

	public import CoreLocation
	internal import Foundation

	#if canImport(CoreMotion)
		internal import CoreMotion
	#endif

	// MARK: - DeviceSensorsConfig

	/// Selects which on-device sensors to activate in a ``DeviceSensors`` stream.
	public struct DeviceSensorsConfig: Sendable {
		/// Enable GPS position updates via CoreLocation.
		///
		/// Available on iOS, macOS, watchOS, macCatalyst.
		public var gps: Bool
		/// Enable magnetic heading updates via `CLLocationManager`.
		///
		/// Available on iOS (+ macCatalyst) and watchOS — both have a magnetometer.
		/// Silent on macOS and tvOS where no compass hardware is present.
		public var heading: Bool
		/// Enable barometric pressure updates via `CMAltimeter`.
		///
		/// `CMAltimeter` lives inside CoreMotion, which is importable on macOS
		/// and tvOS, but Apple marks the class `@unavailable` on those platforms
		/// in the SDK because they have no barometer hardware. The flag is
		/// silently ignored there at compile time.
		public var barometer: Bool

		/// Creates a sensor configuration. All sensors are enabled by default.
		public init(gps: Bool = true, heading: Bool = true, barometer: Bool = true) {
			self.gps = gps
			self.heading = heading
			self.barometer = barometer
		}
	}

	// MARK: - DeviceSensors

	/// Streams live ``BoatMetric`` values from on-device sensors.
	///
	/// Emits the same **canonical metric names** as NMEA/Signal K decoders so that
	/// values flow directly into ``BoatMetricStore`` and compete correctly with
	/// network sources under the same priority rules.
	///
	/// | Sensor | Platform | Metric(s) emitted |
	/// |--------|----------|-------------------|
	/// | GPS | iOS · macOS · watchOS · macCatalyst | `lat`, `lon`, `altitude`, `SOG`, `COG` |
	/// | Compass | iOS · watchOS · macCatalyst | `HDG.magnetic`, `HDG.true` |
	/// | Barometer | iOS · watchOS | `pressure.atmospheric` |
	///
	/// `DeviceSensors` is `@MainActor` because `CLLocationManager` calls its
	/// delegate on the thread that created it (the main thread by default).
	///
	/// > Note: This type is not exposed in the CLI because Location Services
	/// > require a signed, bundled application with the appropriate
	/// > `NSLocationWhenInUseUsageDescription` key in its Info.plist.
	@MainActor
	public final class DeviceSensors: NSObject {

		private let config: DeviceSensorsConfig
		private let manager = CLLocationManager()
		private var continuation: AsyncThrowingStream<BoatMetric, any Error>.Continuation?
		/// Whether location updates have been asked for, so the authorisation
		/// callback — which can fire more than once — starts them only once.
		private var isUpdatingLocation = false

		// CMAltimeter lives in CoreMotion, which is importable on macOS and tvOS,
		// but Apple marks the class @unavailable on those two platforms in the SDK
		// (no barometer hardware).  Use canImport(CoreMotion) as the primary gate
		// and explicitly exclude the two SDK-restricted platforms.
		#if canImport(CoreMotion) && !os(macOS) && !os(tvOS) && !os(visionOS)
			private let altimeter = CMAltimeter()
		#endif

		/// Creates a sensor controller with the given configuration.
		public init(config: DeviceSensorsConfig = .init()) {
			self.config = config
			super.init()
			manager.delegate = self
		}

		/// Starts the enabled sensors and returns an asynchronous metric stream.
		///
		/// The stream continues until the caller discards it (which stops all
		/// sensors) or until CoreLocation reports a fatal error.
		public func stream() -> AsyncThrowingStream<BoatMetric, any Error> {
			AsyncThrowingStream { continuation in
				self.continuation = continuation

				// requestWhenInUseAuthorization() is available on iOS, watchOS,
				// macOS 10.15+, tvOS — covers every platform under canImport(CoreLocation).
				manager.requestWhenInUseAuthorization()

				// On a fresh install the answer arrives long after this call, so
				// location updates wait for it — asking and starting in the same
				// breath left the first launch with no position at all, and no
				// second chance once permission was granted.
				startLocationIfAuthorised()

				// Heading: startUpdatingHeading() is unavailable on macOS and tvOS
				// (no compass hardware, API_UNAVAILABLE in the SDK).  Negative guard
				// mirrors the barometer pattern and automatically covers iOS,
				// macCatalyst, watchOS, and visionOS (Vision Pro has a magnetometer).
				#if !os(macOS) && !os(tvOS) && !os(visionOS)
					if config.heading && CLLocationManager.headingAvailable() {
						manager.startUpdatingHeading()
					}
				#endif

				// Barometer: CoreMotion is importable on macOS and tvOS, but Apple
				// marks CMAltimeter @unavailable there (no barometer hardware).
				// Guard on canImport(CoreMotion) as the primary gate and exclude
				// the two SDK-restricted platforms explicitly.
				// isRelativeAltitudeAvailable() handles hardware absence at runtime
				// (e.g. older Apple Watch models without a barometer).
				#if canImport(CoreMotion) && !os(macOS) && !os(tvOS) && !os(visionOS)
					if config.barometer && CMAltimeter.isRelativeAltitudeAvailable() {
						// `@Sendable`, and capturing the continuation rather than
						// `self`, because CoreMotion does not always honour the queue
						// asked for: crash reports show this block arriving through the
						// permission path (`tccServiceMotionAccessAllowingMac:`) on a
						// dispatch queue of its own rather than the main one.
						//
						// Dropping the `self` capture was not enough on its own — a
						// closure's isolation comes from where it is written, not from
						// what it captures, and `DeviceSensors` is `@MainActor`, so the
						// block inherited that isolation and Swift checked the executor
						// on entry. Off the main queue the check fails and takes the
						// process with it (`_dispatch_assert_queue_fail`). `@Sendable`
						// makes the block non-isolated, so there is no check to fail;
						// the continuation is itself `Sendable` and safe to yield to
						// from any thread.
						altimeter.startRelativeAltitudeUpdates(to: .main) { @Sendable data, _ in
							guard let p = data?.pressure else { return }
							// CMAltimeter gives kPa; canonical unit is hPa (= mbar).
							// 1 kPa = 10 hPa → standard atmosphere 101.3 kPa = 1013 hPa.
							continuation.yield(
								BoatMetric(
									name: "pressure.atmospheric",
									value: p.doubleValue * 10,
									unit: "hPa"))
						}
					}
				#endif

				continuation.onTermination = { @Sendable [weak self] _ in
					Task { @MainActor [weak self] in self?.stopAll() }
				}
			}
		}

		private func stopAll() {
			// So a later stream starts its updates again rather than believing
			// they are already running.
			isUpdatingLocation = false
			continuation = nil
			#if !os(tvOS)
				manager.stopUpdatingLocation()
			#endif
			#if !os(macOS) && !os(tvOS) && !os(visionOS)
				manager.stopUpdatingHeading()
			#endif
			#if canImport(CoreMotion) && !os(macOS) && !os(tvOS) && !os(visionOS)
				altimeter.stopRelativeAltitudeUpdates()
			#endif
			continuation?.finish()
			continuation = nil
		}
	}

	// MARK: - CLLocationManagerDelegate

	extension DeviceSensors: @preconcurrency CLLocationManagerDelegate {

		/// Yields position, altitude, speed and course metrics from the latest fix.
		public func locationManager(
			_ manager: CLLocationManager,
			didUpdateLocations locations: [CLLocation]
		) {
			guard let loc = locations.last, let cont = continuation else { return }
			let ts = loc.timestamp

			// horizontalAccuracy < 0 means CLLocation could not determine a valid
			// coordinate (returns 0,0 on macOS/tvOS without GPS hardware, or when
			// location services are denied).  Never emit a spurious (0,0) fix.
			guard loc.horizontalAccuracy >= 0 else { return }

			cont.yield(BoatMetric(name: "lat", value: loc.coordinate.latitude, unit: "°", timestamp: ts))
			cont.yield(BoatMetric(name: "lon", value: loc.coordinate.longitude, unit: "°", timestamp: ts))

			if loc.verticalAccuracy >= 0 {
				// "altitude" matches the canonical name from GGA / N2K PGN 129029.
				cont.yield(BoatMetric(name: "altitude", value: loc.altitude, unit: "m", timestamp: ts))
			}
			if loc.speed >= 0 {
				// CLLocation.speed is in m/s; canonical SOG is in knots.
				cont.yield(BoatMetric(name: "SOG", value: loc.speed * 1.94384, unit: "kn", timestamp: ts))
			}
			if loc.course >= 0 {
				cont.yield(BoatMetric(name: "COG", value: loc.course, unit: "°", timestamp: ts))
			}
		}

		/// Starts location updates once, when the user has said yes.
		///
		/// Called both from ``stream()`` — for a session that already has
		/// permission — and from the authorisation callback, for the first launch
		/// where the answer comes later.
		private func startLocationIfAuthorised() {
			guard config.gps, continuation != nil, !isUpdatingLocation else { return }
			switch manager.authorizationStatus {
			case .notDetermined:
				return  // the prompt is still up; the callback will bring us back
			case .denied, .restricted:
				return  // reported from the callback, which knows it just changed
			default:
				break
			}
			isUpdatingLocation = true
			manager.desiredAccuracy = kCLLocationAccuracyBest
			#if os(tvOS)
				// tvOS has no continuous location updates — request a single fix.
				manager.requestLocation()
			#else
				manager.startUpdatingLocation()
			#endif
		}

		/// Starts the sensors, or ends the stream, once the user has answered.
		public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
			switch manager.authorizationStatus {
			case .notDetermined:
				break
			case .denied, .restricted:
				continuation?.finish(
					throwing: BoatCloudError.transport("CoreLocation: location access refused"))
			default:
				startLocationIfAuthorised()
			}
		}

		/// Ends the stream on fatal errors; transient location failures are ignored.
		public func locationManager(
			_ manager: CLLocationManager,
			didFailWithError error: any Error
		) {
			// `kCLErrorLocationUnknown` is transient: Core Location could not get a
			// fix *yet* but keeps trying, so a position usually follows. The watch
			// simulator emits it routinely while still delivering locations — tearing
			// the stream down here would drop a working feed. Ignore it; only end the
			// stream on genuinely fatal errors (e.g. authorisation denied).
			if let clError = error as? CLError, clError.code == .locationUnknown {
				return
			}
			continuation?.finish(throwing: BoatCloudError.transport("CoreLocation: \(error)"))
		}

		// didUpdateHeading is unavailable on macOS and tvOS (no compass hardware).
		// Negative guard mirrors startUpdatingHeading() above and covers iOS,
		// macCatalyst, watchOS, and visionOS automatically.
		#if !os(macOS) && !os(tvOS) && !os(visionOS)
			/// Yields magnetic and true heading metrics, plus derived magnetic variation.
			public func locationManager(
				_ manager: CLLocationManager,
				didUpdateHeading newHeading: CLHeading
			) {
				guard let cont = continuation else { return }
				cont.yield(
					BoatMetric(
						name: "HDG.magnetic",
						value: newHeading.magneticHeading,
						unit: "°", timestamp: newHeading.timestamp))
				if newHeading.trueHeading >= 0 {
					cont.yield(
						BoatMetric(
							name: "HDG.true",
							value: newHeading.trueHeading,
							unit: "°", timestamp: newHeading.timestamp))
					// The device compass reports true and magnetic heading from the same
					// sensor at the same instant, so their difference is a sound estimate
					// of the local magnetic variation. We only derive it here, never in
					// the shared store: on a real boat the two headings may come from
					// distinct instruments and subtracting them would yield nonsense
					// (e.g. an 80° variation). Convention: positive = East.
					var variation = newHeading.trueHeading - newHeading.magneticHeading
					if variation > 180 {
						variation -= 360
					} else if variation < -180 {
						variation += 360
					}
					cont.yield(
						BoatMetric(
							name: "magneticVariation",
							value: variation,
							unit: "°", timestamp: newHeading.timestamp))
				}
			}
		#endif
	}

#endif  // canImport(CoreLocation)
