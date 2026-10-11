#if os(tvOS)
import SwiftUI

/// Apple TV: laid out like Apple's TV app. A sidebar (Search, Home, Live
/// TV by shelf, Settings) over full-screen pages.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @AppStorage("tvTab") private var selection = "home"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) {
                SearchView(playing: $playing)
            }
            Tab("Home", systemImage: "house", value: "home") {
                TVHomeView(playing: $playing)
            }
            TabSection("Live TV") {
                ForEach(liveTabs, id: \.id) { tab in
                    Tab(tab.title, systemImage: tab.icon, value: tab.id) {
                        TVLiveView(id: tab.id, playing: $playing)
                    }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// Favourites, the shelves with Local after Sports, and the provider's
    /// own categories last.
    private var liveTabs: [(id: String, title: String, icon: String)] {
        var tabs: [(id: String, title: String, icon: String)] = []
        if !prefs.favorites.isEmpty { tabs.append((AppModel.favoritesID, "Favourites", "star")) }
        for shelf in model.liveLibrary.shelves {
            tabs.append((shelf.id, shelf.title, Self.icon(shelf.id)))
            if shelf.id == LiveOrganizer.sportsID { tabs.append((AppModel.localID, "Local", "antenna.radiowaves.left.and.right")) }
        }
        if !model.liveLibrary.shelves.contains(where: { $0.id == LiveOrganizer.sportsID }), !model.sources.iptv.isEmpty {
            tabs.insert((AppModel.localID, "Local", "antenna.radiowaves.left.and.right"), at: tabs.isEmpty ? 0 : min(1, tabs.count))
        }
        if !model.categories.isEmpty { tabs.append((TVLiveView.categoriesID, "All Categories", "list.bullet")) }
        return tabs
    }

    private static func icon(_ shelf: String) -> String {
        switch shelf {
        case LiveOrganizer.sportsID: "sportscourt"
        case "shelf:news": "newspaper"
        case "shelf:entertainment": "tv"
        case "shelf:movies": "film"
        case "shelf:kids": "figure.and.child.holdinghands"
        case "shelf:nonstop": "infinity"
        case "shelf:music": "music.note"
        case "shelf:radio": "radio"
        case LiveOrganizer.internationalID: "globe"
        default: "ellipsis.circle"
        }
    }
}

/// Home, like the TV app's: a full-screen hero that moves through the
/// featured titles (title logo, what it is, Play and More Info; swipe right
/// on More Info for the next), Continue Watching as wide cards with the
/// progress on the picture, then rows of posters. Posters open the title's
/// page; Continue Watching plays.
struct TVHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @State private var path = NavigationPath()
    @State private var loadingCard: String?
    @State private var playError: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 56) {
                    let heroes = model.spotlight.isEmpty ? (model.featured.map { [$0] } ?? []) : model.spotlight
                    if !heroes.isEmpty {
                        TVHero(items: heroes, play: { play($0) }, open: { open($0) })
                    }
                    ForEach(model.rows.filter { !prefs.hiddenRows.contains($0.title) }) { row in
                        if row.title == "Continue Watching" {
                            TVContinueRow(row: row, loadingCard: loadingCard, play: { play($0) }, open: { open($0) })
                        } else {
                            TVPosterRow(title: row.title, cards: row.cards) { open($0) }
                        }
                    }
                    if model.rows.isEmpty, model.featured == nil {
                        emptyState.frame(maxWidth: .infinity).padding(.top, 200)
                    }
                }
                .padding(.bottom, 80)
            }
            // Edge to edge, on black, like the TV app.
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .scrollClipDisabled()
            .task { await model.loadHome(cardWidth: 480) }
            .navigationDestination(for: ShowRoute.self) { TVShowView(route: $0, playing: $playing) }
            .navigationDestination(for: MovieRoute.self) { TVMovieView(route: $0, playing: $playing) }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.sources.emby == nil {
            ContentUnavailableView("No Emby server", systemImage: "film.stack",
                                   description: Text("Add your Emby server in Settings to see your movies and shows here."))
        } else if let error = model.homeError {
            ContentUnavailableView("Couldn't load Emby", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView()
        }
    }

    /// A title's page.
    private func open(_ card: Card) {
        if card.kind == "Series" {
            path.append(ShowRoute(id: card.id, title: card.title, episodeId: card.episodeId))
        } else {
            path.append(MovieRoute(id: card.id, title: card.title))
        }
    }

    /// Straight to the player: the episode being resumed, or the title.
    private func play(_ card: Card) {
        guard loadingCard == nil else { return }
        loadingCard = card.id
        Task {
            defer { loadingCard = nil }
            do {
                if let episode = card.episodeId {
                    playing = .vod(try await model.playback(itemId: episode, kind: "Episode"))
                } else {
                    playing = .vod(try await model.playback(itemId: card.id, kind: card.kind == "Series" ? "Series" : card.kind))
                }
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

// MARK: - Hero

/// The full-screen top of Home: one title at a time, moving on every few
/// seconds; swiping right on More Info shows the next.
struct TVHero: View {
    let items: [Featured]
    let play: (Card) -> Void
    let open: (Card) -> Void
    @State private var index = 0
    @State private var turn = 0
    @FocusState private var focus: Control?

    enum Control: Hashable { case play, info }

    var body: some View {
        let item = items[min(index, items.count - 1)]
        ZStack(alignment: .bottomLeading) {
            TVBackdrop(url: item.backdrop, title: item.card.title)
                .id(item.backdrop)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 18) {
                TVTitleArt(logo: item.logo, title: item.card.title, maxHeight: 190)
                Text(item.details).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
                        .frame(maxWidth: 820, alignment: .leading)
                }
                HStack(spacing: 24) {
                    Button { play(item.card) } label: {
                        Label(item.card.kind == "Series" ? "Play" : "Play", systemImage: "play.fill")
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    .focused($focus, equals: .play)
                    Button { open(item.card) } label: {
                        Label("More Info", systemImage: "info.circle")
                    }
                    .buttonStyle(.glass)
                    .focused($focus, equals: .info)
                    .onMoveCommand { direction in
                        if direction == .right { advance(by: 1) }
                    }
                    if items.count > 1 {
                        HStack(spacing: 10) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule()
                                    .fill(.white.opacity(i == index ? 0.95 : 0.35))
                                    .frame(width: i == index ? 28 : 10, height: 10)
                            }
                        }
                        .padding(.leading, 20)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.top, 6)
                .tint(.white)
            }
            .padding(.leading, 90)
            .padding(.bottom, 70)
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .frame(height: 900)
        .frame(maxWidth: .infinity)
        // Moves on by itself every nine seconds.
        .task(id: turn) {
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, items.count > 1 else { return }
            advance(by: 1)
        }
    }

    private func advance(by step: Int) {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            index = (index + step + items.count) % items.count
        }
        turn += 1
    }
}

/// A backdrop filling its space, darkened at the bottom and left so text
/// reads over it, fading into the page below.
struct TVBackdrop: View {
    let url: String?
    let title: String

    var body: some View {
        Color.black
            .overlay {
                if let url {
                    CoverImage(images: [CardImage(url: url, contain: false)], title: title)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.75), location: 0.8),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// The title's logo when the server has one, else its name in large type.
struct TVTitleArt: View {
    let logo: String?
    let title: String
    var maxHeight: CGFloat = 170
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 700, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .accessibilityLabel(title)
            } else if logo == nil || failed {
                Text(title)
                    .font(.system(size: 68, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            } else {
                Color.clear.frame(width: 600, height: maxHeight)
            }
        }
        .task(id: logo) {
            image = nil
            failed = false
            guard let logo, let url = URL(string: logo) else { return }
            if let loaded = try? await ImagePipeline.shared.image(for: url) { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Rows

/// Continue Watching: wide pictures with the title, episode and progress on
/// them. Select plays; press and hold for the show's page.
struct TVContinueRow: View {
    let row: HomeRow
    let loadingCard: String?
    let play: (Card) -> Void
    let open: (Card) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle(row.title)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) {
                    ForEach(row.cards) { card in
                        Button { play(card) } label: {
                            CoverImage(images: card.images, title: card.title)
                                .frame(width: 520, height: 292)
                                .overlay {
                                    LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 1)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(card.title).font(.headline).lineLimit(1)
                                        if let subtitle = card.subtitle {
                                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                        }
                                        if let progress = card.progress, progress > 0 {
                                            ProgressBar(value: progress / 100).padding(.top, 6)
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .padding(20)
                                }
                                .overlay {
                                    if loadingCard == card.id { ProgressView() }
                                }
                        }
                        .buttonStyle(.card)
                        .contextMenu {
                            Button(card.kind == "Series" ? "Go to Show" : "Details", systemImage: "info.circle") { open(card) }
                        }
                        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}

/// A row of portrait posters (artwork only, like the TV app); select opens
/// the title.
struct TVPosterRow: View {
    let title: String
    let cards: [Card]
    let select: (Card) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle(title)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 36) {
                    ForEach(cards) { card in
                        Button { select(card) } label: {
                            CoverImage(images: card.images, title: card.title)
                                .frame(width: 240, height: 360)
                                .overlay(alignment: .bottom) {
                                    if let progress = card.progress, progress > 0 {
                                        ProgressBar(value: progress / 100).padding(12)
                                    }
                                }
                        }
                        .buttonStyle(.card)
                        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}

struct TVRowTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.leading, 90)
            .accessibilityAddTraits(.isHeader)
    }
}

#endif
