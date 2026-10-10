import SwiftUI

/// Pair with the OpenIPTV server on your Mac: pick it from the servers found
/// on your network (or type its address), then enter the six-digit code it
/// shows. The server holds your Emby and IPTV logins; this device only keeps
/// the server's address and access key (in the Keychain).
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var browser = ServerBrowser()
    @State private var chosen: URL?
    @State private var chosenName = ""
    @State private var manualAddress = ""
    @State private var pin = ""
    @State private var pairing = false
    @State private var error: String?
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image("Logo").resizable().frame(width: 96, height: 96).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Connect to OpenIPTV").font(.title2.weight(.bold))
                        Text("On your Mac run scripts/serve.sh with --lan. It shows a six-digit pairing code.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let chosen {
                        pinEntry(for: chosen)
                    } else {
                        serverChoice
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(isSheet ? "Pair" : "")
            .inlineTitle()
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .task { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var serverChoice: some View {
        VStack(spacing: 14) {
            Text("On your network").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            if browser.servers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for servers…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(browser.servers) { server in
                        Button {
                            choose(server.url, name: server.name)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) {
                                    Text(server.name).font(.body.weight(.semibold))
                                    Text(server.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            Text("Or enter its address").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            TextField("192.168.1.10:8787", text: $manualAddress)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onSubmit { chooseManual() }
            HStack(spacing: 12) {
                #if os(iOS)
                Button {
                    // The web pairing link carries the key itself.
                    if let pasted = UIPasteboard.general.string, let server = Server(link: pasted), server.key != nil {
                        Task {
                            await model.connect(to: server)
                            if model.connectionError == nil, isSheet { dismiss() }
                        }
                    } else {
                        error = "Copy the link the server prints (it contains ?key=)."
                    }
                } label: {
                    Label("Paste link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                #endif
                Button { chooseManual() } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(Server(link: manualAddress) == nil)
            }
            .controlSize(.large)
        }
    }

    private func pinEntry(for url: URL) -> some View {
        VStack(spacing: 16) {
            Text(chosenName.isEmpty ? (url.host() ?? "") : chosenName).font(.headline)
            TextField("Pairing code", text: $pin)
                .keyboardType(.numberPad)
                .font(.title.monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($pinFocused)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .onSubmit { pair(url) }
                .onChange(of: pin) { _, value in
                    let digits = value.filter(\.isNumber)
                    if digits != value { pin = digits }
                    if digits.count == 6 { pair(url) }
                }
            HStack(spacing: 12) {
                Button {
                    chosen = nil
                    pin = ""
                    error = nil
                } label: {
                    Text("Back").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button { pair(url) } label: {
                    Group {
                        if pairing { ProgressView() } else { Text("Pair") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(pin.count != 6 || pairing)
            }
            .controlSize(.large)
        }
        .onAppear { pinFocused = true }
    }

    private func choose(_ url: URL, name: String) {
        error = nil
        chosenName = name
        // This Mac's own server trusts loopback, so the simulator needs no code.
        if url.host() == "127.0.0.1" || url.host() == "localhost" {
            Task { await model.connect(to: Server(url: url, key: nil)) }
            return
        }
        chosen = url
    }

    private func chooseManual() {
        guard let server = Server(link: manualAddress) else { return }
        if let key = server.key {
            Task { await model.connect(to: Server(url: server.url, key: key)) }
        } else {
            choose(server.url, name: "")
        }
    }

    private func pair(_ url: URL) {
        guard pin.count == 6, !pairing else { return }
        pairing = true
        error = nil
        Task {
            defer { pairing = false }
            do {
                try await model.pair(serverURL: url, pin: pin)
                if isSheet { dismiss() }
            } catch {
                self.error = error.localizedDescription
                pin = ""
            }
        }
    }
}
