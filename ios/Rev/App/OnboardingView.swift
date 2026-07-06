import CoreLocation
import MapKit
import RevKit
import SwiftUI
import UIKit

/// first-launch flow, two steps (REF: docs/game-design.md §Home Hex):
///
///   1. welcome: the game is invite-only, so the invite form is the front door.
///      Sign in with Apple sits behind "Returning player?" for reinstalls
///   2. set home: full-screen map with the center pin and a floating panel,
///      shown once signed in. the chosen coordinate becomes the player's
///      permanent res-10 home hex
struct OnboardingView: View {
    let store: TerritoryStore
    let signIn: AppleSignInCoordinator
    let sync: SyncService

    private static let fallback = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: OnboardingView.fallback,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )
    @State private var centerCoordinate = OnboardingView.fallback
    @State private var addressText = ""
    @State private var isGeocoding = false
    @State private var errorMessage: String?
    @State private var showReturningOptions = false

    private let geocoder = CLGeocoder()

    var body: some View {
        ZStack {
            Map(position: $cameraPosition)
                .onMapCameraChange(frequency: .onEnd) { context in
                    centerCoordinate = context.region.center
                }
                .ignoresSafeArea()

            if sync.isSignedIn {
                homeStep
            } else {
                welcomeStep
            }
        }
        .animation(.snappy, value: sync.isSignedIn)
    }

    // MARK: step 1 - welcome / invite

    private var welcomeStep: some View {
        ZStack {
            // light scrim keeps the card legible while the map stays visible
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    // explicit label color, glass vibrancy washes out semantic styles
                    RevWordmark()
                        .fill(Color(.label))
                        .frame(width: 118, height: 118 * RevWordmark.viewBox.height / RevWordmark.viewBox.width)

                    VStack(spacing: 10) {
                        Text("Rev is invite-only for now")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        InviteSignInView(sync: sync)
                    }

                    returningSection
                }
                .padding(28)
                .glassCard()
                .frame(maxWidth: 480)
                .padding(20)
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var returningSection: some View {
        VStack(spacing: 10) {
            Button(showReturningOptions ? "Hide returning options" : "Returning player?") {
                withAnimation(.snappy) { showReturningOptions.toggle() }
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.borderless)

            if showReturningOptions {
                AppleSignInButton(coordinator: signIn) { response in
                    sync.adoptSession(response)
                    Task { await sync.refreshAfterSignIn() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: step 2 - pick the home hex

    private var homeStep: some View {
        ZStack {
            // fixed center pin, tip on the center point
            Image(systemName: "mappin")
                .font(.title)
                .foregroundStyle(.red)
                .shadow(radius: 2)
                .offset(y: -11)

            VStack {
                addressBar
                Spacer()
                homePanel
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("Search your home address", text: $addressText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(geocode)
                .autocorrectionDisabled()
            if isGeocoding {
                ProgressView()
            } else {
                Button("Search", action: geocode)
                    .buttonStyle(.borderless)
                    .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCapsule()
    }

    private var homePanel: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Set your home")
                    .font(.title3.weight(.semibold))
                Text("Pan the map until the pin sits on your home. Your home hex is permanent, it can never be taken.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // solid prominent style: a glass button inside a glass card washes out
            Button(action: setHome) {
                Label("Set Home Here", systemImage: "house.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(20)
        .glassCard()
    }

    // MARK: actions

    private func geocode() {
        let query = addressText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        errorMessage = nil
        isGeocoding = true
        geocoder.geocodeAddressString(query) { placemarks, _ in
            // CLGeocoder delivers on the main thread, but its closure is nonisolated
            let coordinate = placemarks?.first?.location?.coordinate
            Task { @MainActor in
                isGeocoding = false
                guard let coordinate else {
                    errorMessage = "Couldn't find that address. Try again or drop the pin manually."
                    return
                }
                centerCoordinate = coordinate
                withAnimation {
                    cameraPosition = .region(
                        MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                        )
                    )
                }
            }
        }
    }

    private func setHome() {
        guard let cell = H3Grid.cellId(for: centerCoordinate) else {
            errorMessage = "Couldn't resolve that spot. Move the pin slightly and try again."
            return
        }
        guard HomeSelection.isWithinPlayArea(cell) else {
            errorMessage = "Rev is Chicago-only for now - pick a home inside the city limits."
            return
        }
        guard HomeSelection.isEligible(cell, existingHomes: store.otherPlayerHomeCells) else {
            errorMessage = "That hex is already someone's home. Please pick a different spot."
            return
        }
        store.establishHome(at: cell)
        // push the chosen home hex to the server record so the roster reflects it
        if sync.isSignedIn {
            Task { await sync.pushProfile() }
        }
    }
}

struct InviteSignInView: View {
    let sync: SyncService
    var onSignedIn: () -> Void = {}

    @State private var displayName = ""
    @State private var email = ""
    @State private var code = ""
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if sync.isSignedIn {
                Label("Invite accepted", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                ResponsiveTextField(
                    "Name",
                    text: $displayName,
                    textContentType: .name,
                    autocapitalizationType: .words,
                    autocorrectionType: .no
                )
                .inviteField()
                ResponsiveTextField(
                    "Email",
                    text: $email,
                    textContentType: .emailAddress,
                    keyboardType: .emailAddress,
                    autocapitalizationType: .none,
                    autocorrectionType: .no
                )
                .inviteField()
                ResponsiveTextField(
                    "Invite code",
                    text: $code,
                    autocapitalizationType: .allCharacters,
                    autocorrectionType: .no
                )
                .inviteField()
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    } else {
                        Label("Enter with Invite", systemImage: "key.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4)
                .disabled(!canSubmit || isSubmitting)

                if let error = sync.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        await sync.signInWithInvite(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if sync.isSignedIn {
            onSignedIn()
        }
    }
}

private extension View {
    /// filled field chrome so inputs sit quietly on glass
    func inviteField() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
