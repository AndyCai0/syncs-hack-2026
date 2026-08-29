import Foundation
import SafeRoutesEngine

/// Single point where the UI binds to a routing implementation.
enum EngineProvider {
    static let engine: any RoutingEngine = NativeRoutingEngine()
}
