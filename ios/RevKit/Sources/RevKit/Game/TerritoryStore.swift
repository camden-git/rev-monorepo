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

    /// all known players (local + roster-synced opponents)
    public private(set) var players: [Player] = []
    public private(set) var localPlayer: Player

    /// h3 cell -> current state, for both claim resolution and the per-player overlays
    public private(set) var tiles: [UInt64: ClaimResolver.TileState] = [:]
    @ObservationIgnored private var tileRecords: [UInt64: TileRecord] = [:]
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    /// true until the local player has chosen a home hex (`homeH3 == 0`)
    public private(set) var needsOnboarding: Bool

    public init(context: ModelContext) {
        self.context = context
        Seeder.removeLegacyFakeOpponents(context)
        Seeder.ensureLocalPlayer(context)

        let loadedPlayers = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        let local = loadedPlayers.first(where: { $0.isLocal })
            ?? Player(displayName: "You", homeH3: 0, colorHex: "#3B82F6", isLocal: true)
        players = loadedPlayers
        localPlayer = local
        needsOnboarding = local.homeH3 == 0

        let records = (try? context.fetch(FetchDescriptor<TileRecord>())) ?? []
        for record in records {
            let cellId = record.cellId
            tileRecords[cellId] = record
            tiles[cellId] = ClaimResolver.TileState(
                ownerId: record.ownerId,
                claimScore: record.claimScore,
                refSpeed: record.refSpeed,
                obsCount: record.obsCount,
                captures: record.captures,
                drivenSpeed: record.drivenSpeed,
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
            // a score-based capture (enclosure fill) carries no measured speed
            upsert(
                cellIndex,
                ownerId: claimant,
                score: newScore,
                refSpeed: current?.refSpeed ?? Strength.referenceSpeedPrior,
                obsCount: current?.obsCount ?? 0,
                captures: (current?.captures ?? 0) + 1,
                drivenSpeed: 0,
                isHome: false,
                now: now
            )
        }
        return outcome
    }

    /// Resolve a raw in-tile speed observation through Score Metric v2. The
    /// server stays authoritative, but this mirrors the conversion so live HUD
    /// and provisional local state use the same units as synced tiles.
    @discardableResult
    public func claimSpeed(
        _ cellIndex: UInt64,
        speedMph: Double,
        by ownerId: String? = nil,
        now: Date = .now
    ) -> ClaimResolver.ClaimOutcome {
        let claimant = ownerId ?? localPlayer.id
        let current = tiles[cellIndex]
        let currentRef = current?.refSpeed ?? Strength.referenceSpeedPrior
        let strength = Strength.strength(speedMph: speedMph, refSpeed: currentRef)
        let nextRef = Strength.updateReference(refSpeed: currentRef, speedMph: speedMph)
        let nextObs = (current?.obsCount ?? 0) + 1

        let outcome = ClaimResolver.resolve(
            current: current,
            claimantId: claimant,
            incomingScore: strength,
            now: now
        )

        switch outcome {
        case .noChange:
            if let current {
                // only the reference/obs learning step changed
                upsert(
                    cellIndex,
                    ownerId: current.ownerId,
                    score: current.claimScore,
                    refSpeed: nextRef,
                    obsCount: nextObs,
                    captures: current.captures,
                    drivenSpeed: current.drivenSpeed,
                    isHome: current.isHome,
                    now: current.lastDrivenAt
                )
            }
        case let .created(newScore):
            upsert(
                cellIndex,
                ownerId: claimant,
                score: newScore,
                refSpeed: nextRef,
                obsCount: nextObs,
                captures: 0,
                drivenSpeed: speedMph,
                isHome: false,
                now: now
            )
        case let .reinforced(newScore):
            // re-drive floor: record this drive's speed only when it set the new floor
            let drove = strength >= (current?.claimScore ?? 0) ? speedMph : (current?.drivenSpeed ?? 0)
            upsert(
                cellIndex,
                ownerId: claimant,
                score: newScore,
                refSpeed: nextRef,
                obsCount: nextObs,
                captures: current?.captures ?? 0,
                drivenSpeed: drove,
                isHome: current?.isHome ?? false,
                now: now
            )
        case let .captured(newScore):
            upsert(
                cellIndex,
                ownerId: claimant,
                score: newScore,
                refSpeed: nextRef,
                obsCount: nextObs,
                captures: (current?.captures ?? 0) + 1,
                drivenSpeed: speedMph,
                isHome: false,
                now: now
            )
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
    /// `TileDTO.owner` is a PocketBase user id, it lines up with the local player
    /// only after `reconcileLocalIdentity` has run, and with opponents only after
    /// `applyRemotePlayers` has seeded their `Player` rows
    public func applyRemoteTiles(_ tiles: [TileDTO]) {
        for dto in tiles {
            upsert(
                dto.h3,
                ownerId: dto.owner,
                score: dto.claimScore,
                refSpeed: dto.refSpeed,
                obsCount: dto.obsCount,
                captures: dto.captures,
                drivenSpeed: dto.drivenSpeed,
                isHome: dto.isHome,
                now: dto.lastDrivenAt
            )
        }
    }

    /// reconcile the local cache against the server's complete tile set
    public func reconcileTiles(authoritative remote: [TileDTO]) {
        let live = Set(remote.map(\.h3))
        let stale = tiles.keys.filter { !live.contains($0) }
        for cell in stale {
            if let record = tileRecords[cell] {
                context.delete(record)
            }
            tileRecords[cell] = nil
            tiles[cell] = nil
        }
        applyRemoteTiles(remote)
        saveImmediately()
    }

    /// collapse the locally-generated player id (a `UUID` created before sign-in)
    /// onto the authenticated PocketBase user id, re-pointing every tile the local
    /// player already owns
    ///
    /// idempotent: a no-op once `localPlayer.id` already equals `serverId`
    public func reconcileLocalIdentity(to serverId: String) {
        let oldId = localPlayer.id
        guard oldId != serverId else { return }

        // a stale `Player` row may already hold the server id (e.g. seeded by a
        // prior roster sync)
        if let duplicate = players.first(where: { $0.id == serverId && $0 !== localPlayer }) {
            context.delete(duplicate)
            players.removeAll { $0 === duplicate }
        }

        // re-point persisted tiles owned by the old local id
        let descriptor = FetchDescriptor<TileRecord>(predicate: #Predicate { $0.ownerId == oldId })
        for record in (try? context.fetch(descriptor)) ?? [] {
            record.ownerId = serverId
        }

        // re-point the in-memory cache
        for (cell, state) in tiles where state.ownerId == oldId {
            tiles[cell] = ClaimResolver.TileState(
                ownerId: serverId,
                claimScore: state.claimScore,
                refSpeed: state.refSpeed,
                obsCount: state.obsCount,
                captures: state.captures,
                drivenSpeed: state.drivenSpeed,
                lastDrivenAt: state.lastDrivenAt,
                isHome: state.isHome
            )
        }

        localPlayer.id = serverId
        saveImmediately()
    }

    /// upsert the player roster fetched from the server so opponents' tiles render
    /// with their color + name and tap-inspect resolves them
    public func applyRemotePlayers(_ remote: [PlayerDTO]) {
        for dto in remote {
            if let existing = players.first(where: { $0.id == dto.id }) {
                if !dto.displayName.isEmpty { existing.displayName = dto.displayName }
                if !dto.color.isEmpty { existing.colorHex = dto.color }
                if dto.homeH3 != 0 || existing.homeCell == 0 {
                    existing.homeH3 = Int64(h3: dto.homeH3)
                }
            } else {
                let player = Player(
                    id: dto.id,
                    displayName: dto.displayName.isEmpty ? "Player" : dto.displayName,
                    homeH3: dto.homeH3,
                    colorHex: dto.color.isEmpty ? "#888888" : dto.color,
                    isLocal: false
                )
                context.insert(player)
                players.append(player)
            }
        }
        saveImmediately()
    }

    /// adopt the authenticated display name for the local player
    public func setLocalDisplayName(_ name: String) {
        guard !name.isEmpty, localPlayer.displayName != name else { return }
        localPlayer.displayName = name
        saveImmediately()
    }

    /// update the local player's display name + map color from the profile settings screen
    public func updateLocalProfile(displayName: String, colorHex: String) {
        localPlayer.displayName = displayName
        localPlayer.colorHex = colorHex
        saveImmediately()
        // reassign to nudge @Observable so the map overlay re-renders in the new color
        players = players
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
        upsert(
            cell,
            ownerId: localPlayer.id,
            score: 0,
            refSpeed: Strength.referenceSpeedPrior,
            obsCount: 0,
            captures: 0,
            drivenSpeed: 0,
            isHome: true,
            now: now
        )
        needsOnboarding = false
        saveImmediately()
    }

    /// erase all on-device game state and reset to a fresh, pre-onboarding
    /// identity. used after the server account is deleted so nothing tied to the
    /// old account lingers locally (tiles, drives, roster, the local player id).
    public func wipeLocalData() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        for record in (try? context.fetch(FetchDescriptor<TileRecord>())) ?? [] {
            context.delete(record)
        }
        for drive in (try? context.fetch(FetchDescriptor<DriveRecord>())) ?? [] {
            context.delete(drive)
        }
        for player in (try? context.fetch(FetchDescriptor<Player>())) ?? [] {
            context.delete(player)
        }

        let fresh = Player(displayName: "You", homeH3: 0, colorHex: "#3B82F6", isLocal: true)
        context.insert(fresh)

        tiles = [:]
        tileRecords = [:]
        players = [fresh]
        localPlayer = fresh
        needsOnboarding = true
        try? context.save()
    }

    private func upsert(_ cellIndex: UInt64, ownerId: String, score: Double, isHome: Bool, now: Date) {
        let current = tiles[cellIndex]
        upsert(
            cellIndex,
            ownerId: ownerId,
            score: score,
            refSpeed: current?.refSpeed ?? Strength.referenceSpeedPrior,
            obsCount: current?.obsCount ?? 0,
            captures: current?.captures ?? 0,
            drivenSpeed: current?.drivenSpeed ?? 0,
            isHome: isHome,
            now: now
        )
    }

    private func upsert(
        _ cellIndex: UInt64,
        ownerId: String,
        score: Double,
        refSpeed: Double,
        obsCount: Int,
        captures: Int,
        drivenSpeed: Double,
        isHome: Bool,
        now: Date
    ) {
        if let record = tileRecords[cellIndex] {
            record.ownerId = ownerId
            record.claimScore = score
            record.refSpeed = refSpeed
            record.obsCount = obsCount
            record.captures = captures
            record.drivenSpeed = drivenSpeed
            record.lastDrivenAt = now
            record.isHome = isHome
        } else {
            let record = TileRecord(
                h3: cellIndex,
                ownerId: ownerId,
                claimScore: score,
                refSpeed: refSpeed,
                obsCount: obsCount,
                captures: captures,
                drivenSpeed: drivenSpeed,
                lastDrivenAt: now,
                isHome: isHome
            )
            context.insert(record)
            tileRecords[cellIndex] = record
        }
        tiles[cellIndex] = ClaimResolver.TileState(
            ownerId: ownerId,
            claimScore: score,
            refSpeed: refSpeed,
            obsCount: obsCount,
            captures: captures,
            drivenSpeed: drivenSpeed,
            lastDrivenAt: now,
            isHome: isHome
        )
        scheduleSave()
    }

    /// persist a finished drive (with its provisional summary) so it survives relaunch and is ready
    /// for the future upload queue REF: docs/tech-stack.md §Sync Model
    ///
    /// future server side: `summary` is the local provisional tall, on upload the backend returns
    /// the authoritative result and this record's summary is replaced
    public func record(_ drive: Drive, summary: DriveSummary? = nil) {
        context.insert(DriveRecord(drive: drive, summary: summary))
        saveImmediately()
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            pendingSaveTask = nil
            try? context.save()
        }
    }

    private func saveImmediately() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
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

    /// the player's consecutive-day drive streak from persisted drive history
    public func driveStreak(now: Date = .now) -> DriveStreak {
        DriveStreak.compute(driveDates: driveHistory().map(\.startedAt), now: now)
    }

    /// a single row of the leaderboard: a player and how much territory they currently hold
    public struct LeaderboardEntry: Identifiable, Sendable {
        public let playerId: String
        public let displayName: String
        public let colorHex: String
        public let isLocal: Bool
        public let tilesHeld: Int
        /// speed-weighted strength: sum of stored claim strength across held tiles
        public let empireStrength: Double
        public let empireScore: Double
        public var id: String { playerId }
    }

    /// rank every known player by empire strength, descending
    /// players with no tiles still appear
    public func leaderboard() -> [LeaderboardEntry] {
        var counts: [String: Int] = [:]
        var strengths: [String: Double] = [:]
        var scores: [String: Double] = [:]
        for state in tiles.values {
            counts[state.ownerId, default: 0] += 1
            strengths[state.ownerId, default: 0] += state.claimScore
            scores[state.ownerId, default: 0] += state.isHome ? 1 : Strength.tileValue(captures: state.captures)
        }
        return players
            .map { player in
                LeaderboardEntry(
                    playerId: player.id,
                    displayName: player.displayName,
                    colorHex: player.colorHex,
                    isLocal: player.isLocal,
                    tilesHeld: counts[player.id] ?? 0,
                    empireStrength: strengths[player.id] ?? 0,
                    empireScore: scores[player.id] ?? 0
                )
            }
            .sorted {
                $0.empireStrength != $1.empireStrength
                    ? $0.empireStrength > $1.empireStrength
                    : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    // MARK: rendering / inspection

    /// cells currently owned by a player
    public func cells(ownedBy id: String) -> Set<UInt64> {
        Set(tiles.filter { $0.value.ownerId == id }.keys)
    }

    public func cells(ownedBy id: String, within visibleCells: Set<UInt64>) -> Set<UInt64> {
        guard !visibleCells.isEmpty else { return [] }
        return Set(tiles.compactMap { cell, state in
            state.ownerId == id && visibleCells.contains(cell) ? cell : nil
        })
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
