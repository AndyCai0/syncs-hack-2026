import XCTest
@testable import SafeRoutesEngine

final class PlaceholderTests: XCTestCase {
    func testMockEngineReturnsTwoRoutes() async throws {
        let engine = MockRoutingEngine()
        let pair = try await engine.route(
            from: .init(latitude: -33.92, longitude: 150.92),
            to: .init(latitude: -33.91, longitude: 150.93),
            profile: .walking, safety: 0.6, afterDark: false)
        XCTAssertGreaterThan(pair.fastest.coordinates.count, 1)
        XCTAssertLessThan(pair.safest.riskScore, pair.fastest.riskScore)
    }
}
