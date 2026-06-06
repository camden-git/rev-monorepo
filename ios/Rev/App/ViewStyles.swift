import SwiftUI

/// shared Liquid Glass helpers
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// prominent drive action button
    @ViewBuilder
    func driveButtonStyle(recording: Bool) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(recording ? .red : .blue)
        } else {
            buttonStyle(.borderedProminent).tint(recording ? .red : .blue)
        }
    }
}

/// a circular glass button wrapping arbitrary content (an SF Symbol or an avatar)
struct GlassCircleButton<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let inner = content().frame(width: 44, height: 44)
        if #available(iOS 26, *) {
            Button(action: action) { inner }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(label)
        } else {
            Button(action: action) { inner }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel(label)
        }
    }
}
