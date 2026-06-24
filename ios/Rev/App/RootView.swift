import RevKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: TerritoryStore
    @State private var tracker: DriveTracker
    /// sign in with Apple flow, shares its Keychain token with sync
    @State private var signIn: AppleSignInCoordinator
    /// backend sync
    @State private var sync: SyncService
    /// follow graph + activity feed
    @State private var social: SocialService

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
        _social = State(initialValue: SocialService(client: client))
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
            reconcileRealtime()
            await refreshSocial()
        }
        // keep the live tile stream open only while the app is active and signed in
        .onChange(of: scenePhase) { _, _ in reconcileRealtime() }
        .onChange(of: sync.isSignedIn) { _, _ in
            reconcileRealtime()
            Task { await refreshSocial() }
        }
    }

    private func refreshSocial() async {
        if let userId = sync.currentUserId {
            await social.refresh(viewerId: userId)
        } else {
            social.clear()
        }
    }

    private func reconcileRealtime() {
        if scenePhase == .active && sync.isSignedIn {
            sync.startRealtime()
            // catches a token revoked server-side while idle or backgrounded, which
            // the tile/roster polls can't see (they return an empty 200 for a dead
            // token rather than a 401)
            sync.startHeartbeat()
        } else {
            sync.stopRealtime()
            sync.stopHeartbeat()
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
            .safeAreaInset(edge: .top) { syncStatusBanner }
            .task {
                // stream mid-drive captures to the server so other players see them live
                tracker.onLiveClaims = { scores in
                    Task { await sync.flushLiveClaims(scores) }
                }
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
                    signIn: signIn,
                    sync: sync,
                    social: social,
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

    @ViewBuilder
    private var syncStatusBanner: some View {
        if let message = sync.lastError {
            HStack(spacing: 10) {
                Image(systemName: syncStatusIcon)
                    .foregroundStyle(syncStatusTint)
                Text(message)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if sync.isRestoringSession {
                    ProgressView()
                        .controlSize(.small)
                } else if sync.canRetrySessionRestore {
                    Button {
                        Task { await sync.retrySessionRestore() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry sync")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private var syncStatusIcon: String {
        switch sync.lastErrorKind {
        case .authenticationRequired, .missingSession:
            return "person.crop.circle.badge.exclamationmark"
        case .unavailable:
            return "wifi.exclamationmark"
        case .server, .response, .unknown, nil:
            return "exclamationmark.triangle.fill"
        }
    }

    private var syncStatusTint: Color {
        switch sync.lastErrorKind {
        case .authenticationRequired, .missingSession, .server, .response, .unknown, nil:
            return .orange
        case .unavailable:
            return .yellow
        }
    }

    private func expandToastToSheet() {
        toastTask?.cancel()
        withAnimation { showToast = false }
        showSummary = true
    }

    private func toastHeadline(_ s: DriveSummary) -> String {
        var parts = ["\(s.tilesDriven) tiles"]
        if s.totalCaptured > 0 { parts.append("\(s.totalCaptured) captured") }
        if s.tilesEnclosed > 0 { parts.append("\(s.tilesEnclosed) enclosed") }
        return parts.joined(separator: " · ")
    }
}

struct SessionRecoveryView: View {
    let signIn: AppleSignInCoordinator
    let sync: SyncService
    var onSignedIn: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(sync.lastError ?? "Your session needs to be refreshed before Rev can sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            InviteSignInView(sync: sync) {
                onSignedIn()
            }

            AppleSignInButton(coordinator: signIn) { response in
                sync.adoptSession(response)
                Task { @MainActor in
                    await sync.refreshAfterSignIn()
                    onSignedIn()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        sync.lastErrorKind == .authenticationRequired ? "Sign in again" : "Sign in to sync"
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Player.self, TileRecord.self, DriveRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return RootView(context: container.mainContext)
}
