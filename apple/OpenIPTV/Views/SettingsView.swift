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
                        RowWithAction("Remove", role: .destructive, confirm: "Remove \(source.name)?") {
                            Task { await model.remove(source) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text("\(source.formatName) · \(source.safeDescription)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Add IPTV subscription…") { adding = .iptv }
                    NavigationLink {
                        AreaPicker()
                    } label: {
                        LabeledContent("Your area", value: prefs.area?.label ?? "Not set")
                    }
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
                    Toggle(isOn: $prefs.hardwareDecoding) { Text("Hardware decoding").rowForeground() }
                    Toggle(isOn: $prefs.adaptiveQuality) { Text("Lower quality instead of buffering").rowForeground() }
                    #if os(iOS)
                    Toggle(isOn: $prefs.rotateWithPhone) { Text("Turn videos with the phone, even with Rotation Lock on").rowForeground() }
                    #endif
                } header: {
                    Text("Playback")
                } footer: {
                    Text(prefs.playerProfile.detail + " Applies to the next channel or video you open.")
                }

                if !model.rows.isEmpty {
                    Section("Home rows") {
                        ForEach(model.rows) { row in
                            Toggle(isOn: Binding(
                                get: { !prefs.hiddenRows.contains(row.title) },
                                set: { show in
                                    if show { prefs.hiddenRows.remove(row.title) } else { prefs.hiddenRows.insert(row.title) }
                                }
                            )) { Text(row.title).rowForeground() }
                        }
                    }
                }

                Section("Favourite channels") {
                    if prefs.favorites.isEmpty {
                        Text("Press and hold a channel to add it.").foregroundStyle(.secondary)
                    }
                    ForEach(prefs.favorites) { channel in
                        RowWithAction("Remove", role: .destructive) { prefs.toggleFavorite(channel) } label: {
                            Text(channel.name)
                        }
                    }
                    #if os(iOS)
                    .onMove { prefs.favorites.move(fromOffsets: $0, toOffset: $1) }
                    #endif
                }

                if !prefs.hiddenCategories.isEmpty {
                    Section("Hidden categories") {
                        ForEach(prefs.hiddenCategories.sorted(), id: \.self) { id in
                            RowWithAction("Show") { prefs.hiddenCategories.remove(id) } label: {
                                Text(model.categories.first(where: { $0.id == id })?.name ?? "Unavailable category")
                            }
                        }
                    }
                }

                Section {
                    Button("Forget everything on this device", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Logins live only in this device's Keychain (not iCloud, not backups). Openreel has no servers, collects nothing and logs nothing.")
                }

                Section {
                    LabeledContent("Version", value: HTTP.appVersion)
                    #if os(iOS)
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/jorda0mega/openiptv")!)
                    #else
                    LabeledContent("Source code", value: "github.com/jorda0mega/openiptv")
                    #endif
                } header: {
                    Text("About")
                } footer: {
                    Text("Ratings and popularity: information courtesy of IMDb (imdb.com), used with permission. Downloaded about once a week on Wi-Fi.")
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

/// A row with one trailing action. iPhone: a button at the end of the row.
/// Apple TV: the whole row is the button (a button nested in a row leaves the
/// row's text white on the white focus platter), confirming first if asked.
private struct RowWithAction<Label: View>: View {
    let title: String
    let role: ButtonRole?
    let confirm: String?
    let action: () -> Void
    let label: Label
    @State private var confirming = false

    init(_ title: String, role: ButtonRole? = nil, confirm: String? = nil,
         action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.title = title
        self.role = role
        self.confirm = confirm
        self.action = action
        self.label = label()
    }

    var body: some View {
        #if os(tvOS)
        Button {
            if confirm == nil { action() } else { confirming = true }
        } label: {
            HStack {
                label
                Spacer()
                Text(title).foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
            }
            .rowForeground()
        }
        .confirmationDialog(confirm ?? title, isPresented: $confirming, titleVisibility: .visible) {
            Button(title, role: role, action: action)
        }
        #else
        HStack {
            label
            Spacer()
            Button(title, role: role, action: action)
        }
        #endif
    }
}
