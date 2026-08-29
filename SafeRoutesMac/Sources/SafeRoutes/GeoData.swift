import CoreLocation
import Foundation
import MapKit
import SafeRoutesEngine

// MARK: - Models

enum CrashSeverity: Int, Sendable {
    case fatal = 3
    case serious = 2
    case other = 1

    static func from(degree: String?, detailed: String?) -> CrashSeverity {
        if degree?.caseInsensitiveCompare("Fatal") == .orderedSame { return .fatal }
        if detailed?.localizedCaseInsensitiveContains("Serious") == true { return .serious }
        return .other
    }
}

struct CrashPoint: Identifiable, Sendable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let severity: CrashSeverity
    let degreeDetailed: String
    let year: Int
    let street: String
    let town: String

    var headline: String {
        degreeDetailed.isEmpty ? "Crash" : degreeDetailed
    }

    var subtitle: String {
        let place = [street.capitalized, town.capitalized]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return place.isEmpty ? "\(year)" : "\(place) · \(year)"
    }
}

struct SchoolPoint: Identifiable, Sendable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let name: String
}

struct SchoolZone: Identifiable, Sendable {
    let id: Int
    let ring: [CLLocationCoordinate2D]
    let center: CLLocationCoordinate2D
    let name: String
}

struct MapLayers: Sendable {
    var crashes: [CrashPoint] = []
    var schools: [SchoolPoint] = []
    var zones: [SchoolZone] = []
    /// Human readable note when data could not be found; nil when everything loaded.
    var note: String?

    var isEmpty: Bool { crashes.isEmpty && schools.isEmpty && zones.isEmpty }
}

// MARK: - Zoom gating + caps (performance strategy)

enum LayerBudget {
    /// 12k crash points must never all become annotations.
    static let crashSpan = 0.05
    static let crashCap = 500
    static let schoolSpan = 0.09
    static let schoolCap = 250
    static let zoneSpan = 0.12
    static let zoneCap = 250
}

extension MapLayers {
    func visibleCrashes(in region: MKCoordinateRegion) -> [CrashPoint] {
        guard region.span.latitudeDelta < LayerBudget.crashSpan, !crashes.isEmpty else { return [] }
        let box = BBox(region: region, pad: 1.15)
        var hits: [CrashPoint] = []
        hits.reserveCapacity(LayerBudget.crashCap)
        for c in crashes where box.contains(c.coordinate) {
            hits.append(c)
            if hits.count > LayerBudget.crashCap * 4 { break }
        }
        if hits.count > LayerBudget.crashCap {
            hits.sort { $0.severity.rawValue > $1.severity.rawValue }
            hits = Array(hits.prefix(LayerBudget.crashCap))
        }
        return hits
    }

    func visibleSchools(in region: MKCoordinateRegion) -> [SchoolPoint] {
        guard region.span.latitudeDelta < LayerBudget.schoolSpan, !schools.isEmpty else { return [] }
        let box = BBox(region: region, pad: 1.1)
        var hits: [SchoolPoint] = []
        for s in schools where box.contains(s.coordinate) {
            hits.append(s)
            if hits.count >= LayerBudget.schoolCap { break }
        }
        return hits
    }

    func visibleZones(in region: MKCoordinateRegion) -> [SchoolZone] {
        guard region.span.latitudeDelta < LayerBudget.zoneSpan, !zones.isEmpty else { return [] }
        let box = BBox(region: region, pad: 1.3)
        var hits: [SchoolZone] = []
        for z in zones where box.contains(z.center) {
            hits.append(z)
            if hits.count >= LayerBudget.zoneCap { break }
        }
        return hits
    }
}

struct BBox {
    var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    init(region: MKCoordinateRegion, pad: Double) {
        let dLat = max(region.span.latitudeDelta, 0.0001) * pad / 2
        let dLon = max(region.span.longitudeDelta, 0.0001) * pad / 2
        minLat = region.center.latitude - dLat
        maxLat = region.center.latitude + dLat
        minLon = region.center.longitude - dLon
        maxLon = region.center.longitude + dLon
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon
    }
}

// MARK: - GeoJSON decoding

private struct GJCollection<P: Decodable>: Decodable {
    let features: [GJFeature<P>]
}

private struct GJFeature<P: Decodable>: Decodable {
    let geometry: GJGeometry?
    let properties: P?
}

private struct GJGeometry: Decodable {
    let point: CLLocationCoordinate2D?
    let rings: [[CLLocationCoordinate2D]]

