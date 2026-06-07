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
        self.gps       = gps
        self.heading   = heading
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

            if config.gps {
                manager.desiredAccuracy = kCLLocationAccuracyBest
                #if os(tvOS)
                // tvOS has no continuous location updates — request a single fix.
                manager.requestLocation()
                #else
                manager.startUpdatingLocation()
                #endif
            }

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
                altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                    guard let self, let p = data?.pressure else { return }
                    // CMAltimeter gives kPa; canonical unit is hPa (= mbar).
                    // 1 kPa = 10 hPa → standard atmosphere 101.3 kPa = 1013 hPa.
                    self.continuation?.yield(BoatMetric(
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

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, let cont = continuation else { return }
        let ts = loc.timestamp

        // horizontalAccuracy < 0 means CLLocation could not determine a valid
        // coordinate (returns 0,0 on macOS/tvOS without GPS hardware, or when
        // location services are denied).  Never emit a spurious (0,0) fix.
        guard loc.horizontalAccuracy >= 0 else { return }

        cont.yield(BoatMetric(name: "lat",      value: loc.coordinate.latitude,  unit: "°",  timestamp: ts))
        cont.yield(BoatMetric(name: "lon",      value: loc.coordinate.longitude, unit: "°",  timestamp: ts))

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

    public func locationManager(_ manager: CLLocationManager,
                                didFailWithError error: any Error) {
        continuation?.finish(throwing: BoatCloudError.transport("CoreLocation: \(error)"))
    }

    // didUpdateHeading is unavailable on macOS and tvOS (no compass hardware).
    // Negative guard mirrors startUpdatingHeading() above and covers iOS,
    // macCatalyst, watchOS, and visionOS automatically.
    #if !os(macOS) && !os(tvOS) && !os(visionOS)
    public func locationManager(_ manager: CLLocationManager,
                                didUpdateHeading newHeading: CLHeading) {
        guard let cont = continuation else { return }
        cont.yield(BoatMetric(name: "HDG.magnetic",
                              value: newHeading.magneticHeading,
                              unit: "°", timestamp: newHeading.timestamp))
        if newHeading.trueHeading >= 0 {
            cont.yield(BoatMetric(name: "HDG.true",
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
            cont.yield(BoatMetric(name: "magneticVariation",
                                  value: variation,
                                  unit: "°", timestamp: newHeading.timestamp))
        }
    }
    #endif
}

#endif // canImport(CoreLocation)
