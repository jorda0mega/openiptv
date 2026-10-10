import SwiftUI

/// Accounts, playback tuning, what shows where, and privacy controls.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var adding: AddSheet?
    @State private var confirmForget = false

    var body: some View {
        @Bindable var prefs = prefs
        NavigationStack {
            Form {
                Section("Emby") {
                    if let account = model.sources.emby {
                        LabeledContent(account.serverName, value: account.userName)
                        Button("Sign out", role: .destructive) { Task { await model.signOutOfEmby() } }
                    } else {
                        Button("Add Emby server…") { adding = .emby }
                    }
                }

                Section {
                    ForEach(model.sources.iptv) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text("\(source.formatName) · \(source.safeDescription)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { Task { await model.remove(source) } }
                        }
                    }
                    Button("Add IPTV subscription…") { adding = .iptv }
                    ForEach(model.liveErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("Live TV sources")
                } footer: {
                    Text(guideStatus)
                }

                Section {
                    Picker("Player", selection: $prefs.playerProfile) {
                        ForEach(PlayerProfile.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hardware decoding", isOn: $prefs.hardwareDecoding)
                } header: {
                    Text("Playback")
                } footer: {
                    Text(prefs.playerProfile.detail + " Applies to the next channel or video you open.")
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

                Section("Favourite channels") {
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
                }

                if !prefs.hiddenCategories.isEmpty {
                    Section("Hidden categories") {
                        ForEach(prefs.hiddenCategories.sorted(), id: \.self) { id in
                            HStack {
                                Text(model.categories.first(where: { $0.id == id })?.name ?? "Unavailable category")
                                Spacer()
                                Button("Show") { prefs.hiddenCategories.remove(id) }
                            }
                        }
                    }
                }

                Section {
                    Button("Forget everything on this device", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Logins live only in this device's Keychain (not iCloud, not backups). OpenIPTV has no servers, collects nothing and logs nothing.")
                }

                Section("About") {
                    LabeledContent("Version", value: HTTP.appVersion)
                    #if os(iOS)
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/jorda0mega/openiptv")!)
                    #else
                    LabeledContent("Source code", value: "github.com/jorda0mega/openiptv")
                    #endif
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $adding) { sheet in
                switch sheet {
                case .emby: AddEmbyView()
                case .iptv: AddIPTVView()
                }
            }
            .confirmationDialog("Forget everything?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget everything", role: .destructive) {
                    Task {
                        await model.forgetEverything()
                        prefs.favorites = []
                        prefs.hiddenCategories = []
                        prefs.hiddenRows = []
                    }
                }
            } message: {
                Text("Signs out of Emby and removes every subscription, favourite, setting and cached guide from this device.")
            }
        }
    }

    private var guideStatus: String {
        switch model.guideState {
        case .idle: "Programme guide: not loaded yet."
        case .loading: "Programme guide: downloading in the background…"
        case let .ready(count, at): "Programme guide: \(count.formatted()) programmes, updated \(at.formatted(.relative(presentation: .named)))."
        case let .failed(message): "Programme guide: \(message)"
        }
    }
}
