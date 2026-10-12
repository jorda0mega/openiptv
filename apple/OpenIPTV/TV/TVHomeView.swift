#if os(tvOS)
import SwiftUI

/// Apple TV: Search, Home, Live TV and Settings in the top tab bar, like
/// Max, Prime Video and Paramount+. It hides as you move down a page and
/// comes back with Up or Menu, so it never covers a page's own controls
/// (tvOS 26's sidebar button sat on top of them). Live TV's shelves are a
/// row at the top of its page.
struct TVRootView: View {
    @Binding var playing: PlayerItem?
    @AppStorage("tvTab") private var selection = "home"
    @AppStorage("tvLiveTab") private var liveTab = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) {
                SearchView(playing: $playing)
            }
            Tab("Home", systemImage: "house", value: "home") {
                TVHomeView(playing: $playing)
            }
            Tab("Live TV", systemImage: "dot.radiowaves.left.and.right", value: "live") {
                TVLiveView(playing: $playing)
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                SettingsView()
            }
        }
        .onAppear {
            // A Live TV shelf chosen when each was its own tab in the sidebar.
            if !["search", "home", "live", "settings"].contains(selection) {
                liveTab = selection
                selection = "live"
            }
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
                    } else {
                        // No hero to sit under the tab bar: start below it.
                        Color.clear.frame(height: 110)
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
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
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
                    // Resting on Play: open it in the background, so Select
                    // starts it at once.
                    .task(id: focus == .play ? item.card.id : nil) {
                        guard focus == .play else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        model.warmUp(item.card.id, kind: item.card.kind, options: prefs.playerProfile.mpvOptions,
                                     hardwareDecoding: prefs.hardwareDecoding)
                    }
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
    @State private var loaded: (logo: String, image: UIImage)?
    @State private var failedLogo: String?

    var body: some View {
        // A logo already decoded (fetched with Home, or seen before) is
        // drawn at once: the hero's next title arrives complete.
        let image = logo.flatMap { logo in
            loaded?.logo == logo ? loaded?.image : URL(string: logo).flatMap(ImagePipeline.shared.cached)
        }
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 700, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .accessibilityLabel(title)
            } else if logo == nil || failedLogo == logo {
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
            guard let logo, let url = URL(string: logo), ImagePipeline.shared.cached(url) == nil else { return }
            if let image = try? await ImagePipeline.shared.image(for: url) { loaded = (logo, image) } else { failedLogo = logo }
        }
    }
}

// MARK: - Rows

/// Continue Watching: wide pictures with the title, episode and progress on
/// them. Select plays; press and hold for the show's page.
struct TVContinueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let row: HomeRow
    let loadingCard: String?
    let play: (Card) -> Void
    let open: (Card) -> Void
    @FocusState private var focused: String?

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
                                .tvArtwork()
                        }
                        .buttonStyle(.borderless)
                        .focused($focused, equals: card.id)
                        .contextMenu {
                            Button(card.kind == "Series" ? "Go to Show" : "Details", systemImage: "info.circle") { open(card) }
                        }
                        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .padding(.vertical, 24)
            }
            .tvRowScroll()
        }
        // Resting on a title: open it in the background (paused where it was
        // left), so Select starts it at once.
        .task(id: focused) {
            guard let id = focused, let card = row.cards.first(where: { $0.id == id }) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            model.warmUp(card.episodeId ?? card.id, kind: card.episodeId != nil ? "Episode" : card.kind,
                         options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        }
    }
}

/// A row of portrait posters (artwork only, like the TV app); select opens
/// the title.
struct TVPosterRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let cards: [Card]
    let select: (Card) -> Void
    @FocusState private var focused: String?

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
                                .tvArtwork()
                        }
                        .buttonStyle(.borderless)
                        .focused($focused, equals: card.id)
                        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .padding(.vertical, 24)
            }
            .tvRowScroll()
        }
        // Resting on a poster a moment: fetch its page and pictures, so
        // Select opens it complete (passing over posters fetches nothing).
        .task(id: focused) {
            guard let id = focused, let card = cards.first(where: { $0.id == id }) else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            model.prefetchTitle(card)
        }
    }
}

extension View {
    /// A row that scrolls sideways like the TV app's: the scroll view sits
    /// 90 pt in from each edge and draws past them, so moving along keeps
    /// the focused card that far from the screen's edge (room for its lift,
    /// the next one peeking in), rather than pressed against the edge while
    /// the row slides under it. (Content margins don't steer focus scrolling.)
    func tvRowScroll() -> some View {
        padding(.horizontal, 90)
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
    }

    /// Artwork in a borderless button, lifting under focus like the TV
    /// app's posters: the picture itself rises, tilts with the remote and
    /// catches the light, with no platter behind it.
    func tvArtwork(cornerRadius: CGFloat = 12) -> some View {
        clipShape(.rect(cornerRadius: cornerRadius))
            .hoverEffect(.highlight)
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
