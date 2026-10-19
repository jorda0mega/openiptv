import SwiftUI

/// The channel picked didn't play and the player moved on: its logo, dimmed
/// and marked, then where the player went: a spinner and "Switching" while
/// that channel starts, its logo and "Now on NFL" once it plays. A small
/// capsule at the top: in the middle it would cover the play button, at the
/// bottom the score bar and subtitles.
struct SwitchCue: View {
    let from: LiveChannel
    let fromName: String
    /// The channel the player moved to, once it plays; nil while it starts.
    let to: LiveChannel?
    let toName: String?

    #if os(tvOS)
    private let tile = CGSize(width: 69, height: 48), font: CGFloat = 29, spacing: CGFloat = 14
    private let inset = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 22)
    #else
    private let tile = CGSize(width: 46, height: 32), font: CGFloat = 15, spacing: CGFloat = 8
    private let inset = EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 14)
    #endif
    private let fill = Color(white: 0.1)

    var body: some View {
        HStack(spacing: spacing) {
            logo(from, name: fromName)
                .opacity(0.5)
                .tileBadge(.didNotPlay, ring: fill, onCard: false)
            Image(systemName: "arrow.right")
                .font(.system(size: font * 0.8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            if let to, let toName {
                logo(to, name: toName)
                Text("Now on \(toName)")
            } else {
                ProgressView().tint(.white).frame(width: tile.height, height: tile.height)
                Text("Switching")
            }
        }
        .font(.system(size: font, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        // A long name ("Now on ESPN Unlimited (Spanish)") shrinks a little,
        // then loses its middle.
        .minimumScaleFactor(0.75)
        .truncationMode(.middle)
        .padding(inset)
        .background(fill.opacity(0.9), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchOn.switchSentence(from: fromName, to: toName))
        .accessibilityIdentifier("live.switch-cue")
    }

    /// The channel's logo; without one, its name's first word ("ESPN").
    private func logo(_ channel: LiveChannel, name: String) -> some View {
        ChannelLogo(url: channel.logo, name: name, size: tile,
                    initials: name.split(separator: " ").first.map(String.init) ?? name)
    }
}
