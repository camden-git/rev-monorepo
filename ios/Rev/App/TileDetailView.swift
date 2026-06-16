import RevKit
import SwiftUI

/// inspector sheet shown when a hex on the map is tapped
struct TileDetailView: View {
    let detail: HexTileDetail
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                identity

                if detail.isHome {
                    homeNote
                    metadata
                } else if detail.isClaimed {
                    if let strength = detail.effectiveScore {
                        strengthBlock(strength)
                    }
                    metadata
                } else {
                    unclaimedHint
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Tile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    // MARK: identity

    private var identity: some View {
        HStack(spacing: 16) {
            swatch
            VStack(alignment: .leading, spacing: 3) {
                Text(ownerTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var swatch: some View {
        ZStack {
            if let hex = detail.ownerColorHex {
                Circle()
                    .fill(Color(hex: hex))
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
            } else {
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                    )
            }
            if detail.isHome {
                Image(systemName: "house.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            } else if !detail.isClaimed {
                Image(systemName: "hexagon")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }

    private var ownerTitle: String {
        guard let name = detail.ownerName else { return "Unclaimed" }
        return detail.isLocalOwner ? "\(name) (you)" : name
    }

    private var statusSubtitle: String {
        if !detail.isClaimed { return "Open territory" }
        if detail.isHome { return detail.isLocalOwner ? "Your home base" : "Home base" }
        return detail.isLocalOwner ? "Your territory" : "Rival territory"
    }

    // MARK: strength

    private func strengthBlock(_ strength: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", strength))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("strength")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(strengthCaption)
                .font(.footnote)
                .foregroundStyle(isFading ? Color.orange : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// decay has pulled the effective score meaningfully below the claim score
    private var isFading: Bool {
        guard let claim = detail.claimScore, let effective = detail.effectiveScore else { return false }
        return claim - effective >= 1
    }

    /// caption under the strength
    private var strengthCaption: String {
        let fadingFrom = detail.claimScore.map { String(format: "Fading from %.1f", $0) }
        if detail.isLocalOwner {
            if let fadingFrom, isFading { return "\(fadingFrom), drive it to refresh" }
            return "Holding strong"
        } else {
            if let fadingFrom, isFading { return "\(fadingFrom), easier to take" }
            return "Beat this strength to take it"
        }
    }

    // MARK: metadata

    @ViewBuilder
    private var metadata: some View {
        if let driven = detail.lastDrivenAt {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Last driven")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(driven, format: .relative(presentation: .named))
            }
            .font(.subheadline)
        }
    }

    // MARK: home

    /// home hexes are inviolable
    private var homeNote: some View {
        Label(
            detail.isLocalOwner
                ? "Your home base anchors your territory. It can't be taken."
                : "A rival's home base. It anchors their territory and can't be taken.",
            systemImage: "shield.lefthalf.filled"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: unclaimed

    private var unclaimedHint: some View {
        Label("Drive through this tile to claim it.", systemImage: "flag.checkered")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

#Preview("Rival, fading") {
    Color.gray.sheet(isPresented: .constant(true)) {
        TileDetailView(detail: HexTileDetail(
            id: 1,
            ownerName: "Dakota",
            ownerColorHex: "#EF4444",
            isLocalOwner: false,
            isHome: false,
            effectiveScore: 42,
            claimScore: 51,
            lastDrivenAt: .now.addingTimeInterval(-3 * 86_400)
        ))
        .presentationDetents([.height(340), .medium])
    }
}

#Preview("Unclaimed") {
    Color.gray.sheet(isPresented: .constant(true)) {
        TileDetailView(detail: HexTileDetail(
            id: 2, ownerName: nil, ownerColorHex: nil, isLocalOwner: false,
            isHome: false, effectiveScore: nil, claimScore: nil, lastDrivenAt: nil
        ))
        .presentationDetents([.height(340), .medium])
    }
}
