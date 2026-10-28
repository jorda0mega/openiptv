import SwiftUI

@main
struct OpenIPTVApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()
    @State private var prefs = Preferences()

    init() {
        Telemetry.start()
        #if DEBUG
        TrackChoice.forgetForTesting()
        AppModel.forgetMyListOrderForTesting()
        AppModel.forgetWatchOnPicksForTesting()
        #endif
    }

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
    @Namespace private var filmCards
    @State private var playing: PlayerItem?
    /// The player on screen: `playing`, put up and taken away with no
    /// slide (the player fades itself in and out).
    @State private var shown: PlayerItem?
    #if os(iOS)
    @State private var tab = RootTab.home
    @State private var searchActivation = SearchView.activation(query: SearchView.launchQuery)
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
                        SearchView(playing: $playing, activation: $searchActivation).tint(nil)
                    }
                }
                // The chosen tab white (the bar at the bottom on iPhone, at
                // the top on iPad), as every other highlight in the app; the
                // system's blue looked out of place.
                .tint(.white)
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewSearchActivation(searchActivation)
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
                .grownFrom(item.card, in: filmCards)
        }
        .environment(\.filmCards, filmCards)
        .onChange(of: playing?.id) {
            if playing?.card != nil { shown = playing } else { RootView.quietly { shown = playing } }
        }
        .onChange(of: shown?.id) { if shown == nil, playing != nil { playing = nil } }
        .task { await model.loadLive() }
        #if DEBUG
        .task {
            guard UserDefaults.standard.bool(forKey: "debugPlayCopyFilm"), let film = await model.debugFilmHeardOnlyInAnotherCopy() else { return }
            playing = .film(model.planned(film, held: .backdrop))
        }
        .task {
            if UserDefaults.standard.bool(forKey: "debugServerProbe") { await model.debugProbeServer() }
        }
        // UI tests: when the last stop reached the page (see noteStop).
        .overlay(alignment: .topTrailing) {
            Text(model.debugStop)
                .font(.caption2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-stop")
        }
        .overlay(alignment: .topLeading) {
            Text(Bundle.main.object(forInfoDictionaryKey: "OpenreelBuild") as? String ?? "no stamp")
                .font(.caption2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-build")
        }
        .overlay(alignment: .bottomTrailing) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(model.aheadCounts)
                    .font(.caption2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("debug-ahead")
                Text(model.debugCopyFilm)
                    .font(.caption2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("debug-copy-film")
                Text(model.debugServer)
                    .font(.caption2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("debug-server")
            }
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
        .overlay(alignment: .topTrailing) {
            Text(PictureInPictureProbe.shared.gapText)
                .font(.caption2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-pip-gap")
        }
        #endif
        #if os(iOS)
        // Picture in Picture: back in the app's player when brought back,
        // and its progress kept on the server meanwhile.
        .task {
            let model = model
            PictureInPicture.shared.restore = { playing = .film(.backFromPictureInPicture($0)) }
            PictureInPicture.shared.report = { playback, seconds, event in
                Task { await model.report(playback, seconds: seconds, event: event) }
            }
        }
        #endif
        .task { await model.prepareLibrary() }
        // Pick up library changes whenever the app comes back.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.prepareLibrary(checkingChanges: true) }
            if !model.account.rows.isEmpty { Task { await model.refreshContinueWatching(returning: true) } }
            Task { await model.refreshMyList() }
            model.prepareRotation()
        }
    }
}
