import Network
import XCTest
@testable import OpenIPTV

/// A server on this Mac's loopback. It answers each request as told, `wait`
/// after it came and `firstWait` more on a connection's first, keeps the
/// connection open, and keeps each request's target and key.
final class LocalServer: @unchecked Sendable {
    struct Asked: Equatable {
        let target: String
        let key: String?
    }

    typealias Answer = @Sendable (_ target: String) -> (status: Int, headers: [String: String], body: String)

    let asked = Locked<[Asked]>([])
    let port: UInt16
    private let listener: NWListener

    init(firstWait: Double = 0, wait: Double = 0, answer: @escaping Answer = { _ in (200, [:], "ok") }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        let (asked, queue) = (asked, DispatchQueue(label: "local-server"))
        func serve(_ connection: NWConnection, _ buffer: Data, first: Bool) {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let key = lines.dropFirst().first { $0.lowercased().hasPrefix("x-emby-token:") }
                    .map { String($0.dropFirst("x-emby-token:".count)).trimmingCharacters(in: .whitespaces) }
                asked.mutate { $0.append(Asked(target: target, key: key)) }
                let (status, headers, body) = answer(target)
                var reply = "HTTP/1.1 \(status) Answer\r\nContent-Length: \(body.utf8.count)\r\n"
                for (name, value) in headers { reply += "\(name): \(value)\r\n" }
                queue.asyncAfter(deadline: .now() + wait + (first ? firstWait : 0)) {
                    connection.send(content: Data((reply + "\r\n" + body).utf8), completion: .contentProcessed { _ in
                        serve(connection, Data(buffer[end.upperBound...]), first: false)
                    })
                }
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                guard let data, error == nil, !done || !data.isEmpty else { return connection.cancel() }
                serve(connection, buffer + data, first: first)
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            serve(connection, Data(), first: true)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue else { throw XCTSkip("no local server") }
        self.port = port
    }

    func stop() { listener.cancel() }
}
