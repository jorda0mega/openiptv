import SwiftUI

#if os(iOS)
/// A row of text tabs, the chosen one bright and underlined, the underline
/// sliding between them; scrolls sideways when they don't fit and keeps
/// the chosen one in view. Used for Live TV's categories.
struct TabStrip<ID: Hashable>: View {
    let items: [(id: ID, title: String)]
    let selected: ID?
    var leading: AnyView? = nil
    let select: (ID) -> Void
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            if let leading { leading.padding(.leading, 12) }
            ScrollViewReader { strip in
                ScrollView(.horizontal) {
                    HStack(spacing: 24) {
                        ForEach(items, id: \.id) { item in tab(item) }
                    }
                    .padding(.horizontal, 16)
                    .animation(.snappy(duration: 0.25), value: selected)
                }
                .scrollIndicators(.hidden)
                // Only sideways: a vertical drag here mustn't move the page.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                }
                .onAppear { if let selected { strip.scrollTo(selected, anchor: .center) } }
                .onChange(of: selected) { _, now in
                    if let now { withAnimation(.snappy(duration: 0.3)) { strip.scrollTo(now, anchor: .center) } }
                }
            }
        }
        .background(Color.black.allowsHitTesting(false))
    }

    private func tab(_ item: (id: ID, title: String)) -> some View {
        let chosen = item.id == selected
        return Button { select(item.id) } label: {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chosen ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    if chosen {
                        Capsule().fill(.white).frame(height: 3).padding(.bottom, 6)
                            .matchedGeometryEffect(id: "tab", in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
#endif
