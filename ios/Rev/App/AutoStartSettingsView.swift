import RevKit
import SwiftUI

/// per-motion-type toggles for auto-starting drives
struct AutoStartSettingsView: View {
    @Bindable var preferences: AutoStartPreferences

    var embedded = false
    var onDone: () -> Void = {}

    var body: some View {
        if embedded {
            form
                .navigationTitle("Auto-Start")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            NavigationStack {
                form
                    .navigationTitle("Auto-Start")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.automotive) { row(.automotive) }
                Toggle(isOn: $preferences.cycling) { row(.cycling) }
                Toggle(isOn: $preferences.walking) { row(.walking) }
                Toggle(isOn: $preferences.running) { row(.running) }
            } header: {
                Text("Start a drive automatically when I'm")
            } footer: {
                Text("Rev begins recording on its own when it detects one of these activities. Turn one off and you'll need to tap Start yourself for that type of movement. A drive that's already running keeps recording until you stop.")
            }
        }
    }

    private func row(_ activity: AutoStartPreferences.Activity) -> some View {
        Label(activity.title, systemImage: activity.symbol)
    }
}
