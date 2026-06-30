import CoreLocation
import MapKit
@testable import RevKit
import Testing

struct H3GridTests {
    @Test
    func visibleClaimedCellsDoNotDependOnGridCoverageCap() throws {
        let chicago = CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)
        let losAngeles = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let visibleCell = try #require(H3Grid.cellId(for: chicago))
        let distantCell = try #require(H3Grid.cellId(for: losAngeles))

        let zoomedOutRegion = MKCoordinateRegion(
            center: chicago,
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )

        #expect(H3Grid.visibleCellIds(for: zoomedOutRegion).isEmpty)
        #expect(
            H3Grid.visibleClaimedCellIds(
                in: MKMapRect(zoomedOutRegion),
                from: [visibleCell, distantCell]
            ) == [visibleCell]
        )
    }

    @Test
    func boundaryAndRegionForKnownCell() throws {
        let cell: UInt64 = 0x8a2a1072b59ffff
        let loop = H3Grid.boundary(of: cell)
        #expect(loop.count >= 6)

        let region = try #require(H3Grid.region(covering: [cell]))
        #expect(region.span.latitudeDelta > 0)
        #expect(region.span.longitudeDelta > 0)
    }

    @Test
    func regionIsNilForEmptyInput() {
        #expect(H3Grid.region(covering: []) == nil)
    }
}

private extension MKMapRect {
    init(_ region: MKCoordinateRegion) {
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let pointA = MKMapPoint(topLeft)
        let pointB = MKMapPoint(bottomRight)
        self.init(
            x: min(pointA.x, pointB.x),
            y: min(pointA.y, pointB.y),
            width: abs(pointB.x - pointA.x),
            height: abs(pointB.y - pointA.y)
        )
    }
}
