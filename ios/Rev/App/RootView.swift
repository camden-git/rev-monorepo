import RevKit
import SwiftData
import SwiftUI

struct RootView: View {
    @State private var store: TerritoryStore
    @State private var tracker: DriveTracker
    /// sign in with Apple flow, shares its Keychain token with sync
    @State private var signIn: AppleSignInCoordinator
    /// backend sync
    @State private var sync: SyncService

    /// the post-drive recap surfaces first as a toast, which expands to the full sheet
    @State private var showToast = false
    @State private var showSummarySheet = false
    @State private var showHistory = false
    @State private var showLeaderboard = false
    @State private var showSettings = false
    /// the hex inspector sheet, non-nil while a tapped tile is shown
    @State private var selectedTile: HexTileDetail?
    @State private var toastTask: Task<Void, Never>?
    @State private var visibleTileSyncTask: Task<Void, Never>?

    init(context: ModelContext) {
        let store = TerritoryStore(context: context)
        _store = State(initialValue: store)
        _tracker = State(initialValue: DriveTracker(store: store))

        #if DEBUG
        #if targetEnvironment(simulator)
        let config = PocketBaseConfig.localSimulator
        #else
        let config = PocketBaseConfig.phoneDevelopment
        #endif
        #else
        let config = PocketBaseConfig.production
        #endif
        let tokenStore = KeychainTokenStore()
        let client = URLSessionPocketBaseClient(config: config, tokenStore: tokenStore)
        _signIn = State(initialValue: AppleSignInCoordinator(client: client, tokenStore: tokenStore))
        _sync = State(initialValue: SyncService(store: store, context: context, config: config, tokenStore: tokenStore))
    }

    var body: some View {
        Group {
            if store.needsOnboarding {
                OnboardingView(store: store, signIn: signIn, sync: sync)
            } else {
                mapContent
            }
        }
        .task {
            await sync.restoreSessionIfPossible()
        }
    }

    private var mapContent: some View {
        HexMapView(
            store: store,
            breadcrumb: tracker.drivePath,
            onVisibleCellsChange: { cells in scheduleVisibleTileSync(cells) },
            onSelectTile: { tile in selectedTile = tile }
        )
            .ignoresSafeArea()
            .overlay(alignment: .top) { toast }
            .overlay(alignment: .topTrailing) { navCluster }
            .overlay(alignment: .bottom) { controlPanel }
            .task {
                tracker.start()
            }
            .onChange(of: tracker.lastDriveSummary) { _, summary in
                guard summary != nil else { return }
                presentToast()
                Task { await sync.uploadPending() } // push the finished drive
            }
            .sheet(isPresented: $showSummarySheet) {
                if let summary = tracker.lastDriveSummary {
                    DriveSummaryView(summary: summary, store: store) { showSummarySheet = false }
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showHistory) {
                DriveHistoryView(store: store) { showHistory = false }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLeaderboard) {
                LeaderboardView(store: store) { showLeaderboard = false }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                ProfileSettingsView(store: store, sync: sync) { showSettings = false }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedTile) { tile in
                TileDetailView(detail: tile) { selectedTile = nil }
                    .presentationDetents([.height(340), .medium])
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
                    .presentationDragIndicator(.visible)
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

    private func scheduleVisibleTileSync(_ cells: Set<UInt64>) {
        visibleTileSyncTask?.cancel()
        visibleTileSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await sync.pollVisibleTiles(h3Cells: cells)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if showToast, let summary = tracker.lastDriveSummary {
            Group {
                if #available(iOS 26, *) {
                    Button(action: expandToastToSheet) { toastLabel(summary) }
                        .buttonStyle(.glass)
                } else {
                    Button(action: expandToastToSheet) {
                        toastLabel(summary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .glassCapsule()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func toastLabel(_ summary: DriveSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(toastHeadline(summary))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
    }

    private func expandToastToSheet() {
        toastTask?.cancel()
        withAnimation { showToast = false }
        showSummarySheet = true
    }

    private func toastHeadline(_ s: DriveSummary) -> String {
        var parts = ["+\(s.totalGained) tiles"]
        if s.totalCaptured > 0 { parts.append("\(s.totalCaptured) captured") }
        if s.tilesEnclosed > 0 { parts.append("\(s.tilesEnclosed) enclosed") }
        return parts.joined(separator: " · ")
    }

    /// floating navigation controls, top-right
    private var navActions: [NavAction] {
        var actions: [NavAction] = [
            NavAction(icon: "chart.bar.xaxis", label: "Drive history and empire stats") { showHistory = true },
            NavAction(icon: "trophy", label: "Leaderboard") { showLeaderboard = true },
            NavAction(icon: "person.crop.circle", label: "Profile settings") { showSettings = true },
        ]
        #if DEBUG
        actions.append(NavAction(
            icon: sync.isSignedIn ? "icloud.fill" : "icloud.slash",
            label: "Dev sign in and sync",
            tint: sync.isSignedIn ? .green : .secondary
        ) {
            Task {
                await sync.devSignIn()
                await sync.uploadPending()
            }
        })
        #endif
        return actions
    }

    @ViewBuilder
    private var navCluster: some View {
        Group {
            if #available(iOS 26, *) {

                VStack(spacing: 8) {
                    ForEach(navActions) { item in
                        Button(action: item.action) { navIcon(item) }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel(item.label)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(navActions) { item in
                        Button(action: item.action) { navIcon(item) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.label)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.trailing)
        .padding(.top, 8)
    }

    private func navIcon(_ item: NavAction) -> some View {
        Image(systemName: item.icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(item.tint ?? .primary)
            .frame(width: 44, height: 44)
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassCapsule()
            .contentShape(Capsule())
            .onTapGesture {} // swallow taps so they don't fall through to the map's hex picker

            Button {
                if tracker.isRecording { tracker.endDrive() } else { tracker.startDrive() }
            } label: {
                Label(tracker.isRecording ? "Stop Drive" : "Start Drive",
                      systemImage: tracker.isRecording ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(minHeight: 44)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
            .driveButtonStyle(recording: tracker.isRecording)
            .contentShape(Capsule())
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
            .contentShape(Capsule())
            .onTapGesture {} // swallow taps so they don't fall through to the map's hex picker
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

    @ViewBuilder
    func driveButtonStyle(recording: Bool) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(recording ? .red : .blue)
        } else {
            buttonStyle(.borderedProminent).tint(recording ? .red : .blue)
        }
    }

}

/// a single floating navigation control in the top-right cluster
private struct NavAction: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    var tint: Color?
    let action: () -> Void

    init(icon: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.tint = tint
        self.action = action
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Player.self, TileRecord.self, DriveRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return RootView(context: container.mainContext)
}
