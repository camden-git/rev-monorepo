import SwiftUI

extension Color {
    /// parse a "#RRGGBB" hex string which falls back to gray on malformed input
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// visually-distinct map overlay colors players can choose from
enum MapColorPalette {
    static let swatches: [String] = [
        "#3B82F6", "#EF4444", "#22C55E", "#F59E0B",
        "#A855F7", "#EC4899", "#14B8A6", "#6366F1",
    ]
}
