import RevKit
import SwiftUI

struct RootView: View {
    @State private var store = TerritoryStore()

    var body: some View {
        HexMapView(store: store)
            .ignoresSafeArea()
    }
}

#Preview {
    RootView()
}
