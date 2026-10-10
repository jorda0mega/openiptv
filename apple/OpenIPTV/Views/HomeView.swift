import SwiftUI

/// Continue Watching, Next Up and Latest per library. Rows render from the
/// on-device cache immediately; card boxes are sized before images load.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var showingSettings = false

    private let posterWidth: CGFloat = 118

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.rows.isEmpty {
                        emptyState
                    }
                    ForEach(model.rows) { row in
                        RowView(row: row, posterWidth: posterWidth)
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityLabel("Server")
                }
            }
            .refreshable { await model.loadHome(cardWidth: pixelWidth) }
            .task { await model.loadHome(cardWidth: pixelWidth) }
            .sheet(isPresented: $showingSettings) { ConnectView(isSheet: true) }
        }
    }

    private var pixelWidth: Int { Int(posterWidth * displayScale) }

    @ViewBuilder private var emptyState: some View {
        if let error = model.homeError {
            ContentUnavailableView("Couldn't load Emby", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        }
    }
}

private struct RowView: View {
    let row: HomeRow
    let posterWidth: CGFloat

    private var cardWidth: CGFloat {
        switch row.shape {
        case "landscape": posterWidth * 2
        case "fourThree": posterWidth * 1.45
        case "square": posterWidth * 1.15
        default: posterWidth
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.cards) { card in
                        CardView(card: card, width: cardWidth, aspect: row.aspect)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct CardView: View {
    let card: Card
    let width: CGFloat
    let aspect: Double

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
