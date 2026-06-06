import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// live push of server-authoritative tile changes
public protocol TileRealtimeClient: AnyObject, Sendable {
    /// open the stream and deliver events until `stop()`
    /// - `onConnect`: fired on every (re)connect, the caller backfills anything
    ///   missed while disconnected via the existing delta-poll
    /// - `onTile`: one server-pushed tile, fed straight into `applyRemoteTiles`
    func start(
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    )
    func stop()
}

/// PocketBase realtime (SSE) consumer of the `tiles` collection topic
public final class PocketBaseRealtimeClient: TileRealtimeClient, @unchecked Sendable {
    private let realtimeURL: URL
    private let tokenStore: TokenStore
    private let session: URLSession
    private let decoder = PocketBaseCoding.makeDecoder()

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    #if canImport(os)
    private let logger = Logger(subsystem: "app.driverev.RevKit", category: "RealtimeClient")
    #endif

    public init(config: PocketBaseConfig, tokenStore: TokenStore, session: URLSession? = nil) {
        self.realtimeURL = config.baseURL.appendingPathComponent("api/realtime")
        self.tokenStore = tokenStore
        self.session = session ?? PocketBaseRealtimeClient.makeStreamingSession()
    }

    /// a long-lived SSE connection must not be killed by the default per-request
    /// inactivity timeout, the reconnect loop still covers any drop
    private static func makeStreamingSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    public func start(
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    ) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop(onConnect: onConnect, onTile: onTile)
        }
    }

    public func stop() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    // MARK: stream loop

    private func runLoop(
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    ) async {
        var backoffSeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try await connectAndStream(onConnect: onConnect, onTile: onTile)
                backoffSeconds = 1 // clean EOF, reconnect promptly
            } catch is CancellationError {
                return
            } catch {
                logFailure(error)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    private func connectAndStream(
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    ) async throws {
        var request = URLRequest(url: realtimeURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PocketBaseError.invalidResponse
        }

        var event = SSEEvent()
        for try await line in bytes.lines {
            if line.isEmpty {
                try await dispatch(event, onConnect: onConnect, onTile: onTile)
                event = SSEEvent()
            } else {
                event.consume(line)
            }
        }
    }

    private func dispatch(
        _ event: SSEEvent,
        onConnect: @escaping @MainActor @Sendable () -> Void,
        onTile: @escaping @MainActor @Sendable (TileDTO) -> Void
    ) async throws {
        guard let name = event.event else { return }

        if name == "PB_CONNECT" {
            guard let clientId = clientId(from: event.data) else { return }
            try await setSubscriptions(clientId: clientId)
            await onConnect()
            return
        }

        guard name == "tiles", let dto = tile(from: event.data) else { return }
        await onTile(dto)
    }

    /// register the connection's subscription list (PocketBase `POST /api/realtime`),
    /// the bearer token authorizes the `tiles` topic against the collection's
    /// auth-only list rule
    private func setSubscriptions(clientId: String) async throws {
        var request = URLRequest(url: realtimeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = tokenStore.load() {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "subscriptions": ["tiles"],
        ])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PocketBaseError.invalidResponse
        }
    }

    // MARK: payload decoding

    private func clientId(from data: String) -> String? {
        guard let bytes = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        return object["clientId"] as? String
    }

    /// decode the `record` out of a `{action, record}` envelope
    private func tile(from data: String) -> TileDTO? {
        guard let bytes = data.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (envelope["action"] as? String) != "delete",
              let record = envelope["record"],
              let recordData = try? JSONSerialization.data(withJSONObject: record)
        else { return nil }
        return try? decoder.decode(TileDTO.self, from: recordData)
    }

    private func logFailure(_ error: Error) {
        #if canImport(os)
        logger.error("realtime stream dropped, reconnecting: \(String(describing: error), privacy: .public)")
        #else
        print("realtime stream dropped: \(error)")
        #endif
    }
}

/// accumulates the `field:value` lines of one SSE event until its blank-line terminator
private struct SSEEvent {
    var event: String?
    var data: String = ""

    mutating func consume(_ line: String) {
        if let value = Self.value(of: "event:", in: line) {
            event = value
        } else if let value = Self.value(of: "data:", in: line) {
            if !data.isEmpty { data += "\n" }
            data += value
        }
        // `id:` and comment (`:`) lines are ignored
    }

    /// strip the SSE field name and a single optional leading space
    private static func value(of field: String, in line: String) -> String? {
        guard line.hasPrefix(field) else { return nil }
        var value = line.dropFirst(field.count)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }
}
