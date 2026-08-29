import Foundation

/// Minimal in-test writer for the SRG1 binary format documented in
/// SafeRoutesMac/GRAPH_FORMAT.md. Keeps the unit tests independent of the
/// Python exporter.
struct SyntheticGraph {
    struct Node {
        var lon: Double
        var lat: Double
    }

    struct Edge {
        var u: UInt32
        var v: UInt32
        var length: Float
        var risk: Float = 0
        var riskDark: Float = 0
        var crashCount: UInt16 = 0
        var schoolZone: Bool = false
        /// Points oriented u -> v. Defaults to the straight node-to-node segment.
        var geometry: [(lon: Double, lat: Double)] = []
    }

    var nodes: [Node]
    var edges: [Edge]

    var coordCount: Int {
        edges.reduce(0) { $0 + max(2, $1.geometry.count) }
    }

    func serialized() -> Data {
        var out = Data()

        func align8() {
            while out.count % 8 != 0 { out.append(0) }
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
        func appendF64(_ value: Double) { appendLE(value.bitPattern) }
        func appendF32(_ value: Float) { appendLE(value.bitPattern) }

        // Resolve geometry (defaulting to straight segments) up front.
        let resolved: [[(lon: Double, lat: Double)]] = edges.map { e in
            if e.geometry.count >= 2 { return e.geometry }
            return [(nodes[Int(e.u)].lon, nodes[Int(e.u)].lat),
                    (nodes[Int(e.v)].lon, nodes[Int(e.v)].lat)]
        }

        // --- header (32 bytes) ---
        out.append(contentsOf: Array("SRG1".utf8))
        appendLE(UInt32(1))
        appendLE(UInt32(nodes.count))
        appendLE(UInt32(edges.count))
        appendLE(UInt64(resolved.reduce(0) { $0 + $1.count }))
        out.append(contentsOf: [UInt8](repeating: 0, count: 8))

        // --- nodeLon / nodeLat ---
        align8()
        for n in nodes { appendF64(n.lon) }
        align8()
        for n in nodes { appendF64(n.lat) }

        // --- edges ---
        align8()
        var geomOffset = UInt32(0)
        for (i, e) in edges.enumerated() {
            appendLE(e.u)
            appendLE(e.v)
            appendF32(e.length)
            appendF32(e.risk)
            appendF32(e.riskDark)
            appendLE(e.crashCount)
            out.append(e.schoolZone ? 1 : 0)
            out.append(0) // pad
            appendLE(geomOffset)
            appendLE(UInt32(resolved[i].count))
            geomOffset += UInt32(resolved[i].count)
        }

        // --- geomLon / geomLat ---
        align8()
        for pts in resolved { for p in pts { appendF32(Float(p.lon)) } }
        align8()
        for pts in resolved { for p in pts { appendF32(Float(p.lat)) } }

        return out
    }

    @discardableResult
    func write(to url: URL) throws -> URL {
        try serialized().write(to: url)
        return url
    }
}

enum Fixtures {
    /// Diamond graph: 0 -1- 1 -2- 2 direct, plus a longer detour 1 -> 3 -> 2.
    ///
    ///        3
    ///      /   \        (80 m + 80 m, risk-free; edge 3 is stored v->u on purpose)
    ///  0--1-----2
    ///  100   100 (risky)
    static func diversionGraph(risk: Float, riskDark: Float) -> SyntheticGraph {
        let nodes = [
            SyntheticGraph.Node(lon: 151.0000, lat: -33.9000), // 0
            SyntheticGraph.Node(lon: 151.0010, lat: -33.9000), // 1
            SyntheticGraph.Node(lon: 151.0020, lat: -33.9000), // 2
            SyntheticGraph.Node(lon: 151.0010, lat: -33.8990), // 3
        ]
        let edges = [
            // 3-point geometry so polyline concatenation is exercised.
            SyntheticGraph.Edge(u: 0, v: 1, length: 100, geometry: [
                (151.0000, -33.9000), (151.0005, -33.9001), (151.0010, -33.9000),
            ]),
            SyntheticGraph.Edge(u: 1, v: 2, length: 100, risk: risk, riskDark: riskDark, crashCount: 7),
            SyntheticGraph.Edge(u: 1, v: 3, length: 80),
            // Stored 2 -> 3: traversing 3 -> 2 must reverse the geometry.
            SyntheticGraph.Edge(u: 2, v: 3, length: 80),
        ]
        return SyntheticGraph(nodes: nodes, edges: edges)
    }

    /// Two ways from 0 to 1, both 100 m; the two-hop one is in a school zone
    /// so its discounted cost (90) beats the direct edge (100).
    static func schoolZoneGraph() -> SyntheticGraph {
        let nodes = [
            SyntheticGraph.Node(lon: 151.0000, lat: -33.9000), // 0
            SyntheticGraph.Node(lon: 151.0020, lat: -33.9000), // 1
            SyntheticGraph.Node(lon: 151.0010, lat: -33.8995), // 2
        ]
        let edges = [
            SyntheticGraph.Edge(u: 0, v: 1, length: 100),
            SyntheticGraph.Edge(u: 0, v: 2, length: 50, schoolZone: true),
            SyntheticGraph.Edge(u: 2, v: 1, length: 50, schoolZone: true),
        ]
        return SyntheticGraph(nodes: nodes, edges: edges)
    }
}
