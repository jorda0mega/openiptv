import SwiftUI

/// Accounts, playback tuning, what shows where, and privacy controls.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    /// Opened from Home's gear: a Done button to close it.
    var asSheet = false
    @State private var adding: AddSheet?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            // Grouped like the iPhone's own Settings and Infuse: a short
            // list of places, each with its own page.
            Form {
                Section {
                    NavigationLink { page("Emby") { embySection } } label: {
                        SettingsRow(title: "Emby", symbol: "play.tv.fill", tint: .green,
                                    value: model.sources.emby?.serverName ?? "Not signed in")
                    }
                    NavigationLink { page("Live TV") { liveSection; favoritesSection; hiddenSection } } label: {
                        SettingsRow(title: "Live TV", symbol: "dot.radiowaves.left.and.right", tint: .red,
                                    value: liveSummary)
                    }
                }
                Section {
                    NavigationLink { page("Playback") { playbackSection } } label: {
                        SettingsRow(title: "Playback", symbol: "play.circle.fill", tint: .blue, value: prefs.playerProfile.title)
                    }
                    if !model.rows.isEmpty {
                        NavigationLink { page("Home") { homeSection } } label: {
                            SettingsRow(title: "Home", symbol: "house.fill", tint: .orange)
                        }
                    }
                }
                Section {
                    NavigationLink { page("Advanced") { advancedSection; privacySection } } label: {
                        SettingsRow(title: "Advanced", symbol: "gearshape.2.fill", tint: .gray)
                    }
                    NavigationLink { page("About") { aboutSection } } label: {
                        SettingsRow(title: "About", symbol: "info.circle.fill", tint: .gray, value: HTTP.appVersionAndBuild)
                    }
                }
            }
            #if os(tvOS)
            // A readable column on a TV, not pills across the whole screen.
            .frame(maxWidth: 1150)
            #endif
            .navigationTitle("Settings")
            .toolbar {
                if asSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
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
                Text("Signs out of Emby and removes every subscription, favorite, setting and cached guide from this device.")
            }
        }
    }

    /// A settings page: its sections in a form of their own.
    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            #if os(tvOS)
            .frame(maxWidth: 1150)
            #endif
            .navigationTitle(title)
    }

    private var liveSummary: String {
        let count = model.sources.iptv.count
        return count == 0 ? "Not set up" : count == 1 ? "1 source" : "\(count) sources"
    }

    @ViewBuilder private var embySection: some View {
        Section {
            if let account = model.sources.emby {
                LabeledContent(account.serverName, value: account.userName)
                Button("Sign out", role: .destructive) { Task { await model.signOutOfEmby() } }
            } else {
                Button("Add Emby server…") { adding = .emby }
            }
        } footer: {
            Text("Your Emby library: movies, shows and what you're watching.")
        }
    }

    @ViewBuilder private var liveSection: some View {
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
            Button("Add your TV provider…") { adding = .iptv }
            NavigationLink {
                AreaPicker()
            } label: {
                LabeledContent("Your area", value: prefs.area?.label ?? "Not set")
            }
            ForEach(model.liveErrors, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Sources")
        } footer: {
            Text(guideStatus)
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        Section("Favorite channels") {
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
    }

    @ViewBuilder private var hiddenSection: some View {
        if !prefs.hiddenCategories.isEmpty {
            Section("Hidden categories") {
                ForEach(prefs.hiddenCategories.sorted(), id: \.self) { id in
                    RowWithAction("Show") { prefs.hiddenCategories.remove(id) } label: {
                        Text(model.categories.first(where: { $0.id == id })?.name ?? "Unavailable category")
                    }
                }
            }
        }
    }

    @ViewBuilder private var playbackSection: some View {
        @Bindable var prefs = prefs
        Section {
            Picker("Player", selection: $prefs.playerProfile) {
                ForEach(PlayerProfile.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $prefs.adaptiveQuality) { Text("Lower quality instead of buffering").rowForeground() }
        } footer: {
            Text(prefs.playerProfile.detail + " Applies to the next channel or video you open.")
        }
        Section {
            LabeledContent("Audio", value: "English; Spanish for titles made in Spanish")
            LabeledContent("Subtitles", value: "Off, unless the audio is in neither")
        } header: {
            Text("Languages")
        } footer: {
            Text("What you pick in the player for a show or film is kept for it.")
        }
    }

    @ViewBuilder private var homeSection: some View {
        Section {
            ForEach(model.rows) { row in
                Toggle(isOn: Binding(
                    get: { !prefs.hiddenRows.contains(row.title) },
                    set: { show in
                        if show { prefs.hiddenRows.remove(row.title) } else { prefs.hiddenRows.insert(row.title) }
                    }
                )) { Text(row.title).rowForeground() }
            }
        } header: {
            Text("Rows")
        }
    }

    @ViewBuilder private var advancedSection: some View {
        @Bindable var prefs = prefs
        Section {
            Toggle(isOn: $prefs.hardwareDecoding) { Text("Hardware decoding").rowForeground() }
        } footer: {
            Text("Leave on: it plays 4K and HDR smoothly and saves battery. Turn off only if a video shows a green or broken picture.")
        }
        #if DEBUG
        Section {
            Toggle(isOn: $prefs.showPerformanceStats) { Text("Show performance stats").rowForeground() }
        } header: {
            Text("Developer")
        } footer: {
            Text("Development builds only: how fast videos start and jump, the quality and the connection speed, under the player's title.")
        }
        #endif
    }

    @ViewBuilder private var privacySection: some View {
        Section {
            Button("Forget everything on this device", role: .destructive) { confirmForget = true }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Logins live only in this device's Keychain (not iCloud, not backups). Openreel has no servers, collects nothing and logs nothing.")
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            // The build beside the version, as in TestFlight: every upload
            // is 0.2.0, the build tells them apart (the user's request).
            LabeledContent("Version", value: HTTP.appVersionAndBuild)
            if let built = HTTP.appBuildDate { LabeledContent("Built", value: built) }
            #if os(iOS)
            Link("Source code on GitHub", destination: URL(string: "https://github.com/jorda0mega/openiptv")!)
            #else
            LabeledContent("Source code", value: "github.com/jorda0mega/openiptv")
            #endif
        } footer: {
            Text("Ratings and popularity: information courtesy of IMDb (imdb.com), used with permission. Downloaded about once a week on Wi-Fi.")
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

/// A place in Settings: its icon in a coloured rounded square, like the
/// iPhone's own Settings, and what it's set to.
private struct SettingsRow: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 7))
            Text(title).rowForeground()
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
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
