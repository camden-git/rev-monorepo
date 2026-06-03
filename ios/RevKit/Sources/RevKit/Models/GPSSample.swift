import Foundation

/// a single raw GPS fix recorded during a drive
/// mirrors the `{ts, lat, lng, speed, accuracy}` shape in `drives.raw_path`
public struct GPSSample: Codable, Sendable, Hashable {
    public let timestamp: Date
    public let lat: Double
    public let lng: Double
    /// instantaneous speed in m/s as reported by CoreLocation (`CLLocation.speed`), negative when invalid
    public let speed: Double
    /// horizontal accuracy in meters
    public let accuracy: Double

    public init(timestamp: Date, lat: Double, lng: Double, speed: Double, accuracy: Double) {
        self.timestamp = timestamp
        self.lat = lat
        self.lng = lng
        self.speed = speed
        self.accuracy = accuracy
    }
}
