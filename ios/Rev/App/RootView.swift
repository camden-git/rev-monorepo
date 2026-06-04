import RevKit
import SwiftData
import SwiftUI

struct RootView: View {
    @State private var store: TerritoryStore
    @State private var tracker: DriveTracker

    /// the post-drive recap surfaces first as a toast, which expands to the full sheet
    @State private var showToast = false
    @State private var showSummarySheet = false
    @State private var toastTask: Task<Void, Never>?

    init(context: ModelContext) {
        let store = TerritoryStore(context: context)
        _store = State(initialValue: store)
        _tracker = State(initialValue: DriveTracker(store: store))
    }

    var body: some View {
        if store.needsOnboarding {
            OnboardingView(store: store)
        } else {
            mapContent
        }
    }

    private var mapContent: some View {
        HexMapView(store: store, breadcrumb: tracker.drivePath)
            .ignoresSafeArea()
            .overlay(alignment: .top) { toast }
            .overlay(alignment: .bottom) { controlPanel }
            .task { tracker.start() }
            .onChange(of: tracker.lastDriveSummary) { _, summary in
                guard summary != nil else { return }
                presentToast()
            }
            .sheet(isPresented: $showSummarySheet) {
                if let summary = tracker.lastDriveSummary {
                    DriveSummaryView(summary: summary, store: store) { showSummarySheet = false }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
    }

    private func presentToast() {
        toastTask?.cancel()
        withAnimation { showToast = true }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { showToast = false }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if showToast, let summary = tracker.lastDriveSummary {
            Button {
                toastTask?.cancel()
                withAnimation { showToast = false }
                showSummarySheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toastHeadline(summary))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func toastHeadline(_ s: DriveSummary) -> String {
        var parts = ["+\(s.totalGained) tiles"]
        if s.totalCaptured > 0 { parts.append("\(s.totalCaptured) captured") }
        if s.tilesEnclosed > 0 { parts.append("\(s.tilesEnclosed) enclosed") }
        return parts.joined(separator: " · ")
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if tracker.isRecording { driveHUD }

            HStack(spacing: 16) {
                Image(systemName: tracker.isRecording ? "record.circle.fill" : "pause.circle")
                    .foregroundStyle(tracker.isRecording ? .red : .secondary)
                Text(String(format: "%.0f mph", tracker.currentSpeedMph))
                    .monospacedDigit()
                Text("\(tracker.claimedTileCount) tiles")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassCapsule()

            Button {
                if tracker.isRecording { tracker.endDrive() } else { tracker.startDrive() }
            } label: {
                Label(tracker.isRecording ? "Stop Drive" : "Start Drive",
                      systemImage: tracker.isRecording ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
            .driveButtonStyle(recording: tracker.isRecording)
        }
        .padding()
    }

    /// live in-drive feedback
    private var driveHUD: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                Label("\(tracker.claimsThisDrive)", systemImage: "flag.fill")
                    .foregroundStyle(.blue)
                Text(contestedText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Label(distanceText, systemImage: "ruler")
                Label(elapsedText(asOf: context.date), systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassCapsule()
        }
    }

    private var contestedText: String {
        guard let owner = tracker.contestedOwnerName else { return "—" }
        if owner == "Unclaimed" { return "open tile" }
        if let score = tracker.contestedScore {
            return String(format: "vs %@ %.0f", owner, score)
        }
        return "vs \(owner)"
    }

    private var distanceText: String {
        let miles = tracker.driveDistanceMeters / 1609.344
        return String(format: "%.1f mi", miles)
    }

    private func elapsedText(asOf now: Date) -> String {
        guard let start = tracker.currentDrive?.startedAt else { return "0:00" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    // TODO: Liquid ass needs more work!
    @ViewBuilder
    func driveButtonStyle(recording: Bool) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(recording ? .red : .blue)
        } else {
            buttonStyle(.borderedProminent).tint(recording ? .red : .blue)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Player.self, TileRecord.self, DriveRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return RootView(context: container.mainContext)
}
