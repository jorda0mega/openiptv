import Foundation
import Network

/// Serves the player's file requests on 127.0.0.1 and fetches each one from
/// the server over the app's shared URLSession.
///
/// libmpv (ffmpeg) opens a new HTTPS connection for every seek outside
/// what it has downloaded: on a server 135 ms away that's 0.44 s before the
/// first byte, then a fresh connection's slow start, about 1.3-2.5 s per
/// jump into a 4K film. URLSession keeps one HTTP/2 connection to the
/// server open and up to speed (the one the rest of the app already uses),
/// so a seek costs one round trip plus the download.
///
/// Each file gets an unguessable local address that maps to the real one
/// and its headers in memory only; nothing is logged.
final class StreamRelay: @unchecked Sendable {
    static let shared = StreamRelay()

    private let queue = DispatchQueue(label: "openiptv.relay", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var routes: [String: (url: URL, headers: [(String, String)])] = [:]

    /// Starts listening (once); returns quickly, at most after 0.5 s.
    func start() {
        lock.lock()
        let running = listener != nil
        lock.unlock()
        guard !running else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.lock.lock()
                self?.port = listener.port?.rawValue
                self?.lock.unlock()
                ready.signal()
            case .failed, .cancelled:
                self?.lock.lock()
                self?.listener = nil
                self?.port = nil
                self?.lock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 0.5)
    }

    /// A local address for this file that the player can open, or nil to
    /// open it directly (relay not running).
    func localURL(for url: URL, headers: [String]) -> URL? {
        start()
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return nil }
        let pairs = headers.compactMap { header -> (String, String)? in
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        }
        // A new address each time; keep the last few (a warmed-up player
        // and the one playing).
        if routes.count > 16 { routes.removeAll() }
        let token = UUID().uuidString.lowercased()
        routes[token] = (url, pairs)
        // Keep the file extension: it helps the player pick the demuxer.
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return URL(string: "http://127.0.0.1:\(port)/\(token)\(ext)")
    }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return fail(connection, 400) }
        let method = String(request[0])
        let token = String(request[1].dropFirst().split(separator: ".").first ?? "")
        lock.lock()
        let route = routes[token]
        lock.unlock()
        guard let route, method == "GET" || method == "HEAD" else { return fail(connection, 404) }

        var upstream = URLRequest(url: route.url)
        upstream.httpMethod = method
        upstream.timeoutInterval = 30
        for (name, value) in route.headers { upstream.setValue(value, forHTTPHeaderField: name) }
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].caseInsensitiveCompare("Range") == .orderedSame {
                upstream.setValue(pair[1], forHTTPHeaderField: "Range")
            }
        }
        let task = HTTP.session.dataTask(with: upstream)
        let relay = Transfer(connection: connection, task: task)
        task.delegate = relay
        // The player hung up (a seek): stop downloading what it won't read.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: relay.cancel()
            default: break
            }
        }
        task.resume()
    }

    private func fail(_ connection: NWConnection, _ status: Int) {
        let head = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One request: the server's answer streamed to the player as it arrives,
/// pausing the download when the player falls more than 16 MB behind.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var pending = 0
    private var suspended = false
    private var finished = false

    init(connection: NWConnection, task: URLSessionDataTask) {
        self.connection = connection
        self.task = task
    }

    func cancel() {
        lock.lock()
        finished = true
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
            if let value = http?.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
        }
        if http?.value(forHTTPHeaderField: "Accept-Ranges") == nil { head += "Accept-Ranges: bytes\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending += data.count
        if pending > 16_000_000, !suspended {
            suspended = true
            task.suspend()
        }
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pending -= data.count
            let resume = self.suspended && self.pending < 4_000_000 && !self.finished
            if resume { self.suspended = false }
            self.lock.unlock()
            if resume { self.task.resume() }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        finished = true
        lock.unlock()
        // Close once everything queued has gone out.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
