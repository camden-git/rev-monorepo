import RevKit
import SwiftData
import SwiftUI

struct RootView: View {
    @State private var store: TerritoryStore
    @State private var tracker: DriveTracker

    init(context: ModelContext) {
        let store = TerritoryStore(context: context)
        _store = State(initialValue: store)
        _tracker = State(initialValue: DriveTracker(store: store))
    }

    var body: some View {
        if store.needsOnboarding {
            OnboardingView(store: store)
        } else {
            mapContent
        }
    }

    private var mapContent: some View {
        HexMapView(store: store, breadcrumb: tracker.drivePath)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { controlPanel }
            .task { tracker.start() }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: tracker.isRecording ? "record.circle.fill" : "pause.circle")
                    .foregroundStyle(tracker.isRecording ? .red : .secondary)
                Text(String(format: "%.0f mph", tracker.currentSpeedMph))
                    .monospacedDigit()
                Text("\(tracker.claimedTileCount) tiles")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassCapsule()

            Button {
                if tracker.isRecording { tracker.endDrive() } else { tracker.startDrive() }
            } label: {
                Label(tracker.isRecording ? "Stop Drive" : "Start Drive",
                      systemImage: tracker.isRecording ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
            .driveButtonStyle(recording: tracker.isRecording)
        }
        .padding()
    }
}

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    // TODO: Liquid ass needs more work!
    @ViewBuilder
    func driveButtonStyle(recording: Bool) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(recording ? .red : .blue)
        } else {
            buttonStyle(.borderedProminent).tint(recording ? .red : .blue)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Player.self, TileRecord.self, DriveRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return RootView(context: container.mainContext)
}
