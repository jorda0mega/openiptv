import SwiftUI

/// One search for everything. Movies, shows and channels come from indexes
/// on the device and update on every keystroke, with completions on top;
/// episodes (and anything newer than the index) follow from the Emby server
/// a moment later.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    @Binding var playing: PlayerItem?

    @State private var query = ""
    #if os(iOS)
    @FocusState private var fieldFocused: Bool
    #endif
    @State private var library: [Card] = []
    @State private var channels: [LiveChannel] = []
    @State private var completions: [String] = []
    @State private var serverCards: [Card] = []
    @State private var serverDone = false
    @State private var libraryMatch: SearchCorpus<LibraryEntry>.Match?
    @State private var channelMatch: SearchCorpus<LiveChannel>.Match?
    @State private var loadingCard: String?
    @State private var playError: String?

    private var thumbWidth: Int { Int(Layout.searchThumbWide * displayScale) }

    /// Server results that still fit what's typed now (no flicker while the
    /// next request is in flight).
    private var serverFiltered: [Card] {
        guard !serverCards.isEmpty else { return [] }
        let corpus = SearchCorpus(serverCards) { "\($0.title) \($0.subtitle ?? "")" }
        return corpus.search(query).ranked.sorted().map { corpus.items[$0] }
    }

    private var episodes: [Card] { serverFiltered.filter { $0.kind == "Episode" } }

    private var moviesAndShows: [Card] {
        // Every copy of the titles already listed (HD and 4K are one title).
        let known = Set(library.flatMap { model.library.versions(of: $0.id) })
        return library + serverFiltered.filter { $0.kind != "Episode" && !known.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !completions.isEmpty {
                    Section {
                        ForEach(completions, id: \.self) { completion in
                            Button { query = completion } label: {
                                Label(completion, systemImage: "magnifyingglass")
                                    .lineLimit(1)
                                    .rowForeground()
                            }
                        }
                    }
                }
                if !moviesAndShows.isEmpty {
                    Section("Movies & Shows") {
                        ForEach(moviesAndShows) { card in result(card, wide: false) }
                    }
                }
                if !episodes.isEmpty {
                    Section("Episodes") {
                        ForEach(episodes) { card in result(card, wide: true) }
                    }
                }
                if !channels.isEmpty {
                    Section("Channels") {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            Button {
                                playing = .live(channels, index)
                            } label: {
                                ChannelRow(channel: channel, info: model.nowNext[channel.id], favorite: prefs.isFavorite(channel))
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
            #if os(iOS)
            // One field with one clear button, instead of the system bar's
            // clear and close buttons side by side. Scrolling the results
            // or the keyboard's Search key puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) { searchField }
            .onAppear { if query.isEmpty { fieldFocused = true } }
            #else
            .searchable(text: $query, prompt: "Movies, shows, channels")
            .autocorrectionDisabled()
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

    #if os(iOS)
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Movies, shows, people, channels", text: $query)
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
                                   description: Text("Movies, shows, episodes and live channels. Results appear as you type."))
        } else if serverDone, moviesAndShows.isEmpty, episodes.isEmpty, channels.isEmpty {
            ContentUnavailableView.search(text: q)
        }
    }

    /// Shows open their page; movies and episodes play.
    @ViewBuilder private func result(_ card: Card, wide: Bool) -> some View {
        if card.kind == "Series" {
            NavigationLink(value: ShowRoute(id: card.id, title: card.title)) { resultLabel(card, wide: wide) }
        } else {
            Button { play(card) } label: { resultLabel(card, wide: wide) }
                .buttonStyle(.plain)
        }
    }

    private func resultLabel(_ card: Card, wide: Bool) -> some View {
            HStack(spacing: 12) {
                let width = wide ? Layout.searchThumbWide : Layout.searchThumb
                CoverImage(images: card.images, title: card.title)
                    .frame(width: width, height: wide ? width * 9 / 16 : width * 1.5)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay { if loadingCard == card.id { ProgressView() } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                    if let subtitle = card.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .rowForeground()
            .contentShape(Rectangle())
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
        channels = (Array(cm.ranked.prefix(60)) + typoChannels).map { channelCorpus.items[$0] }
        completions = Self.completions(for: q,
                                       names: (hits.prefix(12) + typos.prefix(6)).map(\.entry.name)
                                           + (Array(cm.ranked.prefix(6)) + typoChannels.prefix(3)).map { channelCorpus.items[$0].name })
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
