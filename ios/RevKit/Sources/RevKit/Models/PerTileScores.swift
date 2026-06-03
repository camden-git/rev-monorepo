import Foundation

/// Codable wrapper that serializes per-tile scores to the JSON object the
/// backend expects in `drives.per_tile_scores` (REF: docs/tech-stack.md).
///
/// It is to note that the backend does not exist yet lol
public struct PerTileScores: Codable, Sendable, Equatable {
    public var scores: [UInt64: Double]

    public init(_ scores: [UInt64: Double]) {
        self.scores = scores
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringKey.self)
        for (h3, score) in scores {
            try container.encode(score, forKey: StringKey(String(h3)))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringKey.self)
        var result: [UInt64: Double] = [:]
        for key in container.allKeys {
            guard let h3 = UInt64(key.stringValue) else { continue }
            result[h3] = try container.decode(Double.self, forKey: key)
        }
        scores = result
    }

    private struct StringKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
