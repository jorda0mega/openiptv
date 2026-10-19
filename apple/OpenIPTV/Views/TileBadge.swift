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
        case .didNotPlay: LiveFailures.didNotPlay
        }
    }
}

/// A white capsule with a TV and the count, or a grey circle with a
/// crossed-out TV.
struct TileBadgeView: View {
    let badge: TileBadge

    /// Its height: 17 points on iPhone, 30 on Apple TV (seen from the sofa).
    #if os(tvOS)
    static let size: CGFloat = 30
    #else
    static let size: CGFloat = 17
    #endif
    /// The TV glyph and the count, from the height: 11 points on iPhone, 19
    /// on Apple TV.
    private let glyph = (TileBadgeView.size * 0.64).rounded()
    private let number = (TileBadgeView.size * 0.62).rounded()

    var body: some View {
        switch badge {
        case let .channels(count):
            HStack(spacing: 2) {
                Image(systemName: "tv").font(.system(size: glyph, weight: .heavy))
                Text("\(count)").font(.system(size: number, weight: .heavy))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, Self.size * 0.3)
            .frame(minWidth: Self.size, minHeight: Self.size)
            .background(.white, in: .capsule)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.spoken)
        case .didNotPlay:
            Image(systemName: "tv.slash")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
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
