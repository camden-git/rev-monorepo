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
    var onClaimTiles: @Sendable ([UInt64: Double]) throws -> Void = { _ in }
    var onListTiles: @Sendable (Date?) throws -> [TileDTO] = { _ in [] }
    var onListTilesForCells: @Sendable (Set<UInt64>) throws -> [TileDTO] = { _ in [] }
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
    var onDeleteAccount: @Sendable () throws -> Void = { }

    private(set) var createdPayloads: [DriveUploadPayload] = []
    private(set) var claimBatches: [[UInt64: Double]] = []
    private(set) var listSinceArgs: [Date?] = []
    private(set) var listCellArgs: [Set<UInt64>] = []
    private(set) var listUsersCallCount = 0
    private(set) var authRefreshCount = 0
    private(set) var deleteAccountCount = 0
    private(set) var profileUpdates: [(userId: String, homeH3: UInt64, color: String, displayName: String)] = []

    func authWithApple(authorizationCode: String, fullName: String?) async throws -> AuthResponse {
        try onAuth(authorizationCode, fullName)
    }

    func authWithPassword(identity: String, password: String) async throws -> AuthResponse {
        try onAuth(identity, password)
    }

    func authRefresh() async throws -> AuthResponse {
        lock.withLock { authRefreshCount += 1 }
        return try onAuthRefresh()
    }

    func authWithInvite(displayName: String, email: String, code: String) async throws -> AuthResponse {
        try onInviteAuth(displayName, email, code)
    }

    func createDrive(_ payload: DriveUploadPayload) async throws -> DriveRecordDTO {
        lock.withLock { createdPayloads.append(payload) }
        return try onCreateDrive(payload)
    }

    func claimTiles(perTileScores: [UInt64: Double]) async throws {
        lock.withLock { claimBatches.append(perTileScores) }
        try onClaimTiles(perTileScores)
    }

    func listTiles(updatedSince: Date?) async throws -> [TileDTO] {
        lock.withLock { listSinceArgs.append(updatedSince) }
        return try onListTiles(updatedSince)
    }

    func listTiles(h3Cells: Set<UInt64>) async throws -> [TileDTO] {
        lock.withLock { listCellArgs.append(h3Cells) }
        return try onListTilesForCells(h3Cells)
    }

    func listUsers() async throws -> [PlayerDTO] {
        lock.withLock { listUsersCallCount += 1 }
        return try onListUsers()
    }

    func updateProfile(userId: String, homeH3: UInt64, color: String, displayName: String) async throws {
        lock.withLock { profileUpdates.append((userId, homeH3, color, displayName)) }
        try onUpdateProfile(userId, homeH3, color, displayName)
    }

    func deleteAccount() async throws {
        lock.withLock { deleteAccountCount += 1 }
        try onDeleteAccount()
    }

    func updatePrivacy(userId: String, isPrivate: Bool) async throws {}

    func fetchProfile(userId: String) async throws -> ProfileDTO {
        throw PocketBaseError.notAuthenticated
    }

    func fetchStats(userId: String) async throws -> [EmpireSnapshotDTO] { [] }

    func fetchFeed() async throws -> [FeedItemDTO] { [] }

    func listFollows() async throws -> [FollowRecordDTO] { [] }

    func createFollow(followerId: String, followeeId: String) async throws -> FollowRecordDTO {
        throw PocketBaseError.notAuthenticated
    }

    func acceptFollow(edgeId: String) async throws {}

    func removeFollow(edgeId: String) async throws {}

    var onRegisterDevice: @Sendable (String, PushEnvironment) throws -> Void = { _, _ in }
    var onUnregisterDevice: @Sendable (String) throws -> Void = { _ in }
    private(set) var registeredDevices: [(token: String, environment: PushEnvironment)] = []
    private(set) var unregisteredTokens: [String] = []

    func registerDevice(token: String, environment: PushEnvironment) async throws {
        lock.withLock { registeredDevices.append((token, environment)) }
        try onRegisterDevice(token, environment)
    }

    func unregisterDevice(token: String) async throws {
        lock.withLock { unregisteredTokens.append(token) }
        try onUnregisterDevice(token)
    }
}

// MARK: realtime mock

/// stubbable `TileRealtimeClient` that lets tests drive server pushes by hand
final class MockTileRealtimeClient: TileRealtimeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var onConnect: (@MainActor @Sendable () -> Void)?
    private var onTile: (@MainActor @Sendable (TileDTO) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var isRunning: Bool { lock.withLock { onConnect != nil } }

    func start(
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    ) {
        lock.withLock {
            startCount += 1
            self.onConnect = onConnect
            self.onTile = onTile
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            onConnect = nil
            onTile = nil
        }
    }

    /// simulate a server-pushed tile reaching the client
    @MainActor func emit(_ dto: TileDTO) {
        let handler = lock.withLock { onTile }
        handler?(dto)
    }

    /// simulate a (re)connect handshake completing
    @MainActor func simulateConnect() {
        let handler = lock.withLock { onConnect }
        handler?()
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

    static func payload(id: UUID = UUID()) -> PendingDrive {
        PendingDrive(
            id: id,
            payload: DriveUploadPayload(
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
