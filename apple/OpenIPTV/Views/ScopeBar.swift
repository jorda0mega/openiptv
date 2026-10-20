#if os(iOS)
import SwiftUI

/// All · Movies · Shows · Live TV, the chosen one in a white pill with
/// black words, as everywhere in the app (the player's pills). One pill,
/// slid to the chosen filter.
struct ScopeBar: View {
    @Binding var scope: SearchView.Scope
    let dimmed: Set<SearchView.Scope>
    /// Called as the pill starts for a new filter (SearchView's body doesn't
    /// read the filter, so a tap doesn't redraw the page before the pill).
    let chosen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let slide = Spring.snappy(duration: 0.25)

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SearchView.Scope.allCases) { option in
                let selected = option == scope
                Button { scope = option } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? .black : .white)
                        .opacity(dimmed.contains(option) && !selected ? 0.4 : 1)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: PillFrames.self, value: .bounds) { [option: $0] }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("scope-\(option.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .backgroundPreferenceValue(PillFrames.self) { frames in
            GeometryReader { proxy in
                if let frame = frames[scope].map({ proxy[$0] }) {
                    Pill(frame: frame, scope: scope, slide: reduceMotion ? nil : Self.slide)
                }
            }
        }
        .animation(.spring(Self.slide), value: scope)
        .onChange(of: scope) { chosen() }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The white pill, slid by Core Animation rather than redrawn by SwiftUI
/// each frame: it keeps moving while the results are rebuilt on the main
/// thread. It slides only to a newly chosen filter; moved for any other
/// reason (the bar laid out again: a resize, larger text) it's there at
/// once, never away from its words.
private struct Pill: UIViewRepresentable {
    let frame: CGRect
    let scope: SearchView.Scope
    /// Nil: no slide (Reduce Motion).
    let slide: Spring?

    final class Coordinator {
        var placed: SearchView.Scope?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let bar = UIView()
        bar.isUserInteractionEnabled = false
        bar.accessibilityElements = []
        let capsule = UIView(frame: frame)
        capsule.backgroundColor = .white
        capsule.layer.cornerRadius = frame.height / 2
        bar.addSubview(capsule)
        context.coordinator.placed = scope
        return bar
    }

    func updateUIView(_ bar: UIView, context: Context) {
        guard let capsule = bar.subviews.first, capsule.frame != frame else { return }
        let move = {
            capsule.frame = frame
            capsule.layer.cornerRadius = frame.height / 2
        }
        let chosen = context.coordinator.placed != scope
        context.coordinator.placed = scope
        guard chosen, let slide else { return UIView.performWithoutAnimation(move) }
        UIView.animate(springDuration: slide.duration, bounce: slide.bounce, options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: move)
    }
}

/// Runs the newest work given at the next screen refresh (work given
/// before it and not run yet is dropped): a hop on the main queue can still
/// land in the frame being made now.
final class NextFrame: NSObject {
    private var work: (() -> Void)?
    private var link: CADisplayLink?

    func run(_ work: @escaping () -> Void) {
        self.work = work
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        let work = self.work
        self.work = nil
        work?()
    }
}

private struct PillFrames: PreferenceKey {
    static let defaultValue: [SearchView.Scope: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SearchView.Scope: Anchor<CGRect>], nextValue: () -> [SearchView.Scope: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
#endif
