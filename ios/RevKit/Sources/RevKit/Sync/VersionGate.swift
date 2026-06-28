import Foundation

/// response from `GET /api/rev/version`
public struct AppVersionGateDTO: Decodable, Sendable, Equatable {
    /// lowest app version still allowed to run
    public let minimumVersion: String
    /// newest version available
    public let latestVersion: String

    public init(minimumVersion: String, latestVersion: String) {
        self.minimumVersion = minimumVersion
        self.latestVersion = latestVersion
    }

    enum CodingKeys: String, CodingKey {
        case minimumVersion = "minimum_version"
        case latestVersion = "latest_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion) ?? "0.0.0"
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion) ?? minimumVersion
    }
}

public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    public init(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        description = trimmed
        let parsed = trimmed
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        components = parsed.isEmpty ? [0] : parsed
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            // a missing trailing component is treated as 0 so "0.2" == "0.2.0"
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// true when this version is below the given minimum-supported floor
    public func isOlderThan(_ minimum: String) -> Bool {
        self < AppVersion(minimum)
    }
}

public extension Bundle {
    var appVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
