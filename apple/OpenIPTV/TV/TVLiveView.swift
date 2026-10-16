#if os(tvOS)
import SwiftUI

/// Live TV: the chosen shelf as grids of cards like the TV app's (a
/// channel shows its logo, name and what's on now; a game its title,
/// league and time, LIVE once it's started), under its name. The shelves
/// are in a list that slides out from the left, like tvOS's own sidebar:
/// Left from the first card (or the ‹ by the name) opens it, with Sports'
/// leagues under Sports; choosing one closes it, and so do Right and Menu.
struct TVLiveView: View {
    static let categoriesID = "tv:categories"

    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @AppStorage("tvLiveTab") private var chosen = ""
    /// Sports: Top, All, a league, or Channels.
    @AppStorage("tvSportsFilter") private var sportsFilter = ""
    @AppStorage("tvTab") private var tab = "home"
    @State private var listOpen = false
    @State private var sportsExpanded = false
    /// Briefly off after the list closes, so focus landing at the left
    /// edge doesn't open it again.
    @State private var edgeOn = true
    @FocusState private var listFocus: String?
    @FocusState private var edgeFocused: Bool

    /// The chosen shelf, or the first while none is (or it's gone).
    private var id: String {
        tabs.contains { $0.id == chosen } ? chosen : tabs.first?.id ?? ""
    }

    private var sports: TVSports.Choices? {
        model.shelf(LiveOrganizer.sportsID).map(TVSports.choices)
    }

