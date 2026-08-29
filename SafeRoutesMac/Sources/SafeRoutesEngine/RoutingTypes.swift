import CoreLocation
import Foundation

// Shared contract between the engine (GraphStore/Router) and the SwiftUI app.
// UI code depends only on what is in this file plus `NativeRoutingEngine`'s
// initializer — keep additions backward-compatible during the hack.

public enum TravelProfile: String, CaseIterable, Sendable {
    case walking
    case cycling

    public var speedMps: Double {
        switch self {
        case .walking: 4.8 / 3.6
        case .cycling: 15.0 / 3.6
        }
    }
}

public struct RouteResult: Sendable {
    /// Full display polyline, WGS84.
    public var coordinates: [CLLocationCoordinate2D]
    public var distanceM: Double
    public var durationS: Double
    /// Summed severity-weighted risk of every edge on the path.
    public var riskScore: Double
    /// Total crashes snapped to edges on the path.
    public var crashCount: Int
    public var schoolZoneMeters: Double

    public init(coordinates: [CLLocationCoordinate2D], distanceM: Double, durationS: Double,
                riskScore: Double, crashCount: Int, schoolZoneMeters: Double) {
        self.coordinates = coordinates
        self.distanceM = distanceM
        self.durationS = durationS
        self.riskScore = riskScore
        self.crashCount = crashCount
        self.schoolZoneMeters = schoolZoneMeters
    }
}

public struct RoutePair: Sendable {
    public var fastest: RouteResult
    public var safest: RouteResult
    public init(fastest: RouteResult, safest: RouteResult) {
        self.fastest = fastest
        self.safest = safest
    }
}

public enum RoutingError: Error, LocalizedError {
    case graphNotLoaded
    case noPath
    case pointOutsideCoverage

    public var errorDescription: String? {
        switch self {
        case .graphNotLoaded: "Routing graph is not loaded yet."
        case .noPath: "No path found between those points."
        case .pointOutsideCoverage: "That point is outside the Greater Sydney graph."
        }
    }
}

public protocol RoutingEngine: Sendable {
    /// safety in 0...1 (slider). afterDark switches to the night-weighted risk column.
    func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
               profile: TravelProfile, safety: Double, afterDark: Bool) async throws -> RoutePair
}

/// Straight-line placeholder so the UI can be built and demoed before the
/// native engine lands. Replace at integration time.
public struct MockRoutingEngine: RoutingEngine {
    public init() {}

    public func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                      profile: TravelProfile, safety: Double, afterDark: Bool) async throws -> RoutePair {
        let mid = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2 + 0.004,
                                         longitude: (start.longitude + end.longitude) / 2)
        let dLat = (end.latitude - start.latitude) * 111_000
        let dLon = (end.longitude - start.longitude) * 92_000
        let dist = (dLat * dLat + dLon * dLon).squareRoot()
        let fastest = RouteResult(coordinates: [start, end], distanceM: dist,
                                  durationS: dist / profile.speedMps,
                                  riskScore: 120, crashCount: 9, schoolZoneMeters: 0)
        let safest = RouteResult(coordinates: [start, mid, end], distanceM: dist * 1.12,
                                 durationS: dist * 1.12 / profile.speedMps,
                                 riskScore: 35, crashCount: 2, schoolZoneMeters: 240)
        return RoutePair(fastest: fastest, safest: safest)
    }
}

public enum AppDataLocator {
    /// Resolution order: SAFEROUTES_DATA env var, ./data/appdata upward from cwd,
    /// then the repo's absolute path as a dev fallback.
    public static func dataDirectory() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SAFEROUTES_DATA"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("data/appdata", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        let dev = URL(fileURLWithPath: "/Users/andy/Desktop/Study/2026S2C/PEP/Hackson/data/appdata")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }
}
