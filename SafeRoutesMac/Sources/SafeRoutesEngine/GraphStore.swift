import CoreLocation
import Foundation

/// Errors raised while loading/parsing a `.graph` (SRG1) file.
public enum GraphLoadError: Error, LocalizedError, Equatable {
    case fileNotFound(String)
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, actual: Int)
    case corruptEdge(index: Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): "Graph file not found at \(p)."
        case .badMagic: "Not a SafeRoutes graph file (bad magic)."
        case .unsupportedVersion(let v): "Unsupported graph version \(v)."
        case .truncated(let e, let a): "Graph file truncated: expected \(e) bytes, found \(a)."
        case .corruptEdge(let i): "Edge record \(i) references an out-of-range node."
        }
    }
}

/// Memory-mapped view of one profile's SRG1 graph, plus the derived structures
/// the router needs: a CSR adjacency (undirected) and a uniform-grid spatial
/// index for snapping coordinates to nodes.
///
/// Immutable after `init`, so it is safe to share across tasks.
public final class GraphStore: @unchecked Sendable {

    // MARK: Header

    public let nodeCount: Int
    public let edgeCount: Int
    public let coordCount: Int
    public let version: UInt32

    // MARK: Node arrays

    let nodeLon: [Double]
    let nodeLat: [Double]

    // MARK: Edge arrays (struct-of-arrays; index == edge id)

    let edgeU: [UInt32]
    let edgeV: [UInt32]
    let edgeLength: [Float]
    let edgeRisk: [Float]
    let edgeRiskDark: [Float]
    let edgeCrashCount: [UInt16]
    let edgeSchoolZone: [UInt8]
    let edgeGeomOffset: [UInt32]
    let edgeGeomCount: [UInt32]

    // MARK: CSR adjacency — each undirected edge appears once per direction

    /// `adjStart[n] ..< adjStart[n + 1]` indexes into `adjNode`/`adjEdge`.
    let adjStart: [Int32]
    let adjNode: [UInt32]
    let adjEdge: [UInt32]

    // MARK: Spatial grid

    static let cellSize = 0.005
    private let gridMinLon: Double
    private let gridMinLat: Double
    private let gridNX: Int
    private let gridNY: Int
    private let cellStart: [Int32]
    private let cellNodes: [UInt32]

    // MARK: Geometry (left in the mapping; read on demand)

    private let data: Data
    private let geomLonOffset: Int
    private let geomLatOffset: Int

    /// Wall-clock seconds spent in `init`, handy for the demo/logging.
    public private(set) var loadSeconds: Double = 0

    // MARK: - Loading

    public convenience init(profile: TravelProfile, directory: URL) throws {
        try self.init(contentsOf: directory.appendingPathComponent("\(profile.rawValue).graph"))
    }

