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

    /// provisional recap of the most recently finished drive, drives the post-drive summary UI
    /// nil while a drive is in progress (cleared when a new drive begins)
    public private(set) var lastDriveSummary: DriveSummary?
    /// the just-finished drive's outlier-filtered path as map coordinates
    public private(set) var lastDrivePath: [CLLocationCoordinate2D] = []

    /// personal records set by the most recently finished drive (empty if none / first drive)
    public private(set) var lastDrivePRs: [DrivePRKind] = []

    /// live HUD: the tile currently being driven on
    /// cleared when the drive ends
    public private(set) var contestedOwnerName: String?
    public private(set) var contestedScore: Double?

    public var claimedTileCount: Int { store.claimedCells.count }
    public var drivePath: [CLLocationCoordinate2D] {
        currentDrive?.rawPath.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } ?? []
    }

    public var drivePathSegments: [[CLLocationCoordinate2D]] {
        TileScoring.segmentedPath(currentDrive?.rawPath ?? [])
    }

    /// live count of tiles gained this drive
    public var claimsThisDrive: Int {
        let me = store.localPlayer.id
        return beforeOwners.reduce(0) { count, entry in
            store.tiles[entry.key]?.ownerId == me && entry.value != me ? count + 1 : count
        }
    }

    /// live distance driven this drive (meters), using the same moving-segment filter as scoring.
    /// cached and refreshed on each (throttled) live rescore + at finalize, so the HUD reading it
    /// every second doesn't re-filter the whole path on every access
    public private(set) var driveDistanceMeters: Double = 0

    /// which motion types are allowed to auto-start a drive
    public let autoStart: AutoStartPreferences

    private let store: TerritoryStore
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let delegate = LocationDelegate()

    private var isMoving = false
    private var stationaryDropTask: Task<Void, Never>?

    /// set when the user manually ends a drive while still in motion
    private var autoStartSuppressed = false

    /// live enclosure-closure tracking, reset per drive
    private var visitedTiles: Set<UInt64> = []
    private var ownedAtDriveStart: Set<UInt64> = []
    private var hasLeftOwned = false
    private var lastTile: UInt64?

    /// per-drive net-diff accounting, reset per drive
    /// owner of each touched cell when the drive first claimed it (nil value = was unowned)
    private var beforeOwners: [UInt64: String?] = [:]
    /// cells gained as enclosed interior this drive
    private var enclosedCells: Set<UInt64> = []
    /// how long activity must read stationary before we drop back to significant-change
    private let stationaryGrace: Duration = .seconds(60)

    /// timestamp of the last live full-path rescore
    private var lastLiveRescore: Date = .distantPast
    private let liveRescoreInterval: TimeInterval = 3

    /// invoked on the throttled live rescore with the raw GPS samples recorded
    /// since the last flush, wired by the app to `SyncService` so the server scores,
    /// resolves, and broadcasts the resulting captures to others mid-drive
    public var onLiveClaims: (([GPSSample]) -> Void)?
    /// count of rawPath samples already streamed, so each tick sends only the new tail
    private var liveFlushedSampleCount = 0

    public init(store: TerritoryStore, autoStart: AutoStartPreferences = AutoStartPreferences()) {
        self.store = store
        self.autoStart = autoStart
        self.authorizationStatus = locationManager.authorizationStatus
        delegate.tracker = self
        locationManager.delegate = delegate
        locationManager.activityType = .automotiveNavigation
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
        autoStartSuppressed = false // opting back in
        beginDriveIfNeeded()
        escalateAccuracy()
    }

    /// manually finish recording. suppress motion auto-restart so Stop sticks while the car is still
    /// moving
    public func endDrive() {
        autoStartSuppressed = true
        finalizeDrive()
        deescalateAccuracy()
    }

    // MARK: motion tier

    private func startActivityUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return } // false in Simulator
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            // snapshot the per-type flags off CMMotionActivity before hopping to the actor
            var active: Set<AutoStartPreferences.Activity> = []
            if activity.automotive { active.insert(.automotive) }
            if activity.cycling { active.insert(.cycling) }
            if activity.walking { active.insert(.walking) }
            if activity.running { active.insert(.running) }
            let stationary = activity.stationary
            // handler is delivered on the main queue
            Task { @MainActor [weak self] in self?.activityChanged(active: active, stationary: stationary) }
        }
    }

    private func activityChanged(active: Set<AutoStartPreferences.Activity>, stationary: Bool) {
        let moving = !active.isEmpty
        // a drive only auto begins for activity types the user left enabled; any motion still keeps
        // an in-progress drive alive (we only gate starting, not continuing)
        let autoStartAllowed = active.contains { autoStart.isEnabled($0) }
        if moving {
            stationaryDropTask?.cancel()
            stationaryDropTask = nil
            if !isMoving { isMoving = true }
            guard !autoStartSuppressed, autoStartAllowed else { return }
            beginDriveIfNeeded()
            escalateAccuracy()
        } else if stationary, isMoving, stationaryDropTask == nil {
            stationaryDropTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: stationaryGrace)
                guard !Task.isCancelled else { return }
                isMoving = false
                stationaryDropTask = nil
                // the trip actually ended
                autoStartSuppressed = false
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
        visitedTiles = []
        ownedAtDriveStart = store.claimedCells
        hasLeftOwned = false
        lastTile = nil
        beforeOwners = [:]
        enclosedCells = []
        contestedOwnerName = nil
        contestedScore = nil
        lastDriveSummary = nil
        lastDrivePath = []
        lastDrivePRs = []
        driveDistanceMeters = 0
        lastLiveRescore = .distantPast
        liveFlushedSampleCount = 0
    }

    /// remember who owned a cell the first time this drive claims it, so the summary can diff
    /// against pre-drive ownership
    private func recordBeforeOwner(_ cell: UInt64) {
        if beforeOwners.index(forKey: cell) == nil {
            beforeOwners[cell] = store.tiles[cell]?.ownerId
        }
    }

    fileprivate func ingest(_ locations: [CLLocation]) {
        guard currentDrive != nil else { return }
        for location in locations {
            // negative speedAccuracy means the Doppler speed is invalid, but the
            // speed value itself can still be non-negative garbage, so gate on it
            let dopplerSpeed = location.speedAccuracy >= 0 ? location.speed : -1
            let sample = GPSSample(
                timestamp: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speed: dopplerSpeed,
                accuracy: location.horizontalAccuracy
            )
            currentDrive?.rawPath.append(sample)
            currentSpeedMph = max(dopplerSpeed, 0) * TileScoring.mphPerMetersPerSecond

            // out-of-Chicago tiles are skipped entirely (no claim, no HUD, no enclosure
            // trail), mirroring the server which silently refuses to create them
            if let tile = TileScoring.cell(lat: sample.lat, lng: sample.lng), Geofence.containsCell(tile) {
                if tile != lastTile {
                    let ownedAtStart = ownedAtDriveStart.contains(tile)
                    // closing the loop = touching a cell we've already crossed this drive, or
                    // reentering territory we owned when the drive began
                    if visitedTiles.contains(tile) || (hasLeftOwned && ownedAtStart) {
                        captureEnclosureIfClosed(now: sample.timestamp)
                    }
                    if !ownedAtStart { hasLeftOwned = true }
                    visitedTiles.insert(tile)
                    lastTile = tile
                    let owner = store.owner(of: tile)
                    contestedOwnerName = owner?.displayName ?? "Unclaimed"
                    contestedScore = store.effectiveScore(of: tile, now: sample.timestamp)
                }
                recordBeforeOwner(tile)
                store.claim(tile)
            }
        }

        // re-score the drive so far for live HUD feedback
        let now = locations.last?.timestamp ?? Date()
        if now.timeIntervalSince(lastLiveRescore) >= liveRescoreInterval {
            lastLiveRescore = now
            applyPerTileScores() // local optimistic HUD; the server re-scores authoritatively
            flushLiveClaims()
        }
    }

    /// stream the raw GPS samples recorded since the last flush so the server scores
    /// and resolves them authoritatively (REF: server-authoritative scoring). an
    /// overlap of one sample keeps the segment straddling the flush boundary from
    /// being dropped between batches.
    private func flushLiveClaims() {
        guard let onLiveClaims, let path = currentDrive?.rawPath else { return }
        guard path.count > liveFlushedSampleCount else { return }
        let start = max(0, liveFlushedSampleCount - 1)
        let batch = Array(path[start...])
        liveFlushedSampleCount = path.count
        guard batch.count >= 2 else { return }
        onLiveClaims(batch)
    }

    /// (re)compute and apply the per-tile distance-weighted scores for the drive so far, and refresh
    /// the cached `driveDistanceMeters`. used both live (throttled) and at finalize. a tile's score
    /// stabilizes once you leave it, so the re-drive floor in `store.claim` keeps the right value.
    /// pass `cleaned` to reuse an already-filtered path and avoid a redundant filter pass
    @discardableResult
    private func applyPerTileScores(cleaned: [GPSSample]? = nil) -> [UInt64: Double] {
        guard let drive = currentDrive else { return [:] }
        let cleanedPath = cleaned ?? GPSOutlierFilter.filterOutliers(drive.rawPath)
        let scores = TileScoring.perTileScores(for: cleanedPath)
        for (tile, score) in scores where Geofence.containsCell(tile) {
            recordBeforeOwner(tile)
            store.claimSpeed(tile, speedMph: score)
        }
        driveDistanceMeters = TileScoring.movementStats(for: cleanedPath).distanceMeters
        return scores
    }

    /// the second a loop closes, score + claim its interior (REF: docs/game-design.md
    /// §Trails & Enclosure)
    private func captureEnclosureIfClosed(now: Date) {
        guard let drive = currentDrive else { return }
        let cleaned = GPSOutlierFilter.filterOutliers(drive.rawPath)
        let crossed = TileScoring.tilesCrossed(for: cleaned)
        let scores = TileScoring.perTileScores(for: cleaned)
        let strengths = Dictionary(uniqueKeysWithValues: scores.map { tile, rawScore in
            let refSpeed = store.tiles[tile]?.refSpeed ?? Strength.referenceSpeedPrior
            return (tile, Strength.strength(speedMph: rawScore, refSpeed: refSpeed))
        })
        let loopScore = strengths.isEmpty ? 0 : strengths.values.reduce(0, +) / Double(strengths.count)
        // wall = trail ∪ territory owned BEFORE this drive
        // using the start snapshot (not live claimedCells) keeps freshly-captured interior out of the wall,
        // so re-triggers re-compute the same interior idempotently instead of recursively filling inward.
        // exclude the home hex so a loop drawn around it doesn't make home's neighbors a max-score ring of "padding"
        let home = store.localPlayer.homeCell
        let walls = ownedAtDriveStart.subtracting([home])
        let enclosed = Enclosure.enclose(trail: crossed, owned: walls, loopScore: loopScore)
        // dont claim zero scores, the home hex, or interior outside Chicago (the server's
        // enclosure resolution geofences each interior cell the same way)
        for (tile, score) in enclosed.scoredInterior where score > 0 && tile != home && Geofence.containsCell(tile) {
            recordBeforeOwner(tile)
            enclosedCells.insert(tile)
            store.claim(tile, score: score, now: now)
        }
    }

    private func finalizeDrive() {
        guard var drive = currentDrive else { return }
        drive.endedAt = Date()

        // filter once
        let cleaned = GPSOutlierFilter.filterOutliers(drive.rawPath)
        let finalScores = applyPerTileScores(cleaned: cleaned)
        drive.perTileScores = finalScores

        let summary = buildSummary(perTileScores: finalScores, cleaned: cleaned)
        lastDriveSummary = summary
        lastDrivePath = cleaned.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }

        let prior = store.driveHistory().compactMap(\.summary)
        lastDrivePRs = DrivePRs.newRecords(for: summary, against: prior)

        // persist the finished drive + its provisional summary (uploaded = false), the future
        // backend upload reads from here and returns the authoritative result
        store.record(drive, summary: summary)
        currentDrive = nil
        isRecording = false
        currentSpeedMph = 0
        contestedOwnerName = nil
        contestedScore = nil
    }

    /// diff the drive's net per-tile ownership change into a `DriveSummary` (REF:
    /// docs/game-design.md §Claiming)
    private func buildSummary(perTileScores: [UInt64: Double], cleaned: [GPSSample]) -> DriveSummary {
        let me = store.localPlayer.id
        let changes: [TileChange] = beforeOwners.map { cell, before in
            TileChange(
                cell: cell,
                previousOwner: before,
                finalOwner: store.tiles[cell]?.ownerId ?? "",
                provenance: enclosedCells.contains(cell) ? .enclosure : .direct
            )
        }
        let stats = TileScoring.movementStats(for: cleaned)
        let metrics = DriveSummary.Metrics(
            distanceMeters: stats.distanceMeters,
            movingTime: stats.movingTime,
            perTileScores: perTileScores
        )
        return DriveSummary.build(changes: changes, localPlayerId: me, metrics: metrics)
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
