import Foundation
import CoreLocation

/// Always-on background location as an AsyncStream for the fusion engine.
/// Requires NSLocationAlwaysAndWhenInUseUsageDescription + the `location`
/// background mode (docs §2.6).
public final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<CLLocation>.Continuation?
    public private(set) lazy var locations: AsyncStream<CLLocation> = AsyncStream { c in
        self.continuation = c
    }

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 25
        manager.activityType = .automotiveNavigation
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        #endif
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locs: [CLLocation]) {
        for loc in locs where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 100 {
            continuation?.yield(loc)
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didFailWithError error: Error) {
        // GPS drop is survivable: fusion falls back to CAN speed + Tessie
        // location within its freshness windows.
    }
}
