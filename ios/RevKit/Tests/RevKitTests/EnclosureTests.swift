import Foundation
import SwiftyH3
import Testing
@testable import RevKit

struct EnclosureTests {
    private let center = TileScoring.cell(lat: 41.8807, lng: -87.6294)!

    private func ring(_ origin: UInt64, _ distance: Int32) -> [UInt64] {
        (try! H3Cell(origin).gridRing(distance: distance)).map(\.id)
    }

    private func disk(_ origin: UInt64, _ distance: Int32) -> [UInt64] {
        (try! H3Cell(origin).gridDisk(distance: distance)).map(\.id)
    }

    // MARK: geometry

    /// a closed ring captures exactly the cells it surrounds
    @Test func ringLoopEnclosesItsInterior() {
        let result = Enclosure.enclose(trail: ring(center, 2), loopScore: 30)
        #expect(Set(result.scoredInterior.keys) == Set(disk(center, 1))) // center + 6 inner cells
    }

    /// an open path (no loop) encloses nothing
    @Test func openTrailEnclosesNothing() {
        let far = TileScoring.cell(lat: 41.8807, lng: -87.6194)! // ~830 m east
        let line = (try! H3Cell(center).path(to: H3Cell(far))).map(\.id)
        let result = Enclosure.enclose(trail: line, loopScore: 30)
        #expect(result.isEmpty)
    }

    /// a loop enclosing fewer than `minArea` hexes is rejected
    @Test func belowMinAreaIsRejected() {
        // the 6 immediate neighbors surround only the single center cell
        let result = Enclosure.enclose(trail: ring(center, 1), loopScore: 30)
        #expect(result.isEmpty)
    }

    /// a trail with a dangling tail still encloses its loop body
    @Test func selfTouchClosureIgnoresTail() {
        let tailEnd = TileScoring.cell(lat: 41.8807, lng: -87.6244)! // ~415 m east of center
        let tail = (try! H3Cell(ring(center, 2).first!).path(to: H3Cell(tailEnd))).map(\.id)
        let result = Enclosure.enclose(trail: tail + ring(center, 2), loopScore: 30)
        #expect(Set(result.scoredInterior.keys) == Set(disk(center, 1)))
    }

    /// leaving and returning to your own territory closes a loop
    @Test func ownedTerritoryReentryClosesLoop() {
        let r2 = ring(center, 2)
        let ownedArc = Set(r2.prefix(4))
        let partialTrail = Array(r2.dropFirst(4))

        let closed = Enclosure.enclose(trail: partialTrail, owned: ownedArc, loopScore: 30)
        #expect(Set(closed.scoredInterior.keys) == Set(disk(center, 1)))

        let open = Enclosure.enclose(trail: partialTrail, owned: [], loopScore: 30)
        #expect(open.isEmpty)
    }

    @Test func interiorScoreFallsToZeroPastTheEdge() {
        let loopScore = 40.0
        let result = Enclosure.enclose(trail: ring(center, 3), loopScore: loopScore)
        let scored = result.scoredInterior

        // gradient reaches 0 after 20% penetration. interior depth runs 1..3, so only the
        // wall-adjacent ring (depth 1) scores; everything deeper is 0
        for cell in ring(center, 2) { #expect(abs((scored[cell] ?? -1) - loopScore) < 0.001) }
        for cell in ring(center, 1) { #expect(scored[cell] == 0) }
        #expect(scored[center] == 0)
    }

    /// enormous fills are capped both by bounding-disk radius and by interior cell count
    @Test func enormousFillsAreCapped() {
        #expect(Enclosure.enclose(trail: ring(center, 2), loopScore: 30, maxRadius: 1).isEmpty)
        #expect(Enclosure.enclose(trail: ring(center, 2), loopScore: 30, maxInterior: 3).isEmpty)
    }

    /// the squareness guard rejects elongated loops. a near-square hex ring encloses by default but
    /// is rejected once the guard is tightened below its (slightly-off-square) bbox ratio
    @Test func aspectRatioGuardRejectsNonSquareLoops() {
        let square = ring(center, 2)
        #expect(!Enclosure.enclose(trail: square, loopScore: 30).isEmpty)
        #expect(Enclosure.enclose(trail: square, loopScore: 30, maxAspect: 1.0).isEmpty)
    }
}
