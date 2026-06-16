import Foundation
import Testing
@testable import RevKit

struct StrengthTests {
    @Test func localReferenceMakesDowntownClaimStrongerThanRuralClaim() {
        let downtown = Strength.strength(speedMph: 35, refSpeed: 18)
        let rural = Strength.strength(speedMph: 100, refSpeed: 75)
        #expect(downtown > rural)
    }

    @Test func strengthUsesPriorFloorAndCap() {
        #expect(abs(Strength.strength(speedMph: 50, refSpeed: 0) - 2) < 1e-9)
        #expect(Strength.strength(speedMph: 100, refSpeed: 1) == Strength.strengthCap)
    }

    @Test func referenceLearnsWithEWMA() {
        #expect(abs(Strength.updateReference(refSpeed: 25, speedMph: 35) - 27) < 1e-9)
    }

    @Test func tileValueRisesWithCaptures() {
        #expect(Strength.tileValue(captures: 0) == 1)
        #expect(Strength.tileValue(captures: 5) > Strength.tileValue(captures: 1))
    }
}
