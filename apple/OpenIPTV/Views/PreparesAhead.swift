import SwiftUI

extension View {
    /// Gets `target` ready while it stays on screen (iPhone) or in focus
    /// (Apple TV), as long as `place` says (see Ahead). On Apple TV, put it
    /// on the button's label: focus is the button's.
    func preparesAhead(_ target: Target, at place: Place) -> some View {
        modifier(PreparesAhead(target: target, place: place))
    }
}

private struct PreparesAhead: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.isFocused) private var focused
    @State private var onScreen = false
    let target: Target
    let place: Place

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.task(id: focused ? target : nil) {
            if focused { await model.ahead.holding(target, at: place) }
        }
        #else
        content
            .onScrollVisibilityChange(threshold: 0.6) { onScreen = $0 }
            .task(id: onScreen ? target : nil) {
                if onScreen { await model.ahead.holding(target, at: place) }
            }
        #endif
    }
}
