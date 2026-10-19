import SwiftUI

enum TileBadge {
    case channels(Int)
    case didNotPlay
    case notPlaying

    static func count(_ channels: Int) -> TileBadge? {
        channels > 1 ? .channels(channels) : nil
    }

    var spoken: String {
        switch self {
        case let .channels(count): "\(count) channels"
        case .didNotPlay: LiveFailures.didNotPlay
        case .notPlaying: "Not playing"
        }
    }
}

struct TileBadgeView: View {
    let badge: TileBadge

    #if os(tvOS)
    static let size: CGFloat = 30
    static let cardInset: CGFloat = 8
    #else
    static let size: CGFloat = 17
    #endif
    static let outset: CGFloat = 6
    static let ringWidth: CGFloat = 2
    static let overhang: CGFloat = outset + ringWidth
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
        case .didNotPlay, .notPlaying:
            Image(systemName: "tv.slash")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
                .background(Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255), in: .circle)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    @ViewBuilder func tileBadge(_ badge: TileBadge?, ring: Color = .black) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let badge {
                TileBadgeView(badge: badge)
                    .background(Capsule().inset(by: -TileBadgeView.ringWidth).fill(ring))
                    .offset(x: TileBadgeView.outset, y: TileBadgeView.outset)
            }
        }
    }

    #if os(tvOS)
    /// The top-trailing corner, inside the card. Focus clips a badge that
    /// sticks out, and lifts the card under it.
    @ViewBuilder func cardBadge(_ badge: TileBadge?) -> some View {
        overlay(alignment: .topTrailing) {
            if let badge {
                TileBadgeView(badge: badge)
                    .background(Capsule().inset(by: -TileBadgeView.ringWidth).fill(.black.opacity(0.5)))
                    .padding(TileBadgeView.cardInset)
            }
        }
    }
    #endif
}
