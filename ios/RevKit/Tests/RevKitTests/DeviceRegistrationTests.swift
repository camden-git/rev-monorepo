import Foundation
import SwiftData
import Testing
@testable import RevKit

/// APNs device-token registration lifecycle on SyncService
@MainActor
@Suite(.serialized)
struct DeviceRegistrationTests {
    static let container: ModelContainer = {
        try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private func makeSync(client: PocketBaseClient, tokenStore: TokenStore = InMemoryTokenStore()) -> SyncService {
        SyncService(
            store: TerritoryStore(context: Self.container.mainContext),
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
            cursor: InMemorySyncCursor(),
            realtime: MockTileRealtimeClient()
        )
    }

    private func signIn(_ sync: SyncService) {
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
    }

    @Test func tokenWhileSignedInRegistersImmediately() async {
        let client = MockPocketBaseClient()
        let sync = makeSync(client: client)
        signIn(sync)

        await sync.registerDeviceToken("abc123", environment: .sandbox)

        #expect(client.registeredDevices.count == 1)
        #expect(client.registeredDevices.first?.token == "abc123")
        #expect(client.registeredDevices.first?.environment == .sandbox)
    }

    @Test func tokenWhileSignedOutIsHeldUntilSignIn() async {
        let client = MockPocketBaseClient()
        let sync = makeSync(client: client)

        // arrives before sign-in -> nothing registered yet
        await sync.registerDeviceToken("held", environment: .production)
        #expect(client.registeredDevices.isEmpty)

        // the post-sign-in refresh flushes the held token
        signIn(sync)
        await sync.refreshAfterSignIn()

        #expect(client.registeredDevices.contains { $0.token == "held" && $0.environment == .production })
    }

    @Test func signOutUnregistersTheDevice() async {
        let client = MockPocketBaseClient()
        let sync = makeSync(client: client)
        signIn(sync)
        await sync.registerDeviceToken("tok", environment: .production)

        sync.signOut()
        // the unregister runs in a detached task; let it settle
        try? await Task.sleep(for: .milliseconds(50))

        #expect(client.unregisteredTokens == ["tok"])
        #expect(!sync.isSignedIn)
    }

    @Test func signOutWithoutTokenStillSignsOut() async {
        let client = MockPocketBaseClient()
        let sync = makeSync(client: client)
        signIn(sync)

        sync.signOut()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(client.unregisteredTokens.isEmpty)
        #expect(!sync.isSignedIn)
    }
}
