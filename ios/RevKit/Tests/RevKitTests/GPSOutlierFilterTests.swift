import CoreLocation
import Foundation
import Testing
@testable import RevKit

struct GPSOutlierFilterTests {
    private let base = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)

    /// build a track stepping east at a fixed lng increment, one sample per second
    private func track(steps: Int, lngStep: Double, speed: Double) -> [GPSSample] {
        let start = Date(timeIntervalSince1970: 0)
        return (0..<steps).map { i in
            GPSSample(
                timestamp: start.addingTimeInterval(Double(i)),
                lat: base.latitude,
                lng: base.longitude + Double(i) * lngStep,
                speed: speed,
                accuracy: 5
            )
        }
    }

    @Test func cleanTrackIsPreserved() {
        let samples = track(steps: 6, lngStep: 0.0003, speed: 12)
        let filtered = GPSOutlierFilter.filterOutliers(samples)
        #expect(filtered.count == samples.count)
    }

    @Test func satelliteGlitchIsRejected() {
        var samples = track(steps: 5, lngStep: 0.0003, speed: 12)
        // implies an impossible jump
        let glitch = GPSSample(
            timestamp: samples[2].timestamp,
            lat: base.latitude + 1.0,
            lng: base.longitude,
            speed: 12,
            accuracy: 5
        )
        samples.insert(glitch, at: 2)

        let filtered = GPSOutlierFilter.filterOutliers(samples)
        #expect(filtered.count == samples.count - 1)
        #expect(!filtered.contains { abs($0.lat - (base.latitude + 1.0)) < 0.0001 })
    }

    @Test func smoothingDampensSpeedSpike() {
        var samples = track(steps: 5, lngStep: 0.0003, speed: 10)
        // a momentary reported-speed spike with otherwise-normal positions survives rejection but
        // should be smoothed down by the moving average
        samples[2] = GPSSample(
            timestamp: samples[2].timestamp,
            lat: samples[2].lat,
            lng: samples[2].lng,
            speed: 50,
            accuracy: 5
        )

        let filtered = GPSOutlierFilter.filterOutliers(samples)
        let spiked = filtered[2].speed
        #expect(spiked < 50)
        #expect(spiked > 10)
    }
}
