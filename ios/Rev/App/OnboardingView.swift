import CoreLocation
import MapKit
import RevKit
import SwiftUI

/// first-launch home selection (REF: docs/game-design.md §Home Hex)
///
/// the player picks a home either by geocoding an address or by panning a pin on the map. the
/// selected coordinate is converted to a res-10 H3 cell and persisted as their home
///
/// FUTURE (server-side): home assignment moves to signup in `backend/internal/game/`
/// behind Sign-in-with-Apple; this screen would post the chosen `home_h3` with the user record.
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

    private let geocoder = CLGeocoder()

    var body: some View {
        ZStack {
            Map(position: $cameraPosition)
                .onMapCameraChange(frequency: .continuous) { context in
                    centerCoordinate = context.region.center
                }
                .ignoresSafeArea()

            // fixed center pin
            Image(systemName: "mappin")
                .font(.title)
                .foregroundStyle(.red)
                .shadow(radius: 2)
                .offset(y: -11) // tip sits on the center point

            VStack {
                addressBar
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: .constant(true)) {
            confirmPanel
                .presentationDetents([.height(390)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(390)))
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
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

    private var confirmPanel: some View {
        VStack(spacing: 12) {
            Text("Set your home")
                .font(.title3.weight(.semibold))
            Text("Move the map to place the pin on your home, then confirm. Your home hex is permanent, it can never be taken.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: setHome) {
                Label("Set Home Here", systemImage: "house.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .glassProminentButton()

            InviteSignInView(sync: sync)

            // scaffolding lowk
            AppleSignInButton(coordinator: signIn) { response in
                sync.adoptSession(response)
                Task { await sync.refreshAfterSignIn() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        guard HomeSelection.isEligible(cell, existingHomes: store.otherPlayerHomeCells) else {
            errorMessage = "That hex is already someone's home. Please pick a different spot."
            return
        }
        store.establishHome(at: cell)
        // if the player onboarded while already signed in, push the chosen home
        // hex to their server record so the roster reflects it
        if sync.isSignedIn {
            Task { await sync.pushProfile() }
        }
    }
}

private struct InviteSignInView: View {
    let sync: SyncService

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
                TextField("Name", text: $displayName)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                TextField("Invite code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Enter with Invite", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmit || isSubmitting)

                if let error = sync.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        await sync.signInWithInvite(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
    func glassProminentButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(.blue)
        } else {
            buttonStyle(.borderedProminent).tint(.blue)
        }
    }
}