    private enum Keys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "Point":
            let raw = (try? c.decode([Double].self, forKey: .coordinates)) ?? []
            point = GJGeometry.coord(raw)
            rings = []
        case "Polygon":
            let raw = (try? c.decode([[[Double]]].self, forKey: .coordinates)) ?? []
            point = nil
            rings = raw.prefix(1).map(GJGeometry.ring)
        case "MultiPolygon":
            let raw = (try? c.decode([[[[Double]]]].self, forKey: .coordinates)) ?? []
            point = nil
            rings = raw.compactMap { poly in poly.first.map(GJGeometry.ring) }
        default:
            point = nil
            rings = []
        }
    }

    private static func coord(_ pair: [Double]) -> CLLocationCoordinate2D? {
        guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
        return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
    }

    private static func ring(_ raw: [[Double]]) -> [CLLocationCoordinate2D] {
        raw.compactMap(GJGeometry.coord)
    }
}

private struct CrashProps: Decodable {
    var degree_of_crash: String?
    var degree_of_crash_detailed: String?
    var year_of_crash: Int?
    var street_of_crash: String?
    var town: String?
}

private struct SchoolProps: Decodable {
    var name: String?
}

private struct ZoneProps: Decodable {
    var SCL_NAME: String?
    var SZ_SPEED: String?
}

// MARK: - Loader

enum GeoDataLoader {
    /// Candidate roots, most-specific first. The engine's locator points at
    /// `data/appdata`; during the hack the raw exports also live in
    /// `data/processed`, so fall back to that.
    static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        if let d = AppDataLocator.dataDirectory() {
            dirs.append(d)
            dirs.append(d.deletingLastPathComponent().appendingPathComponent("processed", isDirectory: true))
        }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0 ..< 6 {
            dirs.append(dir.appendingPathComponent("data/processed", isDirectory: true))
            dirs.append(dir.appendingPathComponent("data/appdata", isDirectory: true))
            dir.deleteLastPathComponent()
        }
        dirs.append(URL(fileURLWithPath: "/Users/andy/Desktop/Study/2026S2C/PEP/Hackson/data/processed"))
        return dirs
    }

    private static func locate(_ file: String) -> URL? {
        let fm = FileManager.default
        for dir in candidateDirectories() {
            let url = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Decodes every layer off the main thread. Missing files are simply skipped.
    static func loadAll() async -> MapLayers {
        await Task.detached(priority: .utility) { () -> MapLayers in
            var layers = MapLayers()
            var missing: [String] = []

            if let url = locate("active_crashes.geojson") {
                layers.crashes = decodeCrashes(url)
            } else {
                missing.append("crashes")
            }
            if let url = locate("school_zones.geojson") {
                layers.zones = decodeZones(url)
            } else {
                missing.append("school zones")
            }
            if let url = locate("schools.geojson") {
                layers.schools = decodeSchools(url)
            } else {
                missing.append("schools")
            }

            if !missing.isEmpty {
                layers.note = "Map data not found (\(missing.joined(separator: ", "))). Routing still works."
            }
            return layers
        }.value
    }

    private static func data(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func decodeCrashes(_ url: URL) -> [CrashPoint] {
        guard let raw = data(url),
              let coll = try? JSONDecoder().decode(GJCollection<CrashProps>.self, from: raw)
        else { return [] }
        var out: [CrashPoint] = []
        out.reserveCapacity(coll.features.count)
        for (i, f) in coll.features.enumerated() {
            guard let c = f.geometry?.point else { continue }
            let p = f.properties
            out.append(CrashPoint(
                id: i,
                coordinate: c,
                severity: .from(degree: p?.degree_of_crash, detailed: p?.degree_of_crash_detailed),
                degreeDetailed: p?.degree_of_crash_detailed ?? p?.degree_of_crash ?? "Crash",
                year: p?.year_of_crash ?? 0,
                street: p?.street_of_crash ?? "",
                town: p?.town ?? ""
            ))
        }
        return out
    }

    private static func decodeSchools(_ url: URL) -> [SchoolPoint] {
        guard let raw = data(url),
              let coll = try? JSONDecoder().decode(GJCollection<SchoolProps>.self, from: raw)
        else { return [] }
        var out: [SchoolPoint] = []
        for (i, f) in coll.features.enumerated() {
            guard let c = f.geometry?.point else { continue }
            out.append(SchoolPoint(id: i, coordinate: c, name: f.properties?.name ?? "School"))
        }
        return out
    }

    private static func decodeZones(_ url: URL) -> [SchoolZone] {
        guard let raw = data(url),
              let coll = try? JSONDecoder().decode(GJCollection<ZoneProps>.self, from: raw)
        else { return [] }
        var out: [SchoolZone] = []
        var next = 0
        for f in coll.features {
            guard let geometry = f.geometry else { continue }
            for ring in geometry.rings where ring.count >= 3 {
                var lat = 0.0, lon = 0.0
                for p in ring { lat += p.latitude; lon += p.longitude }
                let center = CLLocationCoordinate2D(latitude: lat / Double(ring.count),
                                                    longitude: lon / Double(ring.count))
                out.append(SchoolZone(id: next, ring: ring, center: center,
                                      name: f.properties?.SCL_NAME ?? "School zone"))
                next += 1
            }
        }
        return out
    }
}
