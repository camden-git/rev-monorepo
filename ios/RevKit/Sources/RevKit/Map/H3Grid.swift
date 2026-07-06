import CoreLocation
import MapKit
import SwiftyH3

/// helpers over SwiftyH3 for the map slice
public enum H3Grid {
    static let resolution: H3Cell.Resolution = .res10

    /// an approximation of res-10 hexagon edge length in meters
    static let edgeMeters: Double = 65

    /// below this many cells the grid is drawn
    static let maxGridCells = 1800
    static let maxVisibleTileCells = 5000
    static let tileWindowParentResolution: H3Cell.Resolution = .res8

    /// the res-10 cell containing a coordinate, nil if conversion fails
    static func cell(for coordinate: CLLocationCoordinate2D) -> H3Cell? {
        try? H3LatLng(coordinate).cell(at: resolution)
    }

    /// res-10 cell id (UInt64) for a coordinate
    public static func cellId(for coordinate: CLLocationCoordinate2D) -> UInt64? {
        cell(for: coordinate)?.id
    }

    /// the cell's center coordinate, nil if it can't be resolved
    public static func cellCenter(of cellId: UInt64) -> CLLocationCoordinate2D? {
        try? H3Cell(cellId).center.coordinates
    }

    /// res-10 cells covering (roughly) the visible region: the center cell expanded by a grid
    /// disk whose radius is derived from the region's diagonal reach
    /// returns [] when zoomed out past the cell cap
    static func coveringCells(for region: MKCoordinateRegion, paddingRings: Int32 = 0, maxCells: Int = maxGridCells) -> [H3Cell] {
        guard let center = cell(for: region.center) else { return [] }

        // meters, north-south and east-west
        let latMeters = region.span.latitudeDelta * 111_320
        let lngMeters = region.span.longitudeDelta * 111_320
            * cos(region.center.latitude * .pi / 180)
        let halfDiagonal = hypot(latMeters, lngMeters) / 2

        // each disk ring step covers ~one hex edge of additional reach
        let radius = Int32((halfDiagonal / edgeMeters).rounded(.up)) + Swift.max(0, paddingRings)
        guard radius >= 1 else { return [center] }

        // cells in a grid disk of radius k is 3k(k+1)+1
        let estimated = 3 * Int(radius) * (Int(radius) + 1) + 1
        guard estimated <= maxCells else { return [] }

        return (try? center.gridDisk(distance: radius)) ?? [center]
    }

    static func visibleCellIds(for region: MKCoordinateRegion, paddingRings: Int32 = 2) -> Set<UInt64> {
        Set(coveringCells(for: region, paddingRings: paddingRings, maxCells: maxVisibleTileCells).map(\.id))
    }

    static func tileWindowParentIds(for cellIds: Set<UInt64>) -> Set<UInt64> {
        Set(cellIds.compactMap { id in
            try? H3Cell(id).parent(at: tileWindowParentResolution).id
        })
    }

    static func visibleClaimedCellIds<C: Sequence>(
        in visibleMapRect: MKMapRect,
        from cellIds: C,
        paddingFraction: Double = 0.08
    ) -> Set<UInt64> where C.Element == UInt64 {
        let paddedRect = visibleMapRect.insetBy(
            dx: -visibleMapRect.size.width * paddingFraction,
            dy: -visibleMapRect.size.height * paddingFraction
        )
        return Set(cellIds.compactMap { id in
            guard let center = try? H3Cell(id).center.coordinates else { return nil }
            return paddedRect.contains(MKMapPoint(center)) ? id : nil
        })
    }

    static func showsGrid(for region: MKCoordinateRegion) -> Bool {
        !coveringCells(for: region).isEmpty
    }

    /// outline per hex
    static func gridOverlay(for cells: [H3Cell]) -> MKMultiPolygon {
        let polygons = cells.compactMap { cell -> MKPolygon? in
            guard let loop = try? cell.boundary else { return nil }
            return MKPolygon(loop)
        }
        return MKMultiPolygon(polygons)
    }

    /// claimed cells merged into a single merged territory outline
    static func claimedOverlay(for cellIndices: Set<UInt64>) -> MKMultiPolygon? {
        guard !cellIndices.isEmpty else { return nil }
        let cells = cellIndices.map { H3Cell($0) }
        guard let merged = try? cells.multiPolygon else { return nil }
        return MKMultiPolygon(from: merged)
    }

    /// the cell's polygon loop, or [] if it can't be resolved
    public static func boundary(of cellId: UInt64) -> [CLLocationCoordinate2D] {
        guard let loop = try? H3Cell(cellId).boundary else { return [] }
        return loop.map(\.coordinates)
    }

    /// a bounding region over all cells' boundary coordinates, padded out and floored
    public static func region(
        covering cellIds: [UInt64],
        paddingFraction: Double = 0.35,
        minSpanMeters: Double = 400
    ) -> MKCoordinateRegion? {
        guard !cellIds.isEmpty else { return nil }
        var coords: [CLLocationCoordinate2D] = []
        for id in cellIds { coords.append(contentsOf: boundary(of: id)) }
        return region(coveringCoordinates: coords, paddingFraction: paddingFraction, minSpanMeters: minSpanMeters)
    }

    /// a bounding region over raw coordinates with padding and flooring
    public static func region(
        coveringCoordinates coords: [CLLocationCoordinate2D],
        paddingFraction: Double = 0.35,
        minSpanMeters: Double = 400
    ) -> MKCoordinateRegion? {
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLng = Double.greatestFiniteMagnitude
        var maxLng = -Double.greatestFiniteMagnitude
        var found = false

        for coord in coords {
            found = true
            minLat = Swift.min(minLat, coord.latitude)
            maxLat = Swift.max(maxLat, coord.latitude)
            minLng = Swift.min(minLng, coord.longitude)
            maxLng = Swift.max(maxLng, coord.longitude)
        }
        guard found else { return nil }

        let centerLat = (minLat + maxLat) / 2
        let centerLng = (minLng + maxLng) / 2

        let minLatSpan = minSpanMeters / 111_320
        let minLngSpan = minSpanMeters / (111_320 * Swift.max(cos(centerLat * .pi / 180), 0.000001))

        let latSpan = Swift.max((maxLat - minLat) * (1 + paddingFraction), minLatSpan)
        let lngSpan = Swift.max((maxLng - minLng) * (1 + paddingFraction), minLngSpan)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lngSpan)
        )
    }

    static func filledCellsOverlay(for cellIndices: Set<UInt64>) -> MKMultiPolygon? {
        guard !cellIndices.isEmpty else { return nil }
        let polygons = cellIndices.compactMap { id -> MKPolygon? in
            guard let loop = try? H3Cell(id).boundary else { return nil }
            return MKPolygon(loop)
        }
        guard !polygons.isEmpty else { return nil }
        return MKMultiPolygon(polygons)
    }
}
