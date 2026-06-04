import Foundation
import Testing
@testable import RevKit

struct DecayTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func zeroElapsedKeepsFullScore() {
        let score = Decay.effectiveScore(claimScore: 50, lastDrivenAt: now, now: now)
        #expect(abs(score - 50) < 1e-9)
    }

    @Test func oneTauDecaysToAboutThirtySevenPercent() {
        let lastDriven = now.addingTimeInterval(-Decay.tau)
        let score = Decay.effectiveScore(claimScore: 100, lastDrivenAt: lastDriven, now: now)
        #expect(abs(score - 100 * exp(-1)) < 1e-6) // aprox. 36.79
    }

    @Test func twoTauDecaysToAboutFourteenPercent() {
        let lastDriven = now.addingTimeInterval(-2 * Decay.tau)
        let score = Decay.effectiveScore(claimScore: 100, lastDrivenAt: lastDriven, now: now)
        #expect(abs(score - 100 * exp(-2)) < 1e-6) // aprox. 13.53
    }

    @Test func decreasesMonotonicallyWithTime() {
        let claim = 80.0
        var previous = Double.greatestFiniteMagnitude
        for days in stride(from: 0, through: 28, by: 1) {
            let lastDriven = now.addingTimeInterval(-Double(days) * 24 * 3600)
            let score = Decay.effectiveScore(claimScore: claim, lastDrivenAt: lastDriven, now: now)
            #expect(score <= previous)
            previous = score
        }
    }

    @Test func futureLastDrivenIsClampedToFullScore() {
        let future = now.addingTimeInterval(Decay.tau)
        let score = Decay.effectiveScore(claimScore: 42, lastDrivenAt: future, now: now)
        #expect(abs(score - 42) < 1e-9)
    }
}
