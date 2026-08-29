import CoreLocation
import MapKit
import SwiftUI

struct RouteMapView: View {
    @Bindable var model: AppModel

    var body: some View {
        MapReader { proxy in
            Map(position: $model.camera, interactionModes: .all) {
                zoneContent
                schoolContent
                crashContent
                routeContent
                endpointContent
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                model.cameraChanged(to: context.region)
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    if let coordinate = proxy.convert(value.location, from: .local) {
                        model.selectCrash(near: coordinate)
                    }
                }
            )
        }
        .overlay(alignment: .topTrailing) { overlays }
        .overlay(alignment: .bottomLeading) { mapLegend }
    }

    // MARK: - Map content

    @MapContentBuilder
    private var zoneContent: some MapContent {
        ForEach(model.renderedZones) { zone in
            MapPolygon(coordinates: zone.ring)
                .foregroundStyle(Theme.zone.opacity(0.10))
                .stroke(Theme.zone.opacity(0.45), lineWidth: 1)
        }
    }

    @MapContentBuilder
    private var schoolContent: some MapContent {
        ForEach(model.renderedSchools) { school in
            Annotation(school.name, coordinate: school.coordinate) {
                Circle()
                    .fill(Theme.school)
                    .overlay(Circle().stroke(.white, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
        }
        .annotationTitles(.hidden)
    }

    @MapContentBuilder
    private var crashContent: some MapContent {
        ForEach(model.renderedCrashes) { crash in
            Annotation(crash.headline, coordinate: crash.coordinate) {
                CrashDot(severity: crash.severity,
                         selected: model.selectedCrash?.id == crash.id)
            }
        }
        .annotationTitles(.hidden)
    }

    @MapContentBuilder
    private var routeContent: some MapContent {
        if let routes = model.routes,
           routes.fastest.coordinates.count >= 2, routes.lowerHazard.coordinates.count >= 2 {
            // Fastest: wide neutral casing so it reads as the "under" line.
            MapPolyline(coordinates: routes.fastest.coordinates)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: routes.fastest.coordinates)
                .stroke(Theme.fast, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            // Lower-hazard alternative: narrower green line drawn on top.
            MapPolyline(coordinates: routes.lowerHazard.coordinates)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: routes.lowerHazard.coordinates)
                .stroke(Theme.safe, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }

    @MapContentBuilder
    private var endpointContent: some MapContent {
        if let from = model.fromPlace {
            Marker("Start", systemImage: "figure.walk", coordinate: from.coordinate)
                .tint(Theme.safe)
        }
        if let to = model.toPlace {
            Marker("Destination", systemImage: "flag.fill", coordinate: to.coordinate)
                .tint(Theme.danger)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.isLoadingData {
                Label("Loading crash data…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let note = model.layers.note {
                Text(note)
                    .font(.caption2)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let crash = model.selectedCrash {
                CrashCallout(crash: crash) { model.selectedCrash = nil }
            }
        }
        .padding(12)
    }

    private var mapLegend: some View {
        HStack(spacing: 12) {
            legendDot(Theme.fatal, "Fatal")
            legendDot(Theme.serious, "Serious")
            legendDot(Theme.minor, "Other")
            legendDot(Theme.school, "School")
        }
        .font(.system(size: 10))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(12)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}

struct CrashDot: View {
    let severity: CrashSeverity
    let selected: Bool

    private var color: Color {
        switch severity {
        case .fatal: Theme.fatal
        case .serious: Theme.serious
        case .other: Theme.minor
        }
    }

    private var size: CGFloat {
        severity == .fatal ? 12 : 8
    }

    var body: some View {
        Circle()
            .fill(color.opacity(0.85))
            .overlay(Circle().stroke(selected ? Color.black : Color.white,
                                     lineWidth: selected ? 2 : 1))
            .frame(width: size, height: size)
    }
}

struct CrashCallout: View {
    let crash: CrashPoint
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Text(crash.headline).font(.caption).fontWeight(.semibold)
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(crash.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}
