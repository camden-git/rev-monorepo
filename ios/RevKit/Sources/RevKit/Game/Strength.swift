import Foundation

/// Score Metric v2 conversion between raw in-tile mph and stored claim strength.
public enum Strength {
    public static let referenceSpeedPrior = 25.0
    public static let referenceSpeedFloor = 5.0
    public static let referenceAlpha = 0.2
    public static let strengthCap = 5.0
    public static let valueGamma = 0.5

    public static func strength(speedMph: Double, refSpeed: Double) -> Double {
        guard speedMph.isFinite, speedMph > 0 else { return 0 }
        let ref = normalizedRef(refSpeed)
        return min(speedMph / max(ref, referenceSpeedFloor), strengthCap)
    }

    public static func updateReference(refSpeed: Double, speedMph: Double) -> Double {
        let ref = normalizedRef(refSpeed)
        guard speedMph.isFinite, speedMph >= 0 else { return ref }
        return ref + referenceAlpha * (speedMph - ref)
    }

    public static func tileValue(captures: Int) -> Double {
        guard captures > 0 else { return 1 }
        return 1 + valueGamma * log1p(Double(captures))
    }

    private static func normalizedRef(_ refSpeed: Double) -> Double {
        guard refSpeed.isFinite, refSpeed > 0 else { return referenceSpeedPrior }
        return refSpeed
    }
}
