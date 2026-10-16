import SwiftUI

/// One search for everything. Movies, shows and channels come from indexes
/// on the device and update on every keystroke, with completions on top;
/// episodes (and anything newer than the index) follow from the Emby server
/// a moment later. "On TV" finds what's on now or later today and tomorrow
/// by its name (the guide, and games in Sports), wherever it's showing.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    @Binding var playing: PlayerItem?

    /// Debug builds: `-debugSearch "text"` at launch starts with a search.
    @State private var query: String = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "debugSearch") ?? ""
        #else
        ""
        #endif
    }()
    @State private var scope: Scope = .all
    @State private var path = NavigationPath()

    /// What the results show: everything, or one kind. Episodes come under
    /// Shows (an episode is part of a show).
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", shows = "Shows", live = "Live TV"
        var id: Self { self }
    }
    #if os(iOS)
    @FocusState private var fieldFocused: Bool
    @Namespace private var scopeUnderline
    #endif
    /// The device's own title matches, in their order: what the server
    /// adds later goes after them, never between.
    @State private var library: [Card] = []
    /// Titles the server's part added (cast matches, people's titles), and
    /// the text they were found for.
    @State private var extras: [Card] = []
    @State private var extrasQuery = ""
    @State private var channels: [LiveChannel] = []
    @State private var onTV: [AppModel.GuideHit] = []
    @State private var completions: [String] = []
    @State private var serverCards: [Card] = []
    @State private var serverQuery = ""
    /// The text the results on screen are for.
    @State private var shownQuery = ""
    /// Filters a finished search found nothing for: their "no results"
    /// stays while the next letter's search runs, until results come,
    /// rather than blinking off and on at each letter.
    @State private var finishedEmpty: Set<Scope> = []
    @State private var libraryMatch: SearchCorpus<LibraryEntry>.Match?
    @State private var channelMatch: SearchCorpus<LiveChannel>.Match?
    @State private var loadingCard: String?
    @State private var playError: String?

    private var thumbWidth: Int { Int(Layout.searchThumbWide * displayScale) }

    /// Titles and episodes for what's typed, worked out once when results
    /// arrive, not on every redraw (a filter tap redraws the page).
    private struct Titles {
        var all: [Card] = []
        var movies: [Card] = []
        var shows: [Card] = []
        var episodes: [Card] = []
    }
    @State private var titles = Titles()

    private var episodes: [Card] { titles.episodes }
    private var moviesAndShows: [Card] { titles.all }
    private var movies: [Card] { titles.movies }
    private var shows: [Card] { titles.shows }

    /// The library's matches, then what the server added that isn't
    /// another copy of one already listed (HD and 4K are one title): after
    /// them, never between, so nothing listed moves when the server
    /// answers. The server's cards from an earlier letter stay while they
    /// still fit what's typed now (no flicker while the next request is in
    /// flight).
    private func publishTitles() {
        let server = fitting(serverCards, foundFor: serverQuery)
        var seen = Set(library.flatMap { model.library.versions(of: $0.id) })
        let added = (fitting(extras, foundFor: extrasQuery) + server.filter { $0.kind != "Episode" }).filter { card in
            guard !seen.contains(card.id) else { return false }
            seen.formUnion(model.library.versions(of: card.id))
            return true
        }
        let all = library + added
        titles = Titles(all: all, movies: all.filter { $0.kind != "Series" }, shows: all.filter { $0.kind == "Series" },
                        episodes: server.filter { $0.kind == "Episode" })
        resultsChanged()
    }

    /// Cards the server found for `text`: all of them for what's typed
    /// now, else those that still fit it.
    private func fitting(_ cards: [Card], foundFor text: String) -> [Card] {
        guard !cards.isEmpty, text != query else { return cards }
        let corpus = SearchCorpus(cards) { "\($0.title) \($0.subtitle ?? "")" }
        return corpus.search(query).ranked.sorted().map { corpus.items[$0] }
    }

    /// Whether a filter has anything for what's typed (empty ones are dimmed).
    private func hasResults(_ scope: Scope) -> Bool {
        scope == .all || !isEmpty(scope)
    }

    private func isEmpty(_ scope: Scope) -> Bool {
        switch scope {
        case .all: moviesAndShows.isEmpty && episodes.isEmpty && channels.isEmpty && onTV.isEmpty
        case .movies: movies.isEmpty
        case .shows: shows.isEmpty && episodes.isEmpty
        case .live: channels.isEmpty && onTV.isEmpty
        }
    }

    /// Results came: a filter that has some again loses its "no results".
    private func resultsChanged() {
        let still = finishedEmpty.filter(isEmpty)
        if still != finishedEmpty { finishedEmpty = still }
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    #if os(iOS)
    private var phoneBody: some View {
        NavigationStack(path: $path) {
            List {
                // Cleared: nothing under "Search everything", not the last
                // results for a moment.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    results
                }
                if let progress = model.library.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.loaded), total: Double(max(progress.total, 1)))
                        Text("Loading your library: \(progress.loaded.formatted()) of \(progress.total.formatted()) titles. Search covers what's loaded so far.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            // The name pages opened from here go back to.
            .navigationTitle("Search")
            // A header of our own instead of the navigation bar's (on this
            // page only: a title's page keeps its bar): a large title that
            // collapses and is pulled down with the list moved under the
            // eyes; this one stays put while the results scroll or bounce.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationDestination(for: ShowRoute.self) { ShowView(route: $0, playing: $playing) }
            .navigationDestination(for: MovieRoute.self) { MovieView(route: $0, playing: $playing) }
            #if os(iOS)
            .navigationDestination(for: GenreRoute.self) { GenreView(route: $0) }
            // The system's search field, in the tab bar at the bottom, as in
            // the Apple TV app (Home, the field, close), instead of a field
            // of our own over the whole tab bar (two bars). Scrolling the
            // results or the keyboard's Search key puts the keyboard away.
            .searchable(text: $query, prompt: "Movies, shows, people, what's on TV")
            .searchFocused($fieldFocused)
            .onSubmit(of: .search) { fieldFocused = false }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollDismissesKeyboard(.immediately)
            .onAppear { if query.isEmpty { fieldFocused = true } }
            #endif
            // Re-run when the text changes or an index finishes loading.
            .task(id: "\(query)|\(model.library.count)|\(model.channelCorpus.items.count)") { await search() }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
    }

    /// Titles, then what's on and channels, then episodes: the parts that
    /// come later (the server's) go below, so what's listed never moves
    /// down when they arrive.
    @ViewBuilder private var results: some View {
        if scope == .all, !completions.isEmpty {
            // One row of suggestions, the same height however many there
            // are, so the results under it don't move as they change.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(completions, id: \.self) { completion in
                        Button { query = completion } label: {
                            Label(completion, systemImage: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color(white: 0.15), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .frame(height: 44)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
        // One section whatever the filter, so a title shown before
        // and after a filter tap keeps its row instead of a new one.
        let shown = scope == .movies ? movies : scope == .shows ? shows : scope == .all ? moviesAndShows : []
        if !shown.isEmpty {
            Section(scope == .movies ? "Movies" : scope == .shows ? "Shows" : "Movies & Shows") {
                ForEach(shown) { card in result(card, wide: false) }
            }
        }
        if scope == .all || scope == .live, !onTV.isEmpty {
            Section("On TV") {
                let tuned = onTV.map(\.channel)
                ForEach(Array(onTV.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        playing = .live(tuned, index)
                    } label: {
                        GuideHitRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if scope == .all || scope == .live, !channels.isEmpty {
            Section("Channels") {
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playing = .live(channels, index)
                    } label: {
                        ChannelRow(channel: channel, slot: model.slot(channel.id), favorite: prefs.isFavorite(channel))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(prefs.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites",
                               systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                            prefs.toggleFavorite(channel)
                        }
                    }
                    .onAppear { model.appeared(channel.id) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
        }
        if scope == .all || scope == .shows, !episodes.isEmpty {
            Section("Episodes") {
                ForEach(episodes) { card in result(card, wide: true) }
            }
        }
    }
    #endif

    #if os(tvOS)
    /// Apple TV, like Apple's TV app: the system search field and keyboard
    /// row under the tab bar, then the results as rows of cards: titles,
    /// what's on, channels, episodes. Titles open their page; episodes,
    /// programmes and channels play.
    private var tvBody: some View {
        NavigationStack(path: $path) {
            tvResults
                .searchable(text: $query, prompt: "Movies, shows, channels, what's on")
                .autocorrectionDisabled()
                .navigationDestination(for: ShowRoute.self) { TVShowView(route: $0, playing: $playing) }
                .navigationDestination(for: MovieRoute.self) { TVMovieView(route: $0, playing: $playing) }
        }
        .task(id: "\(query)|\(model.library.count)|\(model.channelCorpus.items.count)") { await search() }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    private var tvResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                // Titles, then what's on and channels, then episodes: the
                // parts that come later (the server's) go below, so a row
                // never moves down when they arrive.
                if !moviesAndShows.isEmpty {
                    TVPosterRow(title: "Movies & Shows", cards: moviesAndShows, captions: .always) { openDetails($0) }
                }
                if !onTV.isEmpty {
                    TVShelf(title: "On TV") {
                        let tuned = onTV.map(\.channel)
                        ForEach(Array(onTV.enumerated()), id: \.element.id) { index, hit in
                            Button { playing = .live(tuned, index) } label: {
                                GuideHitRow(hit: hit)
                                    .padding(.horizontal, 24)
                                    .frame(width: 640, height: 150, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                if !channels.isEmpty {
                    TVShelf(title: "Channels") {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            Button { playing = .live(channels, index) } label: {
                                ChannelRow(channel: channel, slot: model.slot(channel.id), favorite: prefs.isFavorite(channel))
                                    .padding(.horizontal, 24)
                                    .frame(width: 640, height: 150, alignment: .leading)
                            }
                            .buttonStyle(.card)
                            .onAppear { model.appeared(channel.id) }
                            .onDisappear { model.disappeared(channel.id) }
                        }
                    }
                }
                if !episodes.isEmpty {
                    TVContinueRow(row: HomeRow(title: "Episodes", shape: "landscape", aspect: 16.0 / 9, cards: episodes),
                                  loadingCard: loadingCard, play: { play($0) }, open: { openDetails($0) })
                }
            }
            .padding(.vertical, 20)
            .environment(\.rowInvertsOnFocus, false)
        }
        .scrollClipDisabled()
        // Rows line up with Home's, 90 points in from the screen's edge.
        .ignoresSafeArea(edges: .horizontal)
        .overlay { emptyState }
    }
    #endif

    #if os(iOS)
    /// "Search", large like the TV app's, and the filters under it, fixed
    /// above the results (which scroll under it). The filters are always
    /// there, so the header is the same height with or without a query.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search")
                .font(.largeTitle.bold())
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("search-title")
            scopeBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.black
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                        .offset(y: 16)
                }
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-header")
    }

    /// All · Movies · Shows · Live TV, the chosen one underlined.
    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(Scope.allCases) { option in
                let selected = option == scope
                // No animation for the results: they change at once; only
                // the pill slides (below).
                Button { scope = option } label: {
                    // The chosen one in a white pill with black words, as
                    // everywhere in the app (the player's pills); the others
                    // plain.
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? .black : .white)
                        // Dimmed when it has nothing for what's typed.
                        .opacity(query.trimmingCharacters(in: .whitespaces).isEmpty || hasResults(option) || selected ? 1 : 0.4)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background {
                            if selected {
                                Capsule().fill(.white).matchedGeometryEffect(id: "scope", in: scopeUnderline)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("scope-\(option.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.25), value: scope)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    #endif

    #if os(iOS)
    /// Before anything is typed: the library's genres as tiles, as in the
    /// Apple TV app (each with its best-known title's poster); a tap
    /// searches that genre.
    private var genreTiles: [(name: String, card: Card)] {
        model.library.topGenres(limit: 12).compactMap { genre in
            model.card(for: genre.entry, width: thumbWidth * 2).map { (genre.name, $0) }
        }
    }

    private var genreGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(genreTiles, id: \.name) { tile in
                    Button {
                        fieldFocused = false
                        path.append(GenreRoute(name: tile.name))
                    } label: {
                        Color.clear
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .overlay { CoverImage(images: tile.card.images, title: tile.name) }
                            .overlay(alignment: .bottomLeading) {
                                Text(tile.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                            }
                            .clipShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(QuickPress())
                    .accessibilityLabel(tile.name)
                    .accessibilityValue(tile.card.title)
                    .accessibilityIdentifier("genre-\(tile.name)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }
    #endif

    @ViewBuilder private var emptyState: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            #if os(iOS)
            if !genreTiles.isEmpty {
                genreGrid
            } else {
                ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                       description: Text("Movies, shows, episodes, channels, and what's on TV now or later by its name. Results appear as you type."))
            }
            #else
            ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                   description: Text("Movies, shows, episodes, channels, and what's on TV now or later by its name. Results appear as you type."))
            #endif
        } else if finishedEmpty.contains(.all), isEmpty(.all) {
            // Only once the search (the server's part too) has finished.
            ContentUnavailableView.search(text: q)
        } else if scope != .all, finishedEmpty.contains(scope), isEmpty(scope) {
            let what = switch scope {
            case .movies: "movies"
            case .shows: "shows or episodes"
            default: "channels"
            }
            ContentUnavailableView("No \(what)", systemImage: "line.3.horizontal.decrease",
                                   description: Text("No \(what) match “\(q)”. Try All."))
        } else if isEmpty(scope) {
            // Nothing yet, the server's part still on its way: said so
            // (over the list, so nothing moves), after a moment, so a quick
            // answer never flashes it.
            ProgressView("Searching…")
                .foregroundStyle(.secondary)
                .transition(.opacity.animation(.easeIn(duration: 0.2).delay(0.25)))
        }
    }

    /// iPhone, like the Apple TV app's search: the row opens its details
    /// (a film's page, a show's page, or an episode's show at that
    /// episode); "…" at its end plays it straight away (a show from the
    /// episode you're up to) or opens it.
    @ViewBuilder private func result(_ card: Card, wide: Bool) -> some View {
        #if os(iOS)
        HStack(spacing: 4) {
            Button { openDetails(card) } label: {
                HStack(spacing: 14) {
                    thumbnail(card, wide: wide, playBadge: false)
                    info(card)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(card.title)
            .accessibilityValue(card.subtitle ?? "")
            .accessibilityHint("Shows details")
            Menu {
                Button("Play", systemImage: "play.fill") { play(card) }
                Button(card.kind == "Series" || card.kind == "Episode" ? "Go to Show" : "Details", systemImage: "info.circle") {
                    openDetails(card)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            // Grey, as in the Apple TV app (it took the blue tint).
            .tint(.secondary)
            .accessibilityLabel("More for \(card.title)")
        }
        .rowForeground()
        #endif
    }

    private func thumbnail(_ card: Card, wide: Bool, playBadge: Bool) -> some View {
        let width = wide ? Layout.searchThumbWide : Layout.searchThumb
        return CoverImage(images: card.images, title: card.title)
            .frame(width: width, height: wide ? width * 9 / 16 : width * 1.5)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                if loadingCard == card.id {
                    ProgressView()
                } else if playBadge {
                    Image(systemName: "play.fill")
                        .font(.system(size: wide ? 12 : 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: wide ? 28 : 22, height: wide ? 28 : 22)
                        .background(.ultraThinMaterial, in: .circle)
                        .environment(\.colorScheme, .dark)
                }
            }
    }

    private func info(_ card: Card) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                // Plain colours, not the button tint.
                Text(card.title).font(.body).foregroundStyle(Color.primary).lineLimit(1)
                // The line kept when there's none, so every row is the
                // same height and a card gaining one doesn't shift the list.
                Text(card.subtitle ?? " ").font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func openDetails(_ card: Card) {
        #if DEBUG
        NSLog("%@", "PERF search open \(card.id) \(card.title) \(card.subtitle ?? "")")
        #endif
        switch card.kind {
        case "Series":
            path.append(ShowRoute(id: card.id, title: card.title))
        case "Episode":
            if let series = card.seriesId {
                path.append(ShowRoute(id: series, title: card.title, episodeId: card.id))
            } else {
                play(card)
            }
        default:
            path.append(MovieRoute(id: card.id, title: card.title))
        }
    }

    /// Local matches straight away (name, year, genres), with what's on TV
    /// when it's ready by then; then, each as soon as it's ready and
    /// neither waiting for the other, what's on TV (if it wasn't) and
    /// (after a short pause) the server's: cast checks, people named,
    /// episodes. The next letter cancels all of it, background work too.
    /// Nothing listed moves when a later part comes: it goes after. When
    /// the device has nothing for the new text, the last results stay until
    /// the server's part is in, rather than the page going blank between.
    private func search() async {
        let q = query
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return clearResults() }
        #if DEBUG
        let began = Date()
        func mark(_ stage: String) { NSLog("%@", String(format: "PERF search %@ %.0f ms (%@)", stage, Date().timeIntervalSince(began) * 1000, "\(q.count) letters")) }
        #endif
        let parsed = SearchQuery(q)
        let libraryCorpus = model.library.corpus
        let channelCorpus = model.channelCorpus
        let previousLibrary = libraryMatch, previousChannels = channelMatch
        // What's on TV, looked up beside the titles and channels.
        let area = prefs.area
        let guideSearch = Task { await model.searchGuide(q, area: area) }
        let work = Task.detached(priority: .userInitiated) { () -> LocalResults? in
            let (lm, hits) = SmartSearch.local(parsed, corpus: libraryCorpus, previous: previousLibrary)
            guard !Task.isCancelled else { return nil }
            let cm = channelCorpus.search(q, refining: previousChannels)
            guard !Task.isCancelled else { return nil }
            // Few matches: also look for near-misses (typos).
            let shown = Set(hits.map(\.entry.id))
            let fl = hits.count < 8 && !parsed.title.isEmpty
                ? libraryCorpus.fuzzy(parsed.title).map { libraryCorpus.items[$0] }.filter { !shown.contains($0.id) } : []
            let fc = cm.ranked.count < 8 ? channelCorpus.fuzzy(q, limit: 30).filter { !Set(cm.ranked.prefix(60)).contains($0) } : []
            return LocalResults(libraryMatch: lm, hits: hits, channelMatch: cm, typoLibrary: fl, typoChannels: fc)
        }
        let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel(); guideSearch.cancel() }
        guard !Task.isCancelled, let found else { return }
        let cm = found.channelMatch
        libraryMatch = found.libraryMatch
        channelMatch = cm
        // Titles still waiting for a cast check aren't listed until it
        // passes (listed first, they'd go again); they come after the rest.
        let hits = found.hits.filter { $0.pending.isEmpty }
        let typos = found.typoLibrary.map { SearchHit(entry: $0, pending: []) }
        let local = Local(titles: cards(hits + typos),
                          channels: (Array(cm.ranked.prefix(60)) + found.typoChannels).map { channelCorpus.items[$0] })
        // Shown with the rest when it's ready by then (it usually is), so
        // its section doesn't come a moment later and push the channels down.
        let early = await Self.value(of: guideSearch, within: 0.1)
        guard !Task.isCancelled else { return }
        let asksServer = trimmed.count >= 2 && model.sources.emby != nil
        let showsNow = !local.titles.isEmpty || !local.channels.isEmpty || early?.isEmpty == false || !asksServer
        if showsNow {
            show(local, onTV: early)
            let titleNames = (hits.prefix(12) + typos.prefix(6)).map(\.entry.name)
            let channelIndices = Array(cm.ranked.prefix(6)) + Array(found.typoChannels.prefix(3))
            let channelNames = channelIndices.map { model.title(of: channelCorpus.items[$0]) }
            updateCompletions(for: q, names: titleNames + channelNames)
        }
        #if DEBUG
        mark("local")
        #endif

        // Results settled: treat the top title as intent and get it ready,
        // so tapping it starts at once.
        if let top = local.titles.first {
            let likely = Array(local.titles.prefix(3))
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, query == q else { return }
                model.warmUp(top.id, kind: top.kind, options: prefs.playerProfile.mpvOptions,
                             hardwareDecoding: prefs.hardwareDecoding)
                // The first few results' pages and pictures too, so the one
                // chosen opens complete.
                if NetworkStatus.shared.knownUnmetered { likely.forEach(model.prefetchTitle) } else if top.kind == "Series" {
                    model.prefetchShows([top.id])
                }
            }
        }

        if showsNow {
            await withTaskGroup(of: Void.self) { group in
                if early == nil { group.addTask { await showOnTV(guideSearch) } }
                group.addTask { await searchServer(q, parsed: parsed, hits: found.hits, listed: hits + typos, held: nil) }
            }
        } else {
            // Nothing here yet for the new text: everything together when
            // the server's part is in.
            let onTV = await guideSearch.value
            guard !Task.isCancelled else { return }
            await searchServer(q, parsed: parsed, hits: found.hits, listed: hits + typos, held: (local, onTV))
        }
        guard !Task.isCancelled else { return }
        finishedEmpty = Set(Scope.allCases.filter(isEmpty))
        #if DEBUG
        mark("all")
        #endif
    }

    private struct LocalResults: Sendable {
        let libraryMatch: SearchCorpus<LibraryEntry>.Match?
        let hits: [SearchHit]
        let channelMatch: SearchCorpus<LiveChannel>.Match
        let typoLibrary: [LibraryEntry]
        let typoChannels: [Int]
    }

    /// What the device found: titles and channels.
    private struct Local {
        let titles: [Card]
        let channels: [LiveChannel]
    }

    /// The device's matches on the page. The same text again (an index
    /// grew meanwhile): what's listed keeps its place, anything new after.
    private func show(_ local: Local, onTV hits: [AppModel.GuideHit]?) {
        let again = query == shownQuery
        library = again ? Self.keepingOrder(library, local.titles) : local.titles
        channels = again ? Self.keepingOrder(channels, local.channels) : local.channels
        if let hits { onTV = hits }
        shownQuery = query
        publishTitles()
    }

    /// `fresh`, with the items also in `old` in old's order, then the rest.
    private static func keepingOrder<Item: Identifiable>(_ old: [Item], _ fresh: [Item]) -> [Item] {
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = old.compactMap { byId[$0.id] }
        let keptIds = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIds.contains($0.id) }
    }

    /// The search field cleared: nothing listed, nothing waiting.
    private func clearResults() {
        library = []
        extras = []
        serverCards = []
        channels = []
        onTV = []
        completions = []
        libraryMatch = nil
        channelMatch = nil
        shownQuery = ""
        finishedEmpty = []
        publishTitles()
    }

    /// The task's value if it's ready within `seconds`, else nil (it goes
    /// on). A task group can't do this: it waits for every child.
    private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let first = AsyncStream<T?> { done in
            Task { done.yield(await task.value) }
            Task { try? await Task.sleep(for: .seconds(seconds)); done.yield(nil) }
        }
        for await value in first { return value }
        return nil
    }

    /// What's on: the guide and today's games, by name.
    private func showOnTV(_ search: Task<[AppModel.GuideHit], Never>) async {
        let hits = await search.value
        guard !Task.isCancelled else { return }
        onTV = hits
        resultsChanged()
    }

    /// The server's part: cast checks for the titles waiting on one,
    /// people the query names, and its own search (episodes, titles the
    /// index doesn't hold yet). `held`: the device's part, not shown yet.
    private func searchServer(_ q: String, parsed: SearchQuery, hits: [SearchHit], listed: [SearchHit],
                              held: (local: Local, onTV: [AppModel.GuideHit])?) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, model.sources.emby != nil else {
            if let held { show(held.local, onTV: held.onTV) }
            serverCards = []
            extras = []
            publishTitles()
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        #if DEBUG
        // UI tests: the server's part late (OPENREEL_DEBUG_SEARCH_DELAY,
        // seconds), to look at the page before it comes.
        if let delay = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_SEARCH_DELAY"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(delay))
        }
        #endif
        guard !Task.isCancelled else { return }
        async let refined = model.refine(parsed, hits: hits)
        let found = await model.serverSearch(trimmed, cardWidth: thumbWidth)
        let (confirmed, people) = await refined
        guard !Task.isCancelled else { return }
        // After the titles listed: those whose cast checks passed, then
        // titles with people the query names.
        var titles = Set(listed.map(\.entry.titleKey))
        let castMatches = confirmed.filter { titles.insert($0.entry.titleKey).inserted }
        let withPeople = people.filter { titles.insert($0.item.titleKey).inserted }
            .compactMap { model.card(for: $0.item, width: thumbWidth, with: $0.person) }
        if let held { show(held.local, onTV: held.onTV) }
        extras = cards(castMatches) + withPeople
        extrasQuery = q
        if held != nil || !castMatches.isEmpty || !people.isEmpty {
            // Suggest what matched the whole query, not just its title words.
            updateCompletions(for: q, names: (listed.prefix(12) + castMatches.prefix(6)).map(\.entry.name)
                                  + people.prefix(6).map(\.item.name) + channels.prefix(3).map(\.name))
        }
        serverCards = found
        serverQuery = q
        publishTitles()
    }

    private func cards(_ hits: [SearchHit]) -> [Card] {
        hits.compactMap { model.card(for: $0.entry, width: thumbWidth, with: $0.person) }
    }

    /// Suggestions for what's typed. When the new text has none, those
    /// that still fit it stay (also one just typed out in full), so the
    /// row of suggestions doesn't come and go at each letter.
    private func updateCompletions(for query: String, names: [String]) {
        let fresh = Self.completions(for: query, names: names)
        guard fresh.isEmpty, !completions.isEmpty else {
            if fresh != completions { completions = fresh }
            return
        }
        let corpus = SearchCorpus(completions) { $0 }
        let kept = SearchCorpus<String>.fold(query).count > 1 ? corpus.search(query).ranked.sorted().map { corpus.items[$0] } : []
        if kept != completions { completions = kept }
    }

    /// Up to three full titles for what's typed, best match first (the
    /// names come from the ranked index matches).
    private static func completions(for query: String, names: [String]) -> [String] {
        let q = SearchCorpus<String>.fold(query)
        guard q.count > 1 else { return [] }
        var seen: Set<[UInt8]> = [q]
        var out: [String] = []
        for name in names {
            guard seen.insert(SearchCorpus<String>.fold(name)).inserted else { continue }
            out.append(name)
            if out.count == 3 { break }
        }
        return out
    }

    private func play(_ card: Card) {
        guard card.playable, loadingCard == nil else { return }
        loadingCard = card.id
        Task {
            defer { loadingCard = nil }
            do {
                playing = .vod(try await model.playback(for: card))
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}


/// Something on TV that matched: what it is, when (LIVE while it's on, with
/// how far through), and the channel.
struct GuideHitRow: View {
    let hit: AppModel.GuideHit

    var body: some View {
        let now = Int64(Date().timeIntervalSince1970)
        let on = hit.isOn(at: now)
        HStack(spacing: 12) {
            ChannelLogo(url: hit.channel.logo, name: hit.channelTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.title).font(.body.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if on {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: .capsule)
                    }
                    Text([when(on: on), hit.channelTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if on, hit.league == nil, let start = hit.start, let stop = hit.stop, stop > start {
                    ProgressView(value: Double(now - start), total: Double(stop - start))
                        .frame(maxWidth: 220)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .rowForeground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func when(on: Bool) -> String {
        guard let start = hit.start else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(start))
        if on {
            if hit.league != nil { return "Started \(start.clock)" }
            return hit.stop.map { "Now · until \($0.clock)" } ?? "Now"
        }
        if Calendar.current.isDateInToday(date) { return start.clock }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(start.clock)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

#if os(iOS)
struct GenreRoute: Hashable {
    let name: String
}

/// A genre's titles in the library, best-known first: a Search tile's page,
/// as in the Apple TV app. From the index on the device, so it's complete
/// at once.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let route: GenreRoute
    private let columns = [GridItem(.adaptive(minimum: Layout.posterWidth), spacing: 12, alignment: .top)]

    var body: some View {
        let width = Int(Layout.posterWidth * 2 * displayScale)
        let cards = model.library.titles(inGenre: route.name, limit: 150).compactMap { model.card(for: $0, width: width) }
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(cards) { card in
                    if card.kind == "Series" {
                        NavigationLink(value: ShowRoute(id: card.id, title: card.title)) { poster(card) }.buttonStyle(.plain)
                    } else {
                        NavigationLink(value: MovieRoute(id: card.id, title: card.title)) { poster(card) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .navigationTitle(route.name)
        #if DEBUG
        .background {
            let scans = String(model.library.genreScansOnMain)
            Text(scans).frame(width: 1, height: 1).opacity(0.02)
                .accessibilityLabel(scans).accessibilityIdentifier("debug-genre-scans")
        }
        #endif
    }

    private func poster(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { CoverImage(images: card.images, title: card.title) }
                .clipShape(.rect(cornerRadius: 12))
            Text(card.title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(card.subtitle ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
    }
}
#endif

