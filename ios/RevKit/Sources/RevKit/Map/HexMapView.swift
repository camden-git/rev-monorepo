#if canImport(UIKit)
import MapKit
import SwiftUI
import SwiftyH3

/// MapKit map with the H3 res-10 grid overlay
public struct HexMapView: UIViewRepresentable {
    private let store: TerritoryStore
    private let breadcrumb: [CLLocationCoordinate2D]

    public init(store: TerritoryStore, breadcrumb: [CLLocationCoordinate2D] = []) {
        self.store = store
        self.breadcrumb = breadcrumb
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
        context.coordinator.syncBreadcrumb(breadcrumb)
    }

    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let store: TerritoryStore
        weak var mapView: MKMapView?

        private var gridOverlay: MKMultiPolygon?
        /// one overlay per player; the value's identity is matched in `rendererFor`.
        private var playerOverlays: [String: MKMultiPolygon] = [:]
        /// the local player's home hex, rendered distinctly (it's the trail-closure anchor)
        private var homeOverlay: MKPolygon?
        private var breadcrumbOverlay: MKPolyline?
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
            // remove and rebuild every player's overlay. fine at friend-group scale; REF:
            // docs/tech-stack.md §Map Rendering notes the MKTileOverlay path for >~10k hexes.
            for overlay in playerOverlays.values { mapView.removeOverlay(overlay) }
            playerOverlays.removeAll()
            for player in store.players {
                guard let overlay = H3Grid.claimedOverlay(for: store.cells(ownedBy: player.id)) else { continue }
                playerOverlays[player.id] = overlay
                mapView.addOverlay(overlay)
            }

            // the local player's home hex on top
            if let homeOverlay { mapView.removeOverlay(homeOverlay) }
            homeOverlay = nil
            let homeCell = store.localPlayer.homeCell
            if homeCell != 0, let boundary = try? H3Cell(homeCell).boundary {
                let polygon = MKPolygon(boundary)
                homeOverlay = polygon
                mapView.addOverlay(polygon)
            }
        }

        func syncBreadcrumb(_ coordinates: [CLLocationCoordinate2D]) {
            guard let mapView else { return }
            if let breadcrumbOverlay { mapView.removeOverlay(breadcrumbOverlay) }
            guard coordinates.count > 1 else {
                breadcrumbOverlay = nil
                return
            }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            breadcrumbOverlay = line
            mapView.addOverlay(line)
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

        // MARK: tap to inspect

        /// tap a hex to see who owns it and at what (decayed) score. REF: docs/tech-stack.md
        /// §Map Rendering — tap handling.
        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard let cell = H3Grid.cell(for: coordinate) else { return }

            let title: String
            let message: String
            if let owner = store.owner(of: cell.id), let effective = store.effectiveScore(of: cell.id) {
                title = owner.displayName
                let home = (store.tiles[cell.id]?.isHome ?? false) ? " · home" : ""
                message = String(format: "%.0f mph effective%@", effective, home)
            } else {
                title = "Unclaimed"
                message = "No owner yet"
            }

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            mapView.window?.rootViewController?.present(alert, animated: true)
        }

        // MARK: rendering

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineDashPattern = [2, 8]
                return renderer
            }
            // local player's home hex
            if let homeOverlay, overlay === homeOverlay {
                let renderer = MKPolygonRenderer(polygon: homeOverlay)
                renderer.fillColor = UIColor.systemYellow.withAlphaComponent(0.35)
                renderer.strokeColor = UIColor.systemYellow
                renderer.lineWidth = 3
                return renderer
            }
            guard let multiPolygon = overlay as? MKMultiPolygon else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            if let ownerId = playerOverlays.first(where: { $0.value === overlay })?.key,
               let color = store.player(id: ownerId).flatMap({ UIColor(hex: $0.colorHex) }) {
                renderer.fillColor = color.withAlphaComponent(0.4)
                renderer.strokeColor = color
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

extension UIColor {
    /// parse a "#RRGGBB" (or "RRGGBB") hex string; nil on malformed input.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
