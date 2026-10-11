import SwiftUI

/// Continue Watching, Next Up and Latest per library. Rows render from the
/// on-device cache immediately; card boxes are sized before images load.
/// Selecting a card plays it (series start their next unwatched episode).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    @Binding var playing: PlayerItem?
    @State private var loadingCard: String?
    @State private var playError: String?
    @State private var addingEmby = false
    @State private var path: [ShowRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    if visibleRows.isEmpty { emptyState }
                    ForEach(visibleRows) { row in
                        RowView(row: row, loadingCard: loadingCard) { card in play(card) }
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Home")
            .refreshableOnPhone { await model.loadHome(cardWidth: pixelWidth) }
            .task { await model.loadHome(cardWidth: pixelWidth) }
            .sheet(isPresented: $addingEmby) { AddEmbyView() }
            .navigationDestination(for: ShowRoute.self) { ShowView(route: $0, playing: $playing) }
            .alert("Couldn't play", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playError ?? "")
            }
        }
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

    /// Shows open their page; everything else plays.
    private func play(_ card: Card) {
        if card.kind == "Series" {
            path.append(ShowRoute(id: card.id, title: card.title))
            return
        }
        guard card.playable, loadingCard == nil else { return }
        loadingCard = card.id
        Task {
            defer { loadingCard = nil }
            do {
                playing = .vod(try await model.playback(for: card))
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

private struct RowView: View {
    let row: HomeRow
    let loadingCard: String?
    let onSelect: (Card) -> Void

    private var cardWidth: CGFloat {
        let poster = Layout.posterWidth
        return switch row.shape {
        case "landscape": poster * 2
        case "fourThree": poster * 1.45
        case "square": poster * 1.15
        default: poster
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                    ForEach(row.cards) { card in
                        Button { onSelect(card) } label: {
                            CardView(card: card, width: cardWidth, aspect: row.aspect, loading: loadingCard == card.id)
                        }
                        .cardButtonStyle()
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }
}

private struct CardView: View {
    let card: Card
    let width: CGFloat
    let aspect: Double
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(images: card.images, title: card.title)
                .frame(width: width, height: width / aspect)
                .overlay(alignment: .bottom) {
                    if let progress = card.progress {
                        GeometryReader { geo in
                            Capsule().fill(.tint).frame(width: geo.size.width * progress / 100, height: 4)
                        }
                        .frame(height: 4)
                        .padding(8)
                    }
                }
                .overlay {
                    if loading { ProgressView().padding(12).glassEffect(.regular, in: .circle) }
                }
                .clipShape(.rect(cornerRadius: 14))
            Text(card.title).font(.subheadline.weight(.medium)).lineLimit(1)
            if let subtitle = card.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
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
                if let loaded = try? await ImagePipeline.shared.image(for: url) {
                    contain = candidate.contain
                    withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                    return
                }
            }
            failed = true
        }
    }
}
