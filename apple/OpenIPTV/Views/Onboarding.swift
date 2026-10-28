import SwiftUI

/// First launch: add an Emby server and/or IPTV subscriptions. Everything
/// entered here stays on this device, in the Keychain.
struct WelcomeView: View {
    @State private var adding: AddSheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("Logo").resizable().frame(width: 112, height: 112).accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text("Zapline").font(.largeTitle.weight(.bold))
                    Text("Your Emby library and live TV in one fast app.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        Button { adding = .emby } label: {
                            Label("Add Emby server", systemImage: "film.stack").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button { adding = .iptv } label: {
                            Label("Add IPTV subscription", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.extraLarge)
                }
                PrivacyNote()
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $adding) { sheet in
            switch sheet {
            case .emby: AddEmbyView()
            case .iptv: AddIPTVView()
            }
        }
    }
}

enum AddSheet: String, Identifiable {
    case emby, iptv
    var id: String { rawValue }
}

struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Your logins are stored only on this device, encrypted in the Keychain. Nothing is sent anywhere except to your own Emby server and IPTV provider, and nothing is logged.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - Emby

struct AddEmbyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Method: String, CaseIterable, Identifiable {
        case server = "Server login", connect = "Emby Connect"
        var id: String { rawValue }
    }

    @State private var method = Method.server
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var connect: EmbyConnectSession?

    var body: some View {
        FormSheet(title: "Emby") {
            Form {
                Picker("Sign in with", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if let connect {
                    Section("Choose a server") {
                        if connect.servers.isEmpty {
                            Text("No servers are linked to this Emby Connect account.").foregroundStyle(.secondary)
                        }
                        ForEach(connect.servers) { server in
                            Button(server.name) { pick(server, in: connect) }.disabled(busy)
                        }
                    }
                } else if method == .server {
                    Section {
                        TextField("Server address", text: $address, prompt: Text(verbatim: "emby.example.com or 192.168.1.10:8096"))
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("Only the session token Emby issues is kept — never your password.")
                    }
                } else {
                    Section {
                        TextField("Email or username", text: $username)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("Your emby.media account. You'll pick one of the servers shared with you.")
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                if connect == nil {
                    Button { signIn() } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || !canSubmit)
                }
            }
            .onChange(of: method) { _, _ in
                error = nil
                connect = nil
            }
        }
    }

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && (method == .connect || EmbyClient.normalise(address) != nil)
    }

    private func signIn() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                switch method {
                case .server:
                    guard let server = EmbyClient.normalise(address) else { return }
                    let account = try await EmbyClient.login(server: server, username: username, password: password,
                                                             deviceId: model.sources.deviceId)
                    password = ""
                    await model.signedInToEmby(account)
                    dismiss()
                case .connect:
                    connect = try await EmbyClient.connectLogin(email: username, password: password)
                    password = ""
                }
            } catch {
                self.error = SourceError.wrap(error).localizedDescription
            }
        }
    }

    private func pick(_ server: EmbyConnectServer, in session: EmbyConnectSession) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let account = try await EmbyClient.exchange(server, session: session, deviceId: model.sources.deviceId)
                await model.signedInToEmby(account)
                dismiss()
            } catch {
                self.error = SourceError.wrap(error).localizedDescription
            }
        }
    }
}

// MARK: - IPTV

