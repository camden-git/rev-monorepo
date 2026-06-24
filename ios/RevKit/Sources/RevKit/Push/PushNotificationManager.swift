#if canImport(UIKit) && canImport(UserNotifications)
import Foundation
import UIKit
import UserNotifications
#if canImport(os)
import os
#endif

/// owns the device's push-notification permission and APNs registration state.
///
/// the raw APNs token arrives through the `UIApplicationDelegate`, which forwards
/// it here via `didRegister(deviceToken:)`; `onToken` then hands the hex token and
/// resolved environment to the sync layer to register with the backend.
@MainActor
@Observable
public final class PushNotificationManager {
    /// current system authorization status, refreshed on foreground
    public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// the most recent APNs token as a lowercase hex string, once registered
    public private(set) var deviceToken: String?

    /// called with the hex token + environment whenever a fresh token arrives
    public var onToken: (@MainActor (String, PushEnvironment) async -> Void)?
    /// called when the user taps a notification, with its routing payload
    public var onOpen: (@MainActor (PushNotificationContent) -> Void)?

    private let environment: PushEnvironment

    #if canImport(os)
    private let logger = Logger(subsystem: "app.driverev.RevKit", category: "Push")
    #endif

    public init(environment: PushEnvironment = PushNotificationManager.resolveEnvironment()) {
        self.environment = environment
    }

    public var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral
    }

    /// re-read the system authorization status (it can change in Settings while
    /// the app is backgrounded)
    public func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// prompt for permission only if the user has not answered yet, then register
    /// for remote notifications if granted. returns the resulting authorization.
    @discardableResult
    public func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            return await requestAuthorization()
        }
        if isAuthorized {
            registerForRemoteNotifications()
        }
        return isAuthorized
    }

    /// explicitly prompt for permission (used by the settings toggle)
    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                registerForRemoteNotifications()
            }
            return granted
        } catch {
            log("authorization request failed: \(error)")
            return false
        }
    }

    /// ask the system for an APNs token; the result lands in `didRegister`
    public func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: app-delegate forwarding

    /// called from the app delegate with the raw APNs token bytes
    public func didRegister(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        let env = environment
        Task { await onToken?(hex, env) }
    }

    /// called from the app delegate when APNs registration fails
    public func didFailToRegister(error: Error) {
        log("remote notification registration failed: \(error)")
    }

    /// called from the app delegate when the user taps a notification
    public func handleOpen(_ content: PushNotificationContent) {
        onOpen?(content)
    }

    // MARK: environment

    /// determine which APNs host this build's token is valid against by reading
    /// the `aps-environment` from the embedded provisioning profile. App Store
    /// builds have the profile stripped and are always production; the simulator
    /// is treated as sandbox.
    public static func resolveEnvironment() -> PushEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let raw = String(data: data, encoding: .ascii),
            let start = raw.range(of: "<?xml"),
            let end = raw.range(of: "</plist>")
        else {
            return .production
        }
        let plistString = String(raw[start.lowerBound..<end.upperBound])
        guard
            let plistData = plistString.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else {
            return .production
        }
        return aps == "production" ? .production : .sandbox
        #endif
    }

    private func log(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        print("Push: \(message)")
        #endif
    }
}

/// the routing payload parsed from a tapped notification's `userInfo`
public struct PushNotificationContent: Sendable, Equatable {
    public let type: String
    public let userId: String?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return nil }
        self.type = type
        self.userId = userInfo["user_id"] as? String ?? userInfo["attacker_id"] as? String
    }

    public init(type: String, userId: String?) {
        self.type = type
        self.userId = userId
    }
}
#endif
