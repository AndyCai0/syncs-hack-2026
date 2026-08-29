import AppKit
import SwiftUI

@main
struct SafeRoutesApp: App {
    init() {
        // Ensure we behave as a regular foreground app even when launched
        // from a terminal / bare executable (keyboard focus, gestures).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        // Plain HStack instead of NavigationSplitView: the split view's
        // AppKit hosting crashes on this macOS beta when the Map invalidates
        // layout during the sidebar collapse animation.
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 350)
            Divider()
            RouteMapView(model: model)
                .ignoresSafeArea(edges: .all)
        }
        .navigationTitle("")
        .task {
            await model.loadDataIfNeeded()
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            // The Map sometimes ignores the initial camera region while the
            // window is still sizing itself; re-assert Sydney once settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.camera = .region(Sydney.overview)
            }
        }
    }
}
