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
/// episode, then every episode in one list with a heading per season. A
/// filter bar (Unwatched, Newest first, a button per season) scrolls up
/// under the header and then stays pinned; the season in view is
/// highlighted and tapping one jumps straight to it. Everything is local,
/// so filtering and jumping are instant.
struct ShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    @State private var data: AppModel.ShowData?
    @State private var error: String?
    @State private var loadingItem: String?
    @State private var playError: String?
    @State private var scrolledToUpNext = false
    @State private var unwatchedOnly = false
    @State private var newestFirst = false
    /// Episodes currently on screen, to highlight the season in view.
    @State private var onScreen: Set<String> = []

    private var thumbWidth: Int { Int(Layout.searchThumbWide * 2 * displayScale) }

    /// The episode the main button plays: the one being resumed, or next.
    private var upNext: EmbyItem? {
        if let id = route.episodeId, let episode = data?.episodes.first(where: { $0.id == id }) { return episode }
        return data?.nextUp
    }

    /// Episodes after the filters, grouped by season in display order.
    private var seasons: [(number: Int, episodes: [EmbyItem])] {
        var episodes = data?.episodes ?? []
        if unwatchedOnly { episodes = episodes.filter { $0.userData?.played != true } }
        if newestFirst { episodes.reverse() }
        var order: [Int] = []
        var grouped: [Int: [EmbyItem]] = [:]
        for episode in episodes {
            let number = episode.parentIndexNumber ?? 0
            if grouped[number] == nil { order.append(number) }
            grouped[number, default: []].append(episode)
        }
        return order.map { (number: $0, episodes: grouped[$0] ?? []) }
    }

    /// The season with the most episodes on screen (rows peeking out from
    /// under the bars shouldn't win).
    private func seasonInView(_ seasons: [(number: Int, episodes: [EmbyItem])]) -> Int? {
        seasons
            .map { season in (season.number, season.episodes.filter { onScreen.contains($0.id) }.count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    var body: some View {
        let seasons = seasons
        ScrollViewReader { proxy in
            List {
                header
                    .listRowInsets(EdgeInsets())
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    #endif
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Section {
                    ForEach(seasons, id: \.number) { season in
                        SeasonHeading(number: season.number, episodes: season.episodes)
                            .id("season-\(season.number)")
                        ForEach(season.episodes, id: \.id) { episode in
                            Button { play(episode.id, kind: "Episode") } label: {
                                EpisodeRow(episode: episode, card: card(episode),
                                           upNext: episode.id == upNext?.id, loading: loadingItem == episode.id)
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                            .onAppear { onScreen.insert(episode.id) }
                            .onDisappear { onScreen.remove(episode.id) }
                        }
                    }
                    if data != nil, seasons.isEmpty {
                        Text(unwatchedOnly ? "You've watched every episode." : "No episodes yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    if data != nil {
                        filterBar(proxy, seasons: seasons)
                    }
                }
                if data == nil, error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
                }
            }
            .listStyle(.plain)
            .onChange(of: data?.episodes.count) { _, _ in
                // Open at the episode you're up to.
                guard let id = upNext?.id, !scrolledToUpNext else { return }
                scrolledToUpNext = true
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.scrollTo(id, anchor: .center)
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
            // Draw what's already here at once, then refresh behind it.
            data = model.shows[route.id]
            if let fresh = await model.loadShow(route.id) {
                data = fresh
            } else if data == nil {
                error = "Couldn't load this show."
            }
        }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let show = data?.show, let url = model.emby?.backdropURL(for: show, width: Int(1280 * displayScale / 2)) {
                // A fixed 16:9 box; the image fills it whatever its own shape.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: route.title) }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(route.title).font(.title2.weight(.bold))
                if let year = data?.show.productionYear {
                    Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                }
                Button { playMain() } label: {
                    Label(loadingItem == mainId ? "Starting…" : mainLabel, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(loadingItem != nil)
                if let overview = data?.show.overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// Pinned under the navigation bar once scrolled to: filters, then a
    /// button per season (the one in view highlighted). Jumps are instant.
    private func filterBar(_ proxy: ScrollViewProxy, seasons: [(number: Int, episodes: [EmbyItem])]) -> some View {
        let current = seasonInView(seasons)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(unwatchedOnly ? "Unwatched ✓" : "Unwatched", selected: unwatchedOnly) {
                    unwatchedOnly.toggle()
                }
                chip(newestFirst ? "Newest first ✓" : "Newest first", selected: newestFirst) {
                    newestFirst.toggle()
                }
                if seasons.count > 1 {
                    Divider().frame(height: 24)
                    ForEach(seasons, id: \.number) { season in
                        chip(Self.shortSeasonName(season.number), selected: season.number == current) {
                            proxy.scrollTo("season-\(season.number)", anchor: .top)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .background(.regularMaterial)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(title, action: action).buttonStyle(TVChipStyle(selected: selected))
        #else
        if selected {
            Button(title, action: action).buttonStyle(.glassProminent)
        } else {
            Button(title, action: action).buttonStyle(.glass)
        }
        #endif
    }

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

    static func seasonName(_ number: Int) -> String { number == 0 ? "Specials" : "Season \(number)" }
    private static func shortSeasonName(_ number: Int) -> String { number == 0 ? "Specials" : "S\(number)" }

    private func card(_ episode: EmbyItem) -> Card? {
        model.emby?.card(for: episode, landscape: true, width: thumbWidth)
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

/// "Season 2 · 8 episodes · 3 watched" between seasons.
private struct SeasonHeading: View {
    let number: Int
    let episodes: [EmbyItem]

    var body: some View {
        let watched = episodes.filter { $0.userData?.played == true }.count
        HStack(alignment: .firstTextBaseline) {
            Text(ShowView.seasonName(number)).font(.title3.weight(.bold))
            Spacer()
            Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")" + (watched > 0 ? " · \(watched) watched" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 14)
        .rowForeground()
        #if os(iOS)
        .listRowSeparator(.hidden)
        #endif
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
