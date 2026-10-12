import SwiftUI

/// Home, like the best streaming apps' (Apple TV, Netflix, HBO Max): a
/// full-bleed hero under the status bar moving through the featured titles
/// (the title, what it is, Play and a details button, page dots), Continue
/// Watching as wide pictures with the progress under them, then rows of
/// posters with nothing but the artwork. Posters open the title's page;
/// Continue Watching plays (press and hold for the page). Settings sit
/// behind the gear, out of the tab bar.
/// Rows render from the on-device cache immediately; card boxes are sized
/// before images load.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    @Binding var playing: PlayerItem?
    @State private var loadingCard: String?
    @State private var playError: String?
    @State private var addingEmby = false
    @State private var showingSettings = false
    @State private var path: [ShowRoute] = []
    @State private var movie: MovieRoute?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // Not lazy: there are only a dozen rows (each scrolls lazily
                // itself), and a lazy stack adding a row as the page slides
                // back after pull to refresh stops it halfway, stuck down.
                VStack(alignment: .leading, spacing: 30) {
                    let heroes = model.spotlight.isEmpty ? (model.featured.map { [$0] } ?? []) : model.spotlight
                    if !heroes.isEmpty {
                        HomeHero(items: heroes, loadingCard: loadingCard, play: { play($0) }, open: { open($0) })
                    } else if model.homePending {
                        // The first Home is on its way: the hero's space is
                        // kept, so Continue Watching (shown as soon as it's
                        // known) doesn't move down when the hero comes.
                        HomeHero.placeholder
                    } else {
                        Color.clear.frame(height: 100)
                    }
                    if visibleRows.isEmpty, model.featured == nil, !model.homePending { emptyState }
                    ForEach(visibleRows) { row in
                        if row.title == "Continue Watching" {
                            ContinueRow(row: row, loadingCard: loadingCard, play: { play($0) }, open: { open($0) })
                        } else {
                            PosterRow(title: row.title, cards: row.cards, open: { open($0) }, play: { play($0) })
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            // The hero runs up under the status bar, like the TV apps'.
            .ignoresSafeArea(edges: .top)
            .background(Color.black)
            .scrollIndicators(.hidden)
            // The name pages opened from here go back to.
            .navigationTitle("Home")
            #if os(iOS)
            // Compact, with no title over the hero (like the TV app's
            // Home): a large one sat on the picture, and on Continue
            // Watching while the first Home was still on its way.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            // Pulling down is one of the moments Home changes (like
            // Netflix's): everything built afresh, shown when it's ready.
            .refreshableOnPhone { await model.refreshHome(cardWidth: pixelWidth) }
            .sheet(isPresented: $addingEmby) { AddEmbyView() }
            .sheet(isPresented: $showingSettings) { SettingsView(asSheet: true) }
            .navigationDestination(for: ShowRoute.self) { ShowView(route: $0, playing: $playing) }
            .navigationDestination(item: $movie) { MovieView(route: $0, playing: $playing) }
            // The first thing in Continue Watching opens the moment it's tapped.
            .task(id: model.rows.first?.cards.first?.id) { warmFirst() }
            .onAppear { warmFirst() }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
        // On the stack, not its first page: coming back from a title's page
        // isn't Home appearing. Home chosen from another tab (or at launch)
        // is: what was built meanwhile goes on before it's drawn, then the
        // next one is built in the background, to wait for the next time.
        .onAppear { model.homeAppeared() }
        .task { await model.loadHome(cardWidth: pixelWidth) }
    }

    private var visibleRows: [HomeRow] {
        model.rows.filter { !prefs.hiddenRows.contains($0.title) }
    }

    private var pixelWidth: Int { Int(Layout.posterWidth * displayScale) }

    @ViewBuilder private var emptyState: some View {
        if model.sources.emby == nil {
            ContentUnavailableView {
                Label("No Emby server", systemImage: "film.stack")
            } description: {
                Text("Add your Emby server to see your movies and shows here.")
            } actions: {
                Button("Add Emby server") { addingEmby = true }.buttonStyle(.glassProminent)
            }
        } else if let error = model.homeError {
            ContentUnavailableView("Couldn't load Emby", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            ContentUnavailableView("All rows are hidden", systemImage: "eye.slash", description: Text("Turn rows back on in Settings."))
        }
    }

    private func warmFirst() {
        // Every show in Continue Watching, and the first few below, open
        // fully drawn (saved ones are only checked for changes).
        let resuming = model.rows.first { $0.title == "Continue Watching" }?.cards ?? []
        let below = model.rows.filter { $0.title != "Continue Watching" }.prefix(1).flatMap { $0.cards.prefix(3) }
        model.prefetchShows((resuming + below).filter { $0.kind == "Series" }.map(\.id))
        guard let card = (model.rows.first { $0.title == "Continue Watching" } ?? model.rows.first)?.cards.first else { return }
        if let episode = card.episodeId {
            model.warmUp(episode, kind: "Episode", options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        } else if card.kind != "Series" {
            model.warmUp(card.id, kind: card.kind, options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        }
    }

    /// A title's page (a show at the episode you're up to).
    private func open(_ card: Card) {
        if card.kind == "Series" {
            path.append(ShowRoute(id: card.id, title: card.title, episodeId: card.episodeId))
        } else {
            movie = MovieRoute(id: card.id, title: card.title)
        }
    }

    /// Straight to the player: the episode being resumed, or the title.
    private func play(_ card: Card) {
        guard loadingCard == nil else { return }
        loadingCard = card.id
        Task {
            defer { loadingCard = nil }
            do {
                if let episode = card.episodeId {
                    playing = .vod(try await model.playback(itemId: episode, kind: "Episode"))
                } else {
                    playing = .vod(try await model.playback(itemId: card.id, kind: card.kind))
                }
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

/// The top of Home: the featured titles full-bleed, one at a time (swipe or
/// wait), each with its name, what it is, Play and a details button.
private struct HomeHero: View {
    let items: [Featured]
    let loadingCard: String?
    let play: (Card) -> Void
    let open: (Card) -> Void
    @State private var index = 0
    @State private var width: CGFloat = 393

    /// The hero's space while the first Home is built: the same height (a
    /// page and its dots), with a spinner.
    static var placeholder: some View {
        VStack(spacing: 14) {
            Color.clear
                .aspectRatio(1 / 1.3, contentMode: .fit)
                .overlay { ProgressView() }
            Color.clear.frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    page(item).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // A fixed size, so pages line up exactly (a size worked out from
            // an aspect ratio left a sliver of the previous one showing).
            .frame(width: width, height: (width * 1.3).rounded())
            if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(i == index ? 0.9 : 0.3))
                            .frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: index)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Other titles (Home changed at a moment): from the first, never
        // a page past the end (a blank one).
        .onChange(of: items.map(\.card.id)) { index = 0 }
        // Moves on by itself every eight seconds.
        .task(id: index) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
    }

    private func page(_ item: Featured) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
                .overlay { CoverImage(images: [CardImage(url: item.backdrop, contain: false)], title: item.card.title) }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                           .init(color: .clear, location: 0.5), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { open(item.card) }
            VStack(spacing: 12) {
                // The same space whether it's the logo, the name, or the
                // logo still on its way.
                HeroTitle(logo: item.logo, title: item.card.title)
                    .frame(minHeight: 96, alignment: .bottom)
                Text(item.details)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 12) {
                    Button { play(item.card) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 150, height: 44)
                            .opacity(loadingCard == item.card.id ? 0 : 1)
                            .overlay { if loadingCard == item.card.id { ProgressView().tint(.black) } }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.white, in: .capsule)
                    GlassIconButton(systemName: "info", label: "Details") { open(item.card) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A title's logo when the server has one, else its name, centred.
struct HeroTitle: View {
    let logo: String?
    let title: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 96)
                    .accessibilityLabel(title)
            } else if logo == nil || failed {
                Text(title)
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            } else {
                Color.clear.frame(width: 200, height: 72)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 10)
        .task(id: logo) {
            guard let logo, let url = URL(string: logo) else { return }
            if let loaded = try? await ImagePipeline.shared.image(for: url) { image = loaded } else { failed = true }
        }
    }
}

/// A row heading in Apple's style.
private struct RowTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Continue Watching: wide pictures, and under each a play mark, how far
/// through, the episode and what's left. Tap plays; press and hold for the
/// show or film.
private struct ContinueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let row: HomeRow
    let loadingCard: String?
    let play: (Card) -> Void
    let open: (Card) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowTitle(title: row.title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.cards) { card in
                        Button { play(card) } label: { cardView(card) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(card.kind == "Series" ? "Go to Show" : "Details", systemImage: "info.circle") { open(card) }
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        // The title you're most likely to resume, opened in the background
        // a second after Home settles (on Wi-Fi), so Play starts at once.
        .task(id: row.cards.first?.id) {
            guard let card = row.cards.first else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, NetworkStatus.shared.knownUnmetered else { return }
            model.warmUp(card.episodeId ?? card.id, kind: card.episodeId != nil ? "Episode" : card.kind,
                         options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
        }
    }

    private func cardView(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(images: card.images, title: card.title)
                .frame(width: 280, height: 158)
                .overlay(alignment: .bottomLeading) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }
                .overlay { if loadingCard == card.id { ProgressView().tint(.white) } }
                .clipShape(.rect(cornerRadius: 14))
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.caption2)
                // Always there (an empty track when not started), so the
                // text beside it doesn't move when progress comes.
                ProgressBar(value: (card.progress ?? 0) / 100).frame(width: 40, height: 4)
                Text(card.subtitle ?? "").font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(width: 280, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays it")
    }
}

/// A row of posters: the artwork only (it carries the title). Tap opens
/// the title; press and hold to play.
private struct PosterRow: View {
    @Environment(AppModel.self) private var model
    @State private var pending: [String: Task<Void, Never>] = [:]
    let title: String
    let cards: [Card]
    let open: (Card) -> Void
    let play: (Card) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowTitle(title: title)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(cards) { card in
                        Button { open(card) } label: {
                            CoverImage(images: card.images, title: card.title)
                                .frame(width: Layout.posterWidth, height: Layout.posterWidth * 1.5)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play", systemImage: "play.fill") { play(card) }
                        }
                        // Really on screen a moment (not scrolling past, not just
                        // laid out ahead): fetch its page and pictures, so a
                        // tap opens it complete.
                        .onScrollVisibilityChange(threshold: 0.6) { visible in
                            pending[card.id]?.cancel()
                            pending[card.id] = visible ? Task {
                                try? await Task.sleep(for: .milliseconds(600))
                                guard !Task.isCancelled, NetworkStatus.shared.knownUnmetered else { return }
                                model.prefetchTitle(card)
                            } : nil
                        }
                        .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A thin white progress line on a dim track.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        #if os(tvOS)
        .frame(height: 6)
        #else
        .frame(height: 4)
        #endif
        .accessibilityHidden(true)
    }
}

/// Tries each image candidate in order and moves on when one fails, so a
/// stale or missing image never leaves a blank cover.
struct CoverImage: View {
    let images: [CardImage]
    let title: String

    @State private var image: UIImage?
    @State private var contain = false
    @State private var failed = false

    init(images: [CardImage], title: String) {
        self.images = images
        self.title = title
        // Already decoded (a row coming back, a filter switched): drawn at
        // once, not blank and then faded in.
        let hit = images.first.flatMap { URL(string: $0.url) }.flatMap { ImagePipeline.shared.cached($0) }
        _image = State(initialValue: hit)
        _contain = State(initialValue: hit != nil && images.first?.contain == true)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contain ? .fit : .fill)
                    .transition(.opacity)
            } else if failed {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
        .clipped()
        .task(id: images.first?.url) {
            for candidate in images {
                guard let url = URL(string: candidate.url) else { continue }
                if let hit = ImagePipeline.shared.cached(url) {
                    contain = candidate.contain
                    image = hit
                    return
                }
                if let loaded = try? await ImagePipeline.shared.image(for: url) {
                    // The card moved on to another picture meanwhile: not this one.
                    guard !Task.isCancelled else { return }
                    contain = candidate.contain
                    withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}
