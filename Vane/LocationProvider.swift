import CoreLocation

/// One-off device locations, awaited rather than delegated. Asks for
/// permission only when a location is first requested, which is only ever
/// in answer to someone tapping My Location.
///
/// City-level accuracy is all weather needs, so approximate location, if
/// that's what someone grants, works just as well.
@MainActor final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, any Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Whether a location can be had without asking: permission was already
    /// given. Used at launch, where a permission prompt would be unexpected.
    var isAuthorized: Bool {
        Self.isAuthorized(manager.authorizationStatus)
    }

    /// The device's location, asking for permission first if it hasn't been
    /// asked for before.
    func currentLocation() async throws -> CLLocation {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard Self.isAuthorized(status) else { throw LocationError.denied }

        // A request already in flight is superseded rather than left hanging.
        locationContinuation?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        // The Mac has one grant, reported as Always.
        status == .authorizedAlways
        #else
        status == .authorizedAlways || status == .authorizedWhenInUse
        #endif
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // Also called once when the delegate is set, before anyone has
            // been asked; only an answer resumes the wait.
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            authorizationContinuation?.resume(returning: status)
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last else { return }
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            let denied = (error as? CLError)?.code == .denied
            locationContinuation?.resume(throwing: denied ? LocationError.denied : LocationError.unavailable)
            locationContinuation = nil
        }
    }
}
