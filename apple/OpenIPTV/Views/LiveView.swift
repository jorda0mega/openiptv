import SwiftUI

/// Live TV: category tabs (Favourites and Local first) over a channel list.
/// The lineup saved on the device shows at once and refreshes in the
/// background, so there's no pull to refresh (which also made the page
/// jump while swiping the tabs). Now/next is fetched for the rows on
/// screen and the 30 below them (with their logos), and refreshed when a
/// programme ends; rows keep one height while it loads, so scrolling never
/// jumps. Long-press a channel to favourite it, a category to hide it.
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
                        Text("Add an Xtream Codes login, an M3U playlist or a Stalker portal.")
                    } actions: {
                        Button("Add subscription") { addingSource = true }.buttonStyle(.glassProminent)
                    }
                } else if showingFavorites, prefs.favorites.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "star",
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
                } else if displayed.isEmpty, model.liveLoading {
                    HStack { Spacer(); ProgressView("Loading channels…"); Spacer() }.padding(.vertical, 40)
                }
                ForEach(model.liveErrors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                let channels = displayed
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playing = .live(channels, index)
                    } label: {
                        ChannelRow(channel: channel, slot: model.slot(channel.id), favorite: prefs.isFavorite(channel))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(prefs.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites",
                               systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                            prefs.toggleFavorite(channel)
                        }
                    }
                    .onAppear { model.appeared(channel.id, ahead: channels[(index + 1)...].prefix(30)) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(selectedName)
            .inlineTitle()
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
            .sheet(isPresented: $showingAllCategories) { categoryPicker }
            .sheet(isPresented: $addingSource) { AddIPTVView() }
            .sheet(isPresented: $choosingArea) { NavigationStack { AreaPicker() } }
            // Event and PPV categories change names per game: fresh on open.
            .task(id: model.selectedCategory) { await model.refreshCategory(model.selectedCategory) }
            .task {
                if model.selectedCategory == nil, !prefs.favorites.isEmpty {
                    model.selectedCategory = AppModel.favoritesID
                }
                await model.loadLive()
            }
        }
    }

    private var visibleCategories: [LiveCategory] {
        model.categories.filter { !prefs.hiddenCategories.contains($0.id) }
    }

    private var selectedName: String {
        if showingFavorites { return "Favourites" }
        if showingLocal { return prefs.area.map { "Local · \($0.label)" } ?? "Local" }
        return model.categories.first(where: { $0.id == model.selectedCategory })?.name ?? "Live TV"
    }

    #if os(iOS)
    private var categoryTabs: some View {
        let lead: [(id: String, title: String)] = (prefs.favorites.isEmpty ? [] : [(AppModel.favoritesID, "Favourites")])
            + [(AppModel.localID, "Local")]
        return TabStrip(items: lead + visibleCategories.map { ($0.id, $0.name) },
                        selected: model.selectedCategory,
                        leading: AnyView(Button { showingAllCategories = true } label: {
                            Image(systemName: "list.bullet").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("All categories"))) { model.selectedCategory = $0 }
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
                    if !prefs.favorites.isEmpty {
                        chip(id: AppModel.favoritesID, title: "★ Favourites")
                    }
                    chip(id: AppModel.localID, title: "Local")
                    ForEach(visibleCategories) { category in
                        chip(id: category.id, title: category.name)
                            .contextMenu {
                                Button("Hide Category", systemImage: "eye.slash") {
                                    prefs.hiddenCategories.insert(category.id)
                                }
                            }
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
        Button(title) { model.selectedCategory = id }
            .buttonStyle(TVChipStyle(selected: id == model.selectedCategory)).lineLimit(1).id(id)
        #else
        if id == model.selectedCategory {
            Button(title) { model.selectedCategory = id }.buttonStyle(.glassProminent).lineLimit(1).id(id)
        } else {
            Button(title) { model.selectedCategory = id }.buttonStyle(.glass).lineLimit(1).id(id)
        }
        #endif
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(filteredCategories) { category in
                Button {
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
            .searchable(text: $categoryFilter, prompt: "Filter categories")
            .navigationTitle("Categories")
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
    let channel: LiveChannel
    let slot: NowNextSlot
    var favorite = false

    var body: some View {
        let info = slot.value
        let now = info?.now
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logo, name: channel.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name).font(.body.weight(.semibold)).lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                Group {
                    // Re-render every 30 s so progress bars move.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(now.map { "\($0.title) · until \($0.stop.clock)" }
                                 ?? (info == nil ? "Programme title · until 9:00 PM" : "No guide data"))
                                .font(.subheadline)
                                .foregroundStyle(now == nil && info != nil ? .tertiary : .secondary)
                                .lineLimit(1)
                            ProgressView(value: now?.progress(at: context.date) ?? 0)
                                .frame(maxWidth: 220)
                                .opacity(now == nil ? 0 : 1)
                        }
                    }
                    Text(info?.next.map { "Next \($0.start.clock) · \($0.title)" } ?? (info == nil ? "Next 9:30 PM · Programme" : " "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .redacted(reason: info == nil ? .placeholder : [])
                .accessibilityHidden(info == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .rowForeground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ChannelLogo: View {
    let url: URL?
    let name: String
    @State private var image: UIImage?

    var body: some View {
        // Already decoded (scrolling back, or fetched ahead): shown at once.
        let shown = image ?? url.flatMap(ImagePipeline.shared.cached)
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image = shown {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else {
                Text(String(name.prefix(2)).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 40)
        .task(id: url) {
            guard let url, ImagePipeline.shared.cached(url) == nil else { return }
            image = try? await ImagePipeline.shared.image(for: url)
        }
    }
}

#if os(tvOS)
/// Category chip for Apple TV: white text on glass, accent fill when
/// selected, white and raised under focus.
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
                        Capsule().fill(Color.accentColor)
                    }
                }
                .glassEffect(focused || selected ? .identity : .regular, in: .capsule)
                .scaleEffect(focused ? (pressed ? 1.02 : 1.08) : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 12, y: 8)
                .animation(.snappy(duration: 0.18), value: focused)
        }
    }
}
#endif