    public init(contentsOf url: URL) throws {
        let t0 = DispatchTime.now().uptimeNanoseconds

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GraphLoadError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        self.data = data
        let fileSize = data.count
        guard fileSize >= 32 else { throw GraphLoadError.truncated(expected: 32, actual: fileSize) }

        // --- header -------------------------------------------------------
        var header = (nodeCount: 0, edgeCount: 0, coordCount: 0, version: UInt32(0))
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            let m0 = base.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let m1 = base.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            let m2 = base.loadUnaligned(fromByteOffset: 2, as: UInt8.self)
            let m3 = base.loadUnaligned(fromByteOffset: 3, as: UInt8.self)
            guard m0 == 0x53, m1 == 0x52, m2 == 0x47, m3 == 0x31 else { // "SRG1"
                throw GraphLoadError.badMagic
            }
            let v = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard v == 1 else { throw GraphLoadError.unsupportedVersion(v) }
            header.version = v
            header.nodeCount = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            header.edgeCount = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            header.coordCount = Int(UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
        }
        let n = header.nodeCount, e = header.edgeCount, c = header.coordCount
        self.version = header.version
        self.nodeCount = n
        self.edgeCount = e
        self.coordCount = c

        // --- array offsets (each 8-byte aligned) ---------------------------
        func align8(_ x: Int) -> Int { (x + 7) & ~7 }
        let nodeLonOff = 32
        let nodeLatOff = align8(nodeLonOff + n * 8)
        let edgesOff = align8(nodeLatOff + n * 8)
        let geomLonOff = align8(edgesOff + e * 32)
        let geomLatOff = align8(geomLonOff + c * 4)
        let needed = geomLatOff + c * 4
        guard fileSize >= needed else { throw GraphLoadError.truncated(expected: needed, actual: fileSize) }
        self.geomLonOffset = geomLonOff
        self.geomLatOffset = geomLatOff

        // --- bulk copies ---------------------------------------------------
        var lon = [Double](repeating: 0, count: n)
        var lat = [Double](repeating: 0, count: n)
        var eu = [UInt32](repeating: 0, count: e)
        var ev = [UInt32](repeating: 0, count: e)
        var elen = [Float](repeating: 0, count: e)
        var erisk = [Float](repeating: 0, count: e)
        var edark = [Float](repeating: 0, count: e)
        var ecrash = [UInt16](repeating: 0, count: e)
        var eszone = [UInt8](repeating: 0, count: e)
        var egoff = [UInt32](repeating: 0, count: e)
        var egcnt = [UInt32](repeating: 0, count: e)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            if n > 0 {
                lon.withUnsafeMutableBytes { memcpy($0.baseAddress!, base + nodeLonOff, n * 8) }
                lat.withUnsafeMutableBytes { memcpy($0.baseAddress!, base + nodeLatOff, n * 8) }
            }
            guard e > 0 else { return }
            // Each EdgeRecord is eight 4-byte little-endian words. memcpy the
            // whole block into an aligned scratch buffer, then split it into
            // columns — much cheaper than nine unaligned loads per record.
            var words = [UInt32](repeating: 0, count: e * 8)
            words.withUnsafeMutableBytes { memcpy($0.baseAddress!, base + edgesOff, e * 32) }
            words.withUnsafeBufferPointer { wbuf in
                let w = wbuf.baseAddress!
                eu.withUnsafeMutableBufferPointer { pu in
                ev.withUnsafeMutableBufferPointer { pv in
                elen.withUnsafeMutableBufferPointer { pl in
                erisk.withUnsafeMutableBufferPointer { pr in
                edark.withUnsafeMutableBufferPointer { pd in
                ecrash.withUnsafeMutableBufferPointer { pc in
                eszone.withUnsafeMutableBufferPointer { ps in
                egoff.withUnsafeMutableBufferPointer { po in
                egcnt.withUnsafeMutableBufferPointer { pn in
                    let u = pu.baseAddress!, v = pv.baseAddress!
                    let l = pl.baseAddress!, r = pr.baseAddress!
                    let d = pd.baseAddress!, cc = pc.baseAddress!
                    let sz = ps.baseAddress!, go = po.baseAddress!, gc = pn.baseAddress!
                    var j = 0
                    for i in 0..<e {
                        u[i] = UInt32(littleEndian: w[j])
                        v[i] = UInt32(littleEndian: w[j + 1])
                        l[i] = Float(bitPattern: UInt32(littleEndian: w[j + 2]))
                        r[i] = Float(bitPattern: UInt32(littleEndian: w[j + 3]))
                        d[i] = Float(bitPattern: UInt32(littleEndian: w[j + 4]))
                        let packed = UInt32(littleEndian: w[j + 5])
                        cc[i] = UInt16(truncatingIfNeeded: packed)
                        sz[i] = UInt8(truncatingIfNeeded: packed >> 16)
                        go[i] = UInt32(littleEndian: w[j + 6])
                        gc[i] = UInt32(littleEndian: w[j + 7])
                        j += 8
                    }
                }}}}}}}}}
            }
        }

