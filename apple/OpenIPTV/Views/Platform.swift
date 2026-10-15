import SwiftUI

/// Small per-platform differences, kept here so screens read the same on
/// iPhone/iPad and Apple TV.
enum Layout {
    #if os(tvOS)
    static let posterWidth: CGFloat = 220
    static let rowSpacing: CGFloat = 40
    static let cardSpacing: CGFloat = 40
    static let chipStripHeight: CGFloat = 110
    static let searchThumb: CGFloat = 80
    static let searchThumbWide: CGFloat = 170
    static let scrubPreviewWidth: CGFloat = 400
    /// Home's featured pick: cinema-wide on a TV.
    static let featuredAspect: CGFloat = 21 / 9
    #else
    /// The Apple TV app's posters: 100 × 150, 12 apart (about 3.7 across).
    static let posterWidth: CGFloat = 100
    static let rowSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 12
    static let chipStripHeight: CGFloat = 60
    /// The Apple TV app's search posters: 54 × 81.
    static let searchThumb: CGFloat = 54
    static let searchThumbWide: CGFloat = 96
    static let scrubPreviewWidth: CGFloat = 200
    static let featuredAspect: CGFloat = 4 / 3
    #endif
}

extension View {
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Readable text inside a list button on Apple TV, which otherwise tints
    /// it with the accent colour: white, and black under the focus platter.
    func rowForeground() -> some View { modifier(RowForeground()) }

    /// Posters lift and tilt under focus on Apple TV; plain taps on iPhone.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

extension EnvironmentValues {
    /// Rows go black under Apple TV's white focus platter in lists; on
    /// cards, whose platter stays dark, they stay white.
    @Entry var rowInvertsOnFocus = true
}

private struct RowForeground: ViewModifier {
    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    @Environment(\.rowInvertsOnFocus) private var inverts
    func body(content: Content) -> some View { content.foregroundStyle(focused && inverts ? Color.black : Color.white) }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
