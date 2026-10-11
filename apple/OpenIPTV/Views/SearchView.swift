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
    @State private var library: [Card] = []
    @State private var channels: [LiveChannel] = []
    @State private var onTV: [AppModel.GuideHit] = []
    @State private var completions: [String] = []
    @State private var serverCards: [Card] = []
    @State private var serverDone = false
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

    /// The library's matches, then the server's that still fit what's typed
    /// now (no flicker while the next request is in flight) and aren't
    /// another copy of one already listed (HD and 4K are one title).
    private func publishTitles() {
        var server: [Card] = []
        if !serverCards.isEmpty {
            let corpus = SearchCorpus(serverCards) { "\($0.title) \($0.subtitle ?? "")" }
            server = corpus.search(query).ranked.sorted().map { corpus.items[$0] }
        }
        let known = Set(library.flatMap { model.library.versions(of: $0.id) })
        let all = library + server.filter { $0.kind != "Episode" && !known.contains($0.id) }
        titles = Titles(all: all, movies: all.filter { $0.kind != "Series" }, shows: all.filter { $0.kind == "Series" },
                        episodes: server.filter { $0.kind == "Episode" })
    }

    /// Whether a filter has anything for what's typed (empty ones are dimmed).
    private func hasResults(_ scope: Scope) -> Bool {
        switch scope {
        case .all: true
        case .movies: !movies.isEmpty
        case .shows: !shows.isEmpty || !episodes.isEmpty
        case .live: !channels.isEmpty || !onTV.isEmpty
        }
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
                if scope == .all, !completions.isEmpty {
                    Section {
                        ForEach(completions, id: \.self) { completion in
                            Button { query = completion } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                    Text(completion).foregroundStyle(Color.primary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                // One section whatever the filter, so a title shown before
                // and after a filter tap keeps its row instead of a new one.
                let shown = scope == .movies ? movies : scope == .shows ? shows : scope == .all ? moviesAndShows : []
                if !shown.isEmpty {
                    Section(scope == .movies ? "Movies" : scope == .shows ? "Shows" : "Movies & Shows") {
                        ForEach(shown) { card in result(card, wide: false) }
                    }
                }
                if scope == .all || scope == .shows, !episodes.isEmpty {
                    Section("Episodes") {
                        ForEach(episodes) { card in result(card, wide: true) }
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
                                Button(prefs.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites",
                                       systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                                    prefs.toggleFavorite(channel)
                                }
                            }
                            .onAppear { model.appeared(channel.id) }
                            .onDisappear { model.disappeared(channel.id) }
                        }
                    }
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
            .navigationTitle("Search")
            .navigationDestination(for: ShowRoute.self) { ShowView(route: $0, playing: $playing) }
            .navigationDestination(for: MovieRoute.self) { MovieView(route: $0, playing: $playing) }
            #if os(iOS)
            // One field with one clear button, instead of the system bar's
            // clear and close buttons side by side. Scrolling the results
            // or the keyboard's Search key puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) { searchField }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty { scopeBar }
            }
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
    #endif

    #if os(tvOS)
    @Namespace private var tvFocus
    @Environment(\.resetFocus) private var resetFocus

    /// Up from the top row of results: back to the keyboard (the remote
    /// won't cross from SwiftUI into the UIKit keyboard by itself).
    private func upToKeyboard(_ direction: MoveCommandDirection) {
        if direction == .up { resetFocus(in: tvFocus) }
    }

    /// Which row is at the top of the results.
    private var topRow: Int {
        !moviesAndShows.isEmpty ? 0 : !episodes.isEmpty ? 1 : !onTV.isEmpty ? 2 : 3
    }

    /// Apple TV, like Apple's TV app: the keyboard row across the top, then
    /// the results as rows of cards: titles, episodes, what's on, channels.
    /// Titles open their page; episodes, programmes and channels play.
    private var tvBody: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TVSearchContainer(query: $query, prompt: "Movies, shows, channels, what's on")
                    // The field and the keyboard row; UIKit keeps its own
                    // side margins (the hint at the field's end ran off the
                    // screen inside SwiftUI's).
                    .frame(height: 300)
                    .ignoresSafeArea(edges: .horizontal)
                    .prefersDefaultFocus(in: tvFocus)
                tvResults
            }
            .focusScope(tvFocus)
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
                if !moviesAndShows.isEmpty {
                    TVPosterRow(title: "Movies & Shows", cards: moviesAndShows) { openDetails($0) }
                        .onMoveCommand(perform: topRow == 0 ? upToKeyboard : nil)
                }
                if !episodes.isEmpty {
                    TVContinueRow(row: HomeRow(title: "Episodes", shape: "landscape", aspect: 16.0 / 9, cards: episodes),
                                  loadingCard: loadingCard, play: { play($0) }, open: { openDetails($0) })
                        .onMoveCommand(perform: topRow == 1 ? upToKeyboard : nil)
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
                    .onMoveCommand(perform: topRow == 2 ? upToKeyboard : nil)
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
                    .onMoveCommand(perform: topRow == 3 ? upToKeyboard : nil)
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
    /// All · Movies · Shows · Live TV, the chosen one underlined.
    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(Scope.allCases) { option in
                let selected = option == scope
                // No animation for the results: they change at once; only
                // the pill slides (below).
                Button { scope = option } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .opacity(hasResults(option) || selected ? 1 : 0.4)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            if selected {
                                Capsule().fill(.white).matchedGeometryEffect(id: "scope", in: scopeUnderline)
                            } else {
                                Capsule().fill(Color(white: 0.15))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.25), value: scope)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background {
            Color.black
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                        .offset(y: 16)
                }
                .allowsHitTesting(false)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Movies, shows, people, what's on TV", text: $query)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit { fieldFocused = false }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .contentShape(.capsule)
        .onTapGesture { fieldFocused = true }
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    #endif

    @ViewBuilder private var emptyState: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                   description: Text("Movies, shows, episodes, channels, and what's on TV now or later by its name. Results appear as you type."))
        } else if serverDone, moviesAndShows.isEmpty, episodes.isEmpty, channels.isEmpty, onTV.isEmpty {
            ContentUnavailableView.search(text: q)
        } else if scope != .all, !hasResults(scope), serverDone {
            let what = switch scope {
            case .movies: "movies"
            case .shows: "shows or episodes"
            default: "channels"
            }
            ContentUnavailableView("No \(what)", systemImage: "line.3.horizontal.decrease",
                                   description: Text("No \(what) match “\(q)”. Try All."))
        }
    }

    /// Shows open their page; movies and episodes play.
    /// iPhone: the picture plays it straight away (a show from the episode
    /// you're up to); the rest of the row opens its details (a film's page,
    /// a show's page, or an episode's show at that episode).
    @ViewBuilder private func result(_ card: Card, wide: Bool) -> some View {
        #if os(iOS)
        HStack(spacing: 12) {
            Button { play(card) } label: { thumbnail(card, wide: wide, playBadge: true) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Play \(card.title)")
            Button { openDetails(card) } label: {
                info(card)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(card.title)
            .accessibilityValue(card.subtitle ?? "")
            .accessibilityHint("Shows details")
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
                Text(card.title).font(.body.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                if let subtitle = card.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func openDetails(_ card: Card) {
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

    /// Local matches straight away (name, year, genres), then after a short
    /// pause the server's: cast checks, people named, episodes.
    private func search() async {
        let q = query
        let parsed = SearchQuery(q)
        let libraryCorpus = model.library.corpus
        let channelCorpus = model.channelCorpus
        let previousLibrary = libraryMatch, previousChannels = channelMatch
        let (lm, hits, cm, typoLibrary, typoChannels) = await Task.detached(priority: .userInitiated) {
            let (lm, hits) = SmartSearch.local(parsed, corpus: libraryCorpus, previous: previousLibrary)
            let cm = channelCorpus.search(q, refining: previousChannels)
            // Few matches: also look for near-misses (typos).
            let shown = Set(hits.map(\.entry.id))
            let fl = hits.count < 8 && !parsed.title.isEmpty
                ? libraryCorpus.fuzzy(parsed.title).map { libraryCorpus.items[$0] }.filter { !shown.contains($0.id) } : []
            let fc = cm.ranked.count < 8 ? channelCorpus.fuzzy(q, limit: 30).filter { !Set(cm.ranked.prefix(60)).contains($0) } : []
            return (lm, hits, cm, fl, fc)
        }.value
        guard !Task.isCancelled else { return }
        libraryMatch = lm
        channelMatch = cm
        let typos = typoLibrary.map { SearchHit(entry: $0, pending: []) }
        library = cards(hits + typos)
        publishTitles()
        channels = (Array(cm.ranked.prefix(60)) + typoChannels).map { channelCorpus.items[$0] }
        // What's on: the guide and today's games, by name.
        let guideHits = await model.searchGuide(q, area: prefs.area)
        guard !Task.isCancelled else { return }
        onTV = guideHits
        completions = Self.completions(for: q,
                                       names: (hits.prefix(12) + typos.prefix(6)).map(\.entry.name)
                                           + (Array(cm.ranked.prefix(6)) + typoChannels.prefix(3)).map { model.title(of: channelCorpus.items[$0]) })
        serverDone = false

        // Results settled: treat the top title as intent and get it ready,
        // so tapping it starts at once.
        if let top = library.first {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, query == q else { return }
                model.warmUp(top.id, kind: top.kind, options: prefs.playerProfile.mpvOptions,
                             hardwareDecoding: prefs.hardwareDecoding)
                if top.kind == "Series" { model.prefetchShows([top.id]) }
            }
        }

        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, model.sources.emby != nil else {
            serverCards = []
            publishTitles()
            serverDone = true
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        async let refined = model.refine(parsed, hits: hits)
        let found = await model.serverSearch(trimmed, cardWidth: thumbWidth)
        let (confirmed, people) = await refined
        guard !Task.isCancelled else { return }
        // Cast checks settled; then titles with people the query names.
        var titles = Set(confirmed.map(\.entry.titleKey) + typos.map(\.entry.titleKey))
        let withPeople = people.filter { titles.insert($0.item.titleKey).inserted }
            .compactMap { model.card(for: $0.item, width: thumbWidth, with: $0.person) }
        library = cards(confirmed) + withPeople + cards(typos)
        if confirmed.count != hits.count || !people.isEmpty {
            // Suggest what matched the whole query, not just its title words.
            completions = Self.completions(for: q, names: (confirmed.prefix(12) + typos.prefix(6)).map(\.entry.name)
                                               + people.prefix(6).map(\.item.name) + channels.prefix(3).map(\.name))
        }
        serverCards = found
        publishTitles()
        serverDone = true
    }

    private func cards(_ hits: [SearchHit]) -> [Card] {
        hits.compactMap { model.card(for: $0.entry, width: thumbWidth, with: $0.person) }
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
