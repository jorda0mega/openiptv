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
    #else
    static let posterWidth: CGFloat = 118
    static let rowSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 12
    static let chipStripHeight: CGFloat = 60
    static let searchThumb: CGFloat = 46
    static let searchThumbWide: CGFloat = 96
    static let scrubPreviewWidth: CGFloat = 200
    #endif
}

extension View {
    /// Pull to refresh where the platform has it.
    @ViewBuilder func refreshableOnPhone(_ action: @escaping @MainActor () async -> Void) -> some View {
        #if os(iOS)
        refreshable { await action() }
        #else
        self
        #endif
    }

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

private struct RowForeground: ViewModifier {
    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    func body(content: Content) -> some View { content.foregroundStyle(focused ? Color.black : Color.white) }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
