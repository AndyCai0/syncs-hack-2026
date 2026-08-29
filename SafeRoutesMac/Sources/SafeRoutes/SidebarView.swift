import MapKit
import SafeRoutesEngine
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inputs stay pinned — never inside the scroll area.
            VStack(alignment: .leading, spacing: 14) {
                header
                AddressField(
                    label: "From",
                    placeholder: "Home address…",
                    text: $model.fromText,
                    place: $model.fromPlace
                )
                AddressField(
                    label: "To",
                    placeholder: "School or destination…",
                    text: $model.toText,
                    place: $model.toPlace
                )
                profilePicker
                safetySlider
                toggles
                findButton
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
            }
            .padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.routes != nil {
                        legend
                        comparison
                    }
                    if let hint = model.crashLayerHint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .background(.background)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("SafeRoutes").font(.system(size: 24, weight: .bold))
                Text("Sydney").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.safe)
            }
            Text("Fastest vs safest walking & cycling routes, powered by 5 years of real NSW crash data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var profilePicker: some View {
        Picker("Mode", selection: $model.profile) {
            Text("Walk").tag(TravelProfile.walking)
            Text("Bike").tag(TravelProfile.cycling)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var safetySlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Safety priority: \(model.safetyPercent)%")
                .font(.caption).fontWeight(.semibold)
            Slider(value: $model.safety, in: 0 ... 1)
                .tint(Theme.safe)
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.afterDark) {
                Text("After dark (weights night-time crashes higher)").font(.caption)
            }
            Toggle(isOn: $model.showSchoolZones) {
                Text("Show 40 km/h school zones").font(.caption)
            }
            .onChange(of: model.showSchoolZones) { _, _ in
                model.recomputeVisibleLayers()
            }
        }
        .toggleStyle(.checkbox)
    }

    private var findButton: some View {
        Button {
            Task { await model.findRoutes() }
        } label: {
            HStack {
                Spacer()
                if model.isRouting {
                    ProgressView().controlSize(.small)
                    Text("Routing…")
                } else {
                    Text("Find routes").fontWeight(.semibold)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.safe)
        .controlSize(.large)
        .disabled(!model.canRoute)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            LegendSwatch(color: Theme.fast, label: "fastest")
            LegendSwatch(color: Theme.safe, label: "safest")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var comparison: some View {
        if let routes = model.routes {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    RouteCard(kind: .fastest, route: routes.fastest)
                    RouteCard(kind: .safest, route: routes.safest)
                }
                if let verdict = model.verdict {
                    Text(verdict)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.verdictBG, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                }
            }
        }
    }

    private var footer: some View {
        Text("Crash data: Transport for NSW Road Crash Data 2020–2024 (CC BY 4.0). Not a substitute for adult supervision.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
    }
}

// MARK: - Address field with MKLocalSearchCompleter autocomplete

struct AddressField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Binding var place: Place?

    @StateObject private var completer = AddressCompleter()
    @State private var showResults = false
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, new in
                        if place?.label != new { place = nil }
                        completer.update(query: new)
                        showResults = true
                    }
                if resolving {
                    ProgressView().controlSize(.small)
                } else if place != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe)
                }
            }
            if showResults, place == nil, !completer.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(completer.suggestions) { suggestion in
                        Button {
                            choose(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title).font(.caption).foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            }
        }
    }

    private func choose(_ suggestion: Suggestion) {
        showResults = false
        resolving = true
        completer.clear()
        Task {
            let resolved = await Geocoder.resolve(suggestion)
            await MainActor.run {
                resolving = false
                guard let resolved else { return }
                // Keep the label identical to the text field so the `onChange`
                // guard above doesn't immediately clear the resolved place.
                text = suggestion.label
                place = Place(label: suggestion.label, coordinate: resolved.coordinate)
            }
        }
    }
}

// MARK: - Small components

struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 20, height: 3)
            Text(label)
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(Theme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct RouteCard: View {
    enum Kind {
        case fastest, safest

        var title: String { self == .fastest ? "⚡ Fastest" : "🛡 Safest" }
        var accent: Color { self == .fastest ? Theme.fast : Theme.safe }
        var background: Color { self == .fastest ? Color.gray.opacity(0.12) : Theme.safeTint }
        var ink: Color { self == .fastest ? Color.primary : Theme.safeInk }
    }

    let kind: Kind
    let route: RouteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title).font(.caption).fontWeight(.semibold)
            Text(Fmt.duration(route.durationS)).font(.title3).fontWeight(.bold)
            Text(Fmt.distance(route.distanceM)).font(.caption)
            Text("risk score \(Fmt.risk(route.riskScore))")
                .font(.caption2)
            Text("\(route.crashCount) crashes on route")
                .font(.caption2)
        }
        .foregroundStyle(kind.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(kind.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(kind.accent, lineWidth: 1.2))
    }
}
