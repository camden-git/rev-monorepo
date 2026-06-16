import Foundation
import SwiftyH3

/// enclosure gemetry for capture mechanic
/// (REF: docs/game-design.md §Trails & Enclosure, docs/tech-stack.md §Server-Authoritative).
///
/// given the ordered res-10 cells a drive traversed and the driver's currently-owned cells, detect a
/// closed loop and return the interior cells it encircles
///
public enum Enclosure {
    public struct Result: Equatable, Sendable {
        public var scoredInterior: [UInt64: Double]
        public init(scoredInterior: [UInt64: Double] = [:]) { self.scoredInterior = scoredInterior }
        public var isEmpty: Bool { scoredInterior.isEmpty }
    }

    /// detect the loop closed by `trail` (possibly stitched through the driver's `owned` land) and
    /// return the scored interior
    ///
    /// - trail: ordered, de-duped cells the drive crossed (`TileScoring.tilesCrossed`)
    /// - owned: the driver's currently-owned cells, they act as wall so leaving and returning to your
    ///   own territory closes a loop without any perimeter-walking code
    /// - loopScore: representative claim strength used as the boundary value of the gradient
    /// - minArea: minimum enclosed hexes to count (docs §Guardrails: >=3)
    /// - maxRadius / maxInterior: enormous-fill guards
    public static func enclose(
        trail: [UInt64],
        owned: Set<UInt64> = [],
        loopScore: Double,
        minArea: Int = 3,
        maxRadius: Int32 = 64,
        maxInterior: Int = 4096,
        maxAspect: Double = 5
    ) -> Result {
        // densify the trail into a contiguous ring of neighboring cells
        let ring = contiguousRing(from: trail)
        guard ring.count >= 3 else { return Result() }

        // reject long thin slivers: the loop's geographic bbox must be roughly square (loose)
        guard aspectRatioOK(ring, maxAspect: maxAspect) else { return Result() }

        // wall = trail ring ∪ owned land
        let walls = ring.union(owned)

        // bounding disk around the ring. radius = ring extent + margin so the disk's outer edge is
        // guaranteed to sit outside the loop (H3 has no rectangular bbox!)
        guard let anchor = ring.first else { return Result() }
        let anchorCell = H3Cell(anchor)
        var radius: Int32 = 0
        for cell in ring {
            guard let d = try? anchorCell.gridDistance(to: H3Cell(cell)), d <= Int64(maxRadius) else {
                return Result() // unreachable or already over the cap
            }
            radius = max(radius, Int32(d))
        }
        radius += 2
        guard radius <= maxRadius else { return Result() }
        guard let regionCells = try? anchorCell.gridDisk(distance: radius) else { return Result() }
        let region = Set(regionCells.map(\.id))
        guard !region.isEmpty else { return Result() }

        // i think this works??
        let interior = floodInterior(region: region, walls: walls)
        guard interior.count >= minArea, interior.count <= maxInterior else { return Result() }

        // diffusion gradient over BFS depth from the wall
        return Result(scoredInterior: gradient(interior: interior, walls: walls, loopScore: loopScore))
    }

    // MARK: geometry

    /// loose squareness check, reject loops whose geographic bbox is far longer in one axis than the
    /// other (long thin slivers)
    private static func aspectRatioOK(_ ring: Set<UInt64>, maxAspect: Double) -> Bool {
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        var minLng = Double.greatestFiniteMagnitude, maxLng = -Double.greatestFiniteMagnitude
        for cell in ring {
            guard let c = try? H3Cell(cell).center else { continue }
            minLat = min(minLat, c.latitudeDegs); maxLat = max(maxLat, c.latitudeDegs)
            minLng = min(minLng, c.longitudeDegs); maxLng = max(maxLng, c.longitudeDegs)
        }
        guard maxLat >= minLat else { return false }
        let metersPerDegLat = 111_320.0
        let midLat = (minLat + maxLat) / 2
        let height = (maxLat - minLat) * metersPerDegLat
        let width = (maxLng - minLng) * metersPerDegLat * cos(midLat * .pi / 180)
        let lo = min(width, height), hi = max(width, height)
        guard lo > 0 else { return false }
        return hi / lo <= maxAspect
    }

    /// stitch consecutive trail cells into one contiguous set
    private static func contiguousRing(from trail: [UInt64]) -> Set<UInt64> {
        var ring: Set<UInt64> = []
        guard let first = trail.first else { return ring }
        ring.insert(first)
        for (a, b) in zip(trail, trail.dropFirst()) where a != b {
            if let path = try? H3Cell(a).path(to: H3Cell(b)) {
                for cell in path { ring.insert(cell.id) }
            } else {
                ring.insert(b) // if it is a far segement we can accept possibly not closing
            }
        }
        return ring
    }

    /// BFS the open cells reachable from the disk's outer edge
    /// returns empty if no exterior seed exists (e.g. owned land fills the whole disk edge)
    private static func floodInterior(region: Set<UInt64>, walls: Set<UInt64>) -> Set<UInt64> {
        let open = region.subtracting(walls)
        guard !open.isEmpty else { return [] }

        var exterior: Set<UInt64> = []
        var queue: [UInt64] = []

        for cell in open where neighbors(of: cell).contains(where: { !region.contains($0) }) {
            if exterior.insert(cell).inserted { queue.append(cell) }
        }
        guard !queue.isEmpty else { return [] }

        var head = 0
        while head < queue.count {
            let cell = queue[head]; head += 1
            for n in neighbors(of: cell) where open.contains(n) && !exterior.contains(n) {
                exterior.insert(n)
                queue.append(n)
            }
        }
        return open.subtracting(exterior)
    }

    /// linear diffusion gradient
    private static func gradient(interior: Set<UInt64>, walls: Set<UInt64>, loopScore: Double) -> [UInt64: Double] {
        var depth: [UInt64: Int] = [:]
        var queue: [UInt64] = []
        for cell in interior where neighbors(of: cell).contains(where: { walls.contains($0) }) {
            depth[cell] = 1
            queue.append(cell)
        }

        var head = 0
        while head < queue.count {
            let cell = queue[head]; head += 1
            let d = depth[cell]!
            for n in neighbors(of: cell) where interior.contains(n) && depth[n] == nil {
                depth[n] = d + 1
                queue.append(n)
            }
        }

        // gradient falls from loopScore at the wall to 0 once you penetrate 20% of the way to the
        // deepest cell; everything past the inner 80% is 0
        let maxDepth = depth.values.max() ?? 1
        var scored: [UInt64: Double] = [:]
        for cell in interior {
            guard let d = depth[cell] else { scored[cell] = 0; continue } // disconnected wtf?
            let penetration = maxDepth == 1 ? 0 : Double(d - 1) / Double(maxDepth - 1)
            scored[cell] = loopScore * max(0, 1 - 5 * penetration)
        }
        return scored
    }

    /// the up-to-6 immediate neighbors of a cell
    private static func neighbors(of cell: UInt64) -> [UInt64] {
        guard let disk = try? H3Cell(cell).gridDisk(distance: 1) else { return [] }
        return disk.map(\.id).filter { $0 != cell }
    }
}
