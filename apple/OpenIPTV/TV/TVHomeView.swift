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
                    // The first hero fades in over its placeholder.
                    ZStack(alignment: .top) {
                        if !heroes.isEmpty {
                            TVHero(items: heroes, play: { play($0) }, open: { open($0) })
                                .transition(.opacity)
                        } else if model.homePending {
                            // The first Home is on its way: the hero's space is
                            // kept, so the rows don't move down when it comes.
                            Color.clear.frame(height: TVHero.height).overlay { ProgressView() }
                                .transition(.opacity)
                        } else {
                            // No hero to sit under the tab bar: start below it.
                            Color.clear.frame(height: 110)
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: heroes.isEmpty)
                    let rows = model.rows.filter { !prefs.hiddenRows.contains($0.title) }
                    if !rows.contains(where: { $0.title == "Continue Watching" }) { myListRow }
                    ForEach(rows) { row in
                        if row.title == "Continue Watching" {
                            TVContinueRow(row: row, loadingCard: loadingCard, play: { play($0) }, open: { open($0) })
                            myListRow
                        } else {
                            TVPosterRow(title: row.title, cards: row.cards, captions: .focused) { open($0) }
                        }
                    }
                    if model.rows.isEmpty, model.featured == nil, !model.homePending {
                        emptyState.frame(maxWidth: .infinity).padding(.top, 200)
                    }
                }
                .padding(.bottom, 80)
            }
            // Edge to edge, on black, like the TV app.
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .scrollClipDisabled()
            .navigationDestination(for: ShowRoute.self) { TVShowView(route: $0, playing: $playing) }
            .navigationDestination(for: MovieRoute.self) { TVMovieView(route: $0, playing: $playing) }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
        // On the stack, not its first page: coming back from a title's page
        // isn't Home appearing. Home chosen in the tab bar (or at launch)
        // is: what was built meanwhile goes on before it's drawn, then the
        // next one is built in the background, to wait for the next time.
        .onAppear { model.homeAppeared() }
        .task { await model.loadHome(cardWidth: 480) }
        .task { await model.loadMyList(cardWidth: 480) }
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
    /// My List, as in the TV app: what you put there with "+", newest first.
    @ViewBuilder private var myListRow: some View {
        if !model.myList.isEmpty {
            TVPosterRow(title: "My List", cards: model.myList, captions: .focused) { open($0) }
        }
    }

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
    /// The last title, under the next one while that fades in.
    @State private var behind: Int?
    @FocusState private var focus: Control?

    enum Control: Hashable { case play, info }

    /// The Apple TV app's: tall enough to feel like a film, short enough
    /// that the next row shows under it (it was 900, which hid it).
    static let height: CGFloat = 780

    var body: some View {
        let item = items[min(index, items.count - 1)]
        ZStack(alignment: .bottomLeading) {
            // The next picture fades in over the last, which stays at full
            // brightness under it until it's covered (both fading at once
            // dimmed the hero by a tenth halfway, every turn).
            // Every title's picture stays drawn (decoded once, never black
            // again); only the shown one and, while it fades in over it, the
            // last one are visible.
            // In their own stack: their order is among themselves, all under
            // the text (ordered with it, the shown picture covered the title,
            // story and buttons).
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.card.id) { i, entry in
                    TVBackdrop(url: entry.backdrop, title: entry.card.title)
                        .opacity(i == min(index, items.count - 1) || i == behind ? 1 : 0)
                        .zIndex(i == min(index, items.count - 1) ? 2 : i == behind ? 1 : 0)
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                // The same space for every title (logo or name, long story
                // or none), so the hero's text doesn't jump as it turns.
                TVTitleArt(logo: item.logo, title: item.card.title, maxHeight: 190)
                    .frame(minHeight: 190, alignment: .bottomLeading)
                Text(item.details).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                Text(item.overview ?? "").font(.callout).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: 820, alignment: .leading)
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
                // The buttons' row reaches across the screen: Down from any
                // tab lands in it, on Play, as in the TV app (it went straight
                // past the hero into Continue Watching).
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .defaultFocus($focus, .play)
                .onChange(of: focus) { before, now in
                    if before == nil, now == .info { focus = .play }
                }
            }
            .padding(.leading, 90)
            .padding(.bottom, 70)
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // Moves on by itself every nine seconds, but not while you're on
        // its buttons: Play plays the title you're looking at.
        .task(id: "\(turn)|\(focus == nil)") {
            guard focus == nil else { return }
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, items.count > 1, focus == nil else { return }
            advance(by: 1)
        }
        // Other titles (Home changed at a moment): from the first, with
        // focus staying on the same button.
        .onChange(of: items.map(\.card.id)) { old, new in
            #if DEBUG
            NSLog("%@", "PERF hero items changed \(old.count) -> \(new.count) first \(old.first == new.first)")
            #endif
            index = 0
        }
    }

    /// The next title, once its picture is decoded: drawn in the first
    /// frame of the cross-fade (an undecoded one faded in as black first,
    /// and the hero dimmed halfway).
    private func advance(by step: Int) {
        guard items.count > 1 else { return }
        let next = (index + step + items.count) % items.count
        Task {
            if let url = URL(string: items[next].backdrop), ImagePipeline.shared.cached(url) == nil {
                _ = try? await ImagePipeline.shared.image(for: url)
            }
            let last = index
            #if DEBUG
            NSLog("%@", "PERF hero turn \(last) -> \(next)")
            #endif
            behind = last
            withAnimation(.easeInOut(duration: 0.5)) { index = next }
            turn += 1
            try? await Task.sleep(for: .milliseconds(650))
            if behind == last { behind = nil }
        }
    }
}

