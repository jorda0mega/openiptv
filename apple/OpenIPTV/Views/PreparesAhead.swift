import SwiftUI

extension View {
    /// Gets `target` ready while it stays on screen (iPhone) or in focus
    /// (Apple TV), as long as `place` says (see Ahead); a page or a
    /// forecast, while its screen is open. Not while the player covers it.
    /// On Apple TV, put it on the button's label: focus is the button's.
    func preparesAhead(_ target: Target?, at place: Place) -> some View {
        modifier(PreparesAhead(target: target, place: place))
    }
}

private struct PreparesAhead: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.isFocused) private var focused
    @State private var onScreen = false
    let target: Target?
    let place: Place

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background {
                GeometryReader { proxy in
                    let seen = Self.mostlySeen(proxy)
                    Color.clear
                        .onAppear { onScreen = seen }
                        .onChange(of: seen) { onScreen = seen }
                }
            }
            #endif
            .task(id: held ? target : nil) {
                if held, let target { await model.ahead.holding(target, at: place) }
            }
    }

    /// At least 60 % of it inside each scroll view it's in (its row's and
    /// the page's).
    private static func mostlySeen(_ proxy: GeometryProxy) -> Bool {
        let frame = proxy.frame(in: .local)
        guard frame.width > 0, frame.height > 0 else { return false }
        var seen = frame
        for axis in [Axis.horizontal, .vertical] {
            if let bounds = proxy.bounds(of: .scrollView(axis: axis)) { seen = seen.intersection(bounds) }
        }
        return !seen.isNull && seen.width * seen.height >= 0.6 * frame.width * frame.height
    }

    private var held: Bool {
        guard !model.playerShown else { return false }
        #if os(tvOS)
        return place.heldWhileOpen || focused
        #else
        return place.heldWhileOpen || onScreen
        #endif
    }
}
