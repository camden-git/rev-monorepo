import Foundation

/// typed PocketBase API surface for the sync layer
public protocol PocketBaseClient: Sendable {
    /// exchange an Apple authorization code for a PocketBase session
    /// `POST /api/collections/users/auth-with-oauth2`
    func authWithApple(authorizationCode: String, fullName: String?) async throws -> AuthResponse

    /// email/password auth `POST /api/collections/users/auth-with-password`
    func authWithPassword(identity: String, password: String) async throws -> AuthResponse

    /// refresh the current token and return the authenticated user
    /// `POST /api/collections/users/auth-refresh`
    func authRefresh() async throws -> AuthResponse

    /// Invite-code auth bypass
    /// `POST /api/rev/auth-with-invite`
    func authWithInvite(displayName: String, email: String, code: String) async throws -> AuthResponse

    /// upload a finished drive, creating the record fires the server resolve hook
    /// `POST /api/collections/drives/records`
    func createDrive(_ payload: DriveUploadPayload) async throws -> DriveRecordDTO

    /// fetch tiles changed since `updatedSince` (nil = full snapshot)
    /// `GET /api/collections/tiles/records?filter=(updated>="…")`
    func listTiles(updatedSince: Date?) async throws -> [TileDTO]

    /// fetch the player roster (every user's public profile)
    /// `GET /api/collections/users/records`
    func listUsers() async throws -> [PlayerDTO]

    /// update the signed-in user's own profile (home hex, color, display name)
    /// `PATCH /api/collections/users/records/{userId}`
    func updateProfile(userId: String, homeH3: UInt64, color: String, displayName: String) async throws
}

/// API connection settings
public struct PocketBaseConfig: Sendable {
    public var baseURL: URL
    public var appleRedirectURL: String

    public init(baseURL: URL, appleRedirectURL: String = "") {
        self.baseURL = baseURL
        self.appleRedirectURL = appleRedirectURL
    }

    /// prod API
    public static let production = PocketBaseConfig(
        baseURL: URL(string: "https://api.driverev.app")!,
        appleRedirectURL: "https://api.driverev.app/api/oauth2-redirect"
    )

    /// local PocketBase for simulator development
    /// this works because the iOS simulator shares the host network
    public static let localSimulator = PocketBaseConfig(
        baseURL: URL(string: "http://localhost:8090")!,
        appleRedirectURL: "http://localhost:8090/api/oauth2-redirect"
    )

    /// local PocketBase for physical-device development over my LAN lol
    public static let phoneDevelopment = PocketBaseConfig(
        baseURL: URL(string: "http://192.168.0.159:8090")!,
        appleRedirectURL: "http://192.168.0.159:8090/api/oauth2-redirect"
    )
}
