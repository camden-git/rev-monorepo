#if canImport(UIKit)
import MapKit
import SwiftUI
import SwiftyH3

/// a tapped hex, distilled into what the inspector sheet needs to render
public struct HexTileDetail: Identifiable, Equatable, Sendable {
    /// the H3 cell index, also sheet identity
    public let id: UInt64
    public let ownerName: String?
    public let ownerColorHex: String?
    public let isLocalOwner: Bool
    public let isHome: Bool
    /// decayed score "right now"
    public let effectiveScore: Double?
    /// the score it was last claimed at, before decay
    public let claimScore: Double?
    public let lastDrivenAt: Date?

    public var isClaimed: Bool { ownerName != nil }

    public init(
        id: UInt64,
        ownerName: String?,
        ownerColorHex: String?,
        isLocalOwner: Bool,
        isHome: Bool,
        effectiveScore: Double?,
        claimScore: Double?,
        lastDrivenAt: Date?
    ) {
        self.id = id
        self.ownerName = ownerName
        self.ownerColorHex = ownerColorHex
        self.isLocalOwner = isLocalOwner
        self.isHome = isHome
        self.effectiveScore = effectiveScore
        self.claimScore = claimScore
        self.lastDrivenAt = lastDrivenAt
    }
}

/// MapKit map with the H3 res-10 grid overlay
public struct HexMapView: UIViewRepresentable {
    private let store: TerritoryStore
    private let breadcrumb: [CLLocationCoordinate2D]
    private let onVisibleCellsChange: @MainActor (Set<UInt64>) -> Void
    private let onSelectTile: @MainActor (HexTileDetail) -> Void

