import CoreLocation
import Foundation
import MapKit
import SafeRoutesEngine
import SwiftUI

@Observable
@MainActor
final class AppModel {
    // Inputs
    var fromText: String = ""
    var toText: String = ""
    var fromPlace: Place?
    var toPlace: Place?
    var profile: TravelProfile = .walking
    var safety: Double = 0.6
    var afterDark: Bool = false
    var showSchoolZones: Bool = true

    // Routing state
    var isRouting: Bool = false
    var routes: RoutePair?
    var errorMessage: String?

    // Map state
    var camera: MapCameraPosition = .region(Sydney.overview)
    var visibleRegion: MKCoordinateRegion = Sydney.overview
    var selectedCrash: CrashPoint?

    // Data layers
    var layers = MapLayers()
    var isLoadingData = false
    var renderedCrashes: [CrashPoint] = []
    var renderedSchools: [SchoolPoint] = []
    var renderedZones: [SchoolZone] = []

    var canRoute: Bool {
        !isRouting && !fromText.trimmingCharacters(in: .whitespaces).isEmpty
            && !toText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var safetyPercent: Int { Int((safety * 100).rounded()) }

    // MARK: - Data

    func loadDataIfNeeded() async {
        guard layers.isEmpty, !isLoadingData else { return }
        isLoadingData = true
        let loaded = await GeoDataLoader.loadAll()
        layers = loaded
        isLoadingData = false
        recomputeVisibleLayers()
    }

    func cameraChanged(to region: MKCoordinateRegion) {
        visibleRegion = region
        recomputeVisibleLayers()
    }

    func recomputeVisibleLayers() {
        renderedCrashes = layers.visibleCrashes(in: visibleRegion)
        renderedSchools = layers.visibleSchools(in: visibleRegion)
        renderedZones = showSchoolZones ? layers.visibleZones(in: visibleRegion) : []
    }

    var crashLayerHint: String? {
        guard !layers.crashes.isEmpty else { return nil }
        if visibleRegion.span.latitudeDelta >= LayerBudget.crashSpan {
            return "Zoom in to see individual crash points."
        }
        if renderedCrashes.count >= LayerBudget.crashCap {
            return "Showing the \(LayerBudget.crashCap) most severe crashes in view."
        }
        return nil
    }

    // MARK: - Selection

    func selectCrash(near coordinate: CLLocationCoordinate2D) {
        guard !renderedCrashes.isEmpty else { selectedCrash = nil; return }
        let tolerance = max(visibleRegion.span.latitudeDelta * 0.03, 0.0002)
        var best: CrashPoint?
        var bestD = Double.greatestFiniteMagnitude
        for c in renderedCrashes {
            let dLat = c.coordinate.latitude - coordinate.latitude
            let dLon = (c.coordinate.longitude - coordinate.longitude) * 0.83
            let d = dLat * dLat + dLon * dLon
            if d < bestD { bestD = d; best = c }
        }
        selectedCrash = bestD.squareRoot() <= tolerance ? best : nil
    }

    // MARK: - Routing

    func findRoutes() async {
        errorMessage = nil
        selectedCrash = nil

        guard let start = await resolveEndpoint(place: fromPlace, text: fromText, label: "start") else { return }
        guard let end = await resolveEndpoint(place: toPlace, text: toText, label: "destination") else { return }

        fromPlace = start
        toPlace = end
        isRouting = true
        defer { isRouting = false }

        do {
            let pair = try await EngineProvider.engine.route(
                from: start.coordinate, to: end.coordinate,
                profile: profile, safety: safety, afterDark: afterDark
            )
            routes = pair
            fitCamera(to: pair, start: start.coordinate, end: end.coordinate)
        } catch let error as RoutingError {
            routes = nil
            errorMessage = error.errorDescription ?? "Routing failed."
        } catch {
            routes = nil
            errorMessage = error.localizedDescription
        }
    }

    private func resolveEndpoint(place: Place?, text: String, label: String) async -> Place? {
        if let place { return place }
        isRouting = true
        let resolved = await Geocoder.resolve(text: text)
        isRouting = false
        if resolved == nil {
            errorMessage = "Couldn't find that \(label) address in Sydney."
        }
        return resolved
    }

    private func fitCamera(to pair: RoutePair, start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        var coords = pair.fastest.coordinates + pair.safest.coordinates
        coords.append(start)
        coords.append(end)
        guard let region = RegionMath.fit(coords) else { return }
        camera = .region(region)
        visibleRegion = region
        recomputeVisibleLayers()
    }

    // MARK: - Verdict

    var verdict: String? {
        guard let routes else { return nil }
        let fast = routes.fastest
        let safe = routes.safest
        guard fast.riskScore > 0 else { return nil }
        if safe.riskScore < fast.riskScore {
            let cut = Int(((1 - safe.riskScore / fast.riskScore) * 100).rounded())
            let extra = max(0, safe.durationS - fast.durationS)
            return "Safest route cuts crash-risk exposure by \(cut)% for \(Fmt.duration(extra)) extra."
        }
        return "The fastest route is already the safest for this trip."
    }
}

enum RegionMath {
    static func fit(_ coords: [CLLocationCoordinate2D], padding: Double = 1.45) -> MKCoordinateRegion? {
        let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
        guard let first = valid.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in valid {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * padding, 0.006),
            longitudeDelta: max((maxLon - minLon) * padding, 0.006)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
