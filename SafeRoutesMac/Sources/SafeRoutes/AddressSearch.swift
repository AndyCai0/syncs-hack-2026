import CoreLocation
import Foundation
import MapKit

struct Place: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var coordinate: CLLocationCoordinate2D

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Suggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion

    var label: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

enum Sydney {
    static let center = CLLocationCoordinate2D(latitude: -33.87, longitude: 151.0)
    static let region = MKCoordinateRegion(center: center,
                                           span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0))
    static let overview = MKCoordinateRegion(center: center,
                                             span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45))
}

/// Thin wrapper over MKLocalSearchCompleter. Kept as an ObservableObject so the
/// NSObject delegate plumbing stays out of the @Observable app model.
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [Suggestion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Sydney.region
        completer.delegate = self
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.prefix(6).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        DispatchQueue.main.async { [weak self] in
            self?.suggestions = Array(mapped)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.suggestions = []
        }
    }
}

enum Geocoder {
    /// Resolves a completion (which carries no coordinate) to a Place.
    static func resolve(_ suggestion: Suggestion) async -> Place? {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.region = Sydney.region
        return await run(request, fallbackLabel: suggestion.label)
    }

    /// Free-text fallback for when the user typed an address but never picked a suggestion.
    static func resolve(text: String) async -> Place? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = Sydney.region
        return await run(request, fallbackLabel: trimmed)
    }

    private static func run(_ request: MKLocalSearch.Request, fallbackLabel: String) async -> Place? {
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { return nil }
            let coordinate = item.placemark.coordinate
            let label = item.name ?? fallbackLabel
            return Place(label: label, coordinate: coordinate)
        } catch {
            return nil
        }
    }
}
