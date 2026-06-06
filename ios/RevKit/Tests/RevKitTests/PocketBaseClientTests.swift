import Foundation
import Testing
@testable import RevKit

/// tests the real `URLSessionPocketBaseClient` against a mock transport
struct PocketBaseClientTests {
    private func makeClient(_ transport: MockHTTPTransport, token: String? = "tok") -> URLSessionPocketBaseClient {
        URLSessionPocketBaseClient(
            config: PocketBaseConfig(baseURL: URL(string: "https://api.test")!, appleRedirectURL: "https://api.test/redir"),
            transport: transport,
            tokenStore: InMemoryTokenStore(token: token)
        )
    }

    @Test func createDriveBuildsAuthedPostWithStringKeyedScores() async throws {
        let respBody = Data(#"{"id":"abc123","created":"2026-06-04 12:00:00.000Z"}"#.utf8)
        let transport = MockHTTPTransport { _ in (respBody, httpResponse(200)) }
        let client = makeClient(transport)

        let cell = SyncFixtures.cell
        let payload = DriveUploadPayload(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_100),
            rawPath: [GPSSample(timestamp: Date(timeIntervalSince1970: 1_000_000), lat: 41.88, lng: -87.62, speed: 10, accuracy: 5)],
            perTileScores: [cell: 32.5]
        )

        let dto = try await client.createDrive(payload)
        #expect(dto.id == "abc123")

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/collections/drives/records")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "tok")

        // this tests exactness
        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        #expect(json?["user"] == nil)
        #expect(json?["raw_path"] != nil)
        let scores = json?["per_tile_scores"] as? [String: Any]
        #expect(scores?["\(cell)"] as? Double == 32.5)
    }

