import Foundation
import Testing
@testable import RevKit

#if canImport(AuthenticationServices)
import AuthenticationServices

/// user-facing message mapping for the Sign in with Apple flow
@MainActor
struct AppleSignInMessageTests {
    @Test func userCancellationIsSilent() {
        let error = ASAuthorizationError(.canceled)
        // a cancel is a normal dismissal, not an error to show
        #expect(AppleSignInCoordinator.userFacingMessage(for: error) == nil)
    }

    @Test func otherAppleErrorsAreFriendly() {
        let error = ASAuthorizationError(.failed)
        let message = AppleSignInCoordinator.userFacingMessage(for: error)
        #expect(message == "Sign in with Apple couldn't complete. Please try again.")
    }

    @Test func serverRejectionIsFriendlyNotRaw() {
        let error = PocketBaseError.http(status: 400, body: #"{"message":"bad code"}"#)
        let message = AppleSignInCoordinator.userFacingMessage(for: error)
        // must not leak the raw status/body dump to the user
        #expect(message == "The server couldn't finish signing you in. Please try again.")
        #expect(message?.contains("400") == false)
    }

    @Test func offlineIsFriendly() {
        let error = URLError(.notConnectedToInternet)
        let message = AppleSignInCoordinator.userFacingMessage(for: error)
        #expect(message == "You appear to be offline. Connect to the internet and try again.")
    }

    @Test func missingCredentialIsFriendly() {
        let message = AppleSignInCoordinator.userFacingMessage(for: AppleAuthError.missingAuthorizationCode)
        #expect(message == "Sign in with Apple didn't return the expected credentials. Please try again.")
    }
}
#endif
