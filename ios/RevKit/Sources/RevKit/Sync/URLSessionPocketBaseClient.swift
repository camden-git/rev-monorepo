import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLSession` backed PocketBase client that builds typed requests against the
/// auto generated PocketBase REST endpoints and attaches the bearer token from
/// the `TokenStore`
public final class URLSessionPocketBaseClient: PocketBaseClient {
    private let config: PocketBaseConfig
    private let transport: HTTPTransport
    private let tokenStore: TokenStore
    private let encoder = PocketBaseCoding.makeEncoder()
    private let decoder = PocketBaseCoding.makeDecoder()

    public init(config: PocketBaseConfig, transport: HTTPTransport = URLSessionTransport(), tokenStore: TokenStore) {
        self.config = config
        self.transport = transport
        self.tokenStore = tokenStore
    }

    // MARK: endpoints

    public func authWithApple(authorizationCode: String, fullName: String?) async throws -> AuthResponse {
        // PocketBase performs the OAuth2 code exchange server-side
        var body: [String: Any] = [
            "provider": "apple",
            "code": authorizationCode,
            "codeVerifier": "",
            "redirectURL": config.appleRedirectURL,
        ]
        if let fullName, !fullName.isEmpty {
            body["createData"] = ["display_name": fullName]
        }
        var request = makeRequest(path: "/api/collections/users/auth-with-oauth2", method: "POST", authed: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, decoding: AuthResponse.self)
    }

    public func authWithPassword(identity: String, password: String) async throws -> AuthResponse {
        var request = makeRequest(path: "/api/collections/users/auth-with-password", method: "POST", authed: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["identity": identity, "password": password])
        return try await send(request, decoding: AuthResponse.self)
    }

    public func authRefresh() async throws -> AuthResponse {
        let request = makeRequest(path: "/api/collections/users/auth-refresh", method: "POST", authed: true)
        return try await send(request, decoding: AuthResponse.self)
    }

    public func authWithInvite(displayName: String, email: String, code: String) async throws -> AuthResponse {
        var request = makeRequest(path: "/api/rev/auth-with-invite", method: "POST", authed: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "display_name": displayName,
            "email": email,
            "code": code,
        ])
        return try await send(request, decoding: AuthResponse.self)
    }

    public func createDrive(_ payload: DriveUploadPayload) async throws -> DriveRecordDTO {
        var request = makeRequest(path: "/api/collections/drives/records", method: "POST", authed: true)
        request.httpBody = try encoder.encode(payload)
        return try await send(request, decoding: DriveRecordDTO.self)
    }

    public func listTiles(updatedSince: Date?) async throws -> [TileDTO] {
        var queryItems = [URLQueryItem(name: "perPage", value: "500")]
        if let updatedSince {
            // quote the datetime literal
            let filter = "updated >= \"\(PocketBaseCoding.filterString(for: updatedSince))\""
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        queryItems.append(URLQueryItem(name: "sort", value: "updated"))

        return try await listAllTilePages(queryItems: queryItems)
    }

    public func listTiles(h3Cells: Set<UInt64>) async throws -> [TileDTO] {
        guard !h3Cells.isEmpty else { return [] }

        let parentIds = H3Grid.tileWindowParentIds(for: h3Cells).sorted()
        guard !parentIds.isEmpty else { return [] }

        var request = makeRequest(path: "/api/rev/tiles/window", method: "POST", authed: true)
        request.httpBody = try encoder.encode(TileWindowRequest(
            parentResolution: Int(H3Grid.tileWindowParentResolution.rawValue),
            parents: parentIds
        ))
        return try await send(request, decoding: TileWindowResponse.self).items
    }

    public func listUsers() async throws -> [PlayerDTO] {
        let query = [URLQueryItem(name: "perPage", value: "500")]
        let request = makeRequest(path: "/api/collections/users/records", method: "GET", authed: true, query: query)
        let response = try await send(request, decoding: ListResponse<PlayerDTO>.self)
        return response.items
    }

    public func updateProfile(userId: String, homeH3: UInt64, color: String, displayName: String) async throws {
        var request = makeRequest(path: "/api/collections/users/records/\(userId)", method: "PATCH", authed: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            // home_h3 crosses the wire as a decimal string for exactness (matches the schema's TEXT field)
            "home_h3": String(homeH3),
            "color": color,
            "display_name": displayName,
        ])
        _ = try await send(request, decoding: PlayerDTO.self)
    }

    // MARK: request plumbing

    private func makeRequest(path: String, method: String, authed: Bool, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        if !query.isEmpty { components?.queryItems = query }
        let url = components?.url ?? config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = tokenStore.load() {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(2048), encoding: .utf8) ?? ""
            throw PocketBaseError.http(status: http.statusCode, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PocketBaseError.decoding(String(describing: error))
        }
    }

    private func listAllTilePages(queryItems: [URLQueryItem]) async throws -> [TileDTO] {
        var page = 1
        var all: [TileDTO] = []
        while true {
            var paged = queryItems
            paged.append(URLQueryItem(name: "page", value: "\(page)"))
            let request = makeRequest(path: "/api/collections/tiles/records", method: "GET", authed: true, query: paged)
            let response = try await send(request, decoding: ListResponse<TileDTO>.self)
            all.append(contentsOf: response.items)

            guard response.totalPages > page else { break }
            page += 1
        }
        return all
    }
}
