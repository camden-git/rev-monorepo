import Foundation
import Observation

/// which CoreMotion activity types are allowed to auto start a drive
@MainActor
@Observable
public final class AutoStartPreferences {
    /// the motion types CoreMotion can report as "moving" that we let kick off a drive
    public enum Activity: String, CaseIterable, Sendable {
        case walking, running, cycling, automotive

        /// user-facing label
        public var title: String {
            switch self {
            case .walking: "Walking"
            case .running: "Running"
            case .cycling: "Cycling"
            case .automotive: "Driving"
            }
        }

        /// SF Symbol for the settings row
        public var symbol: String {
            switch self {
            case .walking: "figure.walk"
            case .running: "figure.run"
            case .cycling: "bicycle"
            case .automotive: "car.fill"
            }
        }
    }

    public var walking: Bool { didSet { persist(.walking, walking) } }
    public var running: Bool { didSet { persist(.running, running) } }
    public var cycling: Bool { didSet { persist(.cycling, cycling) } }
    public var automotive: Bool { didSet { persist(.automotive, automotive) } }

    private let defaults: UserDefaults
    private static let keyPrefix = "autoStart."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // default every activity on until the user explicitly stores a choice
        func load(_ activity: Activity) -> Bool {
            let key = Self.keyPrefix + activity.rawValue
            return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        walking = load(.walking)
        running = load(.running)
        cycling = load(.cycling)
        automotive = load(.automotive)
    }

    public func isEnabled(_ activity: Activity) -> Bool {
        switch activity {
        case .walking: walking
        case .running: running
        case .cycling: cycling
        case .automotive: automotive
        }
    }

    private func persist(_ activity: Activity, _ value: Bool) {
        defaults.set(value, forKey: Self.keyPrefix + activity.rawValue)
    }
}