/// A backdrop filling its space, darkened at the bottom and left so text
/// reads over it, fading into the page below.
struct TVBackdrop: View {
    let url: String?
    let title: String

    var body: some View {
        // Clear under the picture: a hero picture fading in over the last
        // one shows that one, not black, until it's drawn.
        Color.clear
            .overlay {
                if let url {
                    CoverImage(images: [CardImage(url: url, contain: false)], title: title, backdrop: true)
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
                                    // The subtitle's line and the progress bar's
                                    // place always kept, so the title doesn't
                                    // rise when progress comes.
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(card.title).font(.headline).lineLimit(1)
                                        Text(card.subtitle ?? " ").font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                        ProgressBar(value: (card.progress ?? 0) / 100).padding(.top, 6)
                                            .opacity((card.progress ?? 0) > 0 ? 1 : 0)
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
                        .accessibilityIdentifier("continue-\(card.id)")
                    }
                }
                .padding(.vertical, 24)
            }
            .tvRowScroll()
        }
        // Up and Down reach the row from anywhere across the screen (they
        // skipped it when no card was straight above or below).
        .focusSection()
        // Resting on a title: open it in the background (paused where it was
        // left), so Select starts it at once.
        .task(id: focused) {
            guard let id = focused, let card = row.cards.first(where: { $0.id == id }) else { return }
            // Browsing: a Home built from now on waits for the next moment.
            model.homeBrowsed()
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
    /// The title and year under the posters, in room kept for them (nothing
    /// moves when they show): under every poster (Search, a person's page:
    /// several editions of one name tell apart), or under the focused one
    /// only (Home, More Like This), as in the TV app.
    enum Captions { case none, always, focused }
    var captions: Captions = .none
    let select: (Card) -> Void
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle(title)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 36) {
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: 14) {
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
                            if captions != .none {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                                    Text(card.subtitle ?? " ").font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 240, height: 64, alignment: .topLeading)
                                // Lifted with the focused poster, brighter.
                                .opacity(focused == card.id ? 1 : captions == .always ? 0.7 : 0)
                                .offset(y: focused == card.id ? 14 : 0)
                                .animation(.easeOut(duration: 0.2), value: focused == card.id)
                                .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .tvRowScroll()
        }
        // Up and Down reach the row from anywhere across the screen (they
        // went nowhere when no poster was straight above or below).
        .focusSection()
        // Resting on a poster a moment: fetch its page (and pictures), so
        // Select opens it complete; then the next one along, where focus
        // usually goes. Sweeping across posters fetches nothing.
        .task(id: focused) {
            guard let id = focused, let index = cards.firstIndex(where: { $0.id == id }) else { return }
            model.homeBrowsed()
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            model.prefetchTitle(cards[index])
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, index + 1 < cards.count else { return }
            model.prefetchTitle(cards[index + 1])
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