        self.nodeLon = lon
        self.nodeLat = lat
        self.edgeU = eu
        self.edgeV = ev
        self.edgeLength = elen
        self.edgeRisk = erisk
        self.edgeRiskDark = edark
        self.edgeCrashCount = ecrash
        self.edgeSchoolZone = eszone
        self.edgeGeomOffset = egoff
        self.edgeGeomCount = egcnt

        // --- CSR adjacency (undirected: both directions) --------------------
        var start = [Int32](repeating: 0, count: n + 1)
        var degree = [Int32](repeating: 0, count: n)
        for i in 0..<e {
            let a = Int(eu[i]), b = Int(ev[i])
            guard a < n, b < n else { throw GraphLoadError.corruptEdge(index: i) }
            degree[a] += 1
            degree[b] += 1
        }
        var running: Int32 = 0
        for i in 0..<n {
            start[i] = running
            running += degree[i]
        }
        start[n] = running
        var cursor = start // copy; cursor[i] is the next free slot for node i
        var aNode = [UInt32](repeating: 0, count: 2 * e)
        var aEdge = [UInt32](repeating: 0, count: 2 * e)
        for i in 0..<e {
            let a = Int(eu[i]), b = Int(ev[i])
            var slot = Int(cursor[a]); cursor[a] += 1
            aNode[slot] = UInt32(b); aEdge[slot] = UInt32(i)
            slot = Int(cursor[b]); cursor[b] += 1
            aNode[slot] = UInt32(a); aEdge[slot] = UInt32(i)
        }
        self.adjStart = start
        self.adjNode = aNode
        self.adjEdge = aEdge

        // --- uniform grid spatial index ------------------------------------
        var minLon = 0.0, minLat = 0.0, maxLon = 0.0, maxLat = 0.0
        if n > 0 {
            minLon = lon[0]; maxLon = lon[0]; minLat = lat[0]; maxLat = lat[0]
            for i in 1..<n {
                let x = lon[i], y = lat[i]
                if x < minLon { minLon = x } else if x > maxLon { maxLon = x }
                if y < minLat { minLat = y } else if y > maxLat { maxLat = y }
            }
        }
        let cs = GraphStore.cellSize
        let nx = n > 0 ? max(1, Int((maxLon - minLon) / cs) + 1) : 1
        let ny = n > 0 ? max(1, Int((maxLat - minLat) / cs) + 1) : 1
        self.gridMinLon = minLon
        self.gridMinLat = minLat
        self.gridNX = nx
        self.gridNY = ny

