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
/// season bar scrolls up under the header and then stays pinned: the
/// season you're in is underlined and kept in view, tapping one jumps
/// straight to it, and a filter menu sits at its end. Everything is local,
/// so filtering and jumping are instant.
struct ShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let route: ShowRoute
    @Binding var playing: PlayerItem?

    /// The page as last seen (or fetched ahead), complete from the first
    /// frame; brought up to date in the background.
    private var data: AppModel.ShowData? { model.showState(route.id).value }
    @State private var error: String?
    @State private var scrolledToUpNext = false
    /// The viewer has scrolled the page: it's never moved for them after.
    @State private var userScrolled = false
    @State private var unwatchedOnly = false
    @State private var newestFirst = false
    /// Episodes currently on screen, to highlight the season in view.
    /// Rows on screen, kept outside SwiftUI's state: each row scrolling in
    /// or out used to re-run the whole page (regrouping every episode).
    /// Only the season in view is published, when it changes.
    @State private var visible = VisibleRows()
    @State private var seasonOnScreen: Int?
    @State private var pin: PagePin?
    /// The season just jumped to: highlighted until you scroll yourself,
    /// even when it's too short to fill the screen.
    @State private var jumpedTo: Int?
    /// Where the season bar pins (the bottom of the navigation bar).
    @State private var pinY: CGFloat = 0

    private var thumbWidth: Int { Int(Layout.searchThumbWide * 2 * displayScale) }

    /// The episode the main button plays: the one being resumed, or next.
    private var upNext: EmbyItem? {
        // The list's copy: it has the running time, and what you just
        // watched is applied to it straight away.
        if let id = route.episodeId ?? data?.nextUp?.id,
           let episode = data?.episodes.first(where: { $0.id == id }) { return episode }
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
        return Self.specialsLast(order).map { (number: $0, episodes: grouped[$0] ?? []) }
    }

    /// Specials (season 0) after the last season, as in the Apple TV app
    /// (first, the page opened on them, not on the show's own seasons).
    static func specialsLast(_ seasons: [Int]) -> [Int] {
        seasons.filter { $0 != 0 } + (seasons.contains(0) ? [0] : [])
    }

    /// The season with the most episodes on screen (rows peeking out from
    /// under the bars shouldn't win).
    private func seasonInView(_ seasons: [(number: Int, episodes: [EmbyItem])]) -> Int? {
        if let jumpedTo, seasons.contains(where: { $0.number == jumpedTo }) { return jumpedTo }
        return seasonOnScreen
    }

    private func rowAppeared(_ episode: EmbyItem) {
        guard visible.ids.insert(episode.id).inserted else { return }
        visible.bySeason[episode.parentIndexNumber ?? 0, default: 0] += 1
        publishSeason()
    }

    private func rowDisappeared(_ episode: EmbyItem) {
        guard visible.ids.remove(episode.id) != nil else { return }
        visible.bySeason[episode.parentIndexNumber ?? 0, default: 0] -= 1
        publishSeason()
    }

    private func publishSeason() {
        let top = visible.bySeason.filter { $0.value > 0 }
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        if top != seasonOnScreen { seasonOnScreen = top }
    }

    var body: some View {
        let seasons = seasons
        GeometryReader { page in
        ScrollViewReader { proxy in
            List {
                header
                    .listRowInsets(EdgeInsets())
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    // Up under the (see-through) top bar, as on a film's page
                    // and in the Apple TV app; the list keeps its top inset,
                    // so the season tabs still pin just under the back button.
                    .padding(.top, -page.safeAreaInsets.top)
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
                                           upNext: episode.id == upNext?.id)
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                            .onAppear { rowAppeared(episode) }
                            .onDisappear { rowDisappeared(episode) }
                        }
                    }
                    if data != nil, seasons.isEmpty {
                        Text(unwatchedOnly ? "You've watched every episode." : "No episodes yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    if data != nil {
                        #if os(iOS)
                        SeasonBar(seasons: seasons.map(\.number), current: seasonInView(seasons), pinY: pinY,
                                  unwatchedOnly: $unwatchedOnly, newestFirst: $newestFirst) { number in
                            jumpedTo = number
                            // Followed by the eye (it jumped there in one frame).
                            withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo("season-\(number)", anchor: .top) }
                        }
                        #else
                        filterBar(proxy, seasons: seasons)
                        #endif
                    }
                }
                if data == nil, error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
                }
            }
            .listStyle(.plain)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    jumpedTo = nil
                    userScrolled = true
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, top in pinY = top }
            .onChange(of: data?.episodes.count) { _, _ in
                // Opened for one episode (Continue Watching, say): that
                // episode in view. A show otherwise opens at its top (the
                // picture and story), as in the Apple TV app, and never
                // moves once the viewer has started scrolling.
                guard let id = route.episodeId, !scrolledToUpNext, !userScrolled else { return }
                scrolledToUpNext = true
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !userScrolled else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        }
        #if os(iOS)
        // No bar over the art (a black one with the show's name sat over it).
        .toolbarBackground(.hidden, for: .navigationBar)
        #else
        .navigationTitle(route.title)
        #endif
        .inlineTitle()
        .preparesAhead(mainTarget, at: .page)
        .task {
            // Draw what's already here at once, then refresh behind it.
            if pin == nil { pin = model.pin(route.id) }
            _ = model.cachedShow(route.id)
            if await model.loadShow(route.id) == nil, data == nil {
                error = "Couldn't load this show."
            }
        }
        .onAppear { model.showOnScreen = route.id }
        .onDisappear { if model.showOnScreen == route.id { model.showOnScreen = nil } }
    }

    @ViewBuilder private var header: some View {
        let show = data?.show
        VStack(alignment: .leading, spacing: 14) {
            TitleHero(backdrop: show.flatMap { model.emby?.backdropURL(for: $0, width: AppModel.pageBackdropWidth) },
                      logo: show.flatMap { model.emby?.logoURL(for: $0, width: AppModel.pageLogoWidth) },
                      title: route.title, line: showLine, height: 0.95) {
                HStack(alignment: .top, spacing: 12) {
                    PlayCapsule(label: mainLabel,
                                progress: upNext?.resumeFraction, left: upNext?.timeLeft) { playMain() }
                    #if os(iOS)
                    MyListButton(item: show)
                    #endif
                }
            }
            if let overview = show?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    /// "Show · 2016 · IMDb 7.3"
    private var showLine: String {
        let show = data?.show
        let rating = model.library.ratings?.rating(show?.imdb).map(IMDbRatings.label)
        return ["Show", show?.productionYear.map(String.init), rating].compactMap(\.self).joined(separator: " · ")
    }

    #if os(tvOS)
    /// Apple TV: filters, then a button per season (the one in view
    /// highlighted and kept in view). Jumps are instant.
    private func filterBar(_ proxy: ScrollViewProxy, seasons: [(number: Int, episodes: [EmbyItem])]) -> some View {
        let current = seasonInView(seasons)
        return ScrollViewReader { strip in
            ScrollView(.horizontal) {
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
                            .id(season.number)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: current) { _, now in
                if let now { withAnimation { strip.scrollTo(now, anchor: .center) } }
            }
        }
        .background(.regularMaterial)
        .listRowInsets(EdgeInsets())
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(TVChipStyle(selected: selected))
    }
    #endif


    /// "Continue S4 E2" partway through, else "Play S4 E3".
    private var mainLabel: String {
        guard let upNext else { return "Play" }
        let verb = upNext.resumeTicks == nil ? "Play" : "Continue"
        return upNext.episodeCode.map { "\(verb) \($0)" } ?? verb
    }

    static func seasonName(_ number: Int) -> String { number == 0 ? "Specials" : "Season \(number)" }
    private static func shortSeasonName(_ number: Int) -> String { number == 0 ? "Specials" : "S\(number)" }

    private func card(_ episode: EmbyItem) -> Card? {
        model.emby?.card(for: episode, landscape: true, width: thumbWidth)
    }

    private func playMain() {
        if case let .playable(id, kind) = mainTarget { play(id, kind: kind ?? "Series") }
    }

    private var mainTarget: Target { .showMain(route.id, upNext: upNext?.id) }

    private func play(_ id: String, kind: String) {
        playing = .film(model.tap(id, kind: kind, title: route.title, show: route.id))
    }
}

#if os(iOS)
/// Pinned under the navigation bar: the seasons as tabs, the one you're in
/// underlined and slid into view as you scroll, and a filter menu at the
/// end. As it reaches the top the area behind the navigation bar darkens
/// with it into one black header, and episodes fade out softly beneath.
private struct SeasonBar: View {
    let seasons: [Int]
    let current: Int?
    /// Where the bar pins: the list's top inset (the list starts at the
    /// top of the screen, under the navigation bar).
    let pinY: CGFloat
    @Binding var unwatchedOnly: Bool
    @Binding var newestFirst: Bool
    var jump: (Int) -> Void
    @Namespace private var underline
    /// 0 while the bar is well down the page, 1 once pinned.
    @State private var docked: CGFloat = 0

    private var filtered: Bool { unwatchedOnly || newestFirst }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { strip in
                ScrollView(.horizontal) {
                    HStack(spacing: 26) {
                        ForEach(seasons, id: \.self) { number in
                            tab(number)
                        }
                    }
                    .padding(.horizontal, 20)
                    .animation(.snappy(duration: 0.3), value: current)
                }
                .scrollIndicators(.hidden)
                .mask {
                    // Tabs fade at the edges instead of being cut off; the
                    // padding keeps the first and last clear of the fade.
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                    }
                }
                .onAppear {
                    if let current { strip.scrollTo(current, anchor: .center) }
                }
                .onChange(of: current) { _, now in
                    guard let now else { return }
                    withAnimation(.snappy(duration: 0.35)) { strip.scrollTo(now, anchor: .center) }
                }
            }
            filterMenu
        }
        .background {
            Color.black
                .overlay(alignment: .top) {
                    // Up behind the navigation bar, fading in as the bar
                    // arrives so the two become one header.
                    Color.black.frame(height: pinY).offset(y: -pinY).opacity(docked)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                        .offset(y: 22)
                }
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y in
            docked = min(max(1 - (y - pinY) / 90, 0), 1)
        }
        .listRowInsets(EdgeInsets())
    }

    private func tab(_ number: Int) -> some View {
        let selected = number == current
        return Button { jump(number) } label: {
            Text(ShowView.seasonName(number))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary) // not the header's grey
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    if selected {
                        Capsule()
                            .fill(.white)
                            .frame(height: 3)
                            .padding(.bottom, 6)
                            .matchedGeometryEffect(id: "current", in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(number)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Unwatched Only", systemImage: "eye.slash", isOn: $unwatchedOnly)
            Toggle("Newest First", systemImage: "arrow.up.arrow.down", isOn: $newestFirst)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body.weight(.semibold))
                .foregroundStyle(filtered ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding(.trailing, 12)
        .accessibilityLabel(filtered ? "Filters, on" : "Filters")
    }
}
#endif

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(images: card?.images ?? [], title: episode.name)
                .frame(width: Layout.searchThumbWide * 1.25, height: Layout.searchThumbWide * 1.25 * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress = episode.resumeFraction {
                        GeometryReader { geo in
                            Capsule().fill(.white).frame(width: geo.size.width * progress, height: 3)
                        }
                        .frame(height: 3)
                        .padding(4)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if upNext { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.9), lineWidth: 2) }
                }
                // On the picture, so every row is the same height (a line
                // over the title made that row 2 points taller, and the list
                // moved when Up Next did).
                .overlay(alignment: .topLeading) {
                    if upNext {
                        Text("UP NEXT").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: .capsule)
                            .padding(6)
                    }
                }
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

/// Which episode rows are on screen, and how many per season (a plain
/// object: changing it doesn't redraw anything).
private final class VisibleRows {
    var ids: Set<String> = []
    var bySeason: [Int: Int] = [:]
}
