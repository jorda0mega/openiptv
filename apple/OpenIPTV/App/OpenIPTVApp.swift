import SwiftUI

@main
struct OpenIPTVApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                // openiptv://pair?link=<the link the server prints>
                .onOpenURL { url in
                    guard url.scheme == "openiptv",
                          let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                              .queryItems?.first(where: { $0.name == "link" })?.value,
                          let server = Server(link: link)
                    else { return }
                    Task { await model.connect(to: server) }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var playback: PlaybackRequest?

    var body: some View {
        Group {
            if model.server == nil {
                ConnectView()
            } else {
                TabView {
                    Tab("Home", systemImage: "house.fill") {
                        HomeView()
                    }
                    Tab("Live TV", systemImage: "dot.radiowaves.left.and.right") {
                        LiveView(playback: $playback)
                    }
                    Tab(role: .search) {
                        SearchView(playback: $playback)
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            }
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(channels: request.channels, index: request.index)
        }
        .task { await model.refreshStatus() }
    }
}
