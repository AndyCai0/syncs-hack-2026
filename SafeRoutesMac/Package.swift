// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SafeRoutesMac",
    platforms: [.macOS(.v14)],
    targets: [
        // Routing engine: binary graph loading + risk-weighted Dijkstra. No UI imports.
        .target(name: "SafeRoutesEngine"),
        // SwiftUI app shell (MapKit UI). Depends only on the engine's public API.
        .executableTarget(
            name: "SafeRoutes",
            dependencies: ["SafeRoutesEngine"]
        ),
        .testTarget(
            name: "SafeRoutesEngineTests",
            dependencies: ["SafeRoutesEngine"]
        ),
    ]
)
