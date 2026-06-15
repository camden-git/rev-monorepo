import Foundation

/// errors from the Sign in with Apple flow
public enum AppleAuthError: Error, Sendable, Equatable {
    case missingAuthorizationCode
    case unexpectedCredential
}

#if canImport(AuthenticationServices)
import AuthenticationServices

/// Drives Sign in with Apple → PocketBase auth (REF: docs/tech-stack.md §Auth).
/// Pair it with SwiftUI's `SignInWithAppleButton`: hand its `onCompletion`
/// result to `completeSignIn(with:)`. The coordinator extracts Apple's
/// authorization code, exchanges it via the PocketBase client, and stores the
/// returned session token in the `TokenStore`.
///
/// SETUP: requires the Apple Service ID / Key configured server-side in
/// PocketBase (see backend/README.md). The exchange call will fail against a
/// real server until those Apple provider settings are filled in.
@MainActor
@Observable
public final class AppleSignInCoordinator {
    private let client: PocketBaseClient
    private let tokenStore: TokenStore

    /// The signed-in user, or nil if not authenticated.
    public private(set) var session: AuthResponse?
    public private(set) var lastError: String?

    public init(client: PocketBaseClient, tokenStore: TokenStore) {
        self.client = client
        self.tokenStore = tokenStore
    }

    public var isSignedIn: Bool { tokenStore.load() != nil }

    /// Configure a `SignInWithAppleButton` request (ask for name on first sign-in).
    public func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// Process the result handed back by `SignInWithAppleButton.onCompletion`.
    @discardableResult
    public func completeSignIn(with result: Result<ASAuthorization, Error>) async -> AuthResponse? {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AppleAuthError.unexpectedCredential
            }
            guard let codeData = credential.authorizationCode,
                  let code = String(data: codeData, encoding: .utf8)
            else {
                throw AppleAuthError.missingAuthorizationCode
            }
            let fullName = credential.fullName.flatMap { components -> String? in
                let formatter = PersonNameComponentsFormatter()
                let name = formatter.string(from: components)
                return name.isEmpty ? nil : name
            }

            let response = try await client.authWithApple(authorizationCode: code, fullName: fullName)
            tokenStore.save(response.token)
            session = response
            lastError = nil
            return response
        } catch {
            // nil message = a silent outcome (the user cancelled), so no scary red
            // error is shown for a normal dismissal
            lastError = Self.userFacingMessage(for: error)
            return nil
        }
    }

    /// map a sign-in failure to a friendly message, or `nil` when the user simply
    /// cancelled and nothing should be surfaced. never shows the raw error dump.
    static func userFacingMessage(for error: Error) -> String? {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                return nil
            default:
                return "Sign in with Apple couldn't complete. Please try again."
            }
        }
        if error is AppleAuthError {
            return "Sign in with Apple didn't return the expected credentials. Please try again."
        }
        if let pbError = error as? PocketBaseError {
            switch pbError {
            case .http, .notAuthenticated:
                return "The server couldn't finish signing you in. Please try again."
            case .decoding, .invalidResponse:
                return "Got an unexpected response while signing in. Please try again."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed:
                return "You appear to be offline. Connect to the internet and try again."
            default:
                break
            }
        }
        return "Couldn't complete sign in. Please try again."
    }

    /// Sign out: drop the stored token + session.
    public func signOut() {
        tokenStore.clear()
        session = nil
    }
}
#endif
