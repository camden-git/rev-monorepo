import CoreLocation
import Foundation
import SwiftyH3

/// computes the per-tile claim score (distance-weighted average speed while moving) from
/// a (filtered) GPS path per H3 res-10 cell. Mirrors the server math in REF:docs/game-design.md
/// §Score Metric
///
/// score(tile) = Σ distance moved inside the tile / Σ time spent moving inside the tile, where "moving"
///
/// Returned in **mph** to match `tiles.claim_score`
public enum TileScoring {
    /// 1 m/s expressed in mph
    static let mphPerMetersPerSecond = 2.2369362920544

    /// segments slower than this count as "stopped"
    static let stoppedSpeedMetersPerSecond = 2.0 / mphPerMetersPerSecond

    public static func perTileScores(for samples: [GPSSample]) -> [UInt64: Double] {
        guard samples.count > 1 else { return [:] }

        var distanceByTile: [UInt64: Double] = [:]
        var movingTimeByTile: [UInt64: Double] = [:]

        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0 else { continue }

            let distance = GPSOutlierFilter.distanceMeters(a, b)
            let segmentSpeed = distance / dt
            guard segmentSpeed >= stoppedSpeedMetersPerSecond else { continue }

            // attribute the segment to the tile the segment departs from
            guard let tile = cell(lat: a.lat, lng: a.lng) else { continue }
            distanceByTile[tile, default: 0] += distance
            movingTimeByTile[tile, default: 0] += dt
        }

        var scores: [UInt64: Double] = [:]
        for (tile, distance) in distanceByTile {
            guard let movingTime = movingTimeByTile[tile], movingTime > 0 else { continue }
            scores[tile] = (distance / movingTime) * mphPerMetersPerSecond
        }
        return scores
    }

    /// ordered and de-duplicated list of res-10 cells the path passes through (first-seen order)
    /// to be used by the live-claim path to know which tiles a drive has entered
    public static func tilesCrossed(for samples: [GPSSample]) -> [UInt64] {
        var seen: Set<UInt64> = []
        var ordered: [UInt64] = []
        for sample in samples {
            guard let tile = cell(lat: sample.lat, lng: sample.lng) else { continue }
            if seen.insert(tile).inserted { ordered.append(tile) }
        }
        return ordered
    }

    static func cell(lat: Double, lng: Double) -> UInt64? {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return H3Grid.cell(for: coordinate)?.id
    }
}
