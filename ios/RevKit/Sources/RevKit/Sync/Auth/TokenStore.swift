import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(os)
import os
#endif

/// stores the PocketBase auth token
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

/// In-memory token store for tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func save(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

#if canImport(Security)
/// Keychain-backed token store (REF: docs/tech-stack.md §Auth - "Client stores
/// the auth token in the Keychain"). Generic-password item keyed by service +
/// account.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "app.driverev.Rev.auth", account: String = "pocketbase-token") {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) {
        let data = Data(token.utf8)
        // upsert: try update first, fall back to add.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            // ThisDeviceOnly: the bearer token must not ride along in encrypted
            // iCloud/iTunes Keychain backups to other devices.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { logKeychainFailure("add", addStatus) }
        } else if status != errSecSuccess {
            logKeychainFailure("update", status)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// A failed write means `load()` later returns nil and the user silently
    /// appears signed out
    private func logKeychainFailure(_ op: String, _ status: OSStatus) {
        #if canImport(os)
        Logger(subsystem: "app.driverev.Rev", category: "TokenStore")
            .error("Keychain \(op, privacy: .public) failed: status=\(status, privacy: .public)")
        #endif
    }
}
#endif
