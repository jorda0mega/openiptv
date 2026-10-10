import SwiftUI

/// Live TV: glass category chips (Favourites first) over a channel list.
/// Now/next is fetched for visible rows only and refreshed when a programme
/// ends. Long-press a channel to favourite it, a category to hide it.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @State private var categoryFilter = ""
    @State private var showingAllCategories = false
    @State private var addingSource = false

    private var showingFavorites: Bool { model.selectedCategory == AppModel.favoritesID }
    private var displayed: [LiveChannel] { model.channels(in: model.selectedCategory, favorites: prefs.favorites) }

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
                } else if displayed.isEmpty, model.liveLoading {
                    HStack { Spacer(); ProgressView("Loading channels…"); Spacer() }.padding(.vertical, 40)
                }
                ForEach(model.liveErrors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playing = .live(displayed, index)
                    } label: {
                        ChannelRow(channel: channel, info: model.nowNext[channel.id], favorite: prefs.isFavorite(channel))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(prefs.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites",
                               systemImage: prefs.isFavorite(channel) ? "star.slash" : "star") {
                            prefs.toggleFavorite(channel)
                        }
                    }
                    .onAppear { model.appeared(channel.id) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(selectedName)
            .inlineTitle()
            // safeAreaBar (iOS/tvOS 26) keeps the chips in the bar area with the
            // scroll edge effect.
            .safeAreaBar(edge: .top, spacing: 0) {
                if !model.sources.iptv.isEmpty { categoryChips }
            }
            .sheet(isPresented: $showingAllCategories) { categoryPicker }
            .sheet(isPresented: $addingSource) { AddIPTVView() }
            .task {
                if model.selectedCategory == nil, !prefs.favorites.isEmpty {
                    model.selectedCategory = AppModel.favoritesID
                }
                await model.loadLive()
            }
            .refreshableOnPhone { await model.loadLive(force: true) }
        }
    }

    private var visibleCategories: [LiveCategory] {
        model.categories.filter { !prefs.hiddenCategories.contains($0.id) }
    }

    private var selectedName: String {
        if showingFavorites { return "Favourites" }
        return model.categories.first(where: { $0.id == model.selectedCategory })?.name ?? "Live TV"
    }

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

struct ChannelRow: View {
    let channel: LiveChannel
    let info: NowNext?
    var favorite = false

    var body: some View {
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
                // Re-render every 30 s so progress bars move.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let now = info?.now {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(now.title) · until \(now.stop.clock)")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            ProgressView(value: now.progress(at: context.date))
                                .frame(maxWidth: 220)
                        }
                    } else {
                        Text(info == nil ? "…" : "No guide data")
                            .font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                if let next = info?.next {
                    Text("Next \(next.start.clock) · \(next.title)")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
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
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else {
                Text(String(name.prefix(2)).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 40)
        .task(id: url) {
            guard let url else { return }
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
