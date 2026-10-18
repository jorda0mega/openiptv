import SwiftUI

/// The badge on a channel's or a game's tile: how many channels show a
/// game, or that a channel didn't play. One tile has one badge (where: see
/// tileBadge).
enum TileBadge {
    case channels(Int)
    case didNotPlay

    /// A game's: its count when more than one channel shows it.
    static func count(_ channels: Int) -> TileBadge? {
        channels > 1 ? .channels(channels) : nil
    }

    /// What VoiceOver says for it: "5 channels", "Didn’t play".
    var spoken: String {
        switch self {
        case let .channels(count): "\(count) channels"
        case .didNotPlay: "Didn’t play"
        }
    }
}

/// A white capsule with a TV and the count, or a grey circle with a
/// crossed-out TV. 17 points tall on iPhone, 22 on Apple TV.
struct TileBadgeView: View {
    let badge: TileBadge

    #if os(tvOS)
    private let height: CGFloat = 22, glyph: CGFloat = 14
    #else
    private let height: CGFloat = 17, glyph: CGFloat = 11
    #endif

    var body: some View {
        switch badge {
        case let .channels(count):
            HStack(spacing: 2) {
                Image(systemName: "tv")
                Text("\(count)")
            }
            .font(.system(size: glyph, weight: .heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(.white, in: .capsule)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.spoken)
        case .didNotPlay:
            Image(systemName: "tv.slash")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: height, height: height)
                .background(Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255), in: .circle)
                // The words beside it say it ("Didn’t play").
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The badge on this tile: its bottom-trailing corner, 6 points out,
    /// ringed in `ring` (what's behind the tile) so it reads as on top. On
    /// an Apple TV card (`onCard`), inside the top-trailing corner, 8 points
    /// in, ringed dark against the tile: the card's focus clips what sticks
    /// out and lifts the card under it.
    @ViewBuilder func tileBadge(_ badge: TileBadge?, ring: Color = .black, onCard: Bool = true) -> some View {
        #if os(tvOS)
        if onCard {
            overlay(alignment: .topTrailing) {
                if let badge {
                    TileBadgeView(badge: badge)
                        .background(Capsule().inset(by: -2).fill(.black.opacity(0.5)))
                        .padding(8)
                }
            }
        } else {
            sticksOut(badge, ring: ring)
        }
        #else
        sticksOut(badge, ring: ring)
        #endif
    }

    private func sticksOut(_ badge: TileBadge?, ring: Color) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let badge {
                TileBadgeView(badge: badge)
                    .background(Capsule().inset(by: -2).fill(ring))
                    .offset(x: 6, y: 6)
            }
        }
    }
}
