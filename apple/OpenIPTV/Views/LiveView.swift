import SwiftUI

/// Live TV: glass category chips over a channel list. Now/next is fetched for
/// visible rows only and refreshed when a programme ends.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Binding var playback: PlaybackRequest?
    @State private var categoryFilter = ""
    @State private var showingAllCategories = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.channelsError, model.channels.isEmpty {
                    ContentUnavailableView("Couldn't load channels", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(error))
                }
                ForEach(Array(model.channels.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playback = PlaybackRequest(channels: model.channels, index: index)
                    } label: {
                        ChannelRow(channel: channel, info: model.nowNext[channel.id])
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.appeared(channel.id) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(selectedName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { categoryChips }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAllCategories = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("All categories")
                }
            }
            .sheet(isPresented: $showingAllCategories) { categoryPicker }
            .task { await model.loadCategories() }
            .refreshable {
                if let id = model.selectedCategory { await model.select(category: id) }
            }
        }
    }

    private var selectedName: String {
        model.categories.first(where: { $0.id == model.selectedCategory })?.name ?? "Live TV"
    }

    private var categoryChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    LazyHStack(spacing: 8) {
                        ForEach(model.categories) { category in
                            chip(category).id(category.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let id = model.selectedCategory { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func chip(_ category: Category) -> some View {
        let selected = category.id == model.selectedCategory
        if selected {
            Button(category.name) { choose(category) }
                .buttonStyle(.glassProminent)
                .lineLimit(1)
        } else {
            Button(category.name) { choose(category) }
                .buttonStyle(.glass)
                .lineLimit(1)
        }
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(filteredCategories) { category in
                Button {
                    choose(category)
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
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredCategories: [Category] {
        categoryFilter.isEmpty
            ? model.categories
            : model.categories.filter { $0.name.localizedCaseInsensitiveContains(categoryFilter) }
    }

    private func choose(_ category: Category) {
        Task { await model.select(category: category.id) }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let info: NowNext?

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logo, name: channel.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.body.weight(.semibold)).lineLimit(1)
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
