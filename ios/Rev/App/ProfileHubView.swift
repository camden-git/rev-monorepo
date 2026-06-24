import RevKit
import SwiftUI

/// the account hub
///
/// built as a `NavigationStack` so it scales
struct ProfileHubView: View {
    let store: TerritoryStore
    let sync: SyncService
    let social: SocialService
    let signIn: AppleSignInCoordinator
    var onDone: () -> Void = {}

    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            List {
                Section { header }

                Section {
                    NavigationLink {
                        DriveHistoryView(store: store, embedded: true)
                    } label: {
                        Label("Empire & Drive History", systemImage: "chart.bar.xaxis")
                    }
                }

                socialSection

                Section {
                    NavigationLink {
                        ProfileSettingsView(store: store, sync: sync, social: social, embedded: true)
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                    }
                }

                accountSection

                #if DEBUG
                Section("Developer") {
                    Button {
                        Task {
                            await sync.devSignIn()
                            await sync.uploadPending()
                        }
                    } label: {
                        Label(
                            sync.isSignedIn ? "Signed in · sync now" : "Dev sign in & sync",
                            systemImage: sync.isSignedIn ? "icloud.fill" : "icloud.slash"
                        )
                    }
                }
                #endif
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .confirmationDialog("Sign out of Rev?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { sync.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your territory stays on this device. You can sign back in anytime.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { Task { await performDelete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, your claimed territory, and your drive history. This cannot be undone.")
            }
            .sheet(isPresented: $showSignIn) {
                SessionRecoveryView(signIn: signIn, sync: sync) { showSignIn = false }
                    .presentationDetents([.height(420), .medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var socialSection: some View {
        if sync.isSignedIn, let userId = sync.currentUserId {
            Section("Social") {
                NavigationLink {
                    ActivityFeedView(store: store, social: social, embedded: true)
                } label: {
                    Label("Activity Feed", systemImage: "figure.run")
                }
                NavigationLink {
                    FollowListView(store: store, social: social, embedded: true)
                } label: {
                    HStack {
                        Label("Friends", systemImage: "person.2.fill")
                        if social.incomingRequestCount > 0 {
                            Spacer()
                            Text("\(social.incomingRequestCount)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                        }
                    }
                }
                NavigationLink {
                    FindPeopleView(store: store, social: social, sync: sync, embedded: true)
                } label: {
                    Label("Find People", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    EmpireStatsView(social: social, userId: userId, title: "My", embedded: true)
                } label: {
                    Label("My Stats Over Time", systemImage: "chart.xyaxis.line")
                }
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if sync.isSignedIn {
                Button { confirmSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    HStack {
                        Label("Delete Account", systemImage: "trash")
                        if isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isDeleting)
                if let deleteError {
                    Text(deleteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } else {
                Button { showSignIn = true } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
    }

    private func performDelete() async {
        isDeleting = true
        deleteError = nil
        let deleted = await sync.deleteAccount()
        isDeleting = false
        if deleted {
            onDone() // dismiss the hub; the app drops to onboarding (needsOnboarding is now true)
        } else {
            deleteError = sync.lastError ?? "Couldn't delete your account. Try again."
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PlayerAvatar(
                colorHex: store.localPlayer.colorHex,
                name: store.localPlayer.displayName,
                size: 56
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(store.localPlayer.displayName)
                    .font(.title3.weight(.semibold))
                if let standing {
                    Text(standing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    /// "Rank #2 · 39 tiles", drawn from the same leaderboard the trophy button shows
    private var standing: String? {
        let board = store.leaderboard()
        guard let index = board.firstIndex(where: { $0.isLocal }) else { return nil }
        return String(format: "Rank #%d · %.1f score", index + 1, board[index].empireScore)
    }
}
