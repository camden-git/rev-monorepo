import CoreLocation
import Foundation
import Testing
@testable import RevKit

struct TileScoringTests {
    private let base = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)

    private func track(steps: Int, lngStep: Double, dt: TimeInterval) -> [GPSSample] {
        let start = Date(timeIntervalSince1970: 0)
        return (0..<steps).map { i in
            GPSSample(
                timestamp: start.addingTimeInterval(Double(i) * dt),
                lat: base.latitude,
                lng: base.longitude + Double(i) * lngStep,
                speed: -1, // scoring derives speed from position so this field should be ignored
                accuracy: 5
            )
        }
    }

    @Test func constantSpeedYieldsThatSpeedPerTile() {
        let lngStep = 0.0003
        let dt = 2.0
        let samples = track(steps: 8, lngStep: lngStep, dt: dt)

        // expected speed (mph) computed the same way the scorer derives a segment speed
        let stepMeters = GPSOutlierFilter.distanceMeters(samples[0], samples[1])
        let expectedMph = (stepMeters / dt) * TileScoring.mphPerMetersPerSecond

        let scores = TileScoring.perTileScores(for: samples)
        #expect(!scores.isEmpty)

        for score in scores.values {
            #expect(abs(score - expectedMph) < 0.5)
        }
    }

    @Test func crossesMultipleTiles() {
        let samples = track(steps: 12, lngStep: 0.0004, dt: 1.0)
        let crossed = TileScoring.tilesCrossed(for: samples)
        #expect(crossed.count >= 2)
        // every scored tile should be one the path actually crossed
        let scores = TileScoring.perTileScores(for: samples)
        #expect(scores.keys.allSatisfy { crossed.contains($0) })
    }

    @Test func stoppedSegmentsAreExcluded() {
        // ~0.2 m steps once per second
        let samples = track(steps: 6, lngStep: 0.0000025, dt: 1.0)
        let scores = TileScoring.perTileScores(for: samples)
        #expect(scores.isEmpty)
    }

    /// the score is distance-weighted
    @Test func scoreIsDistanceWeightedNotArithmeticMean() {
        let start = Date(timeIntervalSince1970: 0)
        // three fixes a few meters apart
        let lat = base.latitude
        let lng0 = base.longitude
        let dLng1 = 0.00006 // ~5 m east
        let dLng2 = 0.00004 // ~3 m more east
        let samples = [
            GPSSample(timestamp: start, lat: lat, lng: lng0, speed: -1, accuracy: 5),
            GPSSample(timestamp: start.addingTimeInterval(1), lat: lat, lng: lng0 + dLng1, speed: -1, accuracy: 5),
            GPSSample(timestamp: start.addingTimeInterval(4), lat: lat, lng: lng0 + dLng1 + dLng2, speed: -1, accuracy: 5),
        ]

        // sanity check that the whole path stays inside a single tile so weighting is observable
        #expect(TileScoring.tilesCrossed(for: samples).count == 1)

        let d1 = GPSOutlierFilter.distanceMeters(samples[0], samples[1])
        let d2 = GPSOutlierFilter.distanceMeters(samples[1], samples[2])
        let mph = TileScoring.mphPerMetersPerSecond
        let expectedWeighted = ((d1 + d2) / (1.0 + 3.0)) * mph
        let arithmeticMean = ((d1 / 1.0) + (d2 / 3.0)) / 2.0 * mph

        let scores = TileScoring.perTileScores(for: samples)
        #expect(scores.count == 1)
        let score = try! #require(scores.values.first)
        #expect(abs(score - expectedWeighted) < 0.1)

        #expect(abs(score - arithmeticMean) > 1.0)
    }
}