struct AddIPTVView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case xtream = "Xtream Codes", m3u = "M3U playlist", stalker = "Stalker portal"
        var id: String { rawValue }
    }

    @State private var format = Format.xtream
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var playlist = ""
    @State private var guide = ""
    @State private var portal = ""
    @State private var mac = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        FormSheet(title: "IPTV subscription") {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif

                Section {
                    TextField("Name (optional)", text: $name, prompt: Text(verbatim: "My IPTV"))
                    switch format {
                    case .xtream:
                        TextField("Server", text: $server, prompt: Text(verbatim: "http://line.example.com:8080"))
                            .urlField()
                            .onChange(of: server) { old, new in absorbLink(old, new) }
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password).textContentType(.password)
                    case .m3u:
                        TextField("Playlist URL", text: $playlist, prompt: Text(verbatim: "https://…/playlist.m3u"))
                            .urlField()
                        TextField("Guide (XMLTV) URL — optional", text: $guide, prompt: Text(verbatim: "https://…/epg.xml.gz"))
                            .urlField()
                    case .stalker:
                        TextField("Portal URL", text: $portal, prompt: Text(verbatim: "http://portal.example.com/c/"))
                            .urlField()
                        TextField("MAC address", text: $mac, prompt: Text(verbatim: "00:1A:79:XX:XX:XX"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                } footer: {
                    Text(footer)
                }

                if let note {
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                Button { add() } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("Check and add").bold() }
                        Spacer()
                    }
                }
                .disabled(busy || makeSource() == nil)
            }
            .onChange(of: format) { _, _ in error = nil; note = nil }
        }
    }

    private var footer: String {
        switch format {
        case .xtream: "Paste a full get.php or player_api.php link into Server to fill everything in."
        case .m3u: "Playlist links that are really Xtream logins are upgraded automatically for better categories and guide data."
        case .stalker: "The portal sees this device as the set-top box with this MAC address."
        }
    }

    /// A pasted Xtream link carries the username and password too. Only a
    /// paste (several characters at once) is split up; while someone types a
    /// link, the login is read from it when they submit.
    private func absorbLink(_ old: String, _ new: String) {
        guard new.count - old.count > 1, new.contains("username="), new.contains("password="),
              let parsed = XtreamProvider.parse(new), let u = parsed.username, let p = parsed.password
        else { return }
        server = parsed.server.absoluteString
        username = u
        password = p
    }

    private func makeSource() -> IPTVSource? {
        switch format {
        case .xtream:
            guard let parsed = XtreamProvider.parse(server) else { return nil }
            let user = username.isEmpty ? parsed.username ?? "" : username
            let pass = password.isEmpty ? parsed.password ?? "" : password
            guard !user.isEmpty, !pass.isEmpty else { return nil }
            return IPTVSource(name: label(parsed.server), kind: .xtream(server: parsed.server, username: user, password: pass))
        case .m3u:
            let trimmed = playlist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
            // get.php?username=…&password=… is an Xtream login in disguise.
            if url.path.hasSuffix("get.php"), let parsed = XtreamProvider.parse(trimmed),
               let u = parsed.username, let p = parsed.password {
                return IPTVSource(name: label(parsed.server), kind: .xtream(server: parsed.server, username: u, password: p))
            }
            let guideURL = URL(string: guide.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme == nil ? nil : $0 }
            return IPTVSource(name: label(url), kind: .m3u(playlist: url, guide: guideURL))
        case .stalker:
            guard let url = StalkerProvider.normalisePortal(portal), let normalised = StalkerProvider.normaliseMAC(mac) else { return nil }
            return IPTVSource(name: label(url), kind: .stalker(portal: url, mac: normalised))
        }
    }

    private func label(_ url: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (url.host() ?? "IPTV") : trimmed
    }

    /// Loads the lineup once before saving, so a bad login never gets stored.
    private func add() {
        guard let source = makeSource() else { return }
        busy = true
        error = nil
        note = nil
        Task {
            defer { busy = false }
            do {
                let lineup = try await Providers.make(source).load()
                guard !lineup.channels.isEmpty else {
                    error = "That subscription has no live channels."
                    return
                }
                await model.add(source)
                password = ""
                dismiss()
            } catch {
                self.error = SourceError.wrap(error).localizedDescription
            }
        }
    }
}

/// Sheet with a title and Cancel. Apple TV gets a plain heading instead of
/// a navigation bar (which overlaps the form there); Menu closes the sheet.
struct FormSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.weight(.bold)).padding(.horizontal, 40)
            // A Form has no height of its own outside a navigation stack.
            content.frame(minHeight: 640)
        }
        .padding(.top, 40)
        #else
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        #endif
    }
}

private extension View {
    func urlField() -> some View {
        textContentType(.URL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
