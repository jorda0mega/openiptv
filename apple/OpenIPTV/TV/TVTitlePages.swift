#if os(tvOS)
import SwiftUI

/// The top of a title's page, like the TV app's: the backdrop filling the
/// screen, the title's logo, what it is, the story and the buttons.
private struct TVTitleHeader<Buttons: View>: View {
    let backdrop: String?
    let logo: String?
    let title: String
    let details: String
    let overview: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TVBackdrop(url: backdrop, title: title)
            VStack(alignment: .leading, spacing: 18) {
                TVTitleArt(logo: logo, title: title, maxHeight: 180)
                if !details.isEmpty {
                    Text(details).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
                if let overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.white.opacity(0.78)).lineLimit(4)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                HStack(spacing: 24) { buttons }.padding(.top, 8).tint(.white)
            }
            .padding(.leading, 90)
            .padding(.bottom, 60)
        }
        .frame(height: 860)
        .frame(maxWidth: .infinity)
    }
}

/// "2024 · 2 h 46 min · IMDb 8.4 · Science Fiction, Adventure"
@MainActor
private func titleDetails(_ item: EmbyItem?, model: AppModel, kind: String) -> String {
    guard let item else { return "" }
    let minutes = item.runTimeTicks.map { Int($0 / 600_000_000) }
    let length = kind == "Movie" ? minutes.map { $0 >= 60 ? "\($0 / 60) h \($0 % 60) min" : "\($0) min" } : nil
    let rating = model.library.ratings?.rating(item.imdb).map(IMDbRatings.label)
    let genres = item.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: ", ") }
    return [item.productionYear.map(String.init), length, rating, genres].compactMap(\.self).joined(separator: " · ")
}

// MARK: - Film