    /// The chosen Sports filter, or the first.
    private var league: String {
        guard let choices = sports?.all else { return "" }
        return choices.contains(sportsFilter) ? sportsFilter : choices.first ?? ""
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 50) {
                        header
                        if tabs.isEmpty {
                            emptyState.frame(maxWidth: .infinity).padding(.top, 120)
                        } else {
                            content
                                .id(id + league)
                        }
                    }
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
                .disabled(listOpen)
                .overlay {
                    if listOpen { Color.black.opacity(0.55).ignoresSafeArea().allowsHitTesting(false) }
                }
                // Only with somewhere to go: an empty list would hide the tab
                // bar and leave nothing to focus, and Menu would quit the app.
                if edgeOn, !listOpen, !tabs.isEmpty { edge }
                if listOpen {
                    list.transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarVisibility(listOpen ? .hidden : .automatic, for: .tabBar)
            .onExitCommand(perform: listOpen ? { close() } : nil)
            .onChange(of: tabs.isEmpty) { _, empty in if empty, listOpen { close() } }
            .navigationDestination(for: LiveCountry.self) { country in
                TVSectionsPage(title: "\(LiveOrganizer.flag(country.code)) \(LiveOrganizer.countryName(country.code))",
                               sections: model.shelf(LiveOrganizer.internationalID)?.sections.filter { $0.country == country.code } ?? [],
                               playing: $playing)
            }
            .navigationDestination(for: LiveCategory.self) { category in
                TVSectionsPage(title: category.name, channels: model.channels(in: category.id, favorites: prefs.favorites),
                               playing: $playing)
                    .task { await model.refreshCategory(category.id) }
            }
        }
        .task(id: id) {
            if id == LiveOrganizer.sportsID { await model.refreshEvents() }
        }
    }

    // MARK: The page

    /// "‹ NFL" with "Sports" above it: where you are, and that Left opens
    /// the list.
    private var header: some View {
        let shelf = tabs.first { $0.id == id }?.title ?? "Live TV"
        let isSports = id == LiveOrganizer.sportsID
        return HStack(spacing: 24) {
            if !tabs.isEmpty {
                Button { open() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Live TV sections")
            }
            VStack(alignment: .leading, spacing: 2) {
                if isSports {
                    Text(shelf.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(isSports ? TVSports.title(league) : shelf)
                    .font(.title2.weight(.heavy))
            }
            Spacer()
        }
        .padding(.horizontal, 90)
    }

    @ViewBuilder private var content: some View {
        switch id {
        case AppModel.favoritesID:
            TVChannelGrid(title: "Favorites", entries: entries(prefs.favorites.map { model.current($0) }), playing: $playing)
        case AppModel.localID:
            if let area = prefs.area {
                TVChannelGrid(title: "Local · \(area.label)", entries: entries(model.localChannels(area)), playing: $playing)
            } else {
                ContentUnavailableView("Where are you?", systemImage: "location",
                                       description: Text("Set your area in Settings to see your local ABC, NBC, CBS, FOX, CW and PBS stations."))
            }
        case Self.categoriesID:
            TVCategoryList()
        case LiveOrganizer.sportsID:
            if let shelf = model.shelf(id) { TVSports(shelf: shelf, filter: league, playing: $playing) }
        case LiveOrganizer.internationalID:
            if let shelf = model.shelf(id) { TVCountryGrid(shelf: shelf) }
        default:
            if let shelf = model.shelf(id) {
                ForEach(shelf.sections) { section in
                    TVChannelGrid(title: shelf.sections.count > 1 ? section.title : shelf.title, entries: section.entries,
                                  playing: $playing)
                }
            } else if model.liveLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
            }
        }
    }

    /// No shelves yet: why, and a button to fix it (so there's always
    /// something to focus besides the tab bar).
    @ViewBuilder private var emptyState: some View {
        if model.sources.iptv.isEmpty {
            ContentUnavailableView {
                Label("No live TV yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Add your TV provider in Settings to watch its channels here.")
            } actions: {
                Button("Open Settings") { tab = "settings" }
            }
        } else if model.liveLoading {
            ProgressView("Loading channels…")
        } else {
            ContentUnavailableView {
                Label("No channels", systemImage: "exclamationmark.triangle")
            } description: {
                Text(model.liveErrors.first ?? "Your subscription didn't return any channels.")
            } actions: {
                Button("Try Again") { Task { await model.loadLive(force: true) } }
            }
        }
    }

    private func entries(_ channels: [LiveChannel]) -> [LiveOrganizer.Entry] {
        channels.map { LiveOrganizer.Entry(title: model.title(of: $0), channels: [$0]) }
    }

    /// An invisible strip at the left edge: Left from the first card lands
    /// here, which opens the list.
    private var edge: some View {
        Color.white.opacity(0.001)
            .frame(width: 40)
            .frame(maxHeight: .infinity)
            .focusable()
            .focusEffectDisabled()
            .focused($edgeFocused)
            .onChange(of: edgeFocused) { _, focused in if focused { open() } }
            .accessibilityHidden(true)
    }

    // MARK: The list

    private func open() {
        guard !tabs.isEmpty else { return }
        // Sports' leagues show when you're in Sports; otherwise they'd push
        // the shelf you're on out of view.
        sportsExpanded = id == LiveOrganizer.sportsID
        withAnimation(.snappy(duration: 0.3)) { listOpen = true }
        let target = id == LiveOrganizer.sportsID ? "league:" + league : id
        Task { listFocus = target }
    }

    private func close() {
        edgeOn = false
        withAnimation(.snappy(duration: 0.25)) { listOpen = false }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            edgeOn = true
        }
    }

    /// A floating glass panel like tvOS 26's sidebar: each shelf with its
    /// symbol, Sports opening to its leagues (with how many games are on
    /// now), the provider's own categories last.
    private var list: some View {
        let current = id == LiveOrganizer.sportsID ? "league:" + league : id
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live TV")
                    .font(.system(size: 32, weight: .heavy))
                    .padding(.leading, 22)
                    .padding(.bottom, 14)
                ForEach(tabs, id: \.id) { tab in
                    if tab.id == Self.categoriesID {
                        Divider().padding(.horizontal, 22).padding(.vertical, 8)
                    }
                    if tab.id == LiveOrganizer.sportsID, let sports {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { sportsExpanded.toggle() }
                        } label: {
                            TVListRow(icon: tab.icon, title: tab.title,
                                      trailing: sportsExpanded ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(TVListStyle(selected: id == tab.id && !sportsExpanded))
                        .focused($listFocus, equals: tab.id)
                        if sportsExpanded {
                            ForEach(sports.all, id: \.self) { choice in
                                Button { pick(LiveOrganizer.sportsID, league: choice) } label: {
                                    TVListRow(title: TVSports.title(choice), live: sports.live[choice] ?? 0, indent: true)
                                }
                                .buttonStyle(TVListStyle(selected: current == "league:" + choice))
                                .focused($listFocus, equals: "league:" + choice)
                            }
                        }
                    } else {
                        Button { pick(tab.id) } label: {
                            TVListRow(icon: tab.icon, title: tab.title)
                        }
                        .buttonStyle(TVListStyle(selected: current == tab.id))
                        .focused($listFocus, equals: tab.id)
                    }
                }
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 26)
        }
        .scrollIndicators(.hidden)
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .padding(.leading, 40)
        .padding(.vertical, 40)
        .focusSection()
        .defaultFocus($listFocus, current)
        .onMoveCommand { if $0 == .right { close() } }
    }

    private func pick(_ shelf: String, league: String? = nil) {
        chosen = shelf
        if let league { sportsFilter = league }
        close()
    }

    /// Favorites, the shelves with Local after Sports, and the provider's
    /// own categories last.
    private var tabs: [(id: String, title: String, icon: String)] {
        var tabs: [(id: String, title: String, icon: String)] = []
        if !prefs.favorites.isEmpty { tabs.append((AppModel.favoritesID, "Favorites", "star")) }
        for shelf in model.liveLibrary.shelves {
            tabs.append((shelf.id, shelf.title, Self.icon(shelf.id)))
            if shelf.id == LiveOrganizer.sportsID { tabs.append((AppModel.localID, "Local", "antenna.radiowaves.left.and.right")) }
        }
        // Local is picked from the channels: none until they've loaded.
        if !model.liveLibrary.shelves.contains(where: { $0.id == LiveOrganizer.sportsID }), !model.allChannels.isEmpty {
            tabs.insert((AppModel.localID, "Local", "antenna.radiowaves.left.and.right"), at: tabs.isEmpty ? 0 : min(1, tabs.count))
        }
        if !model.categories.isEmpty { tabs.append((Self.categoriesID, "All Categories", "list.bullet")) }
        return tabs
    }

    private static func icon(_ shelf: String) -> String {
        switch shelf {
        case LiveOrganizer.sportsID: "sportscourt"
        case "shelf:news": "newspaper"
        case "shelf:entertainment": "tv"
        case "shelf:movies": "film"
        case "shelf:kids": "figure.and.child.holdinghands"
        case "shelf:nonstop": "infinity"
        case "shelf:music": "music.note"
        case "shelf:radio": "radio"
        case LiveOrganizer.internationalID: "globe"
        default: "ellipsis.circle"
        }
    }
}

