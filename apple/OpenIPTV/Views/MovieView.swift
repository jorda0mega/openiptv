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

    @State private var loading = false
    @State private var playError: String?
    @State private var pin: PagePin?

    @State private var expanded = false
    /// Someone from Cast & Crew, whose page is open.
    @State private var person: EmbyItem.Person?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TitleHero(backdrop: item.flatMap { model.emby?.backdropURL(for: $0, width: AppModel.pageBackdropWidth) },
                          logo: item.flatMap { model.emby?.logoURL(for: $0, width: AppModel.pageLogoWidth) },
                          title: route.title, line: genreLine) {
                    HStack(alignment: .top, spacing: 12) {
                        PlayCapsule(label: playLabel, progress: item?.resumeFraction, left: item?.timeLeft,
                                    loading: loading, action: play)
                        #if os(iOS)
                        MyListButton(item: item)
                        #endif
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let overview = item?.overview, !overview.isEmpty {
                        // Two lines and MORE, as in the Apple TV app.
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(expanded ? nil : 2)
                            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(expanded ? "Shows less" : "Shows the whole story")
                        if !expanded, overview.count > 90 {
                            Button("MORE") { withAnimation(.snappy) { expanded = true } }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                                .accessibilityLabel("More of the story")
                        }
                    }
                    if !facts.isEmpty {
                        Text(facts).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                CastRow(people: item?.people ?? []) { person = $0 }
                if !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("More Like This").font(.title3.weight(.bold)).padding(.horizontal, 20)
                            .accessibilityAddTraits(.isHeader)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(similar) { card in moreLikeThis(card) }
                            }
                            .padding(.horizontal, 20)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        // The art runs up under the navigation bar.
        .ignoresSafeArea(edges: .top)
        .background(Color.black)
        .scrollIndicators(.hidden)
        .inlineTitle()
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task { await load() }
        .navigationDestination(item: $person) { PersonView(person: $0, playing: $playing) }
        .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
        .onAppear { model.movieOnScreen = route.id }
        .onDisappear { if model.movieOnScreen == route.id { model.movieOnScreen = nil } }
    }

    /// "Movie · Science Fiction · Adventure"
    private var genreLine: String {
        (["Movie"] + (item?.genres ?? []).prefix(2)).joined(separator: " · ")
    }

    /// "2024 · 2 h 46 min · IMDb 8.4 · 1.2M ratings"
    private var facts: String {
        guard let item else { return "" }
        let minutes = item.runTimeTicks.map { Int($0 / 600_000_000) }
        let length = minutes.map { $0 >= 60 ? "\($0 / 60) h \($0 % 60) min" : "\($0) min" }
        let rating = model.library.ratings?.rating(item.imdb).map(IMDbRatings.detail)
        return [item.productionYear.map(String.init), length, rating].compactMap(\.self).joined(separator: " · ")
    }

    private var playLabel: String { item?.resumeTicks == nil ? "Play" : "Continue" }


    @ViewBuilder private func moreLikeThis(_ card: Card) -> some View {
        let label = CoverImage(images: card.images, title: card.title)
            .frame(width: Layout.posterWidth, height: Layout.posterWidth * 1.5)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityLabel(card.title)
        if card.kind == "Series" {
            NavigationLink(value: ShowRoute(id: card.id, title: card.title)) { label }.buttonStyle(.plain)
        } else {
            NavigationLink(value: MovieRoute(id: card.id, title: card.title)) { label }.buttonStyle(.plain)
        }
    }

    /// The page as last seen (or fetched ahead), complete from the first
    /// frame; brought up to date in the background.
    private var item: EmbyItem? { model.movieState(route.id).value?.item }

    private var similar: [Card] {
        guard let emby = model.emby, let data = model.movieState(route.id).value else { return [] }
        let width = Int(Layout.posterWidth * displayScale)
        return data.similar.filter { $0.userData?.played != true }
            .map { emby.card($0, context: .poster, shape: .portrait, width: width) }
    }

    private func load() async {
        model.warmUp(route.id, kind: "Movie", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        if pin == nil { pin = model.pin(route.id) }
        _ = model.cachedMovie(route.id)
        _ = await model.loadMovie(route.id)
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
