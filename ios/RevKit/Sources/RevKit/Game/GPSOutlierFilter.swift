import CoreLocation
import Foundation

/// cleans a raw GPS path before scoring, this will eventually be server side
/// REF: docs/game-design.md §Raw GPS Outlier Filter:
///   1. drop fixes the device flags as too inaccurate to trust
///   2. reject GPS "teleport" spikes by geometry (a glitch fix flings away and snaps back)
///   3. reject any sample w/ >1g sustained acceleration vs. the prior retained sample
///   4. invalidate spike-shaped Doppler readings (the position filters above never look at the
///      reported speed, and it's the value scoring actually stores)
///   5. apply smoothing to the remaining samples' reported speeds
///
/// note: never put any speed cap!
public enum GPSOutlierFilter {
    /// the rejection threshold for implied acceleration in m/s/s
    static let maxAcceleration = 9.80665

    /// plausibility threshold (m/s/s, ~1.5g) for a jump in the device-reported Doppler speed
    /// between consecutive fixes. no street vehicle sustains this, while a chip glitch jumps by
    /// hundreds
    static let maxDopplerAcceleration = 15.0

    /// the coarsest fix worth trusting in meters; beyond it the position can be off
    /// far enough to manufacture phantom speed
    static let maxHorizontalAccuracyMeters = 35.0

    static let smoothingWindow = 3

    /// a fix must fling at least this far from the path before it's even considered a teleport
    /// spike
    static let spikeExcursionMeters = 50.0

    /// how much longer the in-and-out detour through a fix must be than the straight hop past it
    /// before that fix is treated as a spike
    static let spikeDetourRatio = 4.0

    public static func filterOutliers(_ samples: [GPSSample]) -> [GPSSample] {
        let trusted = rejectLowAccuracy(samples)
        guard trusted.count > 2 else { return trusted }
        return smoothSpeeds(invalidateDopplerSpikes(rejectAccelerationOutliers(rejectPositionSpikes(trusted))))
    }

    /// drop fixes CoreLocation marks untrustworthy: a negative accuracy means the
    /// coordinate is invalid, a large one means the position can be off far enough
    /// that the distance to the next fix implies a speed that never happened
    static func rejectLowAccuracy(_ samples: [GPSSample]) -> [GPSSample] {
        samples.filter { $0.accuracy >= 0 && $0.accuracy <= maxHorizontalAccuracyMeters }
    }

    static func rejectPositionSpikes(_ samples: [GPSSample]) -> [GPSSample] {
        guard samples.count > 2 else { return samples }

        var kept: [GPSSample] = [samples[0]]
        for i in 1..<(samples.count - 1) {
            let prev = kept[kept.count - 1]
            if isSpike(prev: prev, cur: samples[i], next: samples[i + 1]) { continue }
            kept.append(samples[i])
        }
        kept.append(samples[samples.count - 1])

        // the first and last fixes have only one neighbour, so the detour test can't triangulate
        // them. fall back to a relative-speed check
        if kept.count > 2, endpointIsSpike(kept[0], kept[1], kept[2]) {
            kept.removeFirst()
        }
        if kept.count > 2, endpointIsSpike(kept[kept.count - 1], kept[kept.count - 2], kept[kept.count - 3]) {
            kept.removeLast()
        }
        return kept
    }

    /// true when `cur` is a teleport spike between `prev` and `next`
    private static func isSpike(prev: GPSSample, cur: GPSSample, next: GPSSample) -> Bool {
        let excursion = distanceMeters(prev, cur)
        guard excursion > spikeExcursionMeters else { return false }
        let detour = excursion + distanceMeters(cur, next)
        let direct = distanceMeters(prev, next)
        return detour > spikeDetourRatio * max(direct, 1)
    }