/// One row of the slide-out list: a symbol and a name, a red dot and a
/// count for games on now, or a chevron for a group that opens.
private struct TVListRow: View {
    var icon: String?
    let title: String
    var live = 0
    var trailing: String?
    var indent = false

    var body: some View {
        HStack(spacing: 20) {
            if let icon {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).frame(width: 34)
            }
            Text(title)
                .font(.system(size: indent ? 25 : 28, weight: indent ? .medium : .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if live > 0 {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 11, height: 11)
                    Text("\(live)").font(.system(size: 21, weight: .semibold)).opacity(0.6)
                }
                .accessibilityLabel("\(live) live")
            }
            if let trailing {
                Image(systemName: trailing).font(.system(size: 20, weight: .bold)).opacity(0.6)
            }
        }
        .padding(.leading, indent ? 74 : 22)
        .padding(.trailing, 22)
        .frame(height: indent ? 48 : 58)
    }
}

/// tvOS's list look: white with dark text under focus (a little larger),
/// a soft fill for the chosen one.
private struct TVListStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }

    private struct Styled: View {
        let label: Configuration.Label
        let selected: Bool
        let pressed: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            label
                .foregroundStyle(focused ? Color.black : Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Capsule().fill(focused ? Color.white : selected ? Color.white.opacity(0.14) : Color.clear)
                }
                .scaleEffect(focused ? (pressed ? 1.0 : 1.04) : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 10)
                .animation(.snappy(duration: 0.2), value: focused)
        }
    }
}

