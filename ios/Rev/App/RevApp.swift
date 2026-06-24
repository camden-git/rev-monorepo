import RevKit
import SwiftData
import SwiftUI

@main
struct RevApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Player.self, TileRecord.self, DriveRecord.self)
        } catch {
            fatalError("failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(context: container.mainContext, push: appDelegate.push)
        }
        .modelContainer(container)
    }
}
