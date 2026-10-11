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
        let known = Set(library.map(\.id))
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
                if model.library.indexing, model.library.count == 0, model.sources.emby != nil {
                    Label("Getting your library ready for instant search…", systemImage: "hourglass")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, shows, channels")
            .autocorrectionDisabled()
            .task { if let emby = model.emby { await model.library.prepare(emby) } }
            // Re-run when the text changes or an index finishes loading.
            .task(id: "\(query)|\(model.library.count)|\(model.channelCorpus.items.count)") { await search() }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                   description: Text("Movies, shows, episodes and live channels. Results appear as you type."))
        } else if serverDone, moviesAndShows.isEmpty, episodes.isEmpty, channels.isEmpty {
            ContentUnavailableView.search(text: q)
        }
    }

    private func result(_ card: Card, wide: Bool) -> some View {
        Button { play(card) } label: {
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
        .buttonStyle(.plain)
    }

    /// Local matches straight away, then the server's after a short pause.
    private func search() async {
        let q = query
        let libraryCorpus = model.library.corpus
        let channelCorpus = model.channelCorpus
        let previousLibrary = libraryMatch, previousChannels = channelMatch
        let (lm, cm) = await Task.detached(priority: .userInitiated) {
            (libraryCorpus.search(q, refining: previousLibrary), channelCorpus.search(q, refining: previousChannels))
        }.value
        guard !Task.isCancelled else { return }
        libraryMatch = lm
        channelMatch = cm
        library = lm.ranked.prefix(40).compactMap { model.card(for: libraryCorpus.items[$0], width: thumbWidth) }
        channels = cm.ranked.prefix(60).map { channelCorpus.items[$0] }
        completions = Self.completions(for: q,
                                       names: lm.ranked.prefix(12).map { libraryCorpus.items[$0].name }
                                           + cm.ranked.prefix(6).map { channelCorpus.items[$0].name })
        serverDone = false

        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, model.sources.emby != nil else {
            serverCards = []
            serverDone = true
            return
        }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        let cards = await model.serverSearch(trimmed, cardWidth: thumbWidth)
        guard !Task.isCancelled else { return }
        serverCards = cards
        serverDone = true
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