/// A page of sections (a country's channels, or one provider category).
private struct TVSectionsPage: View {
    @Environment(AppModel.self) private var model
    let title: String
    var sections: [LiveOrganizer.Section] = []
    var channels: [LiveChannel]? = nil
    @Binding var playing: PlayerItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if let channels {
                    TVChannelGrid(title: title, entries: channels.map { LiveOrganizer.Entry(title: model.title(of: $0), channels: [$0]) },
                                  playing: $playing)
                } else {
                    ForEach(sections) { section in
                        TVChannelGrid(title: section.title, entries: section.entries, playing: $playing)
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
    }
}

/// Channels (or games) as a grid of cards under a heading.
struct TVChannelGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let title: String
    let entries: [LiveOrganizer.Entry]
    @Binding var playing: PlayerItem?

    private let columns = [GridItem(.adaptive(minimum: 360, maximum: 420), spacing: 44, alignment: .top)]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                TVRowTitle(title)
                let channels = entries.map { $0.channels[0] }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Group {
                            if entry.event != nil {
                                TVEventCard(entry: entry, action: { playing = .live(channels, index) },
                                            play: { copy in playing = .live(channels, index, copy: copy) })
                            } else {
                                TVChannelCard(entry: entry, slot: model.slot(entry.id), favorite: prefs.isFavorite(entry.channels[0])) {
                                    playing = .live(channels, index)
                                }
                                .onAppear { model.appeared(entry.id, ahead: channels[(index + 1)...].prefix(24)) }
                                .onDisappear { model.disappeared(entry.id) }
                            }
                        }
                        .contextMenu {
                            let channel = entry.channels[0]
                            Button(prefs.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites",
                                   systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                                prefs.toggleFavorite(channel)
                            }
                        }
                    }
                }
                .padding(.horizontal, 90)
            }
        }
    }
}

/// A channel: its logo on a dark tile (lifting under focus), then its name
/// and what's on now with how far through it is.
private struct TVChannelCard: View {
    let entry: LiveOrganizer.Entry
    let slot: NowNextSlot
    let favorite: Bool
    let action: () -> Void

    var body: some View {
        let now = slot.value?.now
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    TVLogo(url: entry.logo, name: entry.title)
                        .padding(.horizontal, 60)
                        .padding(.vertical, 40)
                }
                .frame(height: 216)
                .overlay(alignment: .bottom) {
                    if let now { ProgressBar(value: now.progress()).padding(14) }
                }
                .overlay(alignment: .topTrailing) {
                    if favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(12) }
                }
            }
            .buttonStyle(.card)
            .accessibilityLabel([entry.title, now?.title].compactMap(\.self).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(now.map { "\($0.title) · until \($0.stop.clock)" } ?? (slot.value == nil ? " " : "No guide data"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityHidden(true)
        }
    }
}

/// A game: league and LIVE on the tile, title and time below.
private struct TVEventCard: View {
    @Environment(AppModel.self) private var model
    let entry: LiveOrganizer.Entry
    let action: () -> Void
    /// One of its channels picked in its press-and-hold menu.
    var play: (LiveChannel) -> Void = { _ in }

