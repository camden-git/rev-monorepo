import Foundation
import Testing
@testable import RevKit

struct DrivePRsTests {
    private func summary(
        claimed: Int = 0,
        captured: [String: Int] = [:],
        reinforced: Int = 0,
        enclosed: Int = 0,
        distance: Double = 0,
        moving: TimeInterval = 0
    ) -> DriveSummary {
        DriveSummary(
            tilesClaimed: claimed,
            capturedByOpponent: captured,
            tilesReinforced: reinforced,
            tilesEnclosed: enclosed,
            distanceMeters: distance,
            movingTime: moving
        )
    }

    // MARK: newRecords

    /// the first ever drive sets no records (empty prior)
    @Test func firstDriveSetsNoRecords() {
        let drive = summary(claimed: 50, distance: 10_000, moving: 600)
        #expect(DrivePRs.newRecords(for: drive, against: []) == [])
    }

    /// beating a prior best records that kind
    @Test func beatingPriorBestRecordsKind() {
        let prior = [summary(claimed: 5, distance: 1000)]
        let drive = summary(claimed: 10, distance: 500) // more tiles, less distance
        let records = DrivePRs.newRecords(for: drive, against: prior)
        #expect(records.contains(.tilesGained))
        #expect(records.contains(.tilesDriven))
        #expect(!records.contains(.distance))
    }

    /// a tie does not count as a new record (strictly greater required)
    @Test func tieIsNotARecord() {
        let prior = [summary(claimed: 8)]
        let drive = summary(claimed: 8)
        #expect(!DrivePRs.newRecords(for: drive, against: prior).contains(.tilesGained))
    }

    /// a value of 0 is never a record even against a zero prior best
    @Test func zeroValueIsNeverARecord() {
        let prior = [summary(distance: 1000)] // no captures
        let drive = summary(distance: 2000) // still zero captured
        let records = DrivePRs.newRecords(for: drive, against: prior)
        #expect(!records.contains(.tilesCaptured))
        #expect(records.contains(.distance))
    }

    /// records come back in DrivePRKind.allCases order
    @Test func recordsKeepAllCasesOrder() {
        let prior = [summary(claimed: 1, captured: ["r": 1], distance: 1, moving: 1)]
        let drive = summary(claimed: 9, captured: ["r": 9], distance: 9, moving: 9)
        let records = DrivePRs.newRecords(for: drive, against: prior)
        let expectedOrder = DrivePRKind.allCases.filter { records.contains($0) }
        #expect(records == expectedOrder)
    }

    // MARK: bests

    /// bests take the max per kind and omit kinds whose best is 0
    @Test func bestsTakeMaxAndOmitZeros() {
        let bests: [DrivePRKind: Double] = DrivePRs.bests(from: [
            summary(claimed: 3, distance: 1000),
            summary(claimed: 7, reinforced: 4, distance: 500),
        ])
        #expect(bests[.tilesGained] == 7)
        #expect(bests[.distance] == 1000)
        #expect(bests[.tilesDriven] == 11) // 7 gained + 4 reinforced
        #expect(bests[.tilesCaptured] == nil) // never captured -> omitted
        #expect(bests[.duration] == nil)
    }

    /// empty input yields no bests
    @Test func emptyInputHasNoBests() {
        #expect(DrivePRs.bests(from: []).isEmpty)
    }
}
