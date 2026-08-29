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
    /// Each `route(...)` call produces a fastest baseline and a small bounded
    /// set of historical-hazard-aware candidates from the same snapped endpoints.
public final class NativeRoutingEngine: RoutingEngine {
    public static let maxDetourRatio = 1.25
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

        let fastestRoute = try await Task.detached(priority: .userInitiated) {
            try NativeRouter.route(store: store, from: source, to: target,
                                   profile: profile, k: 0, afterDark: afterDark)
        }.value

        let maximumK = NativeRouter.k(forSafety: 1)
        let candidateKs = Set([safeK * 0.5, safeK, min(maximumK, safeK * 1.5)])
            .filter { $0 > 0 }
            .sorted()
        var eligible: [RouteResult] = []
        for candidateK in candidateKs {
            let candidate = try await Task.detached(priority: .userInitiated) {
                try NativeRouter.route(store: store, from: source, to: target,
                                       profile: profile, k: candidateK, afterDark: afterDark)
            }.value
            let withinCap = candidate.durationS <= fastestRoute.durationS * Self.maxDetourRatio
            if withinCap && candidate.riskScore < fastestRoute.riskScore {
                eligible.append(candidate)
            }
        }
        let lowerHazard = eligible.min {
            ($0.riskScore, $0.durationS) < ($1.riskScore, $1.durationS)
        } ?? fastestRoute
        return RoutePair(fastest: fastestRoute, safest: lowerHazard)
    }
}