    var body: some View {
        let event = entry.event
        let started = event?.start.map { $0 <= Date() } ?? false
        let live = GameTime.state(start: event?.start, league: event?.league ?? "", title: entry.title) == .live
        // Tried in the last half hour, and none of its channels played.
        let notPlaying = live && model.isNotPlaying(entry)
        // Different feeds showing it (the same feed on two channels once).
        let channels = model.feedCount(entry)
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let logo = entry.logo {
                        TVLogo(url: logo, name: event?.league ?? "")
                            .padding(.horizontal, 80)
                            .padding(.vertical, 50)
                            .opacity(0.9)
                    } else {
                        Text(event?.league ?? "")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(30)
                    }
                    if live {
                        Text(notPlaying ? "Not playing" : "LIVE")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(notPlaying ? Color.white.opacity(0.25) : Color.red, in: .capsule)
                            .padding(14)
                    }
                }
                .frame(height: 216)
            }
            .buttonStyle(.card)
            // Press-and-hold: the channels showing it (Watch On).
            .contextMenu { WatchOnMenuItems(channel: entry.channels[0], play: play) }
            .accessibilityLabel([notPlaying ? "Not playing" : live ? "Live" : nil, entry.title, event?.league,
                                 channels > 1 ? "\(channels) channels" : nil].compactMap(\.self).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text([Self.when(event?.start, started: started), event?.league,
                      channels > 1 ? "\(channels) channels" : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityHidden(true)
        }
    }

    private static func when(_ start: Date?, started: Bool) -> String? {
        guard let start else { return nil }
        let time = start.formatted(date: .omitted, time: .shortened)
        if started { return "Started \(time)" }
        if Calendar.current.isDateInToday(start) { return time }
        if Calendar.current.isDateInTomorrow(start) { return "Tomorrow \(time)" }
        return start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A channel logo fitted to its space; the initials until (or unless) it
/// loads.
private struct TVLogo: View {
    let url: URL?
    let name: String
    @State private var image: UIImage?

    var body: some View {
        let shown = image ?? url.flatMap(ImagePipeline.shared.cached)
        Group {
            if let shown {
                Image(uiImage: shown).resizable().scaledToFit()
            } else {
                Text(String(name.prefix(3)).uppercased())
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
                    .minimumScaleFactor(0.5)
            }
        }
        .task(id: url) {
            guard let url, ImagePipeline.shared.cached(url) == nil else { return }
            image = try? await ImagePipeline.shared.image(for: url)
        }
    }
}

// MARK: - Sports

/// Games by league (Top first) and by when they're on; the sports channels
/// under Channels.
struct TVSports: View {
    let shelf: LiveOrganizer.Shelf
    /// Top, All, a league, or Channels (chosen in the slide-out list).
    let filter: String
    @Binding var playing: PlayerItem?

    /// What Sports can show, in order, and how many games each has on now.
    struct Choices {
        let all: [String]
        let live: [String: Int]
    }

    /// Games from the last four hours on; older ones are over.
    private static func events(_ shelf: LiveOrganizer.Shelf, now: Date) -> [LiveOrganizer.Entry] {
        (shelf.sections.first { $0.id == "events" }?.entries ?? []).filter { entry in
            guard let start = entry.event?.start else { return true }
            return now.timeIntervalSince(start) < GameTime.listed
        }
    }

    /// Top (the big leagues) when any are on, All, each league (the big
    /// ones first, then the busiest), then the sports channels.
    static func choices(_ shelf: LiveOrganizer.Shelf) -> Choices {
        let now = Date()
        let events = events(shelf, now: now)
        let featured = Set(LiveOrganizer.featuredLeagues)
        var counts: [String: Int] = [:]
        var live: [String: Int] = [:]
        for entry in events {
            let league = entry.event?.league ?? ""
            counts[league, default: 0] += 1
            if GameTime.state(start: entry.event?.start, league: league, title: entry.title, now: now) == .live {
                live[league, default: 0] += 1
                live["All", default: 0] += 1
                if featured.contains(league) { live["Top", default: 0] += 1 }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: LiveOrganizer.featuredLeagues.enumerated().map { ($1, $0) })
        let leagues = counts.keys.filter { !$0.isEmpty }.sorted { a, b in
            switch (order[a], order[b]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return counts[a, default: 0] > counts[b, default: 0]
            }
        }
        let hasTop = events.contains { featured.contains($0.event?.league ?? "") }
        return Choices(all: (hasTop ? ["Top"] : []) + ["All"] + leagues + ["Channels"], live: live)
    }

    /// The name shown for a choice.
    static func title(_ choice: String) -> String {
        switch choice {
        case "Top": "Top Games"
        case "All": "All Games"
        case "Channels": "Sports Channels"
        case "": "Sports"
        default: choice
        }
    }

    var body: some View {
        let now = Date()
        let events = Self.events(shelf, now: now)
        let featured = Set(LiveOrganizer.featuredLeagues)
        let chosen = filter

        if chosen == "Channels" {
            ForEach(shelf.sections.filter { $0.id != "events" }) { section in
                TVChannelGrid(title: section.title, entries: section.entries, playing: $playing)
            }
        } else {
            let shown = events.filter { entry in
                switch chosen {
                case "All": true
                case "Top": featured.contains(entry.event?.league ?? "")
                default: entry.event?.league == chosen
                }
            }
            let calendar = Calendar.current
            let groups: [(String, [LiveOrganizer.Entry])] = [
                ("Live Now", shown.filter { GameTime.state(start: $0.event?.start, league: $0.event?.league ?? "", title: $0.title, now: now) == .live }),
                ("Later Today", shown.filter { ($0.event?.start).map { $0 > now && calendar.isDate($0, inSameDayAs: now) } ?? false }),
                ("Tomorrow", shown.filter { ($0.event?.start).map { calendar.isDateInTomorrow($0) } ?? false }),
                ("Coming Up", shown.filter { ($0.event?.start).map { $0 > now && !calendar.isDate($0, inSameDayAs: now) && !calendar.isDateInTomorrow($0) } ?? false }),
                // Started longer ago than such a game lasts (see GameTime).
                ("Earlier Today", shown.filter { GameTime.state(start: $0.event?.start, league: $0.event?.league ?? "", title: $0.title, now: now) == .over }),
                ("More Events", shown.filter { $0.event?.start == nil }),
            ]
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { group in
                TVChannelGrid(title: group.0, entries: group.1, playing: $playing)
            }
            if shown.isEmpty {
                Text("Nothing on right now").foregroundStyle(.secondary).padding(.leading, 90)
            }
        }
    }
}

// MARK: - International and categories

/// Countries as tiles: flag, name and how many channels.
private struct TVCountryGrid: View {
    let shelf: LiveOrganizer.Shelf
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 40)]

    var body: some View {
        var seen = Set<String>()
        let countries = shelf.sections.compactMap(\.country).filter { seen.insert($0).inserted }
        VStack(alignment: .leading, spacing: 24) {
            TVRowTitle("International")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                ForEach(countries, id: \.self) { code in
                    let count = shelf.sections.filter { $0.country == code }.reduce(0) { $0 + $1.entries.count }
                    NavigationLink(value: LiveCountry(code: code)) {
                        VStack(spacing: 10) {
                            Text(LiveOrganizer.flag(code)).font(.system(size: 64))
                            Text(LiveOrganizer.countryName(code)).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(count) channels").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 90)
        }
    }
}

/// The provider's own categories.
private struct TVCategoryList: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 400, maximum: 520), spacing: 30)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVRowTitle("All Categories")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                ForEach(model.categories) { category in
                    NavigationLink(value: category) {
                        HStack {
                            Text(category.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(category.channels)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .frame(height: 90)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 90)
        }
    }
}
#endif
