import CoreLocation
import Foundation
import Testing
@testable import RevKit

/// mirrors the server's internal/geofence behavior: same boundary file, same 150 m buffer
struct GeofenceTests {
    @Test func downtownChicagoIsInside() {
        #expect(Geofence.containsLatLng(lat: 41.8807, lng: -87.6294)) // the Loop
        #expect(Geofence.containsLatLng(lat: 41.9484, lng: -87.6553)) // Wrigley Field
        #expect(Geofence.containsLatLng(lat: 41.7401, lng: -87.5919)) // South Side
    }

    @Test func outOfStateIsOutside() {
        #expect(!Geofence.containsLatLng(lat: 43.0389, lng: -87.9065)) // Milwaukee
        #expect(!Geofence.containsLatLng(lat: 39.7684, lng: -86.1581)) // Indianapolis
        #expect(!Geofence.containsLatLng(lat: 41.6764, lng: -86.2520)) // South Bend
    }

    @Test func nearbySuburbsAreOutside() {
        #expect(!Geofence.containsLatLng(lat: 42.0451, lng: -87.6877)) // Evanston
        #expect(!Geofence.containsLatLng(lat: 41.8850, lng: -87.7845)) // Oak Park
        #expect(!Geofence.containsLatLng(lat: 41.7508, lng: -88.1535)) // Naperville
    }

    @Test func cellsFollowTheirCenters() throws {
        let loop = try #require(H3Grid.cellId(for: CLLocationCoordinate2D(latitude: 41.8807, longitude: -87.6294)))
        let milwaukee = try #require(H3Grid.cellId(for: CLLocationCoordinate2D(latitude: 43.0389, longitude: -87.9065)))
        #expect(Geofence.containsCell(loop))
        #expect(!Geofence.containsCell(milwaukee))
    }
}
