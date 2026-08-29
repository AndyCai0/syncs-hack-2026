import CoreLocation
import Foundation

/// Lazily loads and caches one `GraphStore` per profile, off the calling thread.
actor GraphStoreCache {
    private let directory: URL?
    private var stores: [TravelProfile: GraphStore] = [:]
    private var loading: [TravelProfile: Task<GraphStore, Error>] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    func store(for profile: TravelProfile) async throws -> GraphStore {
        if let ready = stores[profile] { return ready }
        if let inFlight = loading[profile] { return try await inFlight.value }

        guard let dir = directory ?? AppDataLocator.dataDirectory() else {
            throw RoutingError.graphNotLoaded
        }
        let url = dir.appendingPathComponent("\(profile.rawValue).graph")
        let task = Task.detached(priority: .userInitiated) { try GraphStore(contentsOf: url) }
        loading[profile] = task
        do {
            let store = try await task.value
            stores[profile] = store
            loading[profile] = nil
            return store
        } catch {
            loading[profile] = nil
            if let load = error as? GraphLoadError, case .fileNotFound = load {
                throw RoutingError.graphNotLoaded
            }
            throw error
        }
    }

    func cachedStore(for profile: TravelProfile) -> GraphStore? { stores[profile] }
}

/// `RoutingEngine` backed by the native SRG1 graph + risk-weighted Dijkstra.
///
/// Each `route(...)` call produces two paths from the same snapped endpoints:
/// the fastest (`k = 0`) and the safest (`k = safety * 4`), computed concurrently.
public final class NativeRoutingEngine: RoutingEngine {
    private let cache: GraphStoreCache

    /// - Parameter dataDirectory: overrides `AppDataLocator.dataDirectory()`
    ///   (used by tests); `nil` resolves the app data directory at load time.
    public init(dataDirectory: URL? = nil) {
        self.cache = GraphStoreCache(directory: dataDirectory)
    }

    /// Warms the graph for a profile so the first route doesn't pay the load cost.
    @discardableResult
    public func preload(profile: TravelProfile) async throws -> Double {
        try await cache.store(for: profile).loadSeconds
    }

    public func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                      profile: TravelProfile, safety: Double, afterDark: Bool) async throws -> RoutePair {
        let store = try await cache.store(for: profile)
        let source = try store.nearestNode(to: start)
        let target = try store.nearestNode(to: end)
        let safeK = NativeRouter.k(forSafety: safety)

        async let fastest = Task.detached(priority: .userInitiated) {
            try NativeRouter.route(store: store, from: source, to: target,
                                   profile: profile, k: 0, afterDark: afterDark)
        }.value
        async let safest = Task.detached(priority: .userInitiated) {
            try NativeRouter.route(store: store, from: source, to: target,
                                   profile: profile, k: safeK, afterDark: afterDark)
        }.value

        return try await RoutePair(fastest: fastest, safest: safest)
    }
}
