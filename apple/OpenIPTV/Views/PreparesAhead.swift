import SwiftUI

extension View {
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
                    let share = Self.shareOnScreen(proxy), origin = proxy.frame(in: .global).origin
                    Color.clear
                        .onAppear { see(share, from: origin) }
                        .onChange(of: share) { see(share, from: origin) }
                        .onDisappear { if let target { model.ahead.showing.hide(target, at: place) } }
                }
            }
            #endif
            .task(id: held ? target : nil, priority: .utility) {
                if held, let target { await model.ahead.holding(target, at: place) }
            }
    }

    #if os(iOS)
    private func see(_ share: Double, from origin: CGPoint) {
        onScreen = share >= 0.6
        guard let target, place.isRestedOn(at: .likely) else { return }
        model.ahead.showing.show(target, at: place, share: share, from: origin)
    }

    private static func shareOnScreen(_ proxy: GeometryProxy) -> Double {
        let frame = proxy.frame(in: .local)
        guard frame.width > 0, frame.height > 0 else { return 0 }
        var seen = frame
        for axis in [Axis.horizontal, .vertical] {
            if let bounds = proxy.bounds(of: .scrollView(axis: axis)) { seen = seen.intersection(bounds) }
        }
        return seen.isNull ? 0 : seen.width * seen.height / (frame.width * frame.height)
    }
    #endif

    private var held: Bool {
        guard !model.playerShown, !AppModel.noPrepareAhead else { return false }
        #if os(tvOS)
        return place.heldWhileOpen || focused
        #else
        return place.heldWhileOpen || onScreen
        #endif
    }
}
