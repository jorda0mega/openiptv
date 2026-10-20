#if os(iOS)
import SwiftUI

/// All · Movies · Shows · Live TV, the chosen one in a white pill with
/// black words, as everywhere in the app (the player's pills). One pill,
/// slid to the chosen filter.
struct ScopeBar: View {
    @Binding var scope: SearchView.Scope
    @Binding var shownScope: SearchView.Scope
    let dimmed: Set<SearchView.Scope>

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
                if let frame = frames[scope].map({ proxy[$0] }) { Pill(frame: frame) }
            }
        }
        .animation(.snappy(duration: 0.25), value: scope)
        .onChange(of: scope) { _, chosen in
            NextFrame.run { withTransaction(\.disablesAnimations, true) { shownScope = chosen } }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The white pill, slid by Core Animation rather than redrawn by SwiftUI
/// each frame: it keeps moving while the results are rebuilt on the main
/// thread.
private struct Pill: UIViewRepresentable {
    let frame: CGRect

    func makeUIView(context: Context) -> UIView {
        let bar = UIView()
        bar.isUserInteractionEnabled = false
        let capsule = UIView(frame: frame)
        capsule.backgroundColor = .white
        capsule.layer.cornerRadius = frame.height / 2
        bar.addSubview(capsule)
        return bar
    }

    func updateUIView(_ bar: UIView, context: Context) {
        guard let capsule = bar.subviews.first, capsule.frame != frame else { return }
        let move = {
            capsule.frame = frame
            capsule.layer.cornerRadius = frame.height / 2
        }
        guard context.transaction.animation != nil, !context.transaction.disablesAnimations else { return move() }
        UIView.animate(springDuration: 0.25, bounce: 0.15, options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: move)
    }
}

/// Runs work at the next screen refresh: a hop on the main queue can
/// still land in the frame being made now.
private final class NextFrame: NSObject {
    private let work: () -> Void
    private init(_ work: @escaping () -> Void) { self.work = work }

    static func run(_ work: @escaping () -> Void) {
        CADisplayLink(target: NextFrame(work), selector: #selector(fire)).add(to: .main, forMode: .common)
    }

    @objc private func fire(_ link: CADisplayLink) {
        link.invalidate()
        work()
    }
}

private struct PillFrames: PreferenceKey {
    static let defaultValue: [SearchView.Scope: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SearchView.Scope: Anchor<CGRect>], nextValue: () -> [SearchView.Scope: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
#endif
