import SwiftUI

/// Live TV: shelves by what's on (Sports, Local, News, Entertainment…;
/// see LiveOrganizer) over their channels, one row per channel however
/// many copies the provider lists. The provider's own categories are a tap
/// away (the list button).
/// The lineup saved on the device shows at once and refreshes in the
/// background, so there's no pull to refresh (which also made the page
/// jump while swiping the tabs). Now/next is fetched for the rows on
/// screen and the 30 below them (with their logos), and refreshed when a
/// programme ends; rows keep one height while it loads, so scrolling never
/// jumps. Long-press a channel to favorite it, a category to hide it.
/// Each row watches only its own now/next, so details arriving redraw that
/// row, not the list.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @State private var categoryFilter = ""
    @State private var showingAllCategories = false
    @State private var addingSource = false
    @State private var choosingArea = false

    private var showingFavorites: Bool { model.selectedCategory == AppModel.favoritesID }
    private var showingLocal: Bool { model.selectedCategory == AppModel.localID }
    private var shelf: LiveOrganizer.Shelf? { model.shelf(model.selectedCategory) }
    private var displayed: [LiveChannel] {
        model.channels(in: model.selectedCategory, favorites: prefs.favorites, area: prefs.area)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.sources.iptv.isEmpty {
                    ContentUnavailableView {
                        Label("No IPTV subscription", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Add your TV provider to watch its channels here.")
                    } actions: {
                        Button("Add subscription") { addingSource = true }.buttonStyle(.glassProminent)
                    }
                } else if showingFavorites, prefs.favorites.isEmpty {
                    ContentUnavailableView("No favorites yet", systemImage: "star",
                                           description: Text("Press and hold a channel to add it."))
                } else if showingLocal, prefs.area == nil {
                    ContentUnavailableView {
                        Label("Where are you?", systemImage: "location")
                    } description: {
                        Text("Set your area to see your local ABC, NBC, CBS, FOX, CW and PBS stations.")
                    } actions: {
                        Button("Set your area") { choosingArea = true }.buttonStyle(.glassProminent)
                    }
                } else if showingLocal, displayed.isEmpty, !model.liveLoading, let area = prefs.area {
                    ContentUnavailableView("No local channels for \(area.label)", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Your subscription doesn't seem to carry stations for this area."))
                } else if shelf == nil, displayed.isEmpty, model.liveLoading {
                    HStack { Spacer(); ProgressView("Loading channels…"); Spacer() }.padding(.vertical, 40)
                }
                // Not on Sports, which says it itself.
                if shelf?.id != LiveOrganizer.sportsID {
                    ForEach(model.liveErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                }
                if let shelf {
                    ShelfContent(shelf: shelf, playing: $playing)
                }
                let channels = shelf == nil ? displayed : []
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playing = .live(channels, index)
                    } label: {
                        ChannelRow(channel: channel, slot: model.slot(channel.id), favorite: prefs.isFavorite(channel))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(prefs.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites",
                               systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                            prefs.toggleFavorite(channel)
                        }
                    }
                    .onAppear { model.appeared(channel.id, ahead: channels[(index + 1)...].prefix(30)) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
            .listStyle(.plain)
            // The tab strip says which shelf; the title says where you are.
            .navigationTitle("Live TV")
            .inlineTitle()
            #if os(iOS)
            .toolbar {
                if !model.sources.iptv.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingAllCategories = true } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("Provider categories")
                    }
                }
            }
            #endif
            // safeAreaBar (iOS/tvOS 26) keeps the chips in the bar area with the
            // scroll edge effect.
            .safeAreaBar(edge: .top, spacing: 0) {
                if !model.sources.iptv.isEmpty {
                    #if os(iOS)
                    categoryTabs
                    #else
                    categoryChips
                    #endif
                }
            }
            .navigationDestination(for: LiveCountry.self) { country in
                CountryChannels(code: country.code, playing: $playing)
            }
            .sheet(isPresented: $showingAllCategories) { categoryPicker }
            .sheet(isPresented: $addingSource) { AddIPTVView() }
            .sheet(isPresented: $choosingArea) { NavigationStack { AreaPicker() } }
            .keepsLiveCurrent(showing: model.selectedCategory)
            .task {
                if model.selectedCategory == nil, !prefs.favorites.isEmpty {
                    model.selectedCategory = AppModel.favoritesID
                }
            }
        }
    }

    private var visibleCategories: [LiveCategory] {
        model.categories.filter { !prefs.hiddenCategories.contains($0.id) }
    }

    private var selectedName: String {
        if showingFavorites { return "Favorites" }
        if showingLocal { return prefs.area.map { "Local · \($0.label)" } ?? "Local" }
        if let shelf { return shelf.title }
        return model.categories.first(where: { $0.id == model.selectedCategory })?.name ?? "Live TV"
    }

    /// Favorites, then the shelves with Local after Sports, then the
    /// provider category being browsed, if any.
    private var tabs: [(id: String, title: String)] {
        var items: [(id: String, title: String)] = prefs.favorites.isEmpty ? [] : [(AppModel.favoritesID, "Favorites")]
        let shelves = model.liveLibrary.shelves.map { (id: $0.id, title: $0.title) }
        let local = (id: AppModel.localID, title: "Local")
        if let first = shelves.first, first.id == LiveOrganizer.sportsID {
            items += [first, local] + shelves.dropFirst()
        } else {
            items += [local] + shelves
        }
        if let id = model.selectedCategory, !items.contains(where: { $0.id == id }),
           let category = model.categories.first(where: { $0.id == id }) {
            items.append((id, category.name))
        }
        return items
    }

    #if os(iOS)
    private var categoryTabs: some View {
        TabStrip(items: tabs, selected: model.selectedCategory) { id in
                            model.browsingProviderCategory = model.categories.contains { $0.id == id }
                            model.selectedCategory = id
                        }
    }
    #endif

    private var categoryChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // Not lazy: a LazyHStack in a bar never draws its children on
                // iPhone (they exist and take taps, but render nothing).
                HStack(spacing: 8) {
                    Button { showingAllCategories = true } label: {
                        Label("All", systemImage: "line.3.horizontal")
                    }
                    #if os(tvOS)
                    .buttonStyle(TVChipStyle(selected: false))
                    #else
                    .buttonStyle(.glass)
                    #endif
                    ForEach(tabs, id: \.id) { tab in
                        chip(id: tab.id, title: tab.id == AppModel.favoritesID ? "★ Favorites" : tab.title)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: Layout.chipStripHeight)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .onAppear {
                if let id = model.selectedCategory { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func chip(id: String, title: String) -> some View {
        #if os(tvOS)
        Button(title) { select(id) }
            .buttonStyle(TVChipStyle(selected: id == model.selectedCategory)).lineLimit(1).id(id)
        #else
        if id == model.selectedCategory {
            Button(title) { select(id) }.buttonStyle(.glassProminent).lineLimit(1).id(id)
        } else {
            Button(title) { select(id) }.buttonStyle(.glass).lineLimit(1).id(id)
        }
        #endif
    }

    private func select(_ id: String) {
        model.browsingProviderCategory = model.categories.contains { $0.id == id }
        model.selectedCategory = id
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(filteredCategories) { category in
                Button {
                    model.browsingProviderCategory = true
                    model.selectedCategory = category.id
                    showingAllCategories = false
                } label: {
                    HStack {
                        Text(category.name)
                        Spacer()
                        Text("\(category.channels)").foregroundStyle(.secondary).monospacedDigit()
                        if category.id == model.selectedCategory {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                #if os(iOS)
                .swipeActions {
                    Button("Hide", systemImage: "eye.slash") { prefs.hiddenCategories.insert(category.id) }
                }
                #endif
                .contextMenu {
                    Button("Hide Category", systemImage: "eye.slash") { prefs.hiddenCategories.insert(category.id) }
                }
            }
            #if os(iOS)
            // At the top, under the title, where it doesn't cover the list.
            .searchable(text: $categoryFilter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter categories")
            #else
            .searchable(text: $categoryFilter, prompt: "Filter categories")
            #endif
            .navigationTitle("Provider categories")
            .inlineTitle()
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var filteredCategories: [LiveCategory] {
        categoryFilter.isEmpty
            ? visibleCategories
            : visibleCategories.filter { $0.name.localizedCaseInsensitiveContains(categoryFilter) }
    }
}

/// A channel with what's on now and next. Always the same lines (grey
/// placeholders until the details arrive, blanks when there are none), so
/// the row never changes height as you scroll.
struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: LiveChannel
    let title: String
    let logo: URL?
    let slot: NowNextSlot
    var favorite = false

    init(channel: LiveChannel, slot: NowNextSlot, favorite: Bool = false) {
        self.channel = channel
        title = LiveOrganizer.Name(channel.name).display
        logo = channel.logo
        self.slot = slot
        self.favorite = favorite
    }

    init(entry: LiveOrganizer.Entry, slot: NowNextSlot, favorite: Bool = false) {
        channel = entry.channels[0]
        title = entry.title
        logo = entry.logo
        self.slot = slot
        self.favorite = favorite
    }

    var body: some View {
        let info = slot.value
        let now = info?.now
        let failed = model.didNotPlay(channel)
        HStack(spacing: 14) {
            ChannelLogo(url: logo, name: title, badge: failed ? .didNotPlay : nil)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(now?.title ?? title).font(.body.weight(.semibold)).lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                // Re-render every 30 s so the bars move.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let mark = failed ? "Didn’t play · " : ""
                    HStack(spacing: 8) {
                        if let now {
                            ProgressBar(value: now.progress(at: context.date)).frame(width: 36)
                            Text("\(mark)\(Self.left(now, at: context.date)) · \(title)").lineLimit(1)
                        } else {
                            Text(info == nil ? "Programme · 24m left" : mark + title).lineLimit(1)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .redacted(reason: info == nil ? .placeholder : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .rowForeground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "24m left", "1h 5m left".
    static func left(_ programme: Programme, at date: Date) -> String {
        let minutes = max(0, Int((Double(programme.stop) - date.timeIntervalSince1970) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}

struct ChannelLogo: View {
    let url: URL?
    let name: String
    var badge: TileBadge? = nil
    var size = CGSize(width: 68, height: 48)
    /// Shown without a logo: the name's first letters, unless given.
    var initials: String? = nil
    @State private var image: UIImage?

    var body: some View {
        // Already decoded (scrolling back, or fetched ahead): shown at once.
        let shown = image ?? url.flatMap(ImagePipeline.shared.cached)
        ZStack {
            RoundedRectangle(cornerRadius: size.height / 4).fill(Color(white: 0.14))
            if let image = shown {
                Image(uiImage: image).resizable().scaledToFit().padding(size.height / 6)
            } else {
                Text(initials ?? String(name.prefix(2)).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: size.width, height: size.height)
        .tileBadge(badge)
        .task(id: url) {
            guard let url, ImagePipeline.shared.cached(url) == nil else { return }
            image = try? await ImagePipeline.shared.image(for: url)
        }
    }
}

#if os(tvOS)
/// Category chip for Apple TV, like the TV app's season picker: white
/// text on glass, a brighter glass when chosen, white with black text and
/// raised under focus.
struct TVChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }

    private struct Chip: View {
        let label: Configuration.Label
        let selected: Bool
        let pressed: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            label
                .font(.callout.weight(.semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background {
                    if focused {
                        Capsule().fill(.white)
                    } else if selected {
                        Capsule().fill(.white.opacity(0.24))
                    }
                }
                .glassEffect(focused ? .identity : .regular, in: .capsule)
                .scaleEffect(focused ? (pressed ? 1.02 : 1.08) : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 12, y: 8)
                .animation(.snappy(duration: 0.18), value: focused)
        }
    }
}
#endif
