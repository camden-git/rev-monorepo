import RevKit
import UIKit
import UserNotifications

/// bridges the UIKit push-notification callbacks (which only reach a
/// `UIApplicationDelegate`) into the `PushNotificationManager` the SwiftUI views
/// observe. Installed via `@UIApplicationDelegateAdaptor` in `RevApp`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let push = PushNotificationManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        push.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        push.didFailToRegister(error: error)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// show banners + play sound even while the app is foregrounded
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// route a tapped notification into the app
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // parse the Sendable routing payload in this nonisolated context so only
        // it (not the non-Sendable userInfo) crosses to the main actor
        let content = PushNotificationContent(userInfo: response.notification.request.content.userInfo)
        completionHandler()
        guard let content else { return }
        Task { @MainActor in push.handleOpen(content) }
    }
}
