import SwiftUI

/// Everything the user can tune: playback behaviour, which Home rows show,
/// favourites and hidden categories, and the server connection.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var showingPairing = false

    var body: some View {
        @Bindable var prefs = prefs
        NavigationStack {
            Form {
                Section("Server") {
                    statusRow("Emby", ok: model.status?.emby.ok,
                              detail: model.status?.emby.server ?? model.status?.emby.error)
                    statusRow("Live TV", ok: model.status?.live.ok,
                              detail: model.status?.live.channels.map { "\($0.formatted()) channels" } ?? model.status?.live.error)
                    LabeledContent("Address", value: model.server?.url.host() ?? "—")
                    Button("Pair with a server…") { showingPairing = true }
                }

                Section {
                    Picker("Player", selection: $prefs.playerProfile) {
                        ForEach(PlayerProfile.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hardware decoding", isOn: $prefs.hardwareDecoding)
                } header: {
                    Text("Playback")
                } footer: {
                    Text(prefs.playerProfile.detail + " Changes apply to the next channel or video you open.")
                }

                if !model.rows.isEmpty {
                    Section("Home rows") {
                        ForEach(model.rows) { row in
                            Toggle(row.title, isOn: Binding(
                                get: { !prefs.hiddenRows.contains(row.title) },
                                set: { show in
                                    if show { prefs.hiddenRows.remove(row.title) } else { prefs.hiddenRows.insert(row.title) }
                                }
                            ))
                        }
                    }
                }

                Section {
                    if prefs.favorites.isEmpty {
                        Text("Press and hold a channel to add it.").foregroundStyle(.secondary)
                    }
                    ForEach(prefs.favorites) { channel in
                        HStack {
                            Text(channel.name)
                            Spacer()
                            Button("Remove", role: .destructive) { prefs.toggleFavorite(channel) }
                        }
                    }
                    #if os(iOS)
                    .onMove { prefs.favorites.move(fromOffsets: $0, toOffset: $1) }
                    #endif
                } header: {
                    Text("Favourite channels")
                }

                if !prefs.hiddenCategories.isEmpty {
                    Section("Hidden categories") {
                        ForEach(prefs.hiddenCategories.sorted(), id: \.self) { id in
                            HStack {
                                Text(model.categories.first(where: { $0.id == id })?.name ?? id)
                                Spacer()
                                Button("Show") { prefs.hiddenCategories.remove(id) }
                            }
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    #if os(iOS)
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/jorda0mega/openiptv")!)
                    #else
                    LabeledContent("Source code", value: "github.com/jorda0mega/openiptv")
                    #endif
                }
            }
            .navigationTitle("Settings")
            .task { await model.refreshStatus() }
            .sheet(isPresented: $showingPairing) { ConnectView(isSheet: true) }
        }
    }

    private func statusRow(_ title: String, ok: Bool?, detail: String?) -> some View {
        HStack {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ok == true ? .green : ok == false ? .red : .secondary)
            Text(title)
            Spacer()
            Text(detail ?? "…").foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
