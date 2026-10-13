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
///
/// What's been fetched of a file is kept on the device (ByteCache): the
/// player reading it again (switching subtitles or audio makes it read
/// from just before where it is; a jump back) gets it at once. Fetching it
/// all again from the server stopped the film for seconds.
final class StreamRelay: @unchecked Sendable {
    static let shared = StreamRelay()

    private let queue = DispatchQueue(label: "openiptv.relay", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var routes: [String: (url: URL, headers: [(String, String)])] = [:]
    /// What's been fetched of the last two files (the one playing, one
    /// opened ahead), by their real address.
    private var caches: [(url: URL, cache: ByteCache)] = []

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
        ByteCache.removeLeftovers()
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

        var range: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].caseInsensitiveCompare("Range") == .orderedSame { range = pair[1] }
        }
        let cache = method == "GET" ? cache(for: route.url) : nil
        // Already here from the start of what's asked: those bytes at once,
        // then the rest from the server.
        if let cache, let (from, to) = Self.bounds(range, total: cache.total), let total = cache.total {
            let have = min(cache.available(from: from), to - from + 1)
            if have > 0 {
                var head = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(cache.contentType ?? "application/octet-stream")\r\n"
                head += "Content-Length: \(to - from + 1)\r\nContent-Range: bytes \(from)-\(to)/\(total)\r\n"
                head += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                sendCached(connection, cache, from: from, count: have) { [weak self] in
                    guard let self else { return }
                    if from + have > to {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        self.fetch(route, range: "bytes=\(from + have)-\(to)", connection: connection, cache: cache, head: false)
                    }
                }
                return
            }
        }
        fetch(route, method: method, range: range, connection: connection, cache: cache, head: true)
    }

    /// The bytes asked for, from where to where (both included), when it's
    /// one plain range and the file's size is known.
    private static func bounds(_ range: String?, total: Int64?) -> (Int64, Int64)? {
        guard let range, range.hasPrefix("bytes="), let total, total > 0 else { return nil }
        let parts = range.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let from = Int64(parts[0]), from < total else { return nil }
        let to = parts[1].isEmpty ? total - 1 : min(Int64(parts[1]) ?? (total - 1), total - 1)
        return to >= from ? (from, to) : nil
    }

    /// The cache for this file (made the first time; the oldest of more
    /// than two goes, with its bytes).
    private func cache(for url: URL) -> ByteCache? {
        lock.lock()
        defer { lock.unlock() }
        if let found = caches.first(where: { $0.url == url }) { return found.cache }
        guard let made = ByteCache() else { return nil }
        caches.append((url, made))
        if caches.count > 2 { caches.removeFirst() }
        return made
    }

    /// Kept bytes to the player, a megabyte at a time, each once the last
    /// has gone out.
    private func sendCached(_ connection: NWConnection, _ cache: ByteCache, from: Int64, count: Int64,
                            then: @escaping () -> Void) {
        var at = from
        let end = from + count
        func next() {
            guard at < end else { return then() }
            let size = Int(min(1 << 20, end - at))
            guard let data = cache.read(at, size) else { return connection.cancel() }
            at += Int64(size)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { return connection.cancel() }
                next()
            })
        }
        next()
    }

    /// From the server: `head` sends its answer's headers to the player
    /// (not when kept bytes have gone first, with their own).
    private func fetch(_ route: (url: URL, headers: [(String, String)]), method: String = "GET", range: String?,
                       connection: NWConnection, cache: ByteCache?, head: Bool) {
        var upstream = URLRequest(url: route.url)
        upstream.httpMethod = method
        upstream.timeoutInterval = 30
        for (name, value) in route.headers { upstream.setValue(value, forHTTPHeaderField: name) }
        if let range { upstream.setValue(range, forHTTPHeaderField: "Range") }
        let task = HTTP.session.dataTask(with: upstream)
        let relay = Transfer(connection: connection, task: task, cache: cache, sendsHead: head)
        task.delegate = relay
        // The player hung up (a seek): stop downloading what it won't read.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: relay.cancel()
            default: break
            }
        }
        task.resume()
        // A hang-up shows as the end of what the player sends (it sends
        // nothing more after its request): notice it at once, rather than
        // only when the next piece fails to send.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil {
                relay.cancel()
                connection.cancel()
            }
        }
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
    private let cache: ByteCache?
    private let sendsHead: Bool
    private let lock = NSLock()
    private var pending = 0
    private var suspended = false
    private var finished = false
    /// Where in the file the next byte received goes (for the cache).
    private var offset: Int64?

    init(connection: NWConnection, task: URLSessionDataTask, cache: ByteCache?, sendsHead: Bool) {
        self.connection = connection
        self.task = task
        self.cache = cache
        self.sendsHead = sendsHead
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
        // Where these bytes sit in the file, and its size, for the cache.
        if status == 206, let range = http?.value(forHTTPHeaderField: "Content-Range"),
           let (from, total) = Self.parse(range) {
            offset = from
            cache?.noteFile(total: total, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        } else if status == 200, response.expectedContentLength > 0 {
            offset = 0
            cache?.noteFile(total: response.expectedContentLength, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        }
        guard sendsHead else {
            // The rest of an answer already under way: only its bytes.
            if status == 206 { completionHandler(.allow) } else {
                completionHandler(.cancel)
                connection.cancel()
            }
            return
        }
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
            if let value = http?.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
        }
        if http?.value(forHTTPHeaderField: "Accept-Ranges") == nil { head += "Accept-Ranges: bytes\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    /// "bytes 0-99/1000" → (0, 1000).
    private static func parse(_ range: String) -> (Int64, Int64)? {
        let parts = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]),
              let from = parts[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
        return (from, total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let at = offset {
            cache?.store(data, at: at)
            offset = at + Int64(data.count)
        }
        lock.lock()
        pending += data.count
        if pending > 16_000_000, !suspended {
            suspended = true
            task.suspend()
        }
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                // The player's gone: stop the download.
                self.cancel()
                self.connection.cancel()
                return
            }
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

/// What's been fetched of one file, kept in a sparse temporary file (only
/// the bytes written take space), up to 1 GB; past that, what's furthest
/// behind the newest bytes is let go.
final class ByteCache: @unchecked Sendable {
    private static let folder = FileManager.default.temporaryDirectory.appending(path: "relay-cache")
    private static let limit: Int64 = 1 << 30

    private let lock = NSLock()
    private let path: URL
    private let handle: FileHandle
    private var ranges: [Range<Int64>] = []
    private var stored: Int64 = 0
    private(set) var total: Int64?
    private(set) var contentType: String?

    init?() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        path = Self.folder.appending(path: UUID().uuidString)
        guard FileManager.default.createFile(atPath: path.path(), contents: nil),
              let handle = try? FileHandle(forUpdating: path) else { return nil }
        self.handle = handle
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: path)
    }

    /// Files left from a run that ended without cleaning up.
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }

    func noteFile(total: Int64, contentType: String?) {
        lock.withLock {
            if self.total == nil { self.total = total }
            if self.contentType == nil { self.contentType = contentType }
        }
    }

    /// How many bytes are kept from `offset` on, in one run.
    func available(from offset: Int64) -> Int64 {
        lock.withLock { ranges.first { $0.contains(offset) }.map { $0.upperBound - offset } ?? 0 }
    }

    func read(_ offset: Int64, _ count: Int) -> Data? {
        lock.withLock {
            guard let range = ranges.first(where: { $0.contains(offset) }), offset + Int64(count) <= range.upperBound else { return nil }
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }
    }

    func store(_ data: Data, at offset: Int64) {
        let end = offset + Int64(data.count)
        lock.withLock {
            if stored + Int64(data.count) > Self.limit { letGo(before: offset - (64 << 20)) }
            guard stored + Int64(data.count) <= Self.limit else { return }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            } catch { return }
            add(offset..<end)
        }
    }

    /// Adds a run of bytes, merging it with those it touches.
    private func add(_ new: Range<Int64>) {
        var merged = new
        var kept: [Range<Int64>] = []
        for range in ranges {
            if range.upperBound < merged.lowerBound || range.lowerBound > merged.upperBound {
                kept.append(range)
            } else {
                merged = min(range.lowerBound, merged.lowerBound)..<max(range.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
        stored = ranges.reduce(0) { $0 + Int64($1.count) }
    }

    /// Frees the runs that end before `offset` (their disk space too).
    private func letGo(before offset: Int64) {
        let old = ranges.filter { $0.upperBound <= offset }
        guard !old.isEmpty else { return }
        for range in old {
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(range.lowerBound), fp_length: off_t(range.count))
            _ = fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole)
        }
        ranges.removeAll { $0.upperBound <= offset }
        stored = ranges.reduce(0) { $0 + Int64($1.count) }
    }
}