    /// true when endpoint `a` (with inward neighbours `b` then `c`) is an uncorroborated spike
    private static func endpointIsSpike(_ a: GPSSample, _ b: GPSSample, _ c: GPSSample) -> Bool {
        let dtAB = abs(b.timestamp.timeIntervalSince(a.timestamp))
        let dtBC = abs(c.timestamp.timeIntervalSince(b.timestamp))
        guard dtAB > 0, dtBC > 0 else { return false }
        let excursion = distanceMeters(a, b)
        guard excursion > spikeExcursionMeters else { return false }
        let hopSpeed = excursion / dtAB
        let trustedSpeed = distanceMeters(b, c) / dtBC
        return hopSpeed > spikeDetourRatio * max(trustedSpeed, 1)
    }

    /// reject any sample implying >1g sustained acceleration vs. the prior retained sample
    static func rejectAccelerationOutliers(_ samples: [GPSSample]) -> [GPSSample] {
        guard samples.count > 2 else { return samples }

        var retained: [GPSSample] = [samples[0]]
        // implied speed (m/s) of the segment leading into the current anchor
        var prevImpliedSpeed: Double?

        for candidate in samples.dropFirst() {
            let anchor = retained[retained.count - 1]
            let dt = candidate.timestamp.timeIntervalSince(anchor.timestamp)
            // non-advancing timestamps are useless
            guard dt > 0 else { continue }

            let impliedSpeed = distanceMeters(anchor, candidate) / dt
            if let prevImpliedSpeed {
                let acceleration = abs(impliedSpeed - prevImpliedSpeed) / dt
                if acceleration > maxAcceleration { continue } // bad
            }

            retained.append(candidate)
            prevImpliedSpeed = impliedSpeed
        }

        return retained
    }

    /// marks spike-shaped Doppler readings invalid (speed -1) so scoring falls back to
    /// position-derived speed there. a spike is implausible acceleration away from both
    /// neighbours while they agree with each other: a glitched chip reading, not hard driving,
    /// which moves all three together
    static func invalidateDopplerSpikes(_ samples: [GPSSample]) -> [GPSSample] {
        guard samples.count > 2 else { return samples }
        var out = samples
        for i in 1..<(samples.count - 1) {
            let prev = samples[i - 1], cur = samples[i], next = samples[i + 1]
            guard prev.speed >= 0, cur.speed >= 0, next.speed >= 0 else { continue }
            let dtIn = cur.timestamp.timeIntervalSince(prev.timestamp)
            let dtOut = next.timestamp.timeIntervalSince(cur.timestamp)
            let dtAcross = next.timestamp.timeIntervalSince(prev.timestamp)
            guard dtIn > 0, dtOut > 0, dtAcross > 0 else { continue }
            let accelIn = abs(cur.speed - prev.speed) / dtIn
            let accelOut = abs(next.speed - cur.speed) / dtOut
            let accelAcross = abs(next.speed - prev.speed) / dtAcross
            if accelIn > maxDopplerAcceleration, accelOut > maxDopplerAcceleration,
               accelAcross <= maxDopplerAcceleration {
                out[i] = GPSSample(
                    timestamp: cur.timestamp,
                    lat: cur.lat,
                    lng: cur.lng,
                    speed: -1,
                    accuracy: cur.accuracy
                )
            }
        }
        return out
    }

    /// window-3 centered moving average over the `speed` field. invalid readings (negative = no
    /// Doppler fix) are excluded and stay invalid: fabricating a speed would drag real speeds
    /// down and defeat the position fallback
    private static func smoothSpeeds(_ samples: [GPSSample]) -> [GPSSample] {
        guard samples.count >= smoothingWindow else { return samples }
        let half = smoothingWindow / 2

        return samples.enumerated().map { index, sample in
            guard sample.speed >= 0 else { return sample }
            let lower = max(0, index - half)
            let upper = min(samples.count - 1, index + half)
            let window = samples[lower...upper].map(\.speed).filter { $0 >= 0 }
            let mean = window.reduce(0, +) / Double(window.count)
            return GPSSample(
                timestamp: sample.timestamp,
                lat: sample.lat,
                lng: sample.lng,
                speed: mean,
                accuracy: sample.accuracy
            )
        }
    }

    static func distanceMeters(_ a: GPSSample, _ b: GPSSample) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lng)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
    }
}
