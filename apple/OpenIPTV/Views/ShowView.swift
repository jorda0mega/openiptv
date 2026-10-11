import SwiftUI

/// Where a selected library item goes: shows open their page, everything
/// else plays.
struct ShowRoute: Hashable {
    let id: String
    let title: String
}

/// A show: artwork and overview, Play for the next episode, then seasons
/// and their episodes (with progress). Selecting an episode plays it.
struct ShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    @State private var show: EmbyItem?
    @State private var seasons: [EmbyItem] = []
    @State private var season: String?
    @State private var episodes: [EmbyItem] = []
    @State private var error: String?
    @State private var loadingItem: String?
    @State private var playError: String?

    private var thumbWidth: Int { Int(Layout.searchThumbWide * 2 * displayScale) }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif
            if seasons.count > 1 {
                Picker("Season", selection: $season) {
                    ForEach(seasons, id: \.id) { s in Text(s.name).tag(Optional(s.id)) }
                }
                #if os(iOS)
                .pickerStyle(.menu)
                #endif
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(episodes, id: \.id) { episode in
                Button { play(episode.id) } label: { EpisodeRow(episode: episode, card: card(episode), loading: loadingItem == episode.id) }
                    .buttonStyle(.plain)
            }
            if episodes.isEmpty, error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
            }
        }
        .listStyle(.plain)
        .navigationTitle(route.title)
        .inlineTitle()
        .task { await load() }
        .task(id: season) { await loadEpisodes() }
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
                Button { play(route.id) } label: {
                    Label(loadingItem == route.id ? "Starting…" : "Play next episode", systemImage: "play.fill")
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

    private func card(_ episode: EmbyItem) -> Card? {
        model.emby?.card(for: episode, landscape: true, width: thumbWidth)
    }

    private func load() async {
        guard let emby = model.emby, show == nil else { return }
        do {
            async let item = emby.item(route.id)
            async let list = emby.seasons(of: route.id)
            show = try await item
            seasons = try await list
            // Open on the season with the next unwatched episode.
            season = seasons.first { $0.userData?.played != true }?.id ?? seasons.first?.id
            if seasons.isEmpty { await loadEpisodes() }
        } catch {
            self.error = SourceError.wrap(error).localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let emby = model.emby, season != nil || seasons.isEmpty, show != nil else { return }
        do {
            episodes = try await emby.episodes(of: route.id, season: season)
        } catch {
            self.error = SourceError.wrap(error).localizedDescription
        }
    }

    private func play(_ id: String) {
        guard loadingItem == nil else { return }
        loadingItem = id
        Task {
            defer { loadingItem = nil }
            do {
                playing = .vod(try await model.playback(itemId: id))
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: EmbyItem
    let card: Card?
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
            VStack(alignment: .leading, spacing: 3) {
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
