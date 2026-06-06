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
    @State private var showSummary = false
    /// the home drawer is a persistent sheet, always up over the map
    @State private var showDrawer = false
    @State private var drawerDetent: PresentationDetent = .height(150)
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
            .task {
                tracker.start()
            }
            .onAppear { showDrawer = true }
            .onChange(of: tracker.isRecording) { _, recording in
                // collapse to the compact trip readout when a drive starts
                if recording { drawerDetent = .height(150) }
            }
            .onChange(of: tracker.lastDriveSummary) { _, summary in
                guard summary != nil else { return }
                presentToast()
                Task { await sync.uploadPending() } // push the finished drive
            }
            .sheet(isPresented: $showDrawer) {
                HomeDrawer(
                    store: store,
                    tracker: tracker,
                    sync: sync,
                    selectedTile: $selectedTile,
                    showSummary: $showSummary
                )
                    .presentationDetents([.height(150), .medium, .large], selection: $drawerDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
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
        showSummary = true
    }

    private func toastHeadline(_ s: DriveSummary) -> String {
        var parts = ["+\(s.totalGained) tiles"]
        if s.totalCaptured > 0 { parts.append("\(s.totalCaptured) captured") }
        if s.tilesEnclosed > 0 { parts.append("\(s.tilesEnclosed) enclosed") }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Player.self, TileRecord.self, DriveRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return RootView(context: container.mainContext)
}