    public init(
        store: TerritoryStore,
        breadcrumb: [CLLocationCoordinate2D] = [],
        onVisibleCellsChange: @escaping @MainActor (Set<UInt64>) -> Void = { _ in },
        onSelectTile: @escaping @MainActor (HexTileDetail) -> Void = { _ in }
    ) {
        self.store = store
        self.breadcrumb = breadcrumb
        self.onVisibleCellsChange = onVisibleCellsChange
        self.onSelectTile = onSelectTile
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onVisibleCellsChange: onVisibleCellsChange, onSelectTile: onSelectTile)
    }

    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        mapView.showsCompass = false
        let compass = MKCompassButton(mapView: mapView)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(compass)
        NSLayoutConstraint.activate([
            compass.topAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 8),
            compass.leadingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
        ])

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
        private let onVisibleCellsChange: @MainActor (Set<UInt64>) -> Void
        private let onSelectTile: @MainActor (HexTileDetail) -> Void
        private let selectionHaptics = UISelectionFeedbackGenerator()
        weak var mapView: MKMapView?

        private var gridOverlay: MKMultiPolygon?
        /// one overlay per player; the value's identity is matched in `rendererFor`.
        private var playerOverlays: [String: MKMultiPolygon] = [:]
        private var visibleClaimCells: Set<UInt64> = []
        /// the local player's home hex, rendered distinctly (it's the trail-closure anchor)
        private var homeOverlay: MKPolygon?
        private var breadcrumbOverlay: MKPolyline?
        private var breadcrumbCount = 0
        private var claimedOverlaySignature: ClaimedOverlaySignature?
        private var didCenterOnUser = false
        private var rebuildItem: DispatchWorkItem?

        init(
            store: TerritoryStore,
            onVisibleCellsChange: @escaping @MainActor (Set<UInt64>) -> Void,
            onSelectTile: @escaping @MainActor (HexTileDetail) -> Void
        ) {
            self.store = store
            self.onVisibleCellsChange = onVisibleCellsChange
            self.onSelectTile = onSelectTile
        }

        // MARK: grid

        @MainActor
        func rebuildGrid() {
            guard let mapView else { return }
            let cells = H3Grid.coveringCells(for: mapView.region)
            updateVisibleCells(for: mapView.region)
            if let gridOverlay { mapView.removeOverlay(gridOverlay) }
            let overlay = H3Grid.gridOverlay(for: cells)
            gridOverlay = overlay
            // insert grid below the claimed fill
            mapView.insertOverlay(overlay, at: 0)
        }

        @MainActor
        func syncClaimedOverlay() {
            guard let mapView else { return }
            let signature = makeClaimedOverlaySignature()
            guard signature != claimedOverlaySignature else { return }
            claimedOverlaySignature = signature

            // remove and rebuild the visible slice of each player's overlay
            for overlay in playerOverlays.values { mapView.removeOverlay(overlay) }
            playerOverlays.removeAll()
            let cellsByOwner = visibleClaimCellsByOwner()
            for player in store.players {
                let cells = cellsByOwner[player.id] ?? []
                guard let overlay = H3Grid.claimedOverlay(for: cells) else { continue }
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

        private func makeClaimedOverlaySignature() -> ClaimedOverlaySignature {
            var visibleOwners: [UInt64: String] = [:]
            visibleOwners.reserveCapacity(Swift.min(visibleClaimCells.count, store.tiles.count))
            for cell in visibleClaimCells {
                if let ownerId = store.tiles[cell]?.ownerId {
                    visibleOwners[cell] = ownerId
                }
            }

            var playerColors: [String: String] = [:]
            playerColors.reserveCapacity(store.players.count)
            for player in store.players {
                playerColors[player.id] = player.colorHex
            }
            return ClaimedOverlaySignature(
                visibleOwners: visibleOwners,
                playerColors: playerColors,
                localHomeCell: store.localPlayer.homeCell
            )
        }

        private func visibleClaimCellsByOwner() -> [String: Set<UInt64>] {
            var cellsByOwner: [String: Set<UInt64>] = [:]
            cellsByOwner.reserveCapacity(store.players.count)
            for cell in visibleClaimCells {
                guard let ownerId = store.tiles[cell]?.ownerId else { continue }
                cellsByOwner[ownerId, default: []].insert(cell)
            }
            return cellsByOwner
        }

        func syncBreadcrumb(_ coordinates: [CLLocationCoordinate2D]) {
            guard let mapView else { return }
            // updateUIView fires ~1 Hz during a drive (speed/state changes); only rebuild the
            // polyline when the path actually grew, otherwise we redraw the whole line for nothing
            guard coordinates.count != breadcrumbCount else { return }
            breadcrumbCount = coordinates.count
            if let breadcrumbOverlay { mapView.removeOverlay(breadcrumbOverlay) }
            guard coordinates.count > 1 else {
                breadcrumbOverlay = nil
                return
            }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            breadcrumbOverlay = line
            mapView.addOverlay(line)
        }

        @MainActor
        private func updateVisibleCells(for region: MKCoordinateRegion) {
            let cells = H3Grid.visibleCellIds(for: region)
            guard cells != visibleClaimCells else { return }
            visibleClaimCells = cells
            syncClaimedOverlay()
            onVisibleCellsChange(cells)
        }

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            rebuildItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.rebuildGrid() }
            }
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

        /// tap a hex to see who owns it and at what (decayed) score, via an
        /// inspector sheet owned by SwiftUI REF: docs/tech-stack.md
        /// §Map Rendering — tap handling.
        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard let cell = H3Grid.cell(for: coordinate) else { return }

            let detail: HexTileDetail
            if let owner = store.owner(of: cell.id), let state = store.tiles[cell.id] {
                detail = HexTileDetail(
                    id: cell.id,
                    ownerName: owner.displayName,
                    ownerColorHex: owner.colorHex,
                    isLocalOwner: owner.isLocal,
                    isHome: state.isHome,
                    effectiveScore: store.effectiveScore(of: cell.id),
                    claimScore: state.claimScore,
                    lastDrivenAt: state.lastDrivenAt
                )
            } else {
                detail = HexTileDetail(
                    id: cell.id,
                    ownerName: nil,
                    ownerColorHex: nil,
                    isLocalOwner: false,
                    isHome: false,
                    effectiveScore: nil,
                    claimScore: nil,
                    lastDrivenAt: nil
                )
            }

            selectionHaptics.selectionChanged()
            onSelectTile(detail)
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

        private struct ClaimedOverlaySignature: Equatable {
            var visibleOwners: [UInt64: String]
            var playerColors: [String: String]
            var localHomeCell: UInt64
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
