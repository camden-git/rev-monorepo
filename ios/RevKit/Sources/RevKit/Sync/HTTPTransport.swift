import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// the low-level seam under the typed PocketBase client
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// default transport over `URLSession`
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PocketBaseError.invalidResponse
        }
        return (data, http)
    }
}

/// errors surfaced by the PocketBase client
public enum PocketBaseError: Error, Sendable, Equatable {
    /// non-2xx response include the status and (truncated) body for diagnostics
    case http(status: Int, body: String)
    /// a request needed a bearer token but none was stored
    case notAuthenticated
    /// response body couldn't be decoded into the expected type
    case decoding(String)
    /// response wasn't an HTTP response
    case invalidResponse
}
