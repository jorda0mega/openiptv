import SwiftUI

/// The top of a film's or show's page, like the TV apps' (Apple TV, HBO
/// Max): the backdrop edge to edge, fading into the page, the title's logo
/// (or its name) centred over it, what it is, and the buttons.
struct TitleHero<Buttons: View>: View {
    let backdrop: URL?
    let logo: URL?
    let title: String
    /// "Movie · Science Fiction · Adventure"
    let line: String
    /// Taller when it runs up under the navigation bar.
    var height: CGFloat = 1.15
    @ViewBuilder var buttons: Buttons
    @State private var width: CGFloat = 393

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .overlay {
                    if let backdrop {
                        CoverImage(images: [CardImage(url: backdrop.absoluteString, contain: false)], title: title, backdrop: true)
                    }
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0), .init(color: .clear, location: 0.22),
                                           .init(color: .clear, location: 0.45), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                HeroTitle(logo: logo?.absoluteString, title: title)
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                buttons.padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: (width * height).rounded())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The white Play capsule ("Continue S4 E2" when partway through), with a
/// spinner while it opens: as wide as its words, at least 178 points, like
/// the Apple TV app's (not the screen's width). Like Disney+, Prime Video
/// and Netflix, the button holds only the words; how far in and the time
/// left sit on a thin bar under it.
struct PlayCapsule: View {
    let label: String
    var progress: Double? = nil
    /// "18 min left", beside the bar.
    var left: String? = nil
    let loading: Bool
    let action: () -> Void

    private var hasProgress: Bool { (progress ?? 0) > 0 }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "play.fill")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 28)
                .frame(minWidth: 178)
                .frame(height: 48)
                .opacity(loading ? 0 : 1)
                .overlay { if loading { ProgressView().tint(.black) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(.white, in: .capsule)
        .disabled(loading)
        // How far in, as wide as the button, under it.
        .overlay(alignment: .bottom) {
            if let progress, progress > 0 {
                HStack(spacing: 10) {
                    Capsule().fill(.white.opacity(0.25))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule().fill(.white).frame(width: bar.size.width * min(progress, 1))
                            }
                        }
                    if let left {
                        Text(left)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize()
                    }
                }
                .frame(height: 16)
                .offset(y: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(left ?? "\(Int(min(progress, 1) * 100))% watched")
            }
        }
        // The bar's room is kept even before there's progress, so coming
        // back from the player doesn't move the title and button up. Not
        // animated: "Play" turning into "Continue" faded one into the other.
        .padding(.bottom, 28)
    }
}

#if os(iOS)
/// "+" beside Play, as in the Apple TV app: puts the title on My List (a
/// tick once it's there). Round glass, as tall as the Play button.
struct MyListButton: View {
    @Environment(AppModel.self) private var model
    let item: EmbyItem?

    var body: some View {
        let on = item.map { model.isOnMyList($0.id, item: $0) } ?? false
        Button {
            if let item { model.toggleMyList(item) }
        } label: {
            Image(systemName: on ? "checkmark" : "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(QuickPress())
        .disabled(item == nil)
        .accessibilityLabel(on ? "Remove from My List" : "Add to My List")
    }
}
#endif

/// Cast & Crew: round photos with name and part.
struct CastRow: View {
    @Environment(AppModel.self) private var model
    let people: [EmbyItem.Person]
    /// Their page (films and shows with them in the library).
    var open: (EmbyItem.Person) -> Void = { _ in }

    var body: some View {
        let shown = Array(people.filter { ["Actor", "Director", "GuestStar", "Writer"].contains($0.type ?? "") }.prefix(20))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cast & Crew").font(.title3.weight(.bold)).padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, person in
                            Button { open(person) } label: { castCard(person) }
                                .buttonStyle(.plain)
                                .disabled(person.id == nil)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func castCard(_ person: EmbyItem.Person) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color(white: 0.16))
                Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.headline).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let url = model.emby?.personImageURL(person, width: 200) {
                    CoverImage(images: [CardImage(url: url.absoluteString, contain: false)], title: "")
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(.circle)
            VStack(spacing: 2) {
                Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(person.role.flatMap { $0.isEmpty ? nil : $0 } ?? (person.type == "GuestStar" ? "Guest Star" : person.type ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 88)
        }
        .accessibilityElement(children: .combine)
    }
}
