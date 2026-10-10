import Foundation
import Network
import Observation

/// Finds OpenIPTV servers on the local network (Bonjour `_openiptv._tcp`),
/// so nobody has to type an IP address with a TV remote.
@Observable
@MainActor
final class ServerBrowser {
    struct Found: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }

    private(set) var servers: [Found] = []
    private(set) var searching = false
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        searching = true
        let browser = NWBrowser(for: .bonjour(type: "_openiptv._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        searching = false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  !servers.contains(where: { $0.name == name }),
                  resolving[name] == nil
            else { continue }
            resolve(name: name, endpoint: result.endpoint)
        }
    }

    /// Connect briefly to learn the server's IPv4 address and port.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state,
                  case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint
            else { return }
            // Resolved addresses carry an interface scope ("192.168.4.29%en1"),
            // which isn't valid in a URL host; drop it.
            let raw: String
            switch host {
            case let .ipv4(address): raw = "\(address)"
            case let .name(value, _): raw = value
            default: return
            }
            let hostString = String(raw.split(separator: "%").first ?? Substring(raw))
            connection.cancel()
            Task { @MainActor in
                guard let self, let url = URL(string: "http://\(hostString):\(port.rawValue)") else { return }
                self.resolving[name] = nil
                if !self.servers.contains(where: { $0.url == url }) {
                    self.servers.append(Found(name: name, url: url))
                }
            }
        }
        connection.start(queue: .main)
    }
}
