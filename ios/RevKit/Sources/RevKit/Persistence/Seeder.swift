import CoreLocation
import Foundation
import SwiftData
import SwiftyH3

/// first-launch seed so the local-only build has a home hex and real opponents to compete with
/// everything is positioned relative to the test route (scripts/chicago-drive.gpx), which runs
/// east along `routeLat`:
///   - the local player's **home** sits on an off-route neighbor of the start cell, so a drive
///     doesn't just reinforce it (home inviolability is exercised by the unit tests)
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

        // home: a neighbor of the start cell that the route does not cross
        let neighbors = ((try? startCell.gridDisk(distance: 1)) ?? []).map(\.id)
        let homeCell = neighbors.first { !routeSet.contains($0) && $0 != startCell.id } ?? startCell.id

        let local = Player(displayName: "You", homeH3: homeCell, colorHex: "#3B82F6", isLocal: true)
        context.insert(local)
        context.insert(TileRecord(h3: homeCell, ownerId: local.id, claimScore: 0, lastDrivenAt: now, isHome: true))

        // opponent tiles live on the cells the drive actually crosses (minus home)
        let opponentCells = routeCells.filter { $0 != homeCell }

        let ada = Player(displayName: "Ada", homeH3: opponentCells.first ?? startCell.id, colorHex: "#EF4444", isLocal: false)
        context.insert(ada)
        let owen = Player(displayName: "Owen", homeH3: opponentCells.last ?? startCell.id, colorHex: "#22C55E", isLocal: false)
        context.insert(owen)

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
