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

    /// primary call-to-action button
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(.blue)
        } else {
            buttonStyle(.borderedProminent).tint(.blue)
        }
    }

    /// floating glass panel (onboarding card, map overlays)
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 28) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
