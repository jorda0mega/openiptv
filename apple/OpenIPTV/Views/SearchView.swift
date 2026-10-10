import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Binding var playback: PlaybackRequest?
    @State private var query = ""
    @State private var results: [Channel] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        playback = PlaybackRequest(channels: results, index: index)
                    } label: {
                        ChannelRow(channel: channel, info: model.nowNext[channel.id])
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.appeared(channel.id) }
                    .onDisappear { model.disappeared(channel.id) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.count >= 2, results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Channels")
            .task(id: query) {
                // Debounce typing.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                results = await model.search(query)
            }
        }
    }
}
