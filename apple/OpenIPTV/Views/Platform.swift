import SwiftUI

/// Small per-platform differences, kept here so screens read the same on
/// iPhone/iPad and Apple TV.
enum Layout {
    #if os(tvOS)
    static let posterWidth: CGFloat = 220
    static let rowSpacing: CGFloat = 40
    static let cardSpacing: CGFloat = 40
    #else
    static let posterWidth: CGFloat = 118
    static let rowSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 12
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

    /// Posters lift and tilt under focus on Apple TV; plain taps on iPhone.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}
