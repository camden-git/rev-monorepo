import CoreLocation
import Foundation
import Testing
@testable import RevKit

struct HomeSelectionTests {
    @Test func homeInsideChicagoIsWithinPlayArea() throws {
        let loop = try #require(H3Grid.cellId(for: CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)))
        #expect(HomeSelection.isWithinPlayArea(loop))
    }

    @Test func homeOutsideChicagoIsRejected() throws {
        let naperville = try #require(H3Grid.cellId(for: CLLocationCoordinate2D(latitude: 41.7508, longitude: -88.1535)))
        #expect(!HomeSelection.isWithinPlayArea(naperville))
    }

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
