#if os(iOS)
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
        let tracker = DriveTracker(store: TerritoryStore(context: container.mainContext))

        tracker.startDrive()
        #expect(tracker.isRecording)

        tracker.endDrive()
        #expect(!tracker.isRecording)
        #expect(tracker.currentDrive == nil)

        tracker.startDrive()
        #expect(tracker.isRecording)
        #expect(tracker.currentDrive != nil)
    }
}
#endif
