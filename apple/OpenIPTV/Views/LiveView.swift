import SwiftUI

/// Live TV: glass category chips (Favorites first) over a channel list.
/// Now/next is fetched for visible rows only and refreshed when a programme
/// ends. Long-press a channel to favourite it, a category to hide it.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var playing: PlayerItem?
    @State private var categoryFilter = ""
    @State private var showingAllCategories = false

    private var showingFavorites: Bool { model.selectedCategory == AppModel.favoritesID }
    private var displayed: [Channel] { showingFavorites ? prefs.favorites : model.channels }

    var body: some View {
        NavigationStack {
            List {
                if showingFavorites, prefs.favorites.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "star",
                                           description: Text("Press and hold a channel to add it."))
                } else if let error = model.channelsError, displayed.isEmpty {
                    ContentUnavailableView("Couldn't load channels", systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text(error))
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
            .safeAreaInset(edge: .top, spacing: 0) { categoryChips }
            .sheet(isPresented: $showingAllCategories) { categoryPicker }
            .task {
                if model.selectedCategory == nil, !prefs.favorites.isEmpty {
                    model.selectedCategory = AppModel.favoritesID
                }
                await model.loadCategories()
            }
            .refreshableOnPhone {
                if let id = model.selectedCategory { await model.select(category: id) }
            }
        }
    }

    private var visibleCategories: [Category] {
        model.categories.filter { !prefs.hiddenCategories.contains($0.id) }
    }

    private var selectedName: String {
        if showingFavorites { return "Favourites" }
        return model.categories.first(where: { $0.id == model.selectedCategory })?.name ?? "Live TV"
    }

    private var categoryChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    LazyHStack(spacing: 8) {
                        Button { showingAllCategories = true } label: {
                            Label("All", systemImage: "line.3.horizontal")
                        }
                        .buttonStyle(.glass)
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
            }
            .scrollIndicators(.hidden)
            // A horizontal ScrollView would otherwise grow to fill the
            // inset's height and push the channel list down.
            .fixedSize(horizontal: false, vertical: true)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .onAppear {
                if let id = model.selectedCategory { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func chip(id: String, title: String) -> some View {
        if id == model.selectedCategory {
            Button(title) { choose(id) }.buttonStyle(.glassProminent).lineLimit(1).id(id)
        } else {
            Button(title) { choose(id) }.buttonStyle(.glass).lineLimit(1).id(id)
        }
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(filteredCategories) { category in
                Button {
                    choose(category.id)
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
            }
            .searchable(text: $categoryFilter, prompt: "Filter categories")
            .navigationTitle("Categories")
            .inlineTitle()
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var filteredCategories: [Category] {
        categoryFilter.isEmpty
            ? visibleCategories
            : visibleCategories.filter { $0.name.localizedCaseInsensitiveContains(categoryFilter) }
    }

    private func choose(_ id: String) {
        Task { await model.select(category: id) }
    }
}

struct ChannelRow: View {
    let channel: Channel
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ChannelLogo: View {
    let url: String?
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
            guard let url, let parsed = URL(string: url) else { return }
            image = try? await ImagePipeline.shared.image(for: parsed)
        }
    }
}
