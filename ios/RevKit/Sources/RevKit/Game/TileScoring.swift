import CoreLocation
import Foundation
import SwiftyH3

/// computes the per-tile claim score (time-weighted average speed while moving) from
/// a (filtered) GPS path per H3 res-10 cell. Mirrors the server math in REF:docs/game-design.md
/// §Score Metric
///
/// score(tile) = Σ speed·time spent moving inside the tile / Σ time spent moving inside the tile.
/// Segment speed is the device's Doppler reading (`CLLocation.speed`) when valid, falling back to
/// the position-derived speed (Δdistance / Δtime) otherwise
///
/// Returned in **mph**; Score Metric v2 converts this raw speed into claim strength.
public enum TileScoring {
    /// 1 m/s expressed in mph
    static let mphPerMetersPerSecond = 2.2369362920544

    /// segments slower than this count as "stopped"
    static let stoppedSpeedMetersPerSecond = 2.0 / mphPerMetersPerSecond

    /// max time between consecutive fixes before a segment is treated as a tracking gap rather than
    /// real travel
    public static let maxSegmentGap: TimeInterval = 10

    /// fastest a segment can imply (m/s) before it's treated as a GPS teleport rather than
    /// real travel
    static let maxSegmentSpeedMetersPerSecond = 134.0

    /// target length (m) of each sub-step a segment is broken into for tile attribution. small
    /// relative to a res-10 hex (~130 m wide) so a segment is credited to each tile in proportion
    /// to how much of it actually lies inside that tile.
    static let subStepMeters = 8.0

    /// cap on sub-steps per segment so a long GPS-gap segment can't blow up the loop.
    static let maxSubSteps = 64

    /// minimum distance (m) actually travelled inside a tile before it earns a score. a tile you
    /// merely clip the edge of has too little in-tile travel to trust - its score would be a single
    /// noisy GPS segment with nothing to average against, which read far too high. below this floor
    /// the tile simply isn't scored (it may still be weakly claimed live at score 0).
    static let minTileDistanceMeters = 12.0

    /// pads the Doppler-vs-position agreement envelope (m/s) for timestamp jitter and
    /// chord-shortening through curves
    static let dopplerAgreementSlack = 3.0

    public static func perTileScores(for samples: [GPSSample]) -> [UInt64: Double] {
        guard samples.count > 1 else { return [:] }

        var distanceByTile: [UInt64: Double] = [:]
        var movingTimeByTile: [UInt64: Double] = [:]
        // scored speed integrated over time (Σ speed·time, in metres). dividing by moving time gives
        // the tile's time-weighted average speed. kept separate from the raw geometric distance
        // because the scored speed comes from the device's Doppler reading, not the position deltas.
        var speedTimeByTile: [UInt64: Double] = [:]

        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= maxSegmentGap else { continue }

            let distance = GPSOutlierFilter.distanceMeters(a, b)
            let segmentSpeed = distance / dt
            guard segmentSpeed >= stoppedSpeedMetersPerSecond else { continue }
            // a GPS teleport: don't interpolate a line between two far-apart fixes
            guard segmentSpeed <= maxSegmentSpeedMetersPerSecond else { continue }

            // position error only ever adds apparent path length, so Doppler below the
            // position-implied speed is the multipath case Doppler exists for. Doppler above
            // what the positions plus their accuracy budget support is a chip glitch: drop the
            // segment rather than trust either signal. bounds glitches without capping
            // legitimate speed, which always comes with matching position deltas
            var scoreSpeed = segmentSpeed
            if a.speed >= 0, b.speed >= 0 {
                let dopplerSpeed = (a.speed + b.speed) / 2
                let tolerance = (max(a.accuracy, 0) + max(b.accuracy, 0)) / dt + dopplerAgreementSlack
                guard dopplerSpeed <= segmentSpeed + tolerance else { continue }
                scoreSpeed = dopplerSpeed
            }

            // walk the segment in small steps and attribute each step's distance/time to the tile
            // it falls in. this keeps a barely-clipped tile from inheriting a whole segment's worth
            // of travel that mostly happened in a neighbor (which inflates its score)
            let steps = max(1, min(maxSubSteps, Int((distance / subStepMeters).rounded(.up))))
            let stepDistance = distance / Double(steps)
            let stepTime = dt / Double(steps)
            for i in 0..<steps {
                let fraction = (Double(i) + 0.5) / Double(steps)
                let lat = a.lat + (b.lat - a.lat) * fraction
                let lng = a.lng + (b.lng - a.lng) * fraction
                guard let tile = cell(lat: lat, lng: lng) else { continue }
                distanceByTile[tile, default: 0] += stepDistance
                movingTimeByTile[tile, default: 0] += stepTime
                speedTimeByTile[tile, default: 0] += scoreSpeed * stepTime
            }
        }

        var scores: [UInt64: Double] = [:]
        for (tile, distance) in distanceByTile {
            guard distance >= minTileDistanceMeters else { continue }
            guard let movingTime = movingTimeByTile[tile], movingTime > 0 else { continue }
            scores[tile] = ((speedTimeByTile[tile] ?? 0) / movingTime) * mphPerMetersPerSecond
        }
        return scores
    }

    /// total distance moved and time spent moving across a (filtered) path
    public static func movementStats(for samples: [GPSSample]) -> (distanceMeters: Double, movingTime: TimeInterval) {
        guard samples.count > 1 else { return (0, 0) }

        var totalDistance = 0.0
        var totalMovingTime = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= maxSegmentGap else { continue }

            let distance = GPSOutlierFilter.distanceMeters(a, b)
            let segmentSpeed = distance / dt
            guard segmentSpeed >= stoppedSpeedMetersPerSecond else { continue }
            guard segmentSpeed <= maxSegmentSpeedMetersPerSecond else { continue }

            totalDistance += distance
            totalMovingTime += dt
        }
        return (totalDistance, totalMovingTime)
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

    /// split a raw path into continuous breadcrumb segments, breaking wherever the gap between
    /// fixes exceeds `maxSegmentGap` (the app was suspended and we don't know the route taken). the
    /// map draws one polyline per segment so a gap stays a gap instead of a false straight line.
    public static func segmentedPath(_ path: [GPSSample]) -> [[CLLocationCoordinate2D]] {
        var segments: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var previous: Date?
        for sample in path {
            if let previous, sample.timestamp.timeIntervalSince(previous) > maxSegmentGap {
                segments.append(current)
                current = []
            }
            current.append(CLLocationCoordinate2D(latitude: sample.lat, longitude: sample.lng))
            previous = sample.timestamp
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    static func cell(lat: Double, lng: Double) -> UInt64? {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return H3Grid.cell(for: coordinate)?.id
    }
}
