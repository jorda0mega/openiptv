import SwiftUI

@main
struct OpenIPTVApp: App {
    @State private var model = AppModel()
    @State private var prefs = Preferences()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(prefs)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var playing: PlayerItem?

    var body: some View {
        Group {
            if model.sources.isEmpty {
                WelcomeView()
            } else {
                TabView {
                    Tab("Home", systemImage: "house.fill") {
                        HomeView(playing: $playing)
                    }
                    Tab("Live TV", systemImage: "dot.radiowaves.left.and.right") {
                        LiveView(playing: $playing)
                    }
                    Tab("Settings", systemImage: "gearshape") {
                        SettingsView()
                    }
                    Tab(role: .search) {
                        SearchView(playing: $playing)
                    }
                }
                #if os(iOS)
                .tabBarMinimizeBehavior(.onScrollDown)
                #endif
            }
        }
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(item: item)
        }
        .task { await model.loadLive() }
    }
}
