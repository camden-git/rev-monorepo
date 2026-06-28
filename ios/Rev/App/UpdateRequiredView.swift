import SwiftUI

/// non-dismissable gate shown when the running build is below the
/// server's minimum-supported version
struct UpdateRequiredView: View {
    /// newest version the backend advertises, if known
    var latestVersion: String?

    private static let appStoreURL = URL(string: "https://driverev.app")!

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Update Required")
                    .font(.title.weight(.bold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                openURL(Self.appStoreURL)
            } label: {
                Text("Update on the App Store")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled()
    }

    private var message: String {
        let base = "This version of Rev is no longer supported. Update to the latest version to keep playing."
        if let latestVersion, !latestVersion.isEmpty {
            return base + "\n\nLatest version: \(latestVersion)"
        }
        return base
    }
}

#Preview {
    UpdateRequiredView(latestVersion: "0.3.0")
}
