#if os(iOS)
import CoreLocation
import CoreMotion
import Foundation
import Observation

/// runs the record -> score -> claim loop from device movement
///
/// location strategy (REF: docs/tech-stack.md §Location Tracking Strategy):
///   1. default - significant-location-change monitoring (coarse, ~zero battery)
///   2. motion detected via CoreMotion (automotive/cycling/walking/running) pass to
///      `kCLLocationAccuracyBestForNavigation` at ~1 Hz and begin a `Drive`
///   3. stationary > 60s -> drop back to significant-change and end the drive
///
/// a manual `startDrive()` / `endDrive()` override exists because `CMMotionActivityManager` is
/// unavailable in the Simulator
@MainActor
@Observable
public final class DriveTracker {
    public private(set) var isRecording = false
    public private(set) var currentDrive: Drive?
    public private(set) var authorizationStatus: CLAuthorizationStatus
    public private(set) var currentSpeedMph: Double = 0

    public var claimedTileCount: Int { store.claimedCells.count }
    public var drivePath: [CLLocationCoordinate2D] {
        currentDrive?.rawPath.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } ?? []
    }

    private let store: TerritoryStore
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let delegate = LocationDelegate()

    private var isMoving = false
    private var stationaryDropTask: Task<Void, Never>?
    /// how long activity must read stationary before we drop back to significant-change
    private let stationaryGrace: Duration = .seconds(60)

    public init(store: TerritoryStore) {
        self.store = store
        self.authorizationStatus = locationManager.authorizationStatus
        delegate.tracker = self
        locationManager.delegate = delegate
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: lifecycle

    /// request permissions and enter the default (significant-change) tier
    public func start() {
        locationManager.requestAlwaysAuthorization()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        startActivityUpdates()
    }

    /// manually begin recording (sim)
    public func startDrive() {
        beginDriveIfNeeded()
        escalateAccuracy()
    }

    /// manually finish recording
    public func endDrive() {
        finalizeDrive()
        deescalateAccuracy()
    }

    // MARK: motion tier

    private func startActivityUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return } // false in Simulator
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let moving = activity.automotive || activity.cycling || activity.walking || activity.running
            let stationary = activity.stationary
            // handler is delivered on the main queue
            Task { @MainActor [weak self] in self?.activityChanged(moving: moving, stationary: stationary) }
        }
    }

    private func activityChanged(moving: Bool, stationary: Bool) {
        if moving {
            stationaryDropTask?.cancel()
            stationaryDropTask = nil
            if !isMoving { isMoving = true }
            beginDriveIfNeeded()
            escalateAccuracy()
        } else if stationary, isMoving, stationaryDropTask == nil {
            stationaryDropTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: stationaryGrace)
                guard !Task.isCancelled else { return }
                isMoving = false
                stationaryDropTask = nil
                finalizeDrive()
                deescalateAccuracy()
            }
        }
    }

    // MARK: location tier

    private func escalateAccuracy() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        if backgroundUpdatesPermitted {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.startUpdatingLocation()
    }

    private func deescalateAccuracy() {
        locationManager.stopUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    /// only flip on background updates if the app actually declares the capability
    private var backgroundUpdatesPermitted: Bool {
        guard authorizationStatus == .authorizedAlways,
              let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        else { return false }
        return modes.contains("location")
    }

    // MARK: drive recording

    private func beginDriveIfNeeded() {
        guard currentDrive == nil else { return }
        currentDrive = Drive(startedAt: Date())
        isRecording = true
    }

    fileprivate func ingest(_ locations: [CLLocation]) {
        guard currentDrive != nil else { return }
        for location in locations {
            let sample = GPSSample(
                timestamp: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speed: location.speed,
                accuracy: location.horizontalAccuracy
            )
            currentDrive?.rawPath.append(sample)
            currentSpeedMph = max(location.speed, 0) * TileScoring.mphPerMetersPerSecond

            if let tile = TileScoring.cell(lat: sample.lat, lng: sample.lng) {
                store.claim(tile)
            }
        }
    }

    private func finalizeDrive() {
        guard var drive = currentDrive else { return }
        drive.endedAt = Date()

        let cleaned = GPSOutlierFilter.filterOutliers(drive.rawPath)
        let scores = TileScoring.perTileScores(for: cleaned)
        drive.perTileScores = scores
        for (tile, score) in scores {
            store.claim(tile, score: score)
        }

        // persist the finished drive (uploaded = false), the future backend upload reads from here
        store.record(drive)
        currentDrive = drive
        isRecording = false
        currentSpeedMph = 0
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
    }

    /// forwards CoreLocation delegate callbacks onto the MainActor
    private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        weak var tracker: DriveTracker?

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            Task { @MainActor [weak tracker] in tracker?.ingest(locations) }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            Task { @MainActor [weak tracker] in tracker?.authorizationChanged(status) }
        }
    }
}
#endif
