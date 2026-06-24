import SwiftUI

struct ScoringExplainerView: View {
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    headline

                    examples

                    VStack(alignment: .leading, spacing: 18) {
                        point(
                            icon: "speedometer",
                            title: "Your pace vs. the road's pace",
                            body: "Every road learns its own average speed. Your strength is how many times faster than that you drove."
                        )
                        point(
                            icon: "shield.lefthalf.filled",
                            title: "Stronger claims are harder to take",
                            body: "To capture a rival tile, you have to beat the strength (speed) they hold it at."
                        )
                        point(
                            icon: "clock.arrow.circlepath",
                            title: "Claims fade over time",
                            body: "If nobody re-drives a tile, its strength slowly decays which makes it easier to take. Re-drive your own tiles to keep them fresh."
                        )
                    }
                }
                .padding(24)
            }
            .navigationTitle("How scoring works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    // MARK: headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed is relative")
                .font(.title2.weight(.bold))
            Text("You're scored on how much you beat the usual pace of the road you're on.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: examples

    /// the key intuition: a slow downtown run can out-score a fast highway run
    private var examples: some View {
        VStack(spacing: 12) {
            exampleRow(
                emoji: "🏙️",
                place: "Downtown street",
                drove: 35,
                usual: 18,
                wins: true
            )
            exampleRow(
                emoji: "🛣️",
                place: "Open highway",
                drove: 70,
                usual: 75,
                wins: false
            )
            Text("The 35 mph downtown claim is **stronger** than the 70 mph highway one because it beat its road's pace by more.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    private func exampleRow(emoji: String, place: String, drove: Double, usual: Double, wins: Bool) -> some View {
        let multiple = drove / usual
        return HStack(spacing: 14) {
            Text(emoji)
                .font(.system(size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text(place)
                    .font(.subheadline.weight(.semibold))
                Text("Drove \(Int(drove)) mph · usually \(Int(usual)) mph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f×", multiple))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(wins ? Color.green : Color.secondary)
                Text(wins ? "stronger" : "weaker")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(wins ? Color.green.opacity(0.5) : .clear, lineWidth: 1.5)
        )
    }

    // MARK: points

    private func point(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    Color.gray.sheet(isPresented: .constant(true)) {
        ScoringExplainerView()
            .presentationDetents([.large])
    }
}
