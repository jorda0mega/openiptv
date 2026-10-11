#if os(tvOS)
import SwiftUI

/// Live TV: a row of shelves at the top (Favourites, Sports, Local, News…,
/// the provider's own categories last), then the chosen one as grids of
/// cards like the TV app's: a channel shows its logo, name and what's on
/// now; a game its title, league and time, LIVE once it's started. The row
/// scrolls away with the page; Up brings it back.
struct TVLiveView: View {
    static let categoriesID = "tv:categories"

    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @AppStorage("tvLiveTab") private var chosen = ""
    @FocusState private var focusedShelf: String?

    /// The chosen shelf, or the first while none is (or it's gone).
    private var id: String {
        tabs.contains { $0.id == chosen } ? chosen : tabs.first?.id ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 50) {
                    shelfRow
                    content
                        .id(id)
                }
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .background(Color.black.ignoresSafeArea())
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

    @ViewBuilder private var content: some View {
        switch id {
        case AppModel.favoritesID:
            TVChannelGrid(title: "Favourites", entries: entries(prefs.favorites.map { model.current($0) }), playing: $playing)
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
            if let shelf = model.shelf(id) { TVSports(shelf: shelf, playing: $playing) }
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

    private func entries(_ channels: [LiveChannel]) -> [LiveOrganizer.Entry] {
        channels.map { LiveOrganizer.Entry(title: model.title(of: $0), channels: [$0]) }
    }

    private var shelfRow: some View {
        let current = id
        return ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(tabs, id: \.id) { tab in
                    Button { chosen = tab.id } label: {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .buttonStyle(TVChipStyle(selected: tab.id == current))
                    .focused($focusedShelf, equals: tab.id)
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        // Up from any card comes back to the row, not just the card above,
        // and lands on the chosen shelf (from the tab bar too).
        .focusSection()
        .defaultFocus($focusedShelf, current, priority: .userInitiated)
    }

    /// Favourites, the shelves with Local after Sports, and the provider's
    /// own categories last.
    private var tabs: [(id: String, title: String, icon: String)] {
        var tabs: [(id: String, title: String, icon: String)] = []
        if !prefs.favorites.isEmpty { tabs.append((AppModel.favoritesID, "Favourites", "star")) }
        for shelf in model.liveLibrary.shelves {
            tabs.append((shelf.id, shelf.title, Self.icon(shelf.id)))
            if shelf.id == LiveOrganizer.sportsID { tabs.append((AppModel.localID, "Local", "antenna.radiowaves.left.and.right")) }
        }
        if !model.liveLibrary.shelves.contains(where: { $0.id == LiveOrganizer.sportsID }), !model.sources.iptv.isEmpty {
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
                                TVEventCard(entry: entry) { playing = .live(channels, index) }
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
                            Button(prefs.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites",
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
    let entry: LiveOrganizer.Entry
    let action: () -> Void

    var body: some View {
        let event = entry.event
        let started = event?.start.map { $0 <= Date() } ?? false
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
                    if started {
                        Text("LIVE")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.red, in: .capsule)
                            .padding(14)
                    }
                }
                .frame(height: 216)
            }
            .buttonStyle(.card)
            .accessibilityLabel([started ? "Live" : nil, entry.title, event?.league].compactMap(\.self).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text([Self.when(event?.start, started: started), event?.league].compactMap(\.self).joined(separator: " · "))
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
private struct TVSports: View {
    let shelf: LiveOrganizer.Shelf
    @Binding var playing: PlayerItem?
    @State private var filter: String?

    var body: some View {
        let now = Date()
        let events = (shelf.sections.first { $0.id == "events" }?.entries ?? []).filter { entry in
            guard let start = entry.event?.start else { return true }
            return now.timeIntervalSince(start) < 4 * 3600
        }
        let featured = Set(LiveOrganizer.featuredLeagues)
        var counts: [String: Int] = [:]
        let _ = events.forEach { counts[$0.event?.league ?? "", default: 0] += 1 }
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
        let choices = (hasTop ? ["Top"] : []) + ["All"] + leagues + ["Channels"]
        let chosen = filter.flatMap { choices.contains($0) ? $0 : nil } ?? choices[0]

        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { filter = choice }.buttonStyle(TVChipStyle(selected: choice == chosen))
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)

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
                ("Live Now", shown.filter { ($0.event?.start).map { $0 <= now } ?? false }),
                ("Later Today", shown.filter { ($0.event?.start).map { $0 > now && calendar.isDate($0, inSameDayAs: now) } ?? false }),
                ("Tomorrow", shown.filter { ($0.event?.start).map { calendar.isDateInTomorrow($0) } ?? false }),
                ("Coming Up", shown.filter { ($0.event?.start).map { $0 > now && !calendar.isDate($0, inSameDayAs: now) && !calendar.isDateInTomorrow($0) } ?? false }),
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
