import SwiftUI

/// One of Live TV's shelves (see LiveOrganizer) as list sections. Sports
/// filters by league and lists games by when they're on; International
/// lists countries, each opening its channels.
struct ShelfContent: View {
    let shelf: LiveOrganizer.Shelf
    @Binding var playing: PlayerItem?

    var body: some View {
        switch shelf.id {
        case LiveOrganizer.sportsID: SportsContent(shelf: shelf, playing: $playing)
        case LiveOrganizer.internationalID: CountryList(shelf: shelf)
        default: EntrySections(sections: shelf.sections, shelfTitle: shelf.title, playing: $playing)
        }
    }
}

/// Sections of entries, titled when there's more than one.
struct EntrySections: View {
    let sections: [LiveOrganizer.Section]
    /// The shelf's own name: its main section needs no heading (the tab
    /// already says it).
    var shelfTitle: String? = nil
    @Binding var playing: PlayerItem?

    var body: some View {
        ForEach(sections) { section in
            Section {
                EntryRows(entries: section.entries, playing: $playing)
            } header: {
                if sections.count > 1, section.title != shelfTitle { Text(section.title) }
            }
        }
    }
}

/// Entries as rows: tap plays the best copy (up and down in the player go
/// through the same list); long-press to favorite.
struct EntryRows: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let entries: [LiveOrganizer.Entry]
    @Binding var playing: PlayerItem?

    var body: some View {
        let channels = entries.map { $0.channels[0] }
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            Button {
                playing = .live(channels, index)
            } label: {
                if entry.event != nil {
                    EventRow(entry: entry)
                } else {
                    ChannelRow(entry: entry, slot: model.slot(entry.id), favorite: prefs.isFavorite(entry.channels[0]))
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                let channel = entry.channels[0]
                if entry.event != nil {
                    // A game: the channels showing it (the long press).
                    WatchOnMenuItems(channel: channel) { copy in playing = .live(channels, index, copy: copy) }
                } else {
                    Button(prefs.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                        prefs.toggleFavorite(channel)
                    }
                }
            }
            .onAppear {
                // Games say what's on in their names; channels need the guide.
                if entry.event == nil { model.appeared(entry.id, ahead: channels[(index + 1)...].prefix(30)) }
            }
            .onDisappear { model.disappeared(entry.id) }
        }
    }
}

/// A game's channels in a menu (long press on iPhone, press-and-hold on
/// Apple TV), as Watch On lists them in the player: the one to play first
/// at the top, each with its feed, language and picture; one picked plays.
struct WatchOnMenuItems: View {
    @Environment(AppModel.self) private var model
    let channel: LiveChannel
    let play: (LiveChannel) -> Void

