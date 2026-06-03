import CoreLocation
import Foundation

/// cleans a raw GPS path before scoring, this will eventually be server side
/// REF: docs/game-design.md §Raw GPS Outlier Filter:
///   1. reject any sample w/ >1g sustained acceleration vs. the prior retained sample
///   2. apply smoothing to the remaining samples' reported speeds
///
/// note: never put any speed cap!
public enum GPSOutlierFilter {
    /// the rejection threshold for implied acceleration in m/s/s
    static let maxAcceleration = 9.80665

    static let smoothingWindow = 3

    public static func filterOutliers(_ samples: [GPSSample]) -> [GPSSample] {
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

        return smoothSpeeds(retained)
    }

    /// window-3 centered moving average over the `speed` field
    private static func smoothSpeeds(_ samples: [GPSSample]) -> [GPSSample] {
        guard samples.count >= smoothingWindow else { return samples }
        let half = smoothingWindow / 2

        return samples.enumerated().map { index, sample in
            let lower = max(0, index - half)
            let upper = min(samples.count - 1, index + half)
            let window = samples[lower...upper].map { max($0.speed, 0) }
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
