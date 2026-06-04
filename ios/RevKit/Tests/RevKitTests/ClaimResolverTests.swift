import Foundation
import Testing
@testable import RevKit

struct ClaimResolverTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func state(
        owner: String,
        score: Double,
        drivenAgo: TimeInterval = 0,
        isHome: Bool = false
    ) -> ClaimResolver.TileState {
        ClaimResolver.TileState(
            ownerId: owner,
            claimScore: score,
            lastDrivenAt: now.addingTimeInterval(-drivenAgo),
            isHome: isHome
        )
    }

    @Test func unownedTileIsCreatedAtDriverScore() {
        let outcome = ClaimResolver.resolve(current: nil, claimantId: "me", incomingScore: 25, now: now)
        #expect(outcome == .created(score: 25))
    }

    @Test func homeHexIsInviolableEvenAgainstHugeScore() {
        let home = state(owner: "rival", score: 1, isHome: true)
        let outcome = ClaimResolver.resolve(current: home, claimantId: "me", incomingScore: 9999, now: now)
        #expect(outcome == .noChange)
    }

    @Test func reDrivingOwnTileTakesTheMax() {
        let mine = state(owner: "me", score: 40)
        #expect(ClaimResolver.resolve(current: mine, claimantId: "me", incomingScore: 55, now: now) == .reinforced(score: 55))
        #expect(ClaimResolver.resolve(current: mine, claimantId: "me", incomingScore: 30, now: now) == .reinforced(score: 40))
    }

    @Test func beatingDecayedOpponentCaptures() {
        // 80 mph driven 2 weeks ago decays to ~11 mph
        let stale = state(owner: "rival", score: 80, drivenAgo: 14 * 24 * 3600)
        // 25 mph > 11 mph
        let outcome = ClaimResolver.resolve(current: stale, claimantId: "me", incomingScore: 25, now: now)
        #expect(outcome == .captured(score: 25))
    }

    @Test func losingToFreshOpponentDoesNotFlip() {
        let fresh = state(owner: "rival", score: 80, drivenAgo: 0)
        let outcome = ClaimResolver.resolve(current: fresh, claimantId: "me", incomingScore: 25, now: now)
        #expect(outcome == .noChange)
    }

    @Test func exactTieIsLastWriteWins() {
        let other = state(owner: "rival", score: 30, drivenAgo: 0) // effective == 30
        let outcome = ClaimResolver.resolve(current: other, claimantId: "me", incomingScore: 30, now: now)
        #expect(outcome == .captured(score: 30))
    }

    @Test func decayMakesAStrongOpponentCapturableOverTime() {
        let claimedAt = now
        let opponent = ClaimResolver.TileState(ownerId: "rival", claimScore: 60, lastDrivenAt: claimedAt, isHome: false)
        let incoming = 30.0

        // 30 < 60, no flip
        #expect(ClaimResolver.resolve(current: opponent, claimantId: "me", incomingScore: incoming, now: claimedAt) == .noChange)

        // same claim after a week should flip due to decay
        let later = claimedAt.addingTimeInterval(Decay.tau)
        #expect(ClaimResolver.resolve(current: opponent, claimantId: "me", incomingScore: incoming, now: later) == .captured(score: incoming))
    }
}
