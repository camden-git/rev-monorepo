import CoreLocation
import Foundation
import SwiftData
import SwiftyH3

/// first-launch bootstrap for the local player.
///
/// the local player starts with no home (`homeH3 == 0`), then onboarding chooses one
/// via `TerritoryStore.establishHome`
public enum Seeder {
    private static let legacyRouteLat = 41.88070
    private static let legacyRouteStartLng = -87.62980
    private static let legacyRouteEndLng = -87.62680

    public static func ensureLocalPlayer(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        guard !existing.contains(where: \.isLocal) else { return }

        let local = Player(displayName: "You", homeH3: 0, colorHex: "#3B82F6", isLocal: true)
        context.insert(local)
        try? context.save()
    }

    public static func removeLegacyFakeOpponents(_ context: ModelContext) {
        let players = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        let tileRecords = (try? context.fetch(FetchDescriptor<TileRecord>())) ?? []
        let legacyCells = legacySeedCells()

        var legacyOpponentIds: Set<String> = []
        for player in players {
            switch (player.isLocal, player.displayName, player.colorHex) {
            case (false, "Ada", "#EF4444"), (false, "Owen", "#22C55E"):
                let ownedCells = Set(tileRecords.filter { $0.ownerId == player.id }.map(\.cellId))
                if ownedCells.isSubset(of: legacyCells) {
                    legacyOpponentIds.insert(player.id)
                }
            default:
                break
            }
        }
        guard !legacyOpponentIds.isEmpty else { return }

        for record in tileRecords where legacyOpponentIds.contains(record.ownerId) {
            context.delete(record)
        }
        for player in players where legacyOpponentIds.contains(player.id) {
            context.delete(player)
        }
        try? context.save()
    }

    private static func legacySeedCells() -> Set<UInt64> {
        let routeCells = legacyDistinctRouteCells()
        var cells = Set(routeCells)

        let start = CLLocationCoordinate2D(latitude: legacyRouteLat, longitude: legacyRouteStartLng)
        if let startCell = H3Grid.cell(for: start) {
            let routeSet = Set(routeCells)
            let neighbors = ((try? startCell.gridDisk(distance: 1)) ?? []).map(\.id)
            let adaHome = neighbors.first { !routeSet.contains($0) && $0 != startCell.id } ?? startCell.id
            cells.insert(adaHome)
        }

        return cells
    }

    private static func legacyDistinctRouteCells() -> [UInt64] {
        var seen: Set<UInt64> = []
        var ordered: [UInt64] = []
        for lng in stride(from: legacyRouteStartLng, through: legacyRouteEndLng, by: 0.00003) {
            let coord = CLLocationCoordinate2D(latitude: legacyRouteLat, longitude: lng)
            guard let cell = H3Grid.cell(for: coord)?.id else { continue }
            if seen.insert(cell).inserted { ordered.append(cell) }
        }
        return ordered
    }
}
