import Foundation

/// a drive-level personal record category
public enum DrivePRKind: String, CaseIterable, Codable, Sendable {
    case tilesDriven
    case tilesGained
    case tilesCaptured
    case distance
    case duration

    public var title: String {
        switch self {
        case .tilesDriven: return "Most tiles driven"
        case .tilesGained: return "Most ground gained"
        case .tilesCaptured: return "Most captured"
        case .distance: return "Longest distance"
        case .duration: return "Longest drive"
        }
    }

    public var systemImage: String {
        switch self {
        case .tilesDriven: return "road.lanes"
        case .tilesGained: return "flag.fill"
        case .tilesCaptured: return "bolt.fill"
        case .distance: return "map.fill"
        case .duration: return "clock.fill"
        }
    }

    /// the comparable value this kind tracks out of a drive summary
    public func value(in summary: DriveSummary) -> Double {
        switch self {
        case .tilesDriven: return Double(summary.tilesDriven)
        case .tilesGained: return Double(summary.totalGained)
        case .tilesCaptured: return Double(summary.totalCaptured)
        case .distance: return summary.distanceMeters
        case .duration: return summary.movingTime
        }
    }
}

/// computes drive-level personal records across a player's drive history
public enum DrivePRs {
    /// the best (max) value per kind across the given summaries, omitting kinds whose best is 0
    public static func bests(from summaries: [DriveSummary]) -> [DrivePRKind: Double] {
        var bests: [DrivePRKind: Double] = [:]
        for kind in DrivePRKind.allCases {
            let best = summaries.map { kind.value(in: $0) }.max() ?? 0
            if best > 0 { bests[kind] = best }
        }
        return bests
    }

    /// the kinds where `summary` set a new record
    public static func newRecords(for summary: DriveSummary, against prior: [DriveSummary]) -> [DrivePRKind] {
        guard !prior.isEmpty else { return [] }
        let priorBests = bests(from: prior)
        return DrivePRKind.allCases.filter { kind in
            let value = kind.value(in: summary)
            return value > 0 && value > (priorBests[kind] ?? 0)
        }
    }
}
