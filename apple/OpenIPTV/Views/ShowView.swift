import SwiftUI

/// Where a selected library item goes: shows open their page, everything
/// else plays. `episodeId` is the episode to resume (from Continue
/// Watching); without it the page uses the server's next episode.
struct ShowRoute: Hashable {
    let id: String
    let title: String
    var episodeId: String? = nil
}

/// A show: artwork and overview, one button to resume or start the right
/// episode, season buttons that jump through one list of every episode
/// (opened at the episode you're up to), and any episode a tap away.
struct ShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    @State private var show: EmbyItem?
    @State private var episodes: [EmbyItem] = []
    /// The episode the main button plays.
    @State private var upNext: EmbyItem?
    @State private var error: String?
    @State private var loadingItem: String?
    @State private var playError: String?
    @State private var scrolledToUpNext = false

    private var thumbWidth: Int { Int(Layout.searchThumbWide * 2 * displayScale) }

    /// Episodes grouped by season number, in order (specials last).
    private var seasons: [(number: Int, episodes: [EmbyItem])] {
        let grouped: [Int: [EmbyItem]] = Dictionary(grouping: episodes) { $0.parentIndexNumber ?? 0 }
        let order: (Int) -> Int = { $0 == 0 ? Int.max : $0 }
        let numbers: [Int] = grouped.keys.sorted { order($0) < order($1) }
        return numbers.map { (number: $0, episodes: grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                header
                    .listRowInsets(EdgeInsets())
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    #endif
                if seasons.count > 1 {
                    seasonBar(proxy)
                        .listRowInsets(EdgeInsets())
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ForEach(seasons, id: \.number) { season in
                    Section {
                        ForEach(season.episodes, id: \.id) { episode in
                            Button { play(episode.id, kind: "Episode") } label: {
                                EpisodeRow(episode: episode, card: card(episode),
                                           upNext: episode.id == upNext?.id, loading: loadingItem == episode.id)
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                        }
                    } header: {
                        // Pinned while its episodes scroll by, so it needs a backing.
                        Text(Self.seasonName(season.number))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .background(.bar)
                            .id("season-\(season.number)")
                    }
                }
                if episodes.isEmpty, error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
                }
            }
            .listStyle(.plain)
            .onChange(of: upNext?.id) { _, id in
                // Open at the episode you're up to.
                guard let id, !scrolledToUpNext, !episodes.isEmpty else { return }
                scrolledToUpNext = true
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .navigationTitle(route.title)
        .inlineTitle()
        .task {
            // The main button starts the moment it's tapped.
            if let episode = route.episodeId {
                model.warmUp(episode, kind: "Episode", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
            } else {
                model.warmUp(route.id, kind: "Series", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
            }
            await load()
        }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let show, let url = model.emby?.backdropURL(for: show, width: Int(1280 * displayScale / 2)) {
                // A fixed 16:9 box; the image fills it whatever its own shape.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: route.title) }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(route.title).font(.title2.weight(.bold))
                if let year = show?.productionYear {
                    Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                }
                Button { playMain() } label: {
                    Label(loadingItem == mainId ? "Starting…" : mainLabel, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(loadingItem != nil)
                if let overview = show?.overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// Season buttons that jump through the list.
    private func seasonBar(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.number) { season in
                    Button(Self.seasonName(season.number)) {
                        withAnimation { proxy.scrollTo("season-\(season.number)", anchor: .top) }
                    }
                    #if os(tvOS)
                    .buttonStyle(TVChipStyle(selected: season.number == upNext?.parentIndexNumber))
                    #else
                    .buttonStyle(.glass)
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    /// The episode the main button plays: the one being resumed, or the
    /// next one to watch.
    private var mainId: String { upNext?.id ?? route.episodeId ?? route.id }

    private var mainLabel: String {
        guard let upNext else { return "Play" }
        let code = upNext.parentIndexNumber.flatMap { s in upNext.indexNumber.map { "S\(s):E\($0)" } } ?? "episode"
        if let ticks = upNext.userData?.playbackPositionTicks, ticks > 0, upNext.userData?.played != true {
            if let total = upNext.runTimeTicks, total > ticks {
                return "Resume \(code) · \(max(1, Int((total - ticks) / 600_000_000))) min left"
            }
            return "Resume \(code)"
        }
        return "Play \(code)"
    }

    private static func seasonName(_ number: Int) -> String {
        number == 0 ? "Specials" : "Season \(number)"
    }

    private func card(_ episode: EmbyItem) -> Card? {
        model.emby?.card(for: episode, landscape: true, width: thumbWidth)
    }

    private func load() async {
        guard let emby = model.emby, show == nil else { return }
        do {
            async let item = emby.item(route.id)
            async let list = emby.episodes(of: route.id, season: nil)
            async let next: EmbyItem? = route.episodeId == nil ? emby.nextEpisode(of: route.id) : nil
            show = try await item
            episodes = try await list
            if let id = route.episodeId {
                upNext = episodes.first { $0.id == id }
            } else {
                upNext = try await next
            }
        } catch {
            self.error = SourceError.wrap(error).localizedDescription
        }
    }

    private func playMain() {
        if let upNext { play(upNext.id, kind: "Episode") } else { play(route.id, kind: "Series") }
    }

    private func play(_ id: String, kind: String) {
        guard loadingItem == nil else { return }
        loadingItem = id
        Task {
            defer { loadingItem = nil }
            do {
                playing = .vod(try await model.playback(itemId: id, kind: kind))
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: EmbyItem
    let card: Card?
    let upNext: Bool
    let loading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(images: card?.images ?? [], title: episode.name)
                .frame(width: Layout.searchThumbWide * 1.25, height: Layout.searchThumbWide * 1.25 * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress = episode.userData?.playedPercentage, progress > 0, progress < 100 {
                        GeometryReader { geo in
                            Capsule().fill(.tint).frame(width: geo.size.width * progress / 100, height: 3)
                        }
                        .frame(height: 3)
                        .padding(4)
                    }
                }
                .overlay { if loading { ProgressView() } }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if upNext { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2) }
                }
            VStack(alignment: .leading, spacing: 3) {
                if upNext {
                    Text("Up next").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                }
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Watched")
                    }
                }
                if let minutes = episode.runTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
                    Text("\(minutes) min").font(.caption).foregroundStyle(.secondary)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .rowForeground()
        .contentShape(Rectangle())
    }

    private var title: String {
        episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name
    }
}