struct TVMovieView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let route: MovieRoute
    @Binding var playing: PlayerItem?

    @State private var item: EmbyItem?
    @State private var similar: [Card] = []
    @State private var loading = false
    @State private var playError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                TVTitleHeader(backdrop: item.flatMap { model.emby?.backdropURL(for: $0, width: 1920)?.absoluteString },
                              logo: item.flatMap { model.emby?.logoURL(for: $0, width: 900)?.absoluteString },
                              title: route.title, details: titleDetails(item, model: model, kind: "Movie"),
                              overview: item?.overview) {
                    Button(action: play) {
                        Label(loading ? "Starting…" : playLabel, systemImage: "play.fill").padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    .disabled(loading)
                    if let progress = item?.resumeFraction {
                        ProgressBar(value: progress).frame(width: 220)
                    }
                }
                if let item, !(item.people ?? []).isEmpty {
                    TVCastRow(people: item.people ?? [])
                }
                if !similar.isEmpty {
                    TVPosterRow(title: "More Like This", cards: similar) { card in
                        // Pushes another page on the same stack.
                        selected = card
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .scrollClipDisabled()
        .navigationDestination(item: $selected) { card in
            if card.kind == "Series" {
                TVShowView(route: ShowRoute(id: card.id, title: card.title), playing: $playing)
            } else {
                TVMovieView(route: MovieRoute(id: card.id, title: card.title), playing: $playing)
            }
        }
        .task { await load() }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    @State private var selected: Card?

    private var playLabel: String {
        guard item?.resumeTicks != nil else { return "Play" }
        return item?.timeLeft.map { "Continue · \($0)" } ?? "Continue"
    }

    private func load() async {
        model.warmUp(route.id, kind: "Movie", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        guard let emby = model.emby else { return }
        async let detail = emby.details(route.id)
        async let like = emby.similar(to: route.id, limit: 20)
        item = await detail
        similar = await like
            .filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: 480) }
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

// MARK: - Show

/// A show: Play (or Resume) the right episode, then the seasons as tabs
/// over a row of episodes, the cast, and more like it.
struct TVShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    @State private var data: AppModel.ShowData?
    @State private var details: EmbyItem?
    @State private var similar: [Card] = []
    @State private var season: Int?
    @State private var loadingItem: String?
    @State private var playError: String?
    @State private var selected: Card?

    private var upNext: EmbyItem? {
        // The list's copy: it has the running time, and what you just
        // watched is applied to it straight away.
        if let id = route.episodeId ?? data?.nextUp?.id,
           let episode = data?.episodes.first(where: { $0.id == id }) { return episode }
        return data?.nextUp
    }

    private var seasons: [Int] {
        var seen = Set<Int>()
        return (data?.episodes ?? []).compactMap { $0.parentIndexNumber ?? 0 }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let show = details ?? data?.show
        let shownSeason = season ?? upNext?.parentIndexNumber ?? seasons.first
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                TVTitleHeader(backdrop: show.flatMap { model.emby?.backdropURL(for: $0, width: 1920)?.absoluteString },
                              logo: show.flatMap { model.emby?.logoURL(for: $0, width: 900)?.absoluteString },
                              title: route.title, details: titleDetails(show, model: model, kind: "Series"),
                              overview: show?.overview) {
                    Button { playMain() } label: {
                        Label(loadingItem == mainId ? "Starting…" : mainLabel, systemImage: "play.fill").padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    .disabled(loadingItem != nil)
                }
                if seasons.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(seasons, id: \.self) { number in
                                Button(ShowView.seasonName(number)) { season = number }
                                    .buttonStyle(TVChipStyle(selected: number == shownSeason))
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .tvRowScroll()
                }
                let episodes = (data?.episodes ?? []).filter { ($0.parentIndexNumber ?? 0) == (shownSeason ?? 0) }
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        if seasons.count <= 1 { TVRowTitle("Episodes") }
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 40) {
                                    ForEach(episodes, id: \.id) { episode in
                                        TVEpisodeCard(episode: episode, card: model.emby?.card(for: episode, landscape: true, width: 960),
                                                      upNext: episode.id == upNext?.id, loading: loadingItem == episode.id) {
                                            play(episode.id, kind: "Episode")
                                        }
                                        .id(episode.id)
                                    }
                                }
                                .padding(.vertical, 24)
                            }
                            .tvRowScroll()
                            .onAppear {
                                // The episode you're up to, in view with the row's margin.
                                if let id = upNext?.id, id != episodes.first?.id { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                } else if data == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let people = show?.people, !people.isEmpty {
                    TVCastRow(people: people)
                }
                if !similar.isEmpty {
                    TVPosterRow(title: "More Like This", cards: similar) { selected = $0 }
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .scrollClipDisabled()
        .navigationDestination(item: $selected) { card in
            if card.kind == "Series" {
                TVShowView(route: ShowRoute(id: card.id, title: card.title), playing: $playing)
            } else {
                TVMovieView(route: MovieRoute(id: card.id, title: card.title), playing: $playing)
            }
        }
        .task { await load() }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    private var mainId: String { upNext?.id ?? route.episodeId ?? route.id }

    private var mainLabel: String {
        guard let upNext else { return "Play" }
        let verb = upNext.resumeTicks == nil ? "Play" : "Continue"
        return upNext.episodeCode.map { "\(verb) \($0)" } ?? verb
    }

    private func load() async {
        if let episode = route.episodeId {
            model.warmUp(episode, kind: "Episode", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        } else {
            model.warmUp(route.id, kind: "Series", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        }
        data = model.cachedShow(route.id)
        guard let emby = model.emby else { return }
        async let detail = emby.details(route.id)
        async let like = emby.similar(to: route.id, limit: 20)
        if let fresh = await model.loadShow(route.id) { data = fresh }
        details = await detail
        similar = await like
            .filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: 480) }
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

/// An episode: its picture (with progress), number, name and length.
private struct TVEpisodeCard: View {
    let episode: EmbyItem
    let card: Card?
    let upNext: Bool
    let loading: Bool
    let action: () -> Void

    var body: some View {
        // Room below the picture for its lift.
        VStack(alignment: .leading, spacing: 22) {
            Button(action: action) {
                CoverImage(images: card?.images ?? [], title: episode.name)
                    .frame(width: 440, height: 248)
                    .overlay(alignment: .bottom) {
                        if let progress = episode.resumeFraction {
                            ProgressBar(value: progress).padding(14)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if episode.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white).padding(12)
                                .shadow(radius: 4)
                        }
                    }
                    .overlay { if loading { ProgressView() } }
                    .tvArtwork()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(episode.indexNumber.map { "Episode \($0), " } ?? "")\(episode.name)")
            VStack(alignment: .leading, spacing: 4) {
                Text([episode.indexNumber.map { "Episode \($0)" }, upNext ? "Up Next" : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(upNext ? Color.white : .secondary)
                Text(episode.name).font(.callout.weight(.medium)).lineLimit(1)
                if let minutes = episode.runTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
                    Text("\(minutes) min").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 440, alignment: .leading)
            .accessibilityHidden(true)
        }
    }
}

/// Cast & Crew: round photos with name and part.
private struct TVCastRow: View {
    @Environment(AppModel.self) private var model
    let people: [EmbyItem.Person]

    var body: some View {
        let shown = Array(people.filter { ["Actor", "Director", "GuestStar", "Writer", "Producer"].contains($0.type ?? "") }.prefix(20))
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle("Cast & Crew")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 12) {
                            Button {} label: {
                                ZStack {
                                    Circle().fill(.quaternary)
                                    Text(initials(person.name)).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                                    if let url = model.emby?.personImageURL(person, width: 360) {
                                        CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: "")
                                            .clipShape(.circle)
                                    }
                                }
                                .frame(width: 170, height: 170)
                                .clipShape(.circle)
                            }
                            .buttonStyle(.borderless)
                            .clipShape(.circle)
                            VStack(spacing: 2) {
                                Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(person.role.flatMap { $0.isEmpty ? nil : $0 } ?? person.type.map(Self.label) ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 200)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 20)
            }
            .tvRowScroll()
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private static func label(_ type: String) -> String {
        switch type {
        case "GuestStar": "Guest Star"
        default: type
        }
    }
}
#endif
