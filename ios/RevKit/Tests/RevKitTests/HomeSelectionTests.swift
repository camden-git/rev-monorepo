import Foundation
import Testing
@testable import RevKit

struct HomeSelectionTests {
    @Test func anyCellIsEligibleWhenNoHomesExist() {
        #expect(HomeSelection.isEligible(0x8a1fb46622dffff, existingHomes: []))
    }

    @Test func exactCollisionWithExistingHomeIsIneligible() {
        let taken: UInt64 = 0x8a1fb46622dffff
        #expect(!HomeSelection.isEligible(taken, existingHomes: [taken]))
    }

    @Test func cellAwayFromOtherHomesIsEligible() {
        let mine: UInt64 = 0x8a1fb46622dffff
        let others: Set<UInt64> = [0x8a1fb46622c7fff, 0x8a1fb46622effff]
        #expect(HomeSelection.isEligible(mine, existingHomes: others))
    }
}
