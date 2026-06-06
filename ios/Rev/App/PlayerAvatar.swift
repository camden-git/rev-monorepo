import RevKit
import SwiftUI

/// circular identity chip (a player's map color with their initials)
struct PlayerAvatar: View {
    let colorHex: String
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            )
    }

    private var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }
}
