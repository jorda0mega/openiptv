#if DEBUG
import Foundation
import Network

/// Real-feed checks (`-debugWebsocketProbe YES`): Emby's websocket opened
/// over a plain connection with one way of sending the key. The address
/// never goes through the system's URL loading, which logs it, query and
/// all, when a request fails or is stopped.
final class SocketProbe: @unchecked Sendable {
    enum Form: CaseIterable {
        case token, embyAuthorization, authorization, query

        var name: String {
            switch self {
            case .token: "X-Emby-Token"
            case .embyAuthorization: "X-Emby-Authorization"
            case .authorization: "Authorization"
            case .query: "key in the query"
            }
        }
    }

    enum Opening {
        case unreachable, refused
        case opened(SocketProbe)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openiptv.socket-probe")
    private var buffer = Data()

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// `authorization`: the MediaBrowser value, for the two authorization forms.
    static func open(_ server: URL, _ form: Form, token: String, deviceId: String, authorization: String) async -> Opening {
        guard let host = server.host() else { return .unreachable }
        let secure = server.scheme == "https"
        let port = NWEndpoint.Port(rawValue: UInt16(server.port ?? (secure ? 443 : 80))) ?? .http
        let probe = SocketProbe(NWConnection(host: NWEndpoint.Host(host), port: port, using: secure ? .tls : .tcp))
        guard await probe.ready() else { return .unreachable }
        let path = (server.path().hasSuffix("/") ? String(server.path().dropLast()) : server.path()) + "/embywebsocket"
        var request = "GET \(path)?deviceId=\(deviceId)\(form == .query ? "&api_key=\(token)" : "") HTTP/1.1\r\n"
        request += "Host: \(host)\(server.port.map { ":\($0)" } ?? "")\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())\r\nSec-WebSocket-Version: 13\r\n"
        switch form {
        case .token: request += "X-Emby-Token: \(token)\r\n"
        case .embyAuthorization: request += "X-Emby-Authorization: \(authorization)\r\n"
        case .authorization: request += "Authorization: \(authorization)\r\n"
        case .query: break
        }
        probe.connection.send(content: Data((request + "\r\n").utf8), completion: .contentProcessed { _ in })
        let accepted = await probe.within(.seconds(10)) { await probe.answer()?.hasPrefix("HTTP/1.1 101") == true }
        guard accepted == true else {
            probe.close()
            return .refused
        }
        return .opened(probe)
    }

    func hears(_ itemId: String, within limit: Duration) async -> Bool {
        await within(limit) { [self] in
            while let (opcode, payload) = await frame() {
                guard opcode == 1 else { continue }
                let text = String(decoding: payload, as: UTF8.self)
                if text.contains("UserDataChanged"), text.contains(itemId) { return true }
            }
            return false
        } ?? false
    }

    func close() {
        connection.cancel()
    }

    private func ready() async -> Bool {
        await within(.seconds(10)) { [self] in
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = Locked(false)
                connection.stateUpdateHandler = { state in
                    let result: Bool? = switch state {
                    case .ready: true
                    case .failed, .cancelled: false
                    default: nil
                    }
                    guard let result, !once.value else { return }
                    once.mutate { $0 = true }
                    done.resume(returning: result)
                }
                connection.start(queue: queue)
            }
        } ?? false
    }

    /// Gives up after `limit` by closing the connection, which ends any read.
    private func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let timer = Task { [connection] in
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timer.cancel() }
        return await work()
    }

    private func answer() async -> String? {
        while true {
            if let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                return head
            }
            guard let more = await receive() else { return nil }
            buffer.append(more)
        }
    }

    private func frame() async -> (UInt8, Data)? {
        while true {
            if let frame = Self.frame(in: &buffer) { return frame }
            guard let more = await receive() else { return nil }
            buffer.append(more)
        }
    }

    private static func frame(in buffer: inout Data) -> (UInt8, Data)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F), offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let masked = bytes[1] & 0x80 != 0
        guard bytes.count >= offset + (masked ? 4 : 0) + length else { return nil }
        let mask = masked ? Array(bytes[offset..<offset + 4]) : []
        if masked { offset += 4 }
        var payload = Array(bytes[offset..<offset + length])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        buffer = Data(bytes[(offset + length)...])
        return (bytes[0] & 0x0F, Data(payload))
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { done in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                done.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }
}
#endif
