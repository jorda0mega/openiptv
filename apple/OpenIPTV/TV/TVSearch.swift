#if os(tvOS)
import SwiftUI

/// A titled row of cards that scrolls sideways, like the TV app's.
struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVRowTitle(title)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) { content }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}
#endif
