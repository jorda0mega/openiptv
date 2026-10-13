import SwiftUI

/// Someone in a title's cast or crew, as in the Apple TV app: their photo
/// and name, and the films and shows in the library they're in, newest
/// first. Opened from a title page's Cast & Crew.
struct PersonView: View {
    @Environment(AppModel.self) private var model
    let person: EmbyItem.Person
    @Binding var playing: PlayerItem?
    @State private var cards: [Card]?
    @State private var failed = false
    @State private var selected: Card?

    var body: some View {
        content
            .task { await load() }
            .navigationDestination(item: $selected) { card in
                #if os(tvOS)
                if card.kind == "Series" {
                    TVShowView(route: ShowRoute(id: card.id, title: card.title), playing: $playing)
                } else {
                    TVMovieView(route: MovieRoute(id: card.id, title: card.title), playing: $playing)
                }
                #else
                if card.kind == "Series" {
                    ShowView(route: ShowRoute(id: card.id, title: card.title), playing: $playing)
                } else {
                    MovieView(route: MovieRoute(id: card.id, title: card.title), playing: $playing)
                }
                #endif
            }
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var photo: some View {
        ZStack {
            Circle().fill(Color(white: 0.16))
            Text(initials).font(.title.weight(.semibold)).foregroundStyle(.secondary)
            if let url = model.emby?.personImageURL(person, width: 400) {
                CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: "")
            }
        }
        .clipShape(.circle)
    }

    #if os(tvOS)
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                HStack(spacing: 40) {
                    photo.frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.name).font(.largeTitle.weight(.bold))
                        if let role = roleLine { Text(role).font(.title3).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.top, 60)
                if let cards {
                    if cards.isEmpty {
                        Text("Nothing with \(person.name) in your library.").foregroundStyle(.secondary).padding(.horizontal, 90)
                    } else {
                        TVPosterRow(title: "Movies & Shows", cards: cards, captions: .always) { selected = $0 }
                    }
                } else if failed {
                    retry.frame(maxWidth: .infinity).frame(height: 400)
                } else {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 400)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }
    #else
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    photo.frame(width: 120, height: 120)
                    Text(person.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    if let role = roleLine { Text(role).font(.subheadline).foregroundStyle(.secondary) }
                }
                .padding(.top, 8)
                if let cards {
                    if cards.isEmpty {
                        Text("Nothing with \(person.name) in your library.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(cards) { card in
                                Button { selected = card } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Color.clear
                                            .aspectRatio(2 / 3, contentMode: .fit)
                                            .overlay { CoverImage(images: card.images, title: card.title) }
                                            .clipShape(.rect(cornerRadius: 10))
                                        Text(card.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                        Text(card.subtitle ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel([card.title, card.subtitle].compactMap(\.self).joined(separator: ", "))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                } else if failed {
                    retry.frame(height: 200)
                } else {
                    ProgressView().frame(height: 200)
                }
            }
            .padding(.bottom, 30)
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    /// "Actor", "Director", "Guest Star".
    private var roleLine: String? {
        guard let type = person.type, !type.isEmpty else { return nil }
        return type == "GuestStar" ? "Guest Star" : type
    }

    /// Couldn't reach the server: said so, with Try Again.
    private var retry: some View {
        VStack(spacing: 12) {
            Text("Couldn't load \(person.name)'s titles.").foregroundStyle(.secondary)
            Button("Try Again") {
                failed = false
                Task { await load() }
            }
        }
    }

    /// Their films and shows in the library, newest first.
    private func load() async {
        guard cards == nil, let emby = model.emby, let id = person.id else {
            if cards == nil { cards = [] }
            return
        }
        guard let found = try? await emby.personTitles(id) else {
            failed = true
            return
        }
        let items = found.sorted { ($0.productionYear ?? 0) > ($1.productionYear ?? 0) }
        #if os(tvOS)
        let width = 360
        #else
        let width = 240
        #endif
        cards = items.map { emby.card($0, context: .poster, shape: .portrait, width: width) }
    }
}
