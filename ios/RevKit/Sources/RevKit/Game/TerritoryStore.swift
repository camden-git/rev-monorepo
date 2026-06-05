import Foundation
import Observation
import SwiftData

/// multi-owner territory state using SwiftData (REF: docs/tech-stack.md §Local Storage).
///
/// owns a `ModelContext` and keeps an in-memory cache of every tile's `ClaimResolver.TileState` for
/// fast resolution + rendering, and persists `TileRecord`s as claims happen
///
/// the future server-authoritative update of the app replaces local resolution

@MainActor
@Observable
public final class TerritoryStore {
    private let context: ModelContext

    /// all players (local + seeded opponents)
    public private(set) var players: [Player] = []
    public private(set) var localPlayer: Player

    /// h3 cell -> current state, for both claim resolution and the per-player overlays
    public private(set) var tiles: [UInt64: ClaimResolver.TileState] = [:]

    /// true until the local player has chosen a home hex (`homeH3 == 0`)
    public private(set) var needsOnboarding: Bool

    public init(context: ModelContext) {
        self.context = context
        Seeder.seedIfEmpty(context)

        let loadedPlayers = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        let local = loadedPlayers.first(where: { $0.isLocal })
            ?? Player(displayName: "You", homeH3: 0, colorHex: "#3B82F6", isLocal: true)
        players = loadedPlayers
        localPlayer = local
        needsOnboarding = local.homeH3 == 0

        let records = (try? context.fetch(FetchDescriptor<TileRecord>())) ?? []
        for record in records {
            tiles[record.cellId] = ClaimResolver.TileState(
                ownerId: record.ownerId,
                claimScore: record.claimScore,
                lastDrivenAt: record.lastDrivenAt,
                isHome: record.isHome
            )
        }
    }

    // MARK: claiming

    /// resolve and (if the outcome mutates) persist a claim. `ownerId` defaults to the local player
    /// so the existing `DriveTracker` traversal/finalize calls keep working unchanged.
    ///
    /// returns the resolved `ClaimOutcome` so callers can account for what changed (the per-drive
    /// summary). `@discardableResult` keeps every existing call site - which actually ignores the result -
    /// source-compatible
    @discardableResult
    public func claim(
        _ cellIndex: UInt64,
        score: Double = 0,
        by ownerId: String? = nil,
        now: Date = .now
    ) -> ClaimResolver.ClaimOutcome {
        let claimant = ownerId ?? localPlayer.id
        let current = tiles[cellIndex]
        let outcome = ClaimResolver.resolve(
            current: current,
            claimantId: claimant,
            incomingScore: score,
            now: now
        )

        switch outcome {
        case .noChange:
            break
        case let .created(newScore):
            upsert(cellIndex, ownerId: claimant, score: newScore, isHome: false, now: now)
        case let .reinforced(newScore):
            // re-drive floor
            upsert(cellIndex, ownerId: claimant, score: newScore, isHome: current?.isHome ?? false, now: now)
        case let .captured(newScore):
            upsert(cellIndex, ownerId: claimant, score: newScore, isHome: false, now: now)
        }
        return outcome
    }

    // MARK: server sync

    /// merge server-authoritative tile state into the local cache + persistence
    ///
    /// called by `TileSyncEngine` on each delta-poll, the server's view replaces
    /// the provisional local resolution for the tiles it returns (REF:
    /// docs/tech-stack.md §Updates to Clients - Polling)
    ///
    /// FUTURE (server-side): `TileDTO.owner` is a PocketBase user id
    ///
    public func applyRemoteTiles(_ tiles: [TileDTO]) {
        for dto in tiles {
            upsert(dto.h3, ownerId: dto.owner, score: dto.claimScore, isHome: dto.isHome, now: dto.lastDrivenAt)
        }
    }

    // MARK: home hex

    /// every home hex owned by someone other than the local player
    public var otherPlayerHomeCells: Set<UInt64> {
        Set(tiles.filter { $0.value.isHome && $0.value.ownerId != localPlayer.id }.keys)
    }

    /// persist the local player's chosen home
    ///
    /// FUTURE (server-side)
    public func establishHome(at cell: UInt64, now: Date = .now) {
        localPlayer.homeH3 = Int64(h3: cell)
        try? context.save()
        upsert(cell, ownerId: localPlayer.id, score: 0, isHome: true, now: now)
        needsOnboarding = false
    }

    private func upsert(_ cellIndex: UInt64, ownerId: String, score: Double, isHome: Bool, now: Date) {
        let key = cellIndex.int64Storage
        let descriptor = FetchDescriptor<TileRecord>(predicate: #Predicate { $0.h3 == key })
        if let record = try? context.fetch(descriptor).first {
            record.ownerId = ownerId
            record.claimScore = score
            record.lastDrivenAt = now
            record.isHome = isHome
        } else {
            context.insert(TileRecord(
                h3: cellIndex,
                ownerId: ownerId,
                claimScore: score,
                lastDrivenAt: now,
                isHome: isHome
            ))
        }
        try? context.save()
        tiles[cellIndex] = ClaimResolver.TileState(
            ownerId: ownerId,
            claimScore: score,
            lastDrivenAt: now,
            isHome: isHome
        )
    }

    /// persist a finished drive (with its provisional summary) so it survives relaunch and is ready
    /// for the future upload queue REF: docs/tech-stack.md §Sync Model
    ///
    /// future server side: `summary` is the local provisional tall, on upload the backend returns
    /// the authoritative result and this record's summary is replaced
    public func record(_ drive: Drive, summary: DriveSummary? = nil) {
        context.insert(DriveRecord(drive: drive, summary: summary))
        try? context.save()
    }

    // MARK: history / stats

    /// every persisted drive, newest first (for the history list)
    ///
    /// future server side
    public func driveHistory() -> [DriveRecord] {
        let descriptor = FetchDescriptor<DriveRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// aggregate empire overview from the current tile cache + persisted drive summaries
    public func empireStats(now: Date = .now, atRiskFraction: Double = 0.5) -> EmpireStats {
        EmpireStats.compute(
            tiles: Array(tiles.values),
            ownedBy: localPlayer.id,
            driveSummaries: driveHistory().compactMap(\.summary),
            now: now,
            atRiskFraction: atRiskFraction
        )
    }

    // MARK: rendering / inspection

    /// cells currently owned by a player
    public func cells(ownedBy id: String) -> Set<UInt64> {
        Set(tiles.filter { $0.value.ownerId == id }.keys)
    }

    public func player(id: String) -> Player? {
        players.first { $0.id == id }
    }

    public func owner(of cell: UInt64) -> Player? {
        guard let ownerId = tiles[cell]?.ownerId else { return nil }
        return player(id: ownerId)
    }

    /// effective (decayed) score of a cell right now
    public func effectiveScore(of cell: UInt64, now: Date = .now) -> Double? {
        guard let state = tiles[cell] else { return nil }
        return Decay.effectiveScore(claimScore: state.claimScore, lastDrivenAt: state.lastDrivenAt, now: now)
    }

    // MARK: compatibility shims (local player's territory)

    public var claimedCells: Set<UInt64> { cells(ownedBy: localPlayer.id) }

    public func isClaimed(_ cellIndex: UInt64) -> Bool {
        tiles[cellIndex]?.ownerId == localPlayer.id
    }
}
