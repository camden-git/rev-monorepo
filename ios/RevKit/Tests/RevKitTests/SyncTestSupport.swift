import Foundation
@testable import RevKit

// MARK: transport mock

/// captures outgoing requests and returns a canned response
final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) -> (Data, HTTPURLResponse)

    init(responder: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) {
        self.responder = responder
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        return responder(request)
    }
}

func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: client mock

/// stubbable PocketBaseClient for queue / sync-engine tests
final class MockPocketBaseClient: PocketBaseClient, @unchecked Sendable {
    private let lock = NSLock()

    var onCreateDrive: @Sendable (DriveUploadPayload) throws -> DriveRecordDTO = { _ in
        DriveRecordDTO(id: "rec", created: nil)
    }
    var onListTiles: @Sendable (Date?) throws -> [TileDTO] = { _ in [] }
    var onAuth: @Sendable (String, String?) throws -> AuthResponse = { _, _ in
        AuthResponse(token: "tok", record: AuthUserDTO(id: "u", email: nil, displayName: nil))
    }
    var onAuthRefresh: @Sendable () throws -> AuthResponse = {
        AuthResponse(token: "tok", record: AuthUserDTO(id: "u", email: nil, displayName: nil))
    }
    var onInviteAuth: @Sendable (String, String, String) throws -> AuthResponse = { _, _, _ in
        AuthResponse(token: "tok", record: AuthUserDTO(id: "u", email: nil, displayName: nil))
    }
    var onListUsers: @Sendable () throws -> [PlayerDTO] = { [] }
    var onUpdateProfile: @Sendable (String, UInt64, String, String) throws -> Void = { _, _, _, _ in }

    private(set) var createdPayloads: [DriveUploadPayload] = []
    private(set) var listSinceArgs: [Date?] = []
    private(set) var listUsersCallCount = 0
    private(set) var profileUpdates: [(userId: String, homeH3: UInt64, color: String, displayName: String)] = []

    func authWithApple(authorizationCode: String, fullName: String?) async throws -> AuthResponse {
        try onAuth(authorizationCode, fullName)
    }

    func authWithPassword(identity: String, password: String) async throws -> AuthResponse {
        try onAuth(identity, password)
    }

    func authRefresh() async throws -> AuthResponse {
        try onAuthRefresh()
    }

    func authWithInvite(displayName: String, email: String, code: String) async throws -> AuthResponse {
        try onInviteAuth(displayName, email, code)
    }

    func createDrive(_ payload: DriveUploadPayload) async throws -> DriveRecordDTO {
        lock.withLock { createdPayloads.append(payload) }
        return try onCreateDrive(payload)
    }

    func listTiles(updatedSince: Date?) async throws -> [TileDTO] {
        lock.withLock { listSinceArgs.append(updatedSince) }
        return try onListTiles(updatedSince)
    }

    func listUsers() async throws -> [PlayerDTO] {
        lock.withLock { listUsersCallCount += 1 }
        return try onListUsers()
    }

    func updateProfile(userId: String, homeH3: UInt64, color: String, displayName: String) async throws {
        lock.withLock { profileUpdates.append((userId, homeH3, color, displayName)) }
        try onUpdateProfile(userId, homeH3, color, displayName)
    }
}

// MARK: unsent-drive source fake

/// in-memory `UnsentDriveSource` for upload-queue tests
@MainActor
final class FakeUnsentDriveSource: UnsentDriveSource {
    var pending: [PendingDrive]
    private(set) var marked: [UUID] = []

    init(_ pending: [PendingDrive]) { self.pending = pending }

    func unsent() -> [PendingDrive] { pending.filter { !marked.contains($0.id) } }
    func markUploaded(_ id: UUID) { marked.append(id) }
}

// MARK: shared fixtures

enum SyncFixtures {
    /// a real res-10 H3 cell id (> 2^53)
    static let cell: UInt64 = H3Grid.cellId(for: .init(latitude: 41.8807, longitude: -87.6294))!

    static func payload(user: String = "user1", id: UUID = UUID()) -> PendingDrive {
        PendingDrive(
            id: id,
            payload: DriveUploadPayload(
                user: user,
                startedAt: Date(timeIntervalSince1970: 1_000_000),
                endedAt: Date(timeIntervalSince1970: 1_000_120),
                rawPath: [GPSSample(timestamp: Date(timeIntervalSince1970: 1_000_000), lat: 41.88, lng: -87.62, speed: 12, accuracy: 5)],
                perTileScores: [cell: 33.0]
            )
        )
    }
}

/// `TileDTO` builder usable from `@Sendable` mock closures
func makeTileDTO(_ h3: UInt64, owner: String, score: Double, updated: Date) -> TileDTO {
    TileDTO(id: "id-\(h3)", h3: h3, owner: owner, claimScore: score, lastDrivenAt: updated, isHome: false, updated: updated)
}

/// `PlayerDTO` builder usable from `@Sendable` mock closures
func makePlayerDTO(_ id: String, name: String, color: String, homeH3: UInt64 = 0) -> PlayerDTO {
    PlayerDTO(id: id, displayName: name, color: color, homeH3: homeH3)
}
