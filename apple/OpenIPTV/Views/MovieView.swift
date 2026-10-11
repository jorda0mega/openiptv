import SwiftUI

/// A film to open its details page.
struct MovieRoute: Hashable {
    let id: String
    let title: String
}

/// A film's details: backdrop, Play (or Resume), what it is (year,
/// running time, IMDb score, genres), the story, who's in it and who made
/// it, and more like it. Playback is warmed up on arrival, so Play starts
/// at once.
struct MovieView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    let route: MovieRoute
    @Binding var playing: PlayerItem?

    @State private var item: EmbyItem?
    @State private var similar: [Card] = []
    @State private var loading = false
    @State private var playError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backdrop
                VStack(alignment: .leading, spacing: 10) {
                    Text(route.title).font(.title2.weight(.bold))
                    if !details.isEmpty {
                        Text(details).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button(action: play) {
                        Label(loading ? "Starting…" : playLabel, systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(loading)
                    if let progress = item?.userData?.playedPercentage, progress > 0, progress < 100, item?.userData?.played != true {
                        ProgressView(value: progress, total: 100).tint(.accentColor)
                    }
                    if let overview = item?.overview, !overview.isEmpty {
                        Text(overview).font(.callout).foregroundStyle(.secondary)
                    }
                    if let cast = names("Actor", limit: 5) {
                        Text("Starring ").foregroundStyle(.secondary) + Text(cast)
                    }
                    if let directors = names("Director", limit: 2) {
                        Text("Directed by ").foregroundStyle(.secondary) + Text(directors)
                    }
                }
                .font(.callout)
                .padding(.horizontal)
                if !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("More like this").font(.title3.weight(.bold)).padding(.horizontal)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: Layout.cardSpacing) {
                                ForEach(similar) { card in moreLikeThis(card) }
                            }
                            .padding(.horizontal)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(route.title)
        .inlineTitle()
        .task { await load() }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    @ViewBuilder private var backdrop: some View {
        if let item, let url = model.emby?.backdropURL(for: item, width: Int(1280 * displayScale / 2)) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: route.title) }
                .clipped()
        } else {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
        }
    }

    /// "2024 · 2 h 46 min · IMDb 8.4 · 1.2M ratings · Science Fiction, Adventure"
    private var details: String {
        guard let item else { return "" }
        let minutes = item.runTimeTicks.map { Int($0 / 600_000_000) }
        let length = minutes.map { $0 >= 60 ? "\($0 / 60) h \($0 % 60) min" : "\($0) min" }
        let rating = model.library.ratings?.rating(item.imdb).map(IMDbRatings.detail)
        let genres = item.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: ", ") }
        return [item.productionYear.map(String.init), length, rating, genres].compactMap(\.self).joined(separator: " · ")
    }

    private var playLabel: String {
        guard let data = item?.userData, data.played != true, let ticks = data.playbackPositionTicks, ticks > 0 else { return "Play" }
        if let total = item?.runTimeTicks, total > ticks {
            return "Resume · \(max(1, Int((total - ticks) / 600_000_000))) min left"
        }
        return "Resume"
    }

    private func names(_ type: String, limit: Int) -> String? {
        let people = (item?.people ?? []).filter { $0.type == type }.prefix(limit).map(\.name)
        return people.isEmpty ? nil : people.joined(separator: ", ")
    }

    @ViewBuilder private func moreLikeThis(_ card: Card) -> some View {
        let label = VStack(alignment: .leading, spacing: 4) {
            CoverImage(images: card.images, title: card.title)
                .frame(width: Layout.posterWidth, height: Layout.posterWidth * 1.5)
                .clipShape(.rect(cornerRadius: 12))
            Text(card.title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(width: Layout.posterWidth)
        if card.kind == "Series" {
            NavigationLink(value: ShowRoute(id: card.id, title: card.title)) { label }.buttonStyle(.plain)
        } else {
            NavigationLink(value: MovieRoute(id: card.id, title: card.title)) { label }.buttonStyle(.plain)
        }
    }

    private func load() async {
        model.warmUp(route.id, kind: "Movie", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        guard let emby = model.emby else { return }
        async let detail = emby.details(route.id)
        async let like = emby.similar(to: route.id, limit: 16)
        item = await detail
        let width = Int(Layout.posterWidth * displayScale)
        similar = await like
            .filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: width) }
    }

    private func play() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                playing = .vod(try await model.playback(itemId: route.id, kind: "Movie"))
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}
