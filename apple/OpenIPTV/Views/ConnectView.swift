import SwiftUI

/// Pair with the OpenIPTV server running on your Mac. The server holds your
/// Emby and IPTV logins (read from 1Password); this device only stores the
/// server address and its access key (in the Keychain).
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var link = ""
    @State private var connecting = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Connect to your server").font(.title2.weight(.bold))
                        Text("On your Mac run `scripts/serve.sh … --lan`, then paste the link it prints (it looks like http://192.168.x.x:8787/?key=…).")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        TextField("http://192.168.1.10:8787/?key=…", text: $link)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focused)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        HStack(spacing: 12) {
                            Button {
                                if let pasted = UIPasteboard.general.string { link = pasted }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            Button {
                                connect()
                            } label: {
                                Group {
                                    if connecting { ProgressView() } else { Text("Connect") }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(Server(link: link) == nil || connecting)
                        }
                        .controlSize(.large)
                    }
                    if let status = model.status, model.server != nil {
                        statusCard(status)
                    }
                    if let error = model.connectionError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                }
                .padding(24)
            }
            .navigationTitle(isSheet ? "Server" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .onAppear { link = model.server.map(linkString) ?? "" }
        }
    }

    private func statusCard(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.emby.ok ? "Emby: \(status.emby.server ?? "connected")" : "Emby: \(status.emby.error ?? "unavailable")",
                  systemImage: status.emby.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            Label(status.live.ok ? "Live TV: \(status.live.channels ?? 0) channels" : "Live TV: \(status.live.error ?? "unavailable")",
                  systemImage: status.live.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func linkString(_ server: Server) -> String {
        var parts = URLComponents(url: server.url, resolvingAgainstBaseURL: false)
        if let key = server.key { parts?.queryItems = [URLQueryItem(name: "key", value: key)] }
        return parts?.string ?? server.url.absoluteString
    }

    private func connect() {
        guard let server = Server(link: link) else { return }
        connecting = true
        focused = false
        Task {
            await model.connect(to: server)
            connecting = false
            if model.connectionError == nil, isSheet { dismiss() }
        }
    }
}
