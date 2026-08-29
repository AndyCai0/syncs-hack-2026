import CoreLocation
import Foundation

/// Array-backed binary min-heap keyed on `Double`. No third-party deps, and
/// lazy deletion (stale entries are skipped by the caller) keeps it simple.
struct MinHeap {
    struct Entry {
        var cost: Double
        var node: Int32
    }

    private var storage: [Entry] = []

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    mutating func reserveCapacity(_ n: Int) { storage.reserveCapacity(n) }

    mutating func push(_ cost: Double, _ node: Int32) {
        storage.append(Entry(cost: cost, node: node))
        var i = storage.count - 1
        let item = storage[i]
        while i > 0 {
            let parent = (i - 1) >> 1
            if storage[parent].cost <= item.cost { break }
            storage[i] = storage[parent]
            i = parent
        }
        storage[i] = item
    }

    mutating func pop() -> Entry? {
        guard let first = storage.first else { return nil }
        let last = storage.removeLast()
        if !storage.isEmpty {
            var i = 0
            let n = storage.count
            while true {
                let l = 2 * i + 1
                if l >= n { break }
                let r = l + 1
                var child = l
                if r < n, storage[r].cost < storage[l].cost { child = r }
                if storage[child].cost >= last.cost { break }
                storage[i] = storage[child]
                i = child
            }
            storage[i] = last
        }
        return first
    }
}

/// One traversed edge on a reconstructed path.
struct PathStep {
    var edge: Int
    /// True when we walked the edge from `v` to `u` (geometry must be reversed).
    var reversed: Bool
}

/// Risk-weighted Dijkstra over a `GraphStore`.
public enum NativeRouter {

    /// `k = safety * 4.0`; `k == 0` reproduces the shortest path.
    public static func k(forSafety safety: Double) -> Double {
        min(max(safety, 0), 1) * 4.0
    }

    /// Shortest path under the risk-weighted cost model, with early exit when
    /// the target is settled.
    static func shortestPath(store: GraphStore, from source: Int, to target: Int,
                             k: Double, afterDark: Bool) throws -> [PathStep] {
        guard source >= 0, source < store.nodeCount, target >= 0, target < store.nodeCount else {
            throw RoutingError.pointOutsideCoverage
        }
        if source == target { return [] }

        let n = store.nodeCount
        var dist = [Double](repeating: .infinity, count: n)
        var prevNode = [Int32](repeating: -1, count: n)
        var prevEdge = [Int32](repeating: -1, count: n)
        var settled = [Bool](repeating: false, count: n)
        var heap = MinHeap()
        heap.reserveCapacity(4096)

        let lengths = store.edgeLength
        let risks = afterDark ? store.edgeRiskDark : store.edgeRisk
        let szone = store.edgeSchoolZone
        let adjStart = store.adjStart
        let adjNode = store.adjNode
        let adjEdge = store.adjEdge

        dist[source] = 0
        heap.push(0, Int32(source))

        var reached = false
        while let entry = heap.pop() {
            let u = Int(entry.node)
            if settled[u] { continue }
            settled[u] = true
            if u == target { reached = true; break }
            let du = dist[u]

            let lo = Int(adjStart[u]), hi = Int(adjStart[u + 1])
            guard lo < hi else { continue }
            for slot in lo..<hi {
                let v = Int(adjNode[slot])
                if settled[v] { continue }
                let e = Int(adjEdge[slot])
                let length = Double(lengths[e])
                let risk = Double(risks[e])
                let riskPer100m = risk / max(length, 5.0) * 100.0
                var w = length * (1.0 + k * riskPer100m / 10.0)
                if szone[e] != 0 { w *= 0.9 }
                let alt = du + w
                if alt < dist[v] {
                    dist[v] = alt
                    prevNode[v] = Int32(u)
                    prevEdge[v] = Int32(e)
                    heap.push(alt, Int32(v))
                }
            }
        }

        guard reached else { throw RoutingError.noPath }

        // Walk predecessors back from the target.
        var steps: [PathStep] = []
        var current = target
        while current != source {
            let e = Int(prevEdge[current])
            let p = Int(prevNode[current])
            guard e >= 0, p >= 0 else { throw RoutingError.noPath }
            // Geometry is stored oriented u -> v; we traversed p -> current.
            steps.append(PathStep(edge: e, reversed: Int(store.edgeU[e]) != p))
            current = p
        }
        steps.reverse()
        return steps
    }

    /// Full route (path + polyline + display stats) between two coordinates.
    public static func route(store: GraphStore, from source: Int, to target: Int,
                             profile: TravelProfile, k: Double, afterDark: Bool) throws -> RouteResult {
        let steps = try shortestPath(store: store, from: source, to: target, k: k, afterDark: afterDark)

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(steps.count * 4 + 2)
        var distanceM = 0.0
        var riskScore = 0.0
        var crashCount = 0
        var schoolZoneMeters = 0.0

        for step in steps {
            let e = step.edge
            let length = Double(store.edgeLength[e])
            distanceM += length
            riskScore += Double(afterDark ? store.edgeRiskDark[e] : store.edgeRisk[e])
            crashCount += Int(store.edgeCrashCount[e])
            if store.edgeSchoolZone[e] != 0 { schoolZoneMeters += length }
            store.appendGeometry(edge: e, reversed: step.reversed, to: &coordinates)
        }

        if coordinates.isEmpty {
            coordinates = [store.coordinate(ofNode: source)]
            if source != target { coordinates.append(store.coordinate(ofNode: target)) }
        }

        return RouteResult(coordinates: coordinates,
                           distanceM: distanceM,
                           durationS: distanceM / profile.speedMps,
                           riskScore: riskScore,
                           crashCount: crashCount,
                           schoolZoneMeters: schoolZoneMeters)
    }
}
