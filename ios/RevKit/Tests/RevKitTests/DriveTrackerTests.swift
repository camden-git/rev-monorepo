#if os(iOS)
import CoreLocation
import SwiftData
import Testing
@testable import RevKit

@MainActor
struct DriveTrackerTests {
    @Test func manualDriveCanRestartAfterStopping() {
        let container = try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = TerritoryStore(context: container.mainContext)
        let tracker = DriveTracker(store: store)

        tracker.startDrive()
        #expect(tracker.isRecording)
        #expect(store.saveDebounce == .seconds(10))

        tracker.endDrive()
        #expect(!tracker.isRecording)
        #expect(tracker.currentDrive == nil)
        #expect(store.saveDebounce == .milliseconds(300))

        tracker.startDrive()
        #expect(tracker.isRecording)
        #expect(tracker.currentDrive != nil)
    }

    @Test func sameTilePassingSamplesClaimOncePerVisit() {
        let container = try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = TerritoryStore(context: container.mainContext)
        let tracker = DriveTracker(store: store)
        let coordinate = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        tracker.startDrive()
        tracker.ingest([
            location(coordinate, speedMph: 30, at: start),
            location(coordinate, speedMph: 30, at: start.addingTimeInterval(1)),
            location(coordinate, speedMph: 30, at: start.addingTimeInterval(2)),
        ])

        #expect(store.tilesVersion == 1)
        #expect(tracker.claimsThisDrive == 1)
    }

    @Test func sameTileClaimsWhenLaterSamplePassesFloor() {
        let container = try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = TerritoryStore(context: container.mainContext)
        let tracker = DriveTracker(store: store)
        let coordinate = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        tracker.startDrive()
        tracker.ingest([
            location(coordinate, speedMph: 5, at: start),
            location(coordinate, speedMph: 30, at: start.addingTimeInterval(1)),
        ])

        #expect(store.tilesVersion == 1)
        #expect(tracker.claimsThisDrive == 1)
    }

    private func location(
        _ coordinate: CLLocationCoordinate2D,
        speedMph: Double,
        at timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            courseAccuracy: 1,
            speed: speedMph / TileScoring.mphPerMetersPerSecond,
            speedAccuracy: 0.5,
            timestamp: timestamp
        )
    }
}
#endif