        var cellCount = [Int32](repeating: 0, count: nx * ny + 1)
        var cellOf = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let ix = min(nx - 1, max(0, Int((lon[i] - minLon) / cs)))
            let iy = min(ny - 1, max(0, Int((lat[i] - minLat) / cs)))
            let ci = iy * nx + ix
            cellOf[i] = Int32(ci)
            cellCount[ci] += 1
        }
        var cStart = [Int32](repeating: 0, count: nx * ny + 1)
        var acc: Int32 = 0
        for i in 0..<(nx * ny) {
            cStart[i] = acc
            acc += cellCount[i]
        }
        cStart[nx * ny] = acc
        var cCursor = cStart
        var cNodes = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let ci = Int(cellOf[i])
            cNodes[Int(cCursor[ci])] = UInt32(i)
            cCursor[ci] += 1
        }
        self.cellStart = cStart
        self.cellNodes = cNodes

        self.loadSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
    }

    // MARK: - Coordinates

    public func coordinate(ofNode index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: nodeLat[index], longitude: nodeLon[index])
    }

    // MARK: - Snapping

    /// Equirectangular metres between two WGS84 points; plenty accurate at city scale.
    @inline(__always)
    static func metres(_ lon1: Double, _ lat1: Double, _ lon2: Double, _ lat2: Double) -> Double {
        let midLat = (lat1 + lat2) * 0.5 * .pi / 180
        let dx = (lon2 - lon1) * 111_320.0 * cos(midLat)
        let dy = (lat2 - lat1) * 110_540.0
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Nearest graph node to a coordinate, searching outward through grid rings.
    /// - Throws: `RoutingError.pointOutsideCoverage` if nothing is within `maxMetres`.
    public func nearestNode(to point: CLLocationCoordinate2D, maxMetres: Double = 500) throws -> Int {
        guard nodeCount > 0 else { throw RoutingError.pointOutsideCoverage }
        let cs = GraphStore.cellSize
        let cx = Int(floor((point.longitude - gridMinLon) / cs))
        let cy = Int(floor((point.latitude - gridMinLat) / cs))

        var best = -1
        var bestDist = Double.infinity
        // 0.005 deg is ~460 m of longitude at Sydney's latitude, so three rings
        // always cover a 500 m radius regardless of where in the cell we land.
        let maxRing = 3
        var ring = 0
        while ring <= maxRing {
            var found = false
            for iy in (cy - ring)...(cy + ring) {
                guard iy >= 0, iy < gridNY else { continue }
                for ix in (cx - ring)...(cx + ring) {
                    // only the perimeter of this ring (inner cells already scanned)
                    if ring > 0, abs(ix - cx) != ring, abs(iy - cy) != ring { continue }
                    guard ix >= 0, ix < gridNX else { continue }
                    let ci = iy * gridNX + ix
                    let lo = Int(cellStart[ci]), hi = Int(cellStart[ci + 1])
                    guard lo < hi else { continue }
                    for s in lo..<hi {
                        let nIdx = Int(cellNodes[s])
                        let d = GraphStore.metres(point.longitude, point.latitude, nodeLon[nIdx], nodeLat[nIdx])
                        if d < bestDist {
                            bestDist = d
                            best = nIdx
                            found = true
                        }
                    }
                }
            }
            // A hit in ring r can still be beaten by ring r+1, so scan one more.
            if found && bestDist < Double(ring) * 400 { break }
            ring += 1
        }
        guard best >= 0, bestDist <= maxMetres else { throw RoutingError.pointOutsideCoverage }
        return best
    }

    // MARK: - Edge cost model (must match GRAPH_FORMAT.md / graph_router.py)

    /// `cost = length * (1 + k * (risk / max(length, 5) * 100) / 10)`, `* 0.9` in a school zone.
    @inline(__always)
    func cost(edge i: Int, k: Double, afterDark: Bool) -> Double {
        let length = Double(edgeLength[i])
        let risk = Double(afterDark ? edgeRiskDark[i] : edgeRisk[i])
        let riskPer100m = risk / max(length, 5.0) * 100.0
        var c = length * (1.0 + k * riskPer100m / 10.0)
        if edgeSchoolZone[i] != 0 { c *= 0.9 }
        return c
    }

    // MARK: - Geometry

    /// Appends edge `i`'s polyline to `out`, oriented `u -> v` unless `reversed`.
    /// Skips the first point when `out` is already non-empty (shared endpoint).
    func appendGeometry(edge i: Int, reversed: Bool, to out: inout [CLLocationCoordinate2D]) {
        let off = Int(edgeGeomOffset[i])
        let count = Int(edgeGeomCount[i])
        guard count > 0, off >= 0, off + count <= coordCount else {
            // Fall back to the straight node-to-node segment.
            let a = Int(reversed ? edgeV[i] : edgeU[i])
            let b = Int(reversed ? edgeU[i] : edgeV[i])
            if out.isEmpty { out.append(coordinate(ofNode: a)) }
            out.append(coordinate(ofNode: b))
            return
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            let skipFirst = out.isEmpty ? 0 : 1
            for step in skipFirst..<count {
                let p = reversed ? (count - 1 - step) : step
                let lonBits = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: geomLonOffset + (off + p) * 4, as: UInt32.self))
                let latBits = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: geomLatOffset + (off + p) * 4, as: UInt32.self))
                out.append(CLLocationCoordinate2D(latitude: Double(Float(bitPattern: latBits)),
                                                  longitude: Double(Float(bitPattern: lonBits))))
            }
        }
    }
}
