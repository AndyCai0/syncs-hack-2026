import CoreLocation
import XCTest
@testable import SafeRoutesEngine

final class GraphStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saferoutes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func store(_ graph: SyntheticGraph, name: String = "walking.graph") throws -> GraphStore {
        let url = tempDir.appendingPathComponent(name)
        try graph.write(to: url)
        return try GraphStore(contentsOf: url)
    }

    // MARK: - Format

    func testHeaderAndArraysParse() throws {
        let graph = Fixtures.diversionGraph(risk: 50, riskDark: 50)
        let s = try store(graph)

        XCTAssertEqual(s.version, 1)
        XCTAssertEqual(s.nodeCount, 4)
        XCTAssertEqual(s.edgeCount, 4)
        XCTAssertEqual(s.coordCount, 9) // 3 + 2 + 2 + 2

        XCTAssertEqual(s.nodeLon[2], 151.0020, accuracy: 1e-9)
        XCTAssertEqual(s.nodeLat[3], -33.8990, accuracy: 1e-9)
        XCTAssertEqual(s.edgeLength[1], 100, accuracy: 1e-4)
        XCTAssertEqual(s.edgeRisk[1], 50, accuracy: 1e-4)
        XCTAssertEqual(s.edgeCrashCount[1], 7)
        XCTAssertEqual(s.edgeGeomOffset[1], 3)
        XCTAssertEqual(s.edgeGeomCount[0], 3)
    }

    func testAdjacencyIsUndirected() throws {
        let s = try store(Fixtures.diversionGraph(risk: 0, riskDark: 0))
        func neighbours(_ n: Int) -> Set<Int> {
            Set((Int(s.adjStart[n])..<Int(s.adjStart[n + 1])).map { Int(s.adjNode[$0]) })
        }
        XCTAssertEqual(neighbours(0), [1])
        XCTAssertEqual(neighbours(1), [0, 2, 3])
        XCTAssertEqual(neighbours(2), [1, 3])
        XCTAssertEqual(neighbours(3), [1, 2])
        XCTAssertEqual(s.adjNode.count, 8)
    }

    func testRejectsBadMagic() throws {
        var bytes = Fixtures.schoolZoneGraph().serialized()
        bytes[0] = 0x58 // "X"
        let url = tempDir.appendingPathComponent("bad.graph")
        try bytes.write(to: url)
        XCTAssertThrowsError(try GraphStore(contentsOf: url)) { error in
            XCTAssertEqual(error as? GraphLoadError, .badMagic)
        }
    }

    func testMissingFileThrows() {
        let url = tempDir.appendingPathComponent("nope.graph")
        XCTAssertThrowsError(try GraphStore(contentsOf: url))
    }

    // MARK: - Snapping

    func testNearestNodeSnapsAndRejectsFarPoints() throws {
        let s = try store(Fixtures.diversionGraph(risk: 0, riskDark: 0))
        let n = try s.nearestNode(to: .init(latitude: -33.90005, longitude: 151.00195))
        XCTAssertEqual(n, 2)

        XCTAssertThrowsError(try s.nearestNode(to: .init(latitude: -33.9, longitude: 152.5))) { error in
            XCTAssertEqual(error as? RoutingError, .pointOutsideCoverage)
        }
        // Just outside the 500 m snap radius.
        XCTAssertThrowsError(try s.nearestNode(to: .init(latitude: -33.8930, longitude: 151.0000)))
    }

    // MARK: - Cost model

    func testCostModelMatchesSpec() throws {
        let s = try store(Fixtures.diversionGraph(risk: 50, riskDark: 80))
        // length 100, risk 50 -> risk per 100 m = 50; cost = 100 * (1 + k * 5)
        XCTAssertEqual(s.cost(edge: 1, k: 0, afterDark: false), 100, accuracy: 1e-6)
        XCTAssertEqual(s.cost(edge: 1, k: 4, afterDark: false), 100 * (1 + 4 * 5), accuracy: 1e-6)
        XCTAssertEqual(s.cost(edge: 1, k: 4, afterDark: true), 100 * (1 + 4 * 8), accuracy: 1e-6)

        let sz = try store(Fixtures.schoolZoneGraph(), name: "sz.graph")
        XCTAssertEqual(sz.cost(edge: 1, k: 0, afterDark: false), 50, accuracy: 1e-6)
        XCTAssertEqual(sz.cost(edge: 0, k: 0, afterDark: false), 100, accuracy: 1e-6)
    }

    // MARK: - Routing on the synthetic graph

    func testFastestPathTakesShortestChain() throws {
        let s = try store(Fixtures.diversionGraph(risk: 50, riskDark: 50))
        let r = try NativeRouter.route(store: s, from: 0, to: 2, profile: .walking, k: 0, afterDark: false)

        XCTAssertEqual(r.distanceM, 200, accuracy: 1e-3)
        XCTAssertEqual(r.riskScore, 50, accuracy: 1e-3)
        XCTAssertEqual(r.crashCount, 7)
        XCTAssertEqual(r.schoolZoneMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(r.durationS, 200 / TravelProfile.walking.speedMps, accuracy: 1e-6)

        // 3 points from edge 0 + 1 new point from edge 1.
        XCTAssertEqual(r.coordinates.count, 4)
        XCTAssertEqual(r.coordinates.first!.longitude, 151.0000, accuracy: 5e-5)
        XCTAssertEqual(r.coordinates[1].latitude, -33.9001, accuracy: 5e-5)
        XCTAssertEqual(r.coordinates.last!.longitude, 151.0020, accuracy: 5e-5)
        XCTAssertEqual(r.coordinates.last!.latitude, -33.9000, accuracy: 5e-5)
    }

    func testHigherSafetyDivertsAroundRiskyEdge() throws {
        let s = try store(Fixtures.diversionGraph(risk: 50, riskDark: 50))
        let k = NativeRouter.k(forSafety: 1.0)
        XCTAssertEqual(k, 4.0, accuracy: 1e-9)

        let safest = try NativeRouter.route(store: s, from: 0, to: 2, profile: .walking, k: k, afterDark: false)
        XCTAssertEqual(safest.distanceM, 260, accuracy: 1e-3) // 100 + 80 + 80
        XCTAssertEqual(safest.riskScore, 0, accuracy: 1e-6)
        XCTAssertEqual(safest.crashCount, 0)

        // The detour passes through node 3, and edge 3 (stored 2->3) must be
        // reversed so the polyline ends at node 2.
        XCTAssertTrue(safest.coordinates.contains { abs($0.latitude - (-33.8990)) < 1e-5 })
        XCTAssertEqual(safest.coordinates.last!.longitude, 151.0020, accuracy: 5e-5)
        XCTAssertEqual(safest.coordinates.last!.latitude, -33.9000, accuracy: 5e-5)
        // No duplicated shared endpoints.
        for i in 1..<safest.coordinates.count {
            let a = safest.coordinates[i - 1], b = safest.coordinates[i]
            XCTAssertFalse(abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9,
                           "duplicate point at index \(i)")
        }
    }

    func testSchoolZoneFlagDoesNotDiscountTheRoute() throws {
        let s = try store(Fixtures.schoolZoneGraph())
        let r = try NativeRouter.route(store: s, from: 0, to: 1, profile: .walking, k: 0, afterDark: false)
        XCTAssertEqual(r.distanceM, 100, accuracy: 1e-3)
        XCTAssertEqual(r.schoolZoneMeters, 0, accuracy: 1e-3)
        XCTAssertFalse(r.coordinates.contains { abs($0.latitude - (-33.8995)) < 1e-5 })
    }

    func testAfterDarkSwitchesRiskColumn() throws {
        // Safe by day, risky after dark.
        let s = try store(Fixtures.diversionGraph(risk: 0, riskDark: 50))
        let k = NativeRouter.k(forSafety: 1.0)

        let day = try NativeRouter.route(store: s, from: 0, to: 2, profile: .walking, k: k, afterDark: false)
        XCTAssertEqual(day.distanceM, 200, accuracy: 1e-3)
        XCTAssertEqual(day.riskScore, 0, accuracy: 1e-6)

        let night = try NativeRouter.route(store: s, from: 0, to: 2, profile: .walking, k: k, afterDark: true)
        XCTAssertEqual(night.distanceM, 260, accuracy: 1e-3)
        XCTAssertEqual(night.riskScore, 0, accuracy: 1e-6)

        // Same path by night without the safety slider, reporting the dark risk.
        let nightFast = try NativeRouter.route(store: s, from: 0, to: 2, profile: .walking, k: 0, afterDark: true)
        XCTAssertEqual(nightFast.distanceM, 200, accuracy: 1e-3)
        XCTAssertEqual(nightFast.riskScore, 50, accuracy: 1e-3)
    }

    func testNoPathThrows() throws {
        var graph = Fixtures.diversionGraph(risk: 0, riskDark: 0)
        graph.nodes.append(.init(lon: 151.0030, lat: -33.9000)) // isolated node 4
        let s = try store(graph)
        XCTAssertThrowsError(try NativeRouter.route(store: s, from: 0, to: 4,
                                                    profile: .walking, k: 0, afterDark: false)) { error in
            XCTAssertEqual(error as? RoutingError, .noPath)
        }
    }

    func testCyclingDurationUsesProfileSpeed() throws {
        let s = try store(Fixtures.diversionGraph(risk: 0, riskDark: 0))
        let r = try NativeRouter.route(store: s, from: 0, to: 2, profile: .cycling, k: 0, afterDark: false)
        XCTAssertEqual(r.durationS, 200 / (15.0 / 3.6), accuracy: 1e-6)
    }

    // MARK: - Engine wiring

    func testEngineRoutesOverSyntheticGraph() async throws {
        try Fixtures.diversionGraph(risk: 50, riskDark: 50, detourLength: 70)
            .write(to: tempDir.appendingPathComponent("walking.graph"))
        let engine = NativeRoutingEngine(dataDirectory: tempDir)

        let pair = try await engine.route(from: .init(latitude: -33.9000, longitude: 151.0000),
                                          to: .init(latitude: -33.9000, longitude: 151.0020),
                                          profile: .walking, safety: 1.0, afterDark: false)
        XCTAssertEqual(pair.fastest.distanceM, 200, accuracy: 1e-3)
        XCTAssertEqual(pair.safest.distanceM, 240, accuracy: 1e-3)
        XCTAssertLessThan(pair.safest.riskScore, pair.fastest.riskScore)

        // Slider at zero: both routes are the fastest one.
        let flat = try await engine.route(from: .init(latitude: -33.9000, longitude: 151.0000),
                                          to: .init(latitude: -33.9000, longitude: 151.0020),
                                          profile: .walking, safety: 0, afterDark: false)
        XCTAssertEqual(flat.safest.distanceM, flat.fastest.distanceM, accuracy: 1e-6)
    }

    func testEngineRejectsLowerHazardCandidateOverDetourCap() async throws {
        try Fixtures.diversionGraph(risk: 50, riskDark: 50)
            .write(to: tempDir.appendingPathComponent("walking.graph"))
        let engine = NativeRoutingEngine(dataDirectory: tempDir)

        let pair = try await engine.route(from: .init(latitude: -33.9000, longitude: 151.0000),
                                          to: .init(latitude: -33.9000, longitude: 151.0020),
                                          profile: .walking, safety: 1.0, afterDark: false)

        XCTAssertEqual(NativeRoutingEngine.maxDetourRatio, 1.25, accuracy: 1e-9)
        XCTAssertEqual(pair.lowerHazard.distanceM, pair.fastest.distanceM, accuracy: 1e-6)
        XCTAssertEqual(pair.lowerHazard.riskScore, pair.fastest.riskScore, accuracy: 1e-6)
    }

    func testEngineSelectsModerateCandidateWhenHighestWeightExceedsCap() async throws {
        try Fixtures.boundedCandidateGraph()
            .write(to: tempDir.appendingPathComponent("walking.graph"))
        let engine = NativeRoutingEngine(dataDirectory: tempDir)

        let pair = try await engine.route(from: .init(latitude: -33.9000, longitude: 151.0000),
                                          to: .init(latitude: -33.9000, longitude: 151.0020),
                                          profile: .walking, safety: 1.0, afterDark: false)

        XCTAssertEqual(pair.fastest.distanceM, 200, accuracy: 1e-3)
        XCTAssertEqual(pair.lowerHazard.distanceM, 240, accuracy: 1e-3)
        XCTAssertLessThan(pair.lowerHazard.riskScore, pair.fastest.riskScore)
        XCTAssertLessThanOrEqual(pair.lowerHazard.durationS,
                                 pair.fastest.durationS * NativeRoutingEngine.maxDetourRatio)
    }

    func testEngineReportsMissingGraph() async {
        let engine = NativeRoutingEngine(dataDirectory: tempDir.appendingPathComponent("empty", isDirectory: true))
        do {
            _ = try await engine.route(from: .init(latitude: -33.9, longitude: 151.0),
                                       to: .init(latitude: -33.9, longitude: 151.002),
                                       profile: .cycling, safety: 0.5, afterDark: false)
            XCTFail("expected graphNotLoaded")
        } catch {
            XCTAssertEqual(error as? RoutingError, .graphNotLoaded)
        }
    }
}
