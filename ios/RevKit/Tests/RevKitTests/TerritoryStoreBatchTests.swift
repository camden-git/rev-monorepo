import Foundation
import SwiftData
import Testing
@testable import RevKit

@MainActor
@Suite(.serialized)
struct TerritoryStoreBatchTests {
    private func makeContainer() -> ModelContainer {
        try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test func batchClaimSpeedsMatchesSingleClaimSpeedResolution() {
        let singleContainer = makeContainer()
        let batchContainer = makeContainer()
        let single = TerritoryStore(context: singleContainer.mainContext)
        let batch = TerritoryStore(context: batchContainer.mainContext)
        batch.reconcileLocalIdentity(to: single.localPlayer.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cells: [UInt64] = [0xA001, 0xA002, 0xA003]
        let scores: [UInt64: Double] = [
            cells[0]: 35,
            cells[1]: 18,
            cells[2]: 62,
        ]

        single.claim(cells[1], score: 2, by: "rival", now: now.addingTimeInterval(-60))
        batch.claim(cells[1], score: 2, by: "rival", now: now.addingTimeInterval(-60))

        var singleOutcomes: [UInt64: ClaimResolver.ClaimOutcome] = [:]
        for cell in cells {
            singleOutcomes[cell] = single.claimSpeed(cell, speedMph: scores[cell]!, now: now)
        }
        let batchOutcomes = batch.claimSpeeds(scores, now: now)

        #expect(batchOutcomes == singleOutcomes)
        #expect(batch.tiles == single.tiles)
    }

    @Test func batchClaimSpeedsBumpsTilesVersionOnce() {
        let container = makeContainer()
        let store = TerritoryStore(context: container.mainContext)
        let startVersion = store.tilesVersion

        store.claimSpeeds([
            0xB001: 30,
            0xB002: 45,
            0xB003: 60,
        ])

        #expect(store.tilesVersion == startVersion + 1)
        #expect(store.tiles.count == 3)
    }

    @Test func saveDebounceHintCanSwitchBetweenDriveAndIdleCadence() {
        let container = makeContainer()
        let store = TerritoryStore(context: container.mainContext)

        #expect(store.saveDebounce == .milliseconds(300))
        store.saveDebounce = .seconds(10)
        #expect(store.saveDebounce == .seconds(10))
        store.saveDebounce = .milliseconds(300)
        #expect(store.saveDebounce == .milliseconds(300))
    }
}
