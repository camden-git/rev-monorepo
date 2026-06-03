import MapKit
import SwiftUI

/// MapKit map with an H3 res-10 grid overlay and tap-to-claim
public struct HexMapView: UIViewRepresentable {
    private let store: TerritoryStore

    public init(store: TerritoryStore) {
        self.store = store
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        let fallback = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)
        mapView.camera = MKMapCamera(
            lookingAtCenter: fallback,
            fromDistance: 1500,
            pitch: 0,
            heading: 0
        )

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        mapView.addGestureRecognizer(tap)

        context.coordinator.mapView = mapView
        context.coordinator.rebuildGrid()
        return mapView
    }

    public func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.syncClaimedOverlay()
    }

    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let store: TerritoryStore
        weak var mapView: MKMapView?

        private var gridOverlay: MKMultiPolygon?
        private var claimedOverlay: MKMultiPolygon?
        private var didCenterOnUser = false
        private var rebuildItem: DispatchWorkItem?

        init(store: TerritoryStore) {
            self.store = store
        }

        // MARK: grid

        func rebuildGrid() {
            guard let mapView else { return }
            let cells = H3Grid.coveringCells(for: mapView.region)
            if let gridOverlay { mapView.removeOverlay(gridOverlay) }
            let overlay = H3Grid.gridOverlay(for: cells)
            gridOverlay = overlay
            // insert grid below the claimed fill
            mapView.insertOverlay(overlay, at: 0)
        }

        @MainActor
        func syncClaimedOverlay() {
            guard let mapView else { return }
            if let claimedOverlay { mapView.removeOverlay(claimedOverlay) }
            if let overlay = H3Grid.claimedOverlay(for: store.claimedCells) {
                claimedOverlay = overlay
                mapView.addOverlay(overlay)
            } else {
                claimedOverlay = nil
            }
        }

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            rebuildItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.rebuildGrid() }
            rebuildItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
        }

        public func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didCenterOnUser, let coordinate = userLocation.location?.coordinate else { return }
            didCenterOnUser = true
            mapView.setCamera(
                MKMapCamera(lookingAtCenter: coordinate, fromDistance: 1500, pitch: 0, heading: 0),
                animated: true
            )
        }

        // MARK: tap to claim

        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard let cell = H3Grid.cell(for: coordinate) else { return }
            store.claim(cell.id)
            syncClaimedOverlay()
        }

        // MARK: rendering

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let multiPolygon = overlay as? MKMultiPolygon else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            if overlay === claimedOverlay {
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.4)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 1.5
            } else {
                renderer.fillColor = .clear
                renderer.strokeColor = UIColor.label.withAlphaComponent(0.3)
                renderer.lineWidth = 0.75
            }
            return renderer
        }
    }
}
