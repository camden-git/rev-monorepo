import AuthenticationServices
import RevKit
import SwiftUI

struct AppleSignInButton: View {
    let coordinator: AppleSignInCoordinator
    var onAuthenticated: (AuthResponse) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 6) {
            if coordinator.isSignedIn {
                Label("Signed in - empire will sync", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                SignInWithAppleButton(.signIn) { request in
                    coordinator.configure(request)
                } onCompletion: { result in
                    Task { @MainActor in
                        if let response = await coordinator.completeSignIn(with: result) {
                            onAuthenticated(response)
                        }
                    }
                }
                .signInWithAppleButtonStyle(.whiteOutline)
                .frame(height: 44)

                if let error = coordinator.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }
}
