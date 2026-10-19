#if os(tvOS)
import SwiftUI

/// Apple TV's Watch On: the channels showing the game in a row, as the
/// player's Episodes row (TVMovieOverlay): its tab lit over them, each
/// one's logo, service, and its feed, language and picture; "Playing" on
/// the one playing, the remote's raised. The remote moves along it (see
/// LivePlayerView), Select plays one.
struct TVWatchOnRow: View {
    @Environment(AppModel.self) private var model
    let choices: [AppModel.WatchChoice]
    let playing: String?
    let focused: Int

    var body: some View {
        ZStack {
            // The row has no glass box: a fade from the middle down keeps
            // its words clear of a bright picture.
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 45) {
                TVPlayerInfoTab(title: "Watch On", selected: true)
                row
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .ignoresSafeArea()
        }
    }

    private var row: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        card(choice, on: index == focused)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onAppear { scroll(reader, animated: false) }
            .onChange(of: focused) { _, _ in scroll(reader, animated: true) }
        }
        .frame(height: 300)
    }

    private func card(_ choice: AppModel.WatchChoice, on: Bool) -> some View {
        let label = choice.label
        let shown = model.watchOnShown(choice, playingCopy: playing)
        return VStack(alignment: .leading, spacing: 10) {
            CoverImage(images: choice.channel.logo.map { [CardImage(url: $0.absoluteString, contain: true)] } ?? [],
                       title: label.title)
                .frame(width: 320, height: 180)
                .background(Color(white: 0.14))
                .clipShape(.rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(on ? 0.9 : 0.15), lineWidth: on ? 3 : 1))
                .cardBadge(shown.didNotPlay ? .didNotPlay : nil)
                // Without a logo it shows the service's name, read below.
                .accessibilityHidden(true)
            Text(label.title).font(.system(size: 25, weight: .semibold)).lineLimit(1)
            if !shown.line.isEmpty {
                Text(shown.line).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 320, alignment: .leading)
        .scaleEffect(on ? 1.08 : 1, anchor: .bottom)
        .shadow(color: .black.opacity(on ? 0.4 : 0), radius: 16, y: 10)
        .id(choice.id)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.watchon.\(choice.id)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func scroll(_ reader: ScrollViewProxy, animated: Bool) {
        guard choices.indices.contains(focused) else { return }
        let id = choices[focused].id
        if animated {
            withAnimation(.snappy(duration: 0.25)) { reader.scrollTo(id, anchor: .center) }
        } else {
            reader.scrollTo(id, anchor: .center)
        }
    }
}
#endif
