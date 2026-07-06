import RevKit
import SwiftUI

/// inspector sheet shown when a hex on the map is tapped
struct TileDetailView: View {
    let detail: HexTileDetail
    var onDone: () -> Void = {}

    @State private var showExplainer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    identity

                    if detail.isHome {
                        homeNote
                        metadata
                    } else if detail.isClaimed {
                        if let strength = detail.effectiveScore {
                            strengthBlock(strength)
                            paceBreakdown(strength: strength)
                        }
                        metadata
                    } else {
                        unclaimedHint
                        if hasTypicalPace { typicalPaceHint }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showExplainer = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("How scoring works")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(isPresented: $showExplainer) {
                ScoringExplainerView(onDone: { showExplainer = false })
                    .presentationDetents([.large])
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
                Text(String(format: "%.1f×", asMultiple(strength)))
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

    /// stored scores come in two scales
    private func asMultiple(_ score: Double) -> Double {
        score > Strength.strengthCap ? score / referencePace : score
    }

    /// decay has pulled the effective score meaningfully below the claim score
    private var isFading: Bool {
        guard let claim = detail.claimScore, let effective = detail.effectiveScore else { return false }
        return asMultiple(claim) - asMultiple(effective) >= 0.1
    }

    /// caption under the strength
    private var strengthCaption: String {
        let fadingFrom = detail.claimScore.map { String(format: "Fading from %.1f×", asMultiple($0)) }
        if detail.isLocalOwner {
            if let fadingFrom, isFading { return "\(fadingFrom), drive it to refresh" }
            return "Holding strong"
        } else {
            if let fadingFrom, isFading { return "\(fadingFrom), easier to take" }
            return "Beat this strength to take it"
        }
    }

    // MARK: pace breakdown

    /// do we actually know this road's typical pace yet?
    private var hasTypicalPace: Bool {
        guard let ref = detail.refSpeed, ref > 0 else { return false }
        return (detail.obsCount ?? 0) >= 1
    }

    /// the reference ("usual") pace we score against
    private var referencePace: Double {
        if let ref = detail.refSpeed, ref > 0 { return ref }
        return Strength.referenceSpeedPrior
    }

    /// true while we're still using the fallback prior (road not driven enough)
    private var referenceIsEstimated: Bool {
        !hasTypicalPace
    }

    /// the score the tile was claimed at (decayed value as a last resort)
    private var claimMultiple: Double? {
        detail.claimScore ?? detail.effectiveScore
    }

    /// the driven mph + multiple-of-usual-pace to show in the breakdown
    private var paceReconstruction: (drove: Double, multiple: Double)? {
        let ref = referencePace
        if let speed = detail.drivenSpeed, speed > 0 {
            return (drove: speed, multiple: speed / ref)
        }
        guard let score = claimMultiple, score > 0 else { return nil }
        // claim_score is always a strength (≤ cap); anything above is corrupt data,
        // not a reconstructable pace. a capped strength with no recorded speed can't
        // be turned back into a real mph
        if score >= Strength.strengthCap {
            return nil
        }
        return (drove: score * ref, multiple: score)
    }

    /// visual breakdown of how strength was earned
    /// strength is the multiple of the road's usual pace that was driven
    @ViewBuilder
    private func paceBreakdown(strength: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("How this was scored", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button("Learn more") { showExplainer = true }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
            }

            if let recon = paceReconstruction {
                HStack(alignment: .top, spacing: 0) {
                    paceStat(
                        label: referenceIsEstimated ? "Usual pace (est.)" : "Usual pace here",
                        value: "≈\(Int(referencePace.rounded())) mph"
                    )
                    Divider().frame(height: 34)
                    paceStat(label: "This claim drove", value: "≈\(Int(recon.drove.rounded())) mph")
                }

                paceBar(multiple: recon.multiple)

                Text(breakdownSentence(multiple: recon.multiple))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if referenceIsEstimated {
                    Text("This road's usual pace is temporarily estimated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Strength is how far a drive beats this road's usual pace.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func paceStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// comparison bar
    private func paceBar(multiple: Double) -> some View {
        let scaleMax = max(2.0, multiple.rounded(.up))
        let fill = min(max(multiple, 0) / scaleMax, 1)
        let typicalX = 1.0 / scaleMax
        let beatsTypical = multiple >= 1

        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 12)
                    Capsule()
                        .fill(beatsTypical ? Color.green : Color.orange)
                        .frame(width: max(8, w * fill), height: 12)
                    // "usual pace" tick
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 2, height: 20)
                        .offset(x: w * typicalX - 1)
                }
                .frame(height: 20)
            }
            .frame(height: 20)

            HStack(spacing: 4) {
                Rectangle()
                    .fill(.primary.opacity(0.6))
                    .frame(width: 2, height: 9)
                Text("usual pace (1×)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: "%.1f× the usual pace", multiple))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(beatsTypical ? Color.green : Color.orange)
            }
        }
    }

    private func breakdownSentence(multiple: Double) -> String {
        let m = String(format: "%.1f×", multiple)
        if multiple >= 1 {
            return "Driven about \(m) this road's usual pace. Beating the pace is what earns strength."
        }
        return "Driven about \(m) this road's usual pace. Strength comes from beating the local pace, so faster-than-usual drives score higher."
    }

    /// shown on unclaimed tiles that already have a learned pace
    private var typicalPaceHint: some View {
        Label(
            "This road usually runs ≈\(Int((detail.refSpeed ?? 0).rounded())) mph. Beat that pace to claim more points.",
            systemImage: "speedometer"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
            effectiveScore: 1.6,
            claimScore: 1.9,
            lastDrivenAt: .now.addingTimeInterval(-3 * 86_400),
            refSpeed: 18,
            obsCount: 7
        ))
        .presentationDetents([.medium, .large])
    }
}

#Preview("Capped strength, real speed") {
    Color.gray.sheet(isPresented: .constant(true)) {
        TileDetailView(detail: HexTileDetail(
            id: 4,
            ownerName: "Camden",
            ownerColorHex: "#3B82F6",
            isLocalOwner: true,
            isHome: false,
            effectiveScore: 5.0,
            claimScore: 5.0,
            lastDrivenAt: .now.addingTimeInterval(-2 * 3600),
            refSpeed: 28,
            obsCount: 9,
            drivenSpeed: 41
        ))
        .presentationDetents([.medium, .large])
    }
}

#Preview("Your tile, legacy data") {
    Color.gray.sheet(isPresented: .constant(true)) {
        TileDetailView(detail: HexTileDetail(
            id: 3,
            ownerName: "Camden",
            ownerColorHex: "#3B82F6",
            isLocalOwner: true,
            isHome: false,
            effectiveScore: 63.6,
            claimScore: 65.5,
            lastDrivenAt: .now.addingTimeInterval(-5 * 3600),
            refSpeed: nil,
            obsCount: nil
        ))
        .presentationDetents([.medium, .large])
    }
}

#Preview("Unclaimed, known pace") {
    Color.gray.sheet(isPresented: .constant(true)) {
        TileDetailView(detail: HexTileDetail(
            id: 2, ownerName: nil, ownerColorHex: nil, isLocalOwner: false,
            isHome: false, effectiveScore: nil, claimScore: nil, lastDrivenAt: nil,
            refSpeed: 30, obsCount: 4
        ))
        .presentationDetents([.height(340), .medium])
    }
}
