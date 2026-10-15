import SwiftUI

@main
struct OpenIPTVApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()
    @State private var prefs = Preferences()

    #if DEBUG
    init() {
        TrackChoice.forgetForTesting()
        AppModel.forgetMyListOrderForTesting()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(prefs)
                .preferredColorScheme(.dark)
        }
    }
}

enum RootTab: Hashable { case home, live, search }

struct RootView: View {
    /// A change made with no animation at all (the player's cover).
    static func quietly(_ change: () -> Void) {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet, change)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: PlayerItem?
    /// The player on screen: `playing`, put up and taken away with no
    /// slide (the player fades itself in and out).
    @State private var shown: PlayerItem?
    #if os(iOS)
    @State private var tab = RootTab.home
    #endif

    var body: some View {
        Group {
            if model.sources.isEmpty {
                WelcomeView()
            } else {
                #if os(tvOS)
                // Laid out like Apple's TV app: a sidebar over full-screen pages.
                TVRootView(playing: $playing)
                #else
                TabView(selection: $tab) {
                    // The pages keep the usual tint (see below).
                    Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                        HomeView(playing: $playing).tint(nil)
                    }
                    Tab("Live TV", systemImage: "dot.radiowaves.left.and.right", value: RootTab.live) {
                        LiveView(playing: $playing).tint(nil)
                    }
                    Tab(value: RootTab.search, role: .search) {
                        SearchView(playing: $playing).tint(nil)
                    }
                }
                // The chosen tab white (the bar at the bottom on iPhone, at
                // the top on iPad), as every other highlight in the app; the
                // system's blue looked out of place.
                .tint(.white)
                .tabBarMinimizeBehavior(.onScrollDown)
                // "Go to Show" in the player: Home opens the show's page,
                // unless that page is already under the player.
                .onChange(of: model.showRequest) { _, request in
                    if let request, model.showOnScreen != request.id { tab = .home }
                }
                .onChange(of: model.movieRequest) { _, request in
                    if let request, model.movieOnScreen != request.id { tab = .home }
                }
                #endif
            }
        }
        .fullScreenCover(item: $shown) { item in
            PlayerScreen(item: item) { RootView.quietly { shown = nil } }
        }
        .onChange(of: playing?.id) { RootView.quietly { shown = playing } }
        .onChange(of: shown?.id) { if shown == nil, playing != nil { playing = nil } }
        .task { await model.loadLive() }
        #if DEBUG
        // UI tests: when the last stop reached the page (see noteStop).
        .overlay(alignment: .topTrailing) {
            Text(model.debugStop)
                .font(.caption2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-stop")
        }
        #endif
        #if DEBUG && os(iOS)
        // UI tests: what Picture in Picture is doing.
        .overlay(alignment: .topLeading) {
            Text(PictureInPictureProbe.shared.text)
                .font(.caption2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-pip")
        }
        #endif
        #if os(iOS)
        // Picture in Picture: back in the app's player when brought back,
        // and its progress kept on the server meanwhile.
        .task {
            let model = model
            PictureInPicture.shared.restore = { playing = .vod($0) }
            PictureInPicture.shared.report = { playback, seconds, event in
                Task { await model.report(playback, seconds: seconds, event: event) }
            }
        }
        #endif
        .task { await model.prepareLibrary() }
        // Pick up library changes whenever the app comes back.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.connectLive()
                Task { await model.prepareLibrary() }
                // Watched or put on My List on another device while away
                // (the live connection was closed): both right when you look.
                if !model.rows.isEmpty { Task { await model.refreshContinueWatching(returning: true) } }
                Task { await model.refreshMyList() }
                // What's usually watched, ready before it's chosen.
                model.prepareRotation()
            case .background:
                model.disconnectLive()
            default:
                break
            }
        }
    }
}
