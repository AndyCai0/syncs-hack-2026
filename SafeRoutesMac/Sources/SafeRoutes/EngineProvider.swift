import Foundation
import SafeRoutesEngine

/// Single point where the UI binds to a routing implementation.
enum EngineProvider {
    // INTEGRATION: swap to NativeRoutingEngine()
    static let engine: any RoutingEngine = MockRoutingEngine()
}
