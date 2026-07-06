import Foundation

/// reports whether a coordinate lies within Chicago, mirroring the server's
/// `internal/geofence` package (same embedded boundary, same 150 m buffer).
///
/// the server silently skips claims outside the city, so without this mirror an
/// out-of-town drive would persist optimistic claims the server never accepts
public enum Geofence {
    /// expands the boundary outward so claims that drift just outside the city
    /// (e.g. GPS noise along the lakefront) still count as inside
    static let bufferMeters = 150.0

    static let metersPerDegLat = 111_320.0

    static func metersPerDegLng(_ lat: Double) -> Double {
        metersPerDegLat * cos(lat * .pi / 180)
    }

    /// a closed list of [lng, lat] vertices (GeoJSON axis order); a polygon is
    /// an outer ring followed by zero or more hole rings
    private typealias Ring = [[Double]]
    private typealias Polygon = [Ring]

    private struct Boundary {
        let polygons: [Polygon]
        let minLng, minLat, maxLng, maxLat: Double
    }

    /// nil when the bundled boundary is missing or unparseable; every check then
    /// fails closed (no claims), matching the server
    private static let boundary: Boundary? = loadBoundary()

    private static func loadBoundary() -> Boundary? {
        struct Geometry: Decodable { let coordinates: [[[[Double]]]] }
        guard let url = Bundle.module.url(forResource: "chicago", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let geo = try? JSONDecoder().decode(Geometry.self, from: data),
              !geo.coordinates.isEmpty
        else {
            assertionFailure("Geofence: bundled chicago.geojson missing or unparseable")
            return nil
        }
        var minLng = Double.infinity, minLat = Double.infinity
        var maxLng = -Double.infinity, maxLat = -Double.infinity
        for poly in geo.coordinates {
            guard let outer = poly.first else { continue }
            for v in outer where v.count >= 2 {
                minLng = Swift.min(minLng, v[0]); maxLng = Swift.max(maxLng, v[0])
                minLat = Swift.min(minLat, v[1]); maxLat = Swift.max(maxLat, v[1])
            }
        }
        return Boundary(polygons: geo.coordinates, minLng: minLng, minLat: minLat, maxLng: maxLng, maxLat: maxLat)
    }

    /// whether the coordinate falls inside the Chicago boundary, or within
    /// `bufferMeters` of it. a point inside an outer ring but within one of its
    /// holes is outside
    public static func containsLatLng(lat: Double, lng: Double) -> Bool {
        guard let boundary else { return false }
        let bufLat = bufferMeters / metersPerDegLat
        let bufLng = bufferMeters / metersPerDegLng(lat)
        if lng < boundary.minLng - bufLng || lng > boundary.maxLng + bufLng
            || lat < boundary.minLat - bufLat || lat > boundary.maxLat + bufLat {
            return false
        }
        for poly in boundary.polygons {
            guard let outer = poly.first, contains(ring: outer, x: lng, y: lat) else { continue }
            let inHole = poly.dropFirst().contains { contains(ring: $0, x: lng, y: lat) }
            if !inHole { return true }
        }
        // outside the polygon, but keep it if it sits within the buffer of any edge
        return withinBuffer(lat: lat, lng: lng)
    }

    /// whether the center of an H3 cell falls inside Chicago
    public static func containsCell(_ id: UInt64) -> Bool {
        guard let center = H3Grid.cellCenter(of: id) else { return false }
        return containsLatLng(lat: center.latitude, lng: center.longitude)
    }

    /// whether the point lies within `bufferMeters` of any boundary edge (outer
    /// rings and holes alike)
    private static func withinBuffer(lat: Double, lng: Double) -> Bool {
        guard let boundary else { return false }
        let mLng = metersPerDegLng(lat)
        for poly in boundary.polygons {
            for ring in poly {
                var j = ring.count - 1
                for i in 0..<ring.count {
                    if segDistMeters(plng: lng, plat: lat, a: ring[j], b: ring[i], mLng: mLng) <= bufferMeters {
                        return true
                    }
                    j = i
                }
            }
        }
        return false
    }

    /// distance from point (plng, plat) to segment a-b, using a local
    /// equirectangular projection (meters relative to the point)
    private static func segDistMeters(plng: Double, plat: Double, a: [Double], b: [Double], mLng: Double) -> Double {
        let ax = (a[0] - plng) * mLng, ay = (a[1] - plat) * metersPerDegLat
        let bx = (b[0] - plng) * mLng, by = (b[1] - plat) * metersPerDegLat
        let dx = bx - ax, dy = by - ay
        if dx == 0, dy == 0 { return (ax * ax + ay * ay).squareRoot() }
        var t = -(ax * dx + ay * dy) / (dx * dx + dy * dy)
        t = Swift.max(0, Swift.min(1, t))
        let cx = ax + t * dx, cy = ay + t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    /// ray-casting point-in-polygon test. x is lng, y is lat to match the
    /// stored [lng, lat] vertex order
    private static func contains(ring: Ring, x: Double, y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
