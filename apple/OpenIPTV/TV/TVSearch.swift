#if os(tvOS)
import SwiftUI
import UIKit

/// The system search field and keyboard row, from UIKit's search
/// container rather than SwiftUI's `.searchable`: on tvOS 26 `.searchable`
/// puts its field under the sidebar's button in the top left corner, where
/// nothing can move it. This one sits wherever it's placed and keeps the
/// system keyboard (typing from an iPhone, dictation). The results go under
/// it in SwiftUI, not in the search controller: the remote can't move focus
/// into SwiftUI hosted inside it.
struct TVSearchContainer: UIViewControllerRepresentable {
    @Binding var query: String
    let prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }

    func makeUIViewController(context: Context) -> UISearchContainerViewController {
        // tvOS requires a results controller; the results are below, in SwiftUI.
        let empty = UIViewController()
        empty.view.backgroundColor = .clear
        empty.view.isUserInteractionEnabled = false
        let search = UISearchController(searchResultsController: empty)
        search.searchResultsUpdater = context.coordinator
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = prompt
        search.searchBar.text = query
        search.searchBar.autocorrectionType = .no
        search.searchBar.autocapitalizationType = .none
        return UISearchContainerViewController(searchController: search)
    }

    func updateUIViewController(_ container: UISearchContainerViewController, context: Context) {
        context.coordinator.query = $query
    }

    @MainActor
    final class Coordinator: NSObject, UISearchResultsUpdating {
        var query: Binding<String>

        init(query: Binding<String>) { self.query = query }

        func updateSearchResults(for searchController: UISearchController) {
            let text = searchController.searchBar.text ?? ""
            if query.wrappedValue != text { query.wrappedValue = text }
        }
    }
}

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
