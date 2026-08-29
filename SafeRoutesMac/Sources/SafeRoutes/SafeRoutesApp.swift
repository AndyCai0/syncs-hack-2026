import SwiftUI

@main
struct SafeRoutesApp: App {
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
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 430)
        } detail: {
            RouteMapView(model: model)
                .ignoresSafeArea(edges: .all)
        }
        .navigationTitle("SafeRoutes Sydney")
        .task {
            await model.loadDataIfNeeded()
        }
    }
}