    var body: some View {
        let choices = model.gameChannels(for: channel)
        Section(choices.count > 1 ? "Watch On · \(choices.count) channels" : "Watch On") {
            ForEach(choices) { choice in
                let line = model.watchOnShown(choice, playingCopy: nil).line
                Button { play(choice.channel) } label: {
                    Text(choice.label.title)
                    if !line.isEmpty { Text(line) }
                }
                // A menu item exposes only its first line otherwise.
                .accessibilityLabel([choice.label.title, line].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
    }
}

// MARK: - Sports

/// Games by when they're on (live now, later today, tomorrow, coming up),
/// filtered by league: "Top" (the major leagues and sports) first, then
/// every league with something on, then the sports channels.
struct SportsContent: View {
    let shelf: LiveOrganizer.Shelf
    @Binding var playing: PlayerItem?
    @State private var filter: String?
    @Environment(AppModel.self) private var model

    private static let top = "Top", all = "All", channels = "Channels"

    var body: some View {
        let now = Date()
        // Games that started more than four hours ago are over.
        let events = (shelf.sections.first { $0.id == "events" }?.entries ?? []).filter { entry in
            guard let start = entry.event?.start else { return true }
            return now.timeIntervalSince(start) < GameTime.listed
        }
        let featured = Set(LiveOrganizer.featuredLeagues)
        let leagues = Self.leagues(events)
        let hasTop = events.contains { featured.contains($0.event?.league ?? "") }
        let choices = (hasTop ? [Self.top] : []) + [Self.all] + leagues + [Self.channels]
        let chosen = filter.flatMap { choices.contains($0) ? $0 : nil } ?? choices[0]

        Section {
            FilterChips(choices: choices, chosen: chosen) { filter = $0 }
                .listRowInsets(EdgeInsets())
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
        }
        if chosen == Self.channels {
            GamesNoticeView(notice: model.gamesNotice, nothingListed: false)
            EntrySections(sections: shelf.sections.filter { $0.id != "events" }, playing: $playing)
        } else {
            let shown = events.filter { entry in
                switch chosen {
                case Self.all: true
                case Self.top: featured.contains(entry.event?.league ?? "")
                default: entry.event?.league == chosen
                }
            }
            GamesNoticeView(notice: model.gamesNotice, nothingListed: shown.isEmpty)
            ForEach(LiveOrganizer.gameSections(shown, now: now), id: \.title) { bucket in
                Section(bucket.title) { EntryRows(entries: bucket.entries, playing: $playing) }
            }
        }
    }

    /// Leagues with something on: the major ones in their order, then the
    /// rest by how much they have on.
    private static func leagues(_ events: [LiveOrganizer.Entry]) -> [String] {
        var counts: [String: Int] = [:]
        for event in events { counts[event.event?.league ?? "", default: 0] += 1 }
        counts[""] = nil
        let order = Dictionary(uniqueKeysWithValues: LiveOrganizer.featuredLeagues.enumerated().map { ($1, $0) })
        return counts.keys.sorted { a, b in
            switch (order[a], order[b]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return counts[a, default: 0] != counts[b, default: 0] ? counts[a, default: 0] > counts[b, default: 0] : a < b
            }
        }
    }
}

/// A row of filter buttons that scrolls sideways.
struct FilterChips: View {
    let choices: [String]
    let chosen: String
    let choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    #if os(tvOS)
                    Button(choice) { choose(choice) }.buttonStyle(TVChipStyle(selected: choice == chosen))
                    #else
                    if choice == chosen {
                        // Selected: white, like the references' filters.
                        Button(choice) { choose(choice) }
                            .buttonStyle(.glassProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                    } else {
                        Button(choice) { choose(choice) }.buttonStyle(.glass)
                    }
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// A game: what, when (LIVE once it's started) and which league.
struct EventRow: View {
    @Environment(AppModel.self) private var model
    let entry: LiveOrganizer.Entry

    var body: some View {
        let event = entry.event
        let started = event?.start.map { $0 <= Date() } ?? false
        let live = GameTime.state(start: event?.start, league: event?.league ?? "", title: entry.title) == .live
        let state = model.gameState(entry)
        let badge = TileBadge.game(state)
        let notPlaying = live && state == .notPlaying
        let line = [Self.when(event?.start, started: started), event?.league, event?.detail]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(spacing: 12) {
            ChannelLogo(url: entry.logo, name: event?.league ?? entry.title, badge: badge)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if notPlaying {
                        Text("Not playing")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.25), in: .capsule)
                    } else if live {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: .capsule)
                    }
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .rowForeground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.title, notPlaying ? "Not playing" : live ? "LIVE" : nil, line, notPlaying ? nil : badge?.spoken]
            .compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private static func when(_ start: Date?, started: Bool) -> String? {
        guard let start else { return nil }
        let time = start.formatted(date: .omitted, time: .shortened)
        if started { return "Started \(time)" }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return time }
        if calendar.isDateInTomorrow(start) { return "Tomorrow \(time)" }
        return start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

// MARK: - International

/// A country in International.
struct LiveCountry: Hashable {
    let code: String
}

/// Countries with their channel counts; each opens its channels by topic.
struct CountryList: View {
    let shelf: LiveOrganizer.Shelf

    var body: some View {
        var seen = Set<String>()
        let countries = shelf.sections.compactMap(\.country).filter { seen.insert($0).inserted }
        ForEach(countries, id: \.self) { code in
            let count = shelf.sections.filter { $0.country == code }.reduce(0) { $0 + $1.entries.count }
            NavigationLink(value: LiveCountry(code: code)) {
                HStack(spacing: 12) {
                    Text(LiveOrganizer.flag(code)).font(.title2)
                    Text(LiveOrganizer.countryName(code)).font(.body.weight(.semibold))
                    Spacer()
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// One country's channels, by topic.
struct CountryChannels: View {
    @Environment(AppModel.self) private var model
    let code: String
    @Binding var playing: PlayerItem?

    var body: some View {
        let sections = model.shelf(LiveOrganizer.internationalID)?.sections.filter { $0.country == code } ?? []
        List {
            EntrySections(sections: sections, playing: $playing)
        }
        .listStyle(.plain)
        .navigationTitle("\(LiveOrganizer.flag(code)) \(LiveOrganizer.countryName(code))")
        .inlineTitle()
    }
}

// MARK: - Keeping the lineup current

extension View {
    /// Keeps Live TV's lineup as current as `page` needs while this view is
    /// on screen and the app is in front (AppModel.keepLiveCurrent).
    func keepsLiveCurrent(showing page: String?) -> some View {
        modifier(KeepLiveCurrent(page: page))
    }
}

/// Leaving the page or the app cancels the task; coming back starts it
/// again, and it asks at once if the lineup is due.
private struct KeepLiveCurrent: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let page: String?

    private struct Visit: Hashable {
        let page: String?
        let inFront: Bool
    }

    func body(content: Content) -> some View {
        let inFront = scenePhase != .background
        return content.task(id: Visit(page: page, inFront: inFront)) {
            guard inFront else { return }
            await model.keepLiveCurrent(showing: page)
        }
    }
}

/// Under Sports' filters: what to say when nothing is listed, or when the
/// games may not be current.
struct GamesNoticeView: View {
    let notice: GamesNotice
    /// Nothing listed under the chosen filter.
    let nothingListed: Bool

    var body: some View {
        switch notice {
        case .current:
            if nothingListed { Text("Nothing on right now").foregroundStyle(.secondary) }
        case .checking:
            if nothingListed { Text("Checking for games…").foregroundStyle(.secondary) }
        case let .couldNotUpdate(lastUpdated, reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't update the games", systemImage: "exclamationmark.triangle").font(.headline)
                Text(Self.detail(lastUpdated: lastUpdated, reason: reason, now: Date()))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// "Last updated 2 hours ago. Test: Your provider is busy right now (too
    /// many requests)."; with no known time, the reason alone.
    static func detail(lastUpdated: Date?, reason: String, now: Date) -> String {
        let age = lastUpdated.map { "Last updated \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now)). " } ?? ""
        return age + reason
    }
}
