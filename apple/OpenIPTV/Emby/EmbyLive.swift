import Foundation

/// Emby's live connection (its WebSocket): the server announces changes as
/// they happen, something watched here or on another device, items added,
/// changed or removed, so the app updates what it shows without asking.
/// Open while the app is active; reconnects with a growing pause if it
/// drops; keeps itself alive every 30 s.
@MainActor
final class EmbyLive {
    struct WatchChange: Sendable {
        let itemId: String
        let positionTicks: Int64?
        let played: Bool?
        let playedPercentage: Double?
    }

    enum Change: Sendable {
        case watched([WatchChange])
        case library(added: [String], updated: [String], removed: [String])
    }

    var onChange: ((Change) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var account: EmbyAccount?
    private var deviceId = ""
    private var failures = 0
    private var keepAlive: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?

    func connect(_ account: EmbyAccount, deviceId: String) {
        if socket != nil, self.account == account { return }
        disconnect()
        self.account = account
        self.deviceId = deviceId
        open()
    }

    func disconnect() {
        reconnect?.cancel()
        keepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func open() {
        guard let account,
              var parts = URLComponents(url: account.serverURL.appending(path: "embywebsocket"), resolvingAgainstBaseURL: false)
        else { return }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue(account.accessToken, forHTTPHeaderField: "X-Emby-Token")
        let socket = HTTP.session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        listen(socket)
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let socket = self?.socket else { return }
                try? await socket.send(.string(#"{"MessageType":"KeepAlive"}"#))
            }
        }
    }

    private func listen(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, socket === self.socket else { return }
                switch result {
                case let .success(message):
                    self.failures = 0
                    switch message {
                    case let .string(text): self.handle(Data(text.utf8))
                    case let .data(data): self.handle(data)
                    @unknown default: break
                    }
                    self.listen(socket)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func dropped() {
        keepAlive?.cancel()
        socket = nil
        failures += 1
        let pause = min(60, pow(2, Double(min(failures, 6))))
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled, let self, self.socket == nil, self.account != nil else { return }
            self.open()
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["MessageType"] as? String else { return }
        let body = message["Data"] as? [String: Any]
        switch type {
        case "UserDataChanged":
            let list = (body?["UserDataList"] as? [[String: Any]] ?? []).compactMap { entry -> WatchChange? in
                guard let id = entry["ItemId"] as? String else { return nil }
                return WatchChange(itemId: id, positionTicks: (entry["PlaybackPositionTicks"] as? NSNumber)?.int64Value,
                                   played: entry["Played"] as? Bool,
                                   playedPercentage: (entry["PlayedPercentage"] as? NSNumber)?.doubleValue)
            }
            if !list.isEmpty { onChange?(.watched(list)) }
        case "LibraryChanged":
            func ids(_ key: String) -> [String] { body?[key] as? [String] ?? [] }
            let added = ids("ItemsAdded"), updated = ids("ItemsUpdated"), removed = ids("ItemsRemoved")
            if !(added.isEmpty && updated.isEmpty && removed.isEmpty) {
                onChange?(.library(added: added, updated: updated, removed: removed))
            }
        case "ForceKeepAlive":
            Task { [socket] in try? await socket?.send(.string(#"{"MessageType":"KeepAlive"}"#)) }
        default:
            break
        }
    }
}
