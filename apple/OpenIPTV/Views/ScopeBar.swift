#if os(iOS)
import SwiftUI

struct ScopeBar: View {
    @Binding var scope: SearchView.Scope
    let dimmed: Set<SearchView.Scope>
    let onPillStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    fileprivate static let slide = Spring.snappy(duration: 0.25)

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
                if let anchor = frames[scope] {
                    Pill(frame: proxy[anchor], scope: scope, slides: !reduceMotion)
                }
            }
        }
        .animation(.spring(Self.slide), value: scope)
        .onChange(of: scope) { onPillStart() }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The white pill, slid by Core Animation rather than redrawn by SwiftUI
/// each frame: it keeps moving while the results are rebuilt on the main
/// thread.
private struct Pill: UIViewRepresentable {
    let frame: CGRect
    let scope: SearchView.Scope
    let slides: Bool

    final class Coordinator {
        var placedFor: SearchView.Scope?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let bar = UIView()
        bar.isUserInteractionEnabled = false
        bar.accessibilityElements = []
        let capsule = UIView()
        capsule.backgroundColor = .white
        Self.place(capsule, in: frame)
        bar.addSubview(capsule)
        context.coordinator.placedFor = scope
        return bar
    }

    func updateUIView(_ bar: UIView, context: Context) {
        guard let capsule = bar.subviews.first, capsule.frame != frame else { return }
        let move = { Self.place(capsule, in: frame) }
        let newFilter = context.coordinator.placedFor != scope
        context.coordinator.placedFor = scope
        if newFilter, slides {
            UIView.animate(springDuration: ScopeBar.slide.duration, bounce: ScopeBar.slide.bounce,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: move)
        } else {
            UIView.performWithoutAnimation(move)
        }
    }

    private static func place(_ capsule: UIView, in frame: CGRect) {
        capsule.frame = frame
        capsule.layer.cornerRadius = frame.height / 2
    }
}

/// Two screen refreshes on: by then the frame being made now is on
/// screen, and with it the first frame of anything Core Animation started
/// in it (a hop on the main queue, or one refresh, can land in that frame).
final class AfterNextFrame: NSObject {
    private var work: (() -> Void)?
    private var link: CADisplayLink?
    private var refreshes = 0

    func run(_ work: @escaping () -> Void) {
        self.work = work
        refreshes = 0
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshed))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func refreshed() {
        refreshes += 1
        guard refreshes == 2 else { return }
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
