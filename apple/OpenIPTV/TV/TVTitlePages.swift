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

/// "+" beside Play, as in the TV app: puts the title on My List (a tick
/// once it's there).
private struct TVMyListButton: View {
    @Environment(AppModel.self) private var model
    let item: EmbyItem?

    var body: some View {
        let on = item.map { model.isOnMyList($0.id, item: $0) } ?? false
        Button {
            if let item { model.toggleMyList(item, cardWidth: 480) }
        } label: {
            Image(systemName: on ? "checkmark" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .disabled(item == nil)
        .accessibilityLabel(on ? "Remove from My List" : "Add to My List")
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
    let route: MovieRoute
    @Binding var playing: PlayerItem?

    @State private var pin: PagePin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                TVTitleHeader(backdrop: item.flatMap { model.emby?.backdropURL(for: $0, width: AppModel.pageBackdropWidth)?.absoluteString },
                              logo: item.flatMap { model.emby?.logoURL(for: $0, width: AppModel.pageLogoWidth)?.absoluteString },
                              title: route.title, details: titleDetails(item, model: model, kind: "Movie"),
                              overview: item?.overview) {
                    Button(action: play) {
                        Label(playLabel, systemImage: "play.fill").padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    TVMyListButton(item: item)
                    if let progress = item?.resumeFraction {
                        ProgressBar(value: progress).frame(width: 220)
                    }
                }
                if let item, !(item.people ?? []).isEmpty {
                    TVCastRow(people: item.people ?? []) { person = $0 }
                }
                if !similar.isEmpty {
                    TVPosterRow(title: "More Like This", cards: similar, captions: .focused) { card in
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
        .navigationDestination(item: $person) { PersonView(person: $0, playing: $playing) }
        .task { await load() }
        .preparesAhead(.playable(id: route.id, kind: "Movie"), at: .page)
    }

    @State private var selected: Card?
    /// Someone from Cast & Crew, whose page is open.
    @State private var person: EmbyItem.Person?

    private var playLabel: String {
        guard item?.resumeTicks != nil else { return "Play" }
        return item?.timeLeft.map { "Continue · \($0)" } ?? "Continue"
    }

    /// The page as last seen (or fetched ahead when it was focused),
    /// complete from the first frame; brought up to date in the background.
    private var item: EmbyItem? { model.movieState(route.id).value?.item }

    private var similar: [Card] {
        guard let emby = model.emby, let data = model.movieState(route.id).value else { return [] }
        return data.similar.filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: 480) }
    }

    private func load() async {
        if pin == nil { pin = model.pin(route.id) }
        _ = model.cachedMovie(route.id)
        _ = await model.loadMovie(route.id)
    }

    private func play() {
        playing = .film(model.tap(route.id, kind: "Movie", title: route.title))
    }
}

// MARK: - Show

/// A show: Play (or Resume) the right episode, then the seasons as tabs
/// over a row of episodes, the cast, and more like it.
struct TVShowView: View {
    @Environment(AppModel.self) private var model
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    @State private var season: Int?
    @State private var pin: PagePin?
    @State private var selected: Card?
    /// Someone from Cast & Crew, whose page is open.
    @State private var person: EmbyItem.Person?
    /// Where the remote is in the season chips and the episode row: coming
    /// down into them, it lands on the season shown and the episode you're
    /// up to (it landed on the first chip, Specials, and on Episode 1).
    @FocusState private var focusedSeason: Int?
    @FocusState private var focusedEpisode: String?


    private var shownSeason: Int? { season ?? upNext?.parentIndexNumber ?? seasons.first }

    private var upNext: EmbyItem? {
        // The list's copy: it has the running time, and what you just
        // watched is applied to it straight away.
        if let id = route.episodeId ?? data?.nextUp?.id,
           let episode = data?.episodes.first(where: { $0.id == id }) { return episode }
        return data?.nextUp
    }

    /// The episode you're up to, when it's in this list.
    private func upNextIn(_ episodes: [EmbyItem]) -> String? {
        upNext.flatMap { next in episodes.contains { $0.id == next.id } ? next.id : nil }
    }

    private var seasons: [Int] {
        var seen = Set<Int>()
        return ShowView.specialsLast((data?.episodes ?? []).compactMap { $0.parentIndexNumber ?? 0 }.filter { seen.insert($0).inserted })
    }

    /// The page as last seen (or fetched ahead when it was focused),
    /// complete from the first frame; brought up to date in the background.
    private var data: AppModel.ShowData? { model.showState(route.id).value }

    private var similar: [Card] {
        guard let emby = model.emby else { return [] }
        return (data?.similar ?? []).filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: 480) }
    }

    var body: some View {
        let show = data?.show
        let shownSeason = shownSeason
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                TVTitleHeader(backdrop: show.flatMap { model.emby?.backdropURL(for: $0, width: AppModel.pageBackdropWidth)?.absoluteString },
                              logo: show.flatMap { model.emby?.logoURL(for: $0, width: AppModel.pageLogoWidth)?.absoluteString },
                              title: route.title, details: titleDetails(show, model: model, kind: "Series"),
                              overview: show?.overview) {
                    Button { playMain() } label: {
                        Label(mainLabel, systemImage: "play.fill").padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    TVMyListButton(item: show)
                }
                if seasons.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(seasons, id: \.self) { number in
                                Button(ShowView.seasonName(number)) { season = number }
                                    .buttonStyle(TVChipStyle(selected: number == shownSeason))
                                    .focused($focusedSeason, equals: number)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .tvRowScroll()
                    .focusSection()
                    .defaultFocus($focusedSeason, shownSeason)
                    .onChange(of: focusedSeason) { before, now in
                        // Coming in from above or below: the season shown.
                        if before == nil, let now, let shown = self.shownSeason, now != shown { focusedSeason = shown }
                    }
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
                                                      upNext: episode.id == upNext?.id) {
                                            play(episode.id, kind: "Episode")
                                        }
                                        .id(episode.id)
                                        .focused($focusedEpisode, equals: episode.id)
                                    }
                                }
                                .padding(.vertical, 24)
                            }
                            .tvRowScroll()
                            .focusSection()
                            .defaultFocus($focusedEpisode, upNextIn(episodes))
                            .onChange(of: focusedEpisode) { before, now in
                                // Coming in from above or below: the episode you're up to.
                                if before == nil, let now, let target = upNextIn(episodes), now != target { focusedEpisode = target }
                            }
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
                    TVCastRow(people: people) { person = $0 }
                }
                if !similar.isEmpty {
                    TVPosterRow(title: "More Like This", cards: similar, captions: .focused) { selected = $0 }
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
        .navigationDestination(item: $person) { PersonView(person: $0, playing: $playing) }
        .task { await load() }
        .preparesAhead(mainTarget, at: .page)
    }


    private var mainLabel: String {
        guard let upNext else { return "Play" }
        let verb = upNext.resumeTicks == nil ? "Play" : "Continue"
        return upNext.episodeCode.map { "\(verb) \($0)" } ?? verb
    }

    private func load() async {
        if pin == nil { pin = model.pin(route.id) }
        _ = model.cachedShow(route.id)
        _ = await model.loadShow(route.id)
    }

    private func playMain() {
        if case let .playable(id, kind) = mainTarget { play(id, kind: kind ?? "Series") }
    }

    private var mainTarget: Target { .showMain(route.id, upNext: upNext?.id) }

    private func play(_ id: String, kind: String) {
        playing = .film(model.tap(id, kind: kind, title: route.title, show: route.id))
    }
}

/// An episode: its picture (with progress), number, name and length.
private struct TVEpisodeCard: View {
    let episode: EmbyItem
    let card: Card?
    let upNext: Bool
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
                    .tvArtwork()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(episode.indexNumber.map { "Episode \($0), " } ?? "")\(episode.name)")
            VStack(alignment: .leading, spacing: 4) {
                // As in the TV app: "EPISODE 3", the name, two lines of the
                // story (their room kept, so every card is the same height).
                Text([episode.indexNumber.map { "Episode \($0)" }, upNext ? "Up Next" : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(upNext ? Color.white : .secondary)
                Text(episode.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(episode.overview ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
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
    /// Their page (films and shows with them in the library).
    var open: (EmbyItem.Person) -> Void = { _ in }

    var body: some View {
        let shown = Array(people.filter { ["Actor", "Director", "GuestStar", "Writer", "Producer"].contains($0.type ?? "") }.prefix(20))
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle("Cast & Crew")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 12) {
                            Button { open(person) } label: {
                                ZStack {
                                    Circle().fill(.quaternary)
                                    Text(initials(person.name)).font(.title2.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
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
