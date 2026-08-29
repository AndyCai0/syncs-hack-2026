import CoreLocation
import XCTest
@testable import SafeRoutesEngine

/// Exercises the engine against the real exported Sydney graph when it is
/// present. Skips cleanly while `data/appdata/walking.graph` is still being
/// generated.
final class RealGraphIntegrationTests: XCTestCase {

    private static let cbd = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    private static let newtown = CLLocationCoordinate2D(latitude: -33.8890, longitude: 151.1950)

    private func walkingGraphURL() throws -> URL {
        guard let dir = AppDataLocator.dataDirectory() else {
            throw XCTSkip("No data/appdata directory found.")
        }
        let url = dir.appendingPathComponent("walking.graph")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("walking.graph not exported yet at \(url.path)")
        }
        return url
    }

    func testLoadsRealWalkingGraph() throws {
        let url = try walkingGraphURL()
        let clock = ContinuousClock()
        var store: GraphStore!
        let elapsed = try clock.measure { store = try GraphStore(contentsOf: url) }
        print("[integration] loaded walking.graph in \(elapsed): "
              + "\(store.nodeCount) nodes, \(store.edgeCount) edges, \(store.coordCount) geometry points")

        XCTAssertGreaterThan(store.nodeCount, 1000)
        XCTAssertGreaterThan(store.edgeCount, 1000)
        XCTAssertEqual(store.adjNode.count, store.edgeCount * 2)
        XCTAssertEqual(Int(store.adjStart[store.nodeCount]), store.edgeCount * 2)
        XCTAssertLessThan(elapsed, .seconds(10), "graph load is unexpectedly slow")

        let snapped = try store.nearestNode(to: Self.cbd)
        let coord = store.coordinate(ofNode: snapped)
        XCTAssertLessThan(GraphStore.metres(coord.longitude, coord.latitude,
                                            Self.cbd.longitude, Self.cbd.latitude), 500)
    }

    func testRoutesSydneyCBDToNewtown() async throws {
        guard let dir = AppDataLocator.dataDirectory() else { throw XCTSkip("No data/appdata directory found.") }
        _ = try walkingGraphURL()

        let engine = NativeRoutingEngine(dataDirectory: dir)
        let loadSeconds = try await engine.preload(profile: .walking)

        let clock = ContinuousClock()
        var pair: RoutePair!
        let elapsed = try await clock.measure {
            pair = try await engine.route(from: Self.cbd, to: Self.newtown,
                                          profile: .walking, safety: 0.8, afterDark: false)
        }
        print(String(format: "[integration] load %.2fs, CBD->Newtown pair in %.3fs", loadSeconds,
                     Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        print(String(format: "[integration] fastest %.0f m risk %.2f crashes %d | safest %.0f m risk %.2f crashes %d",
                     pair.fastest.distanceM, pair.fastest.riskScore, pair.fastest.crashCount,
                     pair.safest.distanceM, pair.safest.riskScore, pair.safest.crashCount))

        XCTAssertGreaterThan(pair.fastest.distanceM, 2500)
        XCTAssertLessThan(pair.fastest.distanceM, 5000)
        XCTAssertGreaterThan(pair.safest.distanceM, 2500)
        XCTAssertLessThan(pair.safest.distanceM, 8000)
        XCTAssertLessThanOrEqual(pair.safest.riskScore, pair.fastest.riskScore)
        XCTAssertGreaterThanOrEqual(pair.safest.distanceM, pair.fastest.distanceM - 1)
        XCTAssertGreaterThan(pair.fastest.coordinates.count, 10)
        XCTAssertGreaterThan(pair.safest.coordinates.count, 10)
        XCTAssertEqual(pair.fastest.durationS, pair.fastest.distanceM / TravelProfile.walking.speedMps, accuracy: 1e-6)

        // Endpoints must sit near the requested coordinates.
        let first = pair.fastest.coordinates.first!
        let last = pair.fastest.coordinates.last!
        XCTAssertLessThan(GraphStore.metres(first.longitude, first.latitude, Self.cbd.longitude, Self.cbd.latitude), 600)
        XCTAssertLessThan(GraphStore.metres(last.longitude, last.latitude, Self.newtown.longitude, Self.newtown.latitude), 600)
    }

    func testAfterDarkRouteOnRealGraph() async throws {
        guard let dir = AppDataLocator.dataDirectory() else { throw XCTSkip("No data/appdata directory found.") }
        _ = try walkingGraphURL()
        let engine = NativeRoutingEngine(dataDirectory: dir)
        let pair = try await engine.route(from: Self.cbd, to: Self.newtown,
                                          profile: .walking, safety: 1.0, afterDark: true)
        XCTAssertLessThanOrEqual(pair.safest.riskScore, pair.fastest.riskScore)
        XCTAssertGreaterThan(pair.safest.distanceM, 2000)
    }
}
