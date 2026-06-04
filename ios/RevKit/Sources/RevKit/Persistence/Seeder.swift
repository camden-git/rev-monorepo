import CoreLocation
import Foundation
import SwiftData
import SwiftyH3

/// first-launch seed so the local-only build has real opponents to compete with
///
/// everything is positioned relative to the test route (scripts/chicago-drive.gpx), which runs
/// east along `routeLat`:
///   - the local player is seeded with **no home** (`homeH3 == 0`), the home is chosen during
///     onboarding (see `RootView` / `OnboardingView` -> `TerritoryStore.establishHome`).
///     FUTURE (server-side): the home is assigned at signup in `backend/internal/game/`
///     off sign in with apple
///   - **Ada** (red) owns the first route cell, strong + freshly driven meaning her decayed score still
///     beats a normal drive, so that tile should NOT flip
///   - **Owen** (green) owns the last route cell and due to his score should be captued
///
/// REF: docs/game-design.md §Defense & Decay, §Home Hex
public enum Seeder {
    static let routeLat = 41.88070
    static let routeStartLng = -87.62980
    static let routeEndLng = -87.62680

    public static func seedIfEmpty(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        guard existing.isEmpty else { return }

        let start = CLLocationCoordinate2D(latitude: routeLat, longitude: routeStartLng)
        guard let startCell = H3Grid.cell(for: start) else { return }

        let routeCells = distinctRouteCells()
        let routeSet = Set(routeCells)
        let now = Date()
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 60 * 60)

        // local player starts with NO home (homeH3 == 0) so onboarding prompts for one
        let local = Player(displayName: "You", homeH3: 0, colorHex: "#3B82F6", isLocal: true)
        context.insert(local)

        // opponent tiles live on the cells the drive actually crosses
        let opponentCells = routeCells

        // Ada's home
        let neighbors = ((try? startCell.gridDisk(distance: 1)) ?? []).map(\.id)
        let adaHome = neighbors.first { !routeSet.contains($0) && $0 != startCell.id } ?? startCell.id

        let ada = Player(displayName: "Ada", homeH3: adaHome, colorHex: "#EF4444", isLocal: false)
        context.insert(ada)
        let owen = Player(displayName: "Owen", homeH3: opponentCells.last ?? startCell.id, colorHex: "#22C55E", isLocal: false)
        context.insert(owen)

        context.insert(TileRecord(h3: adaHome, ownerId: ada.id, claimScore: 0, lastDrivenAt: now, isHome: true))

        if let adaCell = opponentCells.first {
            // should not flip
            context.insert(TileRecord(h3: adaCell, ownerId: ada.id, claimScore: 80, lastDrivenAt: now, isHome: false))
        }
        if opponentCells.count >= 2, let boCell = opponentCells.last {
            // should flip
            context.insert(TileRecord(h3: boCell, ownerId: owen.id, claimScore: 80, lastDrivenAt: twoWeeksAgo, isHome: false))
        }

        try? context.save()
    }

    // helper function bullshit
    private static func distinctRouteCells() -> [UInt64] {
        var seen: Set<UInt64> = []
        var ordered: [UInt64] = []
        for lng in stride(from: routeStartLng, through: routeEndLng, by: 0.00003) {
            let coord = CLLocationCoordinate2D(latitude: routeLat, longitude: lng)
            guard let cell = H3Grid.cell(for: coord)?.id else { continue }
            if seen.insert(cell).inserted { ordered.append(cell) }
        }
        return ordered
    }
}