    @Test func listTilesAddsUpdatedFilterAndDecodesStringH3() async throws {
        let cell = SyncFixtures.cell
        let listJSON = """
        {"page":1,"perPage":500,"totalItems":1,"totalPages":1,"items":[
          {"id":"t1","h3":"\(cell)","owner":"u2","claim_score":40.5,"last_driven_at":"2026-06-01 09:00:00.000Z","is_home":false,"updated":"2026-06-02 09:00:00.000Z"}
        ]}
        """
        let transport = MockHTTPTransport { _ in (Data(listJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport)

        let tiles = try await client.listTiles(updatedSince: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(tiles.count == 1)
        let tile = try #require(tiles.first)
        #expect(tile.h3 == cell) // string -> uint64, no precision loss
        #expect(tile.owner == "u2")
        #expect(tile.claimScore == 40.5)
        #expect(tile.isHome == false)

        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.contains("/api/collections/tiles/records"))
        #expect(url.contains("filter"))
        #expect(url.contains("updated"))
    }

    @Test func listTilesWithoutCursorOmitsFilter() async throws {
        let empty = Data(#"{"page":1,"perPage":500,"totalItems":0,"totalPages":0,"items":[]}"#.utf8)
        let transport = MockHTTPTransport { _ in (empty, httpResponse(200)) }
        let client = makeClient(transport)

        _ = try await client.listTiles(updatedSince: nil)
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(!url.contains("filter"))
    }

    @Test func listTilesByCellsPostsCompactParentWindow() async throws {
        let cell = SyncFixtures.cell
        let listJSON = """
        {"items":[
          {"id":"t1","h3":"\(cell)","owner":"u2","claim_score":40.5,"last_driven_at":"2026-06-01 09:00:00.000Z","is_home":false,"updated":"2026-06-02 09:00:00.000Z"}
        ]}
        """
        let transport = MockHTTPTransport { _ in (Data(listJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport)

        let tiles = try await client.listTiles(h3Cells: [cell, cell &+ 1])

        #expect(tiles.map(\.h3) == [cell])
        #expect(transport.requests.count == 1)
        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/rev/tiles/window")
        #expect(req.url?.query == nil)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "tok")

        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        #expect(json?["parent_resolution"] as? Int == 8)
        let parents = try #require(json?["parents"] as? [String])
        #expect(!parents.isEmpty)
        #expect(parents.count < 3)
        #expect(parents.allSatisfy { UInt64($0) != nil })
    }

    @Test func authWithApplePostsProviderAndCode() async throws {
        let authJSON = #"{"token":"sess-token","record":{"id":"u9","email":"a@b.com","display_name":"Ann"}}"#
        let transport = MockHTTPTransport { _ in (Data(authJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport, token: nil)

        let resp = try await client.authWithApple(authorizationCode: "apple-code", fullName: "Ann")
        #expect(resp.token == "sess-token")
        #expect(resp.record.id == "u9")

        let req = try #require(transport.requests.first)
        #expect(req.url?.path == "/api/collections/users/auth-with-oauth2")
        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        #expect(json?["provider"] as? String == "apple")
        #expect(json?["code"] as? String == "apple-code")
    }

    @Test func authRefreshPostsWithBearerToken() async throws {
        let authJSON = #"{"token":"fresh-token","record":{"id":"u9","email":"a@b.com","display_name":"Ann"}}"#
        let transport = MockHTTPTransport { _ in (Data(authJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport, token: "old-token")

        let resp = try await client.authRefresh()
        #expect(resp.token == "fresh-token")
        #expect(resp.record.id == "u9")

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/collections/users/auth-refresh")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "old-token")
    }

    @Test func authWithInvitePostsInfoAndCode() async throws {
        let authJSON = #"{"token":"invite-token","record":{"id":"u10","email":"cam@example.com","display_name":"Cam"}}"#
        let transport = MockHTTPTransport { _ in (Data(authJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport, token: nil)

        let resp = try await client.authWithInvite(displayName: "Cam", email: "cam@example.com", code: "loop-1")
        #expect(resp.token == "invite-token")
        #expect(resp.record.id == "u10")

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/rev/auth-with-invite")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        #expect(json?["display_name"] as? String == "Cam")
        #expect(json?["email"] as? String == "cam@example.com")
        #expect(json?["code"] as? String == "loop-1")
    }

    @Test func listUsersDecodesRosterWithStringHomeH3() async throws {
        let home = SyncFixtures.cell
        let listJSON = """
        {"page":1,"perPage":500,"totalItems":2,"totalPages":1,"items":[
          {"id":"u1","display_name":"Ada","color":"#EF4444","home_h3":"\(home)"},
          {"id":"u2","display_name":"Owen","color":"#22C55E","home_h3":"0"}
        ]}
        """
        let transport = MockHTTPTransport { _ in (Data(listJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport)

        let players = try await client.listUsers()
        #expect(players.count == 2)
        let ada = try #require(players.first)
        #expect(ada.id == "u1")
        #expect(ada.displayName == "Ada")
        #expect(ada.color == "#EF4444")
        #expect(ada.homeH3 == home) // string -> uint64, no precision loss
        #expect(players[1].homeH3 == 0)

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/api/collections/users/records")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "tok")
    }

    @Test func updateProfilePatchesOwnRecordWithStringHomeH3() async throws {
        let home = SyncFixtures.cell
        let respJSON = """
        {"id":"u9","display_name":"Cam","color":"#3B82F6","home_h3":"\(home)"}
        """
        let transport = MockHTTPTransport { _ in (Data(respJSON.utf8), httpResponse(200)) }
        let client = makeClient(transport)

        try await client.updateProfile(userId: "u9", homeH3: home, color: "#3B82F6", displayName: "Cam")

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "PATCH")
        #expect(req.url?.path == "/api/collections/users/records/u9")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "tok")

        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        #expect(json?["home_h3"] as? String == "\(home)") // exact, as a decimal string
        #expect(json?["color"] as? String == "#3B82F6")
        #expect(json?["display_name"] as? String == "Cam")
    }

    @Test func non2xxThrowsHTTPError() async throws {
        let transport = MockHTTPTransport { _ in (Data(#"{"message":"bad"}"#.utf8), httpResponse(400)) }
        let client = makeClient(transport)
        await #expect(throws: PocketBaseError.self) {
            _ = try await client.listTiles(updatedSince: nil)
        }
    }

    @Test func authedRequestWithoutTokenFailsBeforeNetwork() async throws {
        let transport = MockHTTPTransport { _ in (Data(), httpResponse(200)) }
        let client = makeClient(transport, token: nil)

        await #expect(throws: PocketBaseError.self) {
            _ = try await client.listUsers()
        }
        #expect(transport.requests.isEmpty)
    }
}
