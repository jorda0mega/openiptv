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
    private var routes = RelayRoutes()
    /// Converted versions listed from where they play (ConvertedPlaylist),
    /// the last few, by their local token.
    private var playlists: [(token: String, body: Data)] = []
    /// What's been fetched of the last few files (the one playing, ones
    /// opened or fetched ahead), by their real address without the
    /// server's per-request session (asked again later, a title's address
    /// differs only there).
    private var caches: [(key: String, cache: ByteCache)] = []
    /// Fetches ahead of a tap (fetchStart), by the file they're for:
    /// stopped when something starts playing, except the file playing (its
    /// bytes are the ones about to be read). Regression: they went on, each
    /// step after the last, competing with the film just started.
    private var ahead: [String: [URLSessionDataTask]] = [:]
    private var aheadFiles: Set<String> = []
    private var stoppedAhead: Set<String> = []
    private let accountCacheID = Locked(UUID().uuidString)
    /// The file playing (none: nothing yet): while something plays, no
    /// other file is fetched ahead.
    private var playingFile: String?
    private static let keptFiles = 6
    static let firstRead: Int64 = 512 << 10
    static let readSize: Int64 = 8 << 20

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
        // A new address each time (see RelayRoutes).
        let token = UUID().uuidString.lowercased()
        routes.add(Self.route(url, headers), token: token)
        // Keep the file extension: it helps the player pick the demuxer.
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return URL(string: "http://127.0.0.1:\(port)/\(token)\(ext)")
    }

    func localURL(serving playlist: String) -> URL? {
        start()
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return nil }
        let token = UUID().uuidString.lowercased()
        playlists.append((token, Data(playlist.utf8)))
        if playlists.count > 4 { playlists.removeFirst() }
        return URL(string: "http://127.0.0.1:\(port)/\(token).m3u8")
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
        let playlist = playlists.first { $0.token == token }?.body
        let route = routes.route(token)
        lock.unlock()
        if let playlist, method == "GET" || method == "HEAD" {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(playlist.count)\r\nConnection: close\r\n\r\n"
            return connection.send(content: Data(head.utf8) + (method == "GET" ? playlist : Data()), contentContext: .finalMessage,
                                   isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        guard let route, method == "GET" || method == "HEAD" else { return fail(connection, 404) }

        var range: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].caseInsensitiveCompare("Range") == .orderedSame { range = pair[1] }
        }
        let cache = method == "GET" ? cache(for: route.url) : nil
        #if DEBUG
        noteRead(token, range)
        let cachedNow = cache.flatMap { cache in Self.bounds(range, total: cache.total).map { min(cache.available(from: $0.0), $0.1 - $0.0 + 1) } }
        let cached = max(0, cachedNow ?? 0)
        lock.withLock {
            startReads.requests += 1
            startReads.cached += cached
            startLog.append(StartRead(at: CFAbsoluteTimeGetCurrent() - startBegan, range: range, cache: cache, device: cached))
            startReadOf[ObjectIdentifier(connection)] = startLog.count - 1
        }
        #endif
        if let cache, cache.claimIndex() {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.prefetchIndex(route, cache) }
        }
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

    #if DEBUG
    /// UI tests: how many times the player went back in a file to read it
    /// again (a jump back, or subtitles picked the first time).
    private(set) var readsBack = 0
    private var lastRead: [String: Int64] = [:]

    private var startReads = (requests: 0, cached: Int64(0), fetches: 0, fetched: Int64(0), firstByte: 0.0)

    private struct StartRead {
        let at: Double
        let range: String?
        let cache: ByteCache?
        let device: Int64
        var server: Int64 = 0

        var readout: String {
            let parts = (range ?? "bytes=0-").dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let from = Int64(parts.first ?? "") ?? 0, to = parts.count == 2 ? Int64(parts[1]) : nil
            let place = cache?.total.map { String(format: "%.2f%%", Double(from) / Double($0) * 100) } ?? "?"
            let asked = to.map { String(format: "%.2f MB", Double($0 - from + 1) / 1e6) } ?? "to the end"
            return String(format: "%.0f ms at %@ %@: device %.2f, server %.2f", at * 1000, place, asked,
                          Double(device) / 1e6, Double(server) / 1e6)
        }
    }

    private var startLog: [StartRead] = []
    private var startReadOf: [ObjectIdentifier: Int] = [:]
    private var startBegan = CFAbsoluteTimeGetCurrent()

    func beginStartReads() {
        lock.withLock {
            startReads = (0, 0, 0, 0, 0)
            startLog = []
            startReadOf = [:]
            startBegan = CFAbsoluteTimeGetCurrent()
        }
    }

    var serverBytes: Int64 { lock.withLock { startReads.fetched } }

    var startReadsReadout: String {
        let (reads, log) = lock.withLock { (startReads, startLog) }
        let each = log.prefix(12).map(\.readout).joined(separator: "; ")
        return String(format: "reads %d, from the device %.1f MB, from the server %d reads %.1f MB first byte up to %.0f ms",
                      reads.requests, Double(reads.cached) / 1e6, reads.fetches, Double(reads.fetched) / 1e6, reads.firstByte * 1000)
            + (each.isEmpty ? "" : " | " + each)
    }

    fileprivate func startRead(for connection: NWConnection) -> Int? {
        lock.withLock { startReadOf[ObjectIdentifier(connection)] }
    }

    fileprivate func noteFetch(firstByteAfter seconds: Double) {
        lock.withLock {
            startReads.fetches += 1
            startReads.firstByte = max(startReads.firstByte, seconds)
        }
    }

    fileprivate func noteFetched(_ count: Int, for read: Int?) {
        lock.withLock {
            startReads.fetched += Int64(count)
            if let read, startLog.indices.contains(read) { startLog[read].server += Int64(count) }
        }
    }

    private func noteRead(_ token: String, _ range: String?) {
        guard let range, range.hasPrefix("bytes="),
              let from = Int64(range.dropFirst(6).split(separator: "-").first ?? "") else { return }
        lock.lock()
        // More than a megabyte back from where the last read began.
        if let last = lastRead[token], from < last - (1 << 20) { readsBack += 1 }
        lastRead[token] = from
        lock.unlock()
    }
    #endif

    /// The bytes asked for, from where to where (both included), when it's
    /// one plain range and the file's size is known.
    private static func bounds(_ range: String?, total: Int64?) -> (Int64, Int64)? {
        guard let range, range.hasPrefix("bytes="), let total, total > 0 else { return nil }
        let parts = range.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let from = Int64(parts[0]), from < total else { return nil }
        let to = parts[1].isEmpty ? total - 1 : min(Int64(parts[1]) ?? (total - 1), total - 1)
        return to >= from ? (from, to) : nil
    }

    private func cache(for url: URL) -> ByteCache? {
        let key = cacheKey(url)
        lock.lock()
        defer { lock.unlock() }
        if let index = caches.firstIndex(where: { $0.key == key }) {
            // Used again: the newest, the last to go.
            let found = caches.remove(at: index)
            caches.append(found)
            return found.cache
        }
        guard let made = ByteCache(limit: Self.keptBytes) else { return nil }
        caches.append((key, made))
        if caches.count > Self.keptFiles { caches.removeFirst() }
        return made
    }

    #if DEBUG
    // UI tests (OPENREEL_DEBUG_RELAY_KEEP_MB=megabytes): a small test film
    // fills less than a real one does.
    private static let keptBytes = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_RELAY_KEEP_MB"].flatMap(Int64.init).map { $0 << 20 }
        ?? ByteCache.limit
    #else
    private static let keptBytes = ByteCache.limit
    #endif

    /// A file's address without the server's session for one request.
    private func cacheKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return accountCacheID.value + " " + url.absoluteString }
        parts.queryItems = parts.queryItems?.filter { !["playsessionid", "api_key"].contains($0.name.lowercased()) }
        return accountCacheID.value + " " + (parts.string ?? url.absoluteString)
    }

    func forgetAccount() {
        accountCacheID.mutate { $0 = UUID().uuidString }
        let stopping: [URLSessionDataTask] = lock.withLock {
            let stopping = ahead.values.flatMap { $0 }
            routes = RelayRoutes()
            playlists = []
            caches = []
            ahead = [:]
            aheadFiles = []
            stoppedAhead = []
            playingFile = nil
            return stopping
        }
        stopping.forEach { $0.cancel() }
    }

    /// The Emby key goes in a header: the system logs the address of a
    /// request that fails or is stopped.
    private static func route(_ url: URL, _ headers: [String]) -> (url: URL, headers: [(String, String)]) {
        let request = HTTP.keyInHeader(URLRequest(url: url))
        var pairs = headers.compactMap { header -> (String, String)? in
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        }
        if let key = request.value(forHTTPHeaderField: "X-Emby-Token"), !pairs.contains(where: { $0.0 == "X-Emby-Token" }) {
            pairs.append(("X-Emby-Token", key))
        }
        return (request.url ?? url, pairs)
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
        #if DEBUG
        relay.relay = self
        relay.read = startRead(for: connection)
        #endif
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

    // MARK: Ahead of a tap

    func fetchStart(url: URL, headers: [String], at seconds: Double) async -> Bool {
        start()
        let key = cacheKey(url)
        // Asked a moment after something started playing: not now.
        let allowed = lock.withLock { () -> Bool in
            guard !PlaybackActivity.isPlaying || key == playingFile else { return false }
            stoppedAhead.remove(key)
            aheadFiles.insert(key)
            return true
        }
        let route = Self.route(url, headers)
        guard allowed, let cache = cache(for: route.url) else { return false }
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let fetch = { [self] (from: Int64, count: Int64) in
            await withCheckedContinuation { done in
                queue.async { [self] in
                    ensure(route, cache, from: from, count: count, ahead: key) { bytes, total in
                        done.resume(returning: bytes.flatMap { data in total.map { (data, $0) } })
                    }
                }
            }
        }
        #if DEBUG
        // The old fetch took the whole second below the resume point.
        let fetched = Self.oldReadyStart
            ? await Matroska.fetchStartAsBefore(at: seconds.rounded(.down), fetch: fetch) : await Matroska.fetchStart(at: seconds, fetch: fetch)
        #else
        let fetched = await Matroska.fetchStart(at: seconds, fetch: fetch)
        #endif
        #if DEBUG
        if fetched {
            NSLog("%@", String(format: "PERF relay start fetched ahead at %.0f s in %.0f ms", seconds, (CFAbsoluteTimeGetCurrent() - started) * 1000))
        }
        #endif
        return fetched
    }

    #if DEBUG
    private static var oldReadyStart: Bool { UserDefaults.standard.bool(forKey: "oldReadyStart") }
    #endif

    /// These bytes of the file in the cache (fetched unless already there),
    /// then `then` with them and the file's size (nil: failed). `ahead`:
    /// fetched ahead of a tap for this file (low priority; nothing more once
    /// something else plays, see stopAhead).
    private func ensure(_ route: (url: URL, headers: [(String, String)]), _ cache: ByteCache, from: Int64, count: Int64,
                        ahead key: String? = nil, then: @escaping @Sendable (Data?, Int64?) -> Void) {
        if count > 0, cache.available(from: from) >= count, let kept = cache.read(from, Int(count)) {
            return then(kept, cache.total)
        }
        if let key, lock.withLock({ stoppedAhead.contains(key) }) { return then(nil, nil) }
        var request = URLRequest(url: route.url)
        request.timeoutInterval = 30
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(from)-\(from + count - 1)", forHTTPHeaderField: "Range")
        var made: URLSessionDataTask?
        let task = HTTP.session.dataTask(with: request) { [weak self] data, response, _ in
            if let key, let made { self?.lock.withLock { self?.ahead[key]?.removeAll { $0 === made } } }
            let http = response as? HTTPURLResponse
            let total = http?.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last.flatMap { Int64($0) } }
            guard http?.statusCode == 206, let data, !data.isEmpty else { return then(nil, nil) }
            if let total { cache.noteFile(total: total, contentType: http?.value(forHTTPHeaderField: "Content-Type")) }
            cache.store(data, at: from, evicting: false)
            then(data, total ?? cache.total)
        }
        made = task
        task.delegate = HTTP.keyOutOfRedirects
        if let key {
            task.priority = URLSessionTask.lowPriority
            lock.withLock { ahead[key, default: []].append(task) }
        }
        task.resume()
    }

    /// Something starts playing: what was being fetched ahead for other
    /// files stops (under way and still to come), so it has the connection
    /// to itself; that for `playing` (the same file) goes on.
    func stopAhead(keeping playing: URL?) {
        let keep = playing.map(cacheKey)
        let stopping: [URLSessionDataTask] = lock.withLock {
            playingFile = keep
            let others = aheadFiles.filter { $0 != keep }
            stoppedAhead.formUnion(others)
            aheadFiles.subtract(others)
            let tasks = others.flatMap { ahead.removeValue(forKey: $0) ?? [] }
            return tasks
        }
        stopping.forEach { $0.cancel() }
        #if DEBUG
        if !stopping.isEmpty { NSLog("%@", "PERF relay stopped \(stopping.count) fetches ahead") }
        #endif
    }

    // MARK: The file's index

    /// A Matroska file's index (its Cues), fetched into the cache a moment
    /// after the file opens. libmpv reads it at its first jump in the file:
    /// subtitles or audio picked for the first time (it reads from just
    /// before where it is, for the new track), or a seek. It usually sits at
    /// the end of the file, which nothing else downloads, so that first
    /// jump waited for the server, and the picture stopped meanwhile (it
    /// waits for the new subtitles). `tries`: the file's start isn't here
    /// yet (a player opened ahead reads little).
    private func prefetchIndex(_ route: (url: URL, headers: [(String, String)]), _ cache: ByteCache, tries: Int = 5) {
        guard let total = cache.total else {
            if tries > 0 { queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.prefetchIndex(route, cache, tries: tries - 1) } }
            return
        }
        let have = Int(min(cache.available(from: 0), 1 << 18))
        guard have >= 4096, let head = cache.read(0, have) else {
            if tries > 0 { queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.prefetchIndex(route, cache, tries: tries - 1) } }
            return
        }
        guard let cues = Matroska.cuesOffset(in: [UInt8](head)), cues < total, cache.available(from: cues) == 0 else { return }
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        // The element's header and, for most films, all of it; then the rest.
        let first = min(Int64(1 << 16), total - cues)
        fetchBytes(route, from: cues, count: first) { [weak self] data in
            guard let self, let data else { return }
            cache.store(data, at: cues, evicting: false)
            guard let length = Matroska.elementLength([UInt8](data.prefix(16))) else { return }
            let end = min(cues + min(length, 32 << 20), total)
            let next = cues + Int64(data.count)
            #if DEBUG
            func done() {
                NSLog("%@", String(format: "PERF relay index %lld bytes at %lld in %.0f ms", end - cues, cues,
                                   (CFAbsoluteTimeGetCurrent() - started) * 1000))
            }
            #endif
            guard end > next else {
                #if DEBUG
                done()
                #endif
                return
            }
            self.fetchBytes(route, from: next, count: end - next) { rest in
                if let rest { cache.store(rest, at: next, evicting: false) }
                #if DEBUG
                done()
                #endif
            }
        }
    }

    /// `count` bytes of the file from `from`, from the server (nil: failed).
    private func fetchBytes(_ route: (url: URL, headers: [(String, String)]), from: Int64, count: Int64,
                            then: @escaping @Sendable (Data?) -> Void) {
        var request = URLRequest(url: route.url)
        request.timeoutInterval = 30
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(from)-\(from + count - 1)", forHTTPHeaderField: "Range")
        let task = HTTP.session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 206 && data?.count == Int(count)
            then(ok ? data : nil)
        }
        task.delegate = HTTP.keyOutOfRedirects
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
    private let cache: ByteCache?
    private let sendsHead: Bool
    private let lock = NSLock()
    private var pending = 0
    private var suspended = false
    private var finished = false
    /// Where in the file the next byte received goes (for the cache).
    private var offset: Int64?
    #if DEBUG
    weak var relay: StreamRelay?
    var read: Int?
    private let asked = CFAbsoluteTimeGetCurrent()
    #endif

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

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(HTTP.redirected(request, from: task.originalRequest?.url))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        #if DEBUG
        relay?.noteFetch(firstByteAfter: CFAbsoluteTimeGetCurrent() - asked)
        #endif
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
        #if DEBUG
        relay?.noteFetched(data.count, for: read)
        #endif
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
/// the bytes written take space), up to 1 GB; past that, the bytes
/// farthest from the newest are let go.
final class ByteCache: @unchecked Sendable {
    private static let folder = FileManager.default.temporaryDirectory.appending(path: "relay-cache")
    static let limit: Int64 = 1 << 30

    private let limit: Int64
    private let lock = NSLock()
    private let path: URL
    private let handle: FileHandle
    private var ranges: [Range<Int64>] = []
    private var stored: Int64 = 0
    private(set) var total: Int64?
    private(set) var contentType: String?

    init?(limit: Int64 = ByteCache.limit) {
        self.limit = limit
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

    /// Whether the file's index is still to be fetched (true once).
    func claimIndex() -> Bool {
        lock.withLock {
            defer { indexClaimed = true }
            return !indexClaimed
        }
    }
    private var indexClaimed = false

    /// `evicting`: may let the bytes farthest from these go to make room
    /// (not for the index, far from where the film plays).
    func store(_ data: Data, at offset: Int64, evicting: Bool = true) {
        let end = offset + Int64(data.count)
        lock.withLock {
            if evicting { makeRoom(for: Int64(data.count), near: offset) }
            guard stored + Int64(data.count) <= limit else { return }
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

    /// mpv reads again from ten seconds back for a track it hasn't been
    /// reading, so the bytes near `offset` stay.
    private func makeRoom(for count: Int64, near offset: Int64) {
        #if DEBUG
        if Self.oldRule { return oldMakeRoom(for: count, near: offset) }
        #endif
        let step: Int64 = 1 << 20
        while stored + count > limit, let first = ranges.first, let last = ranges.last {
            let excess = stored + count - limit
            if offset - first.lowerBound >= last.upperBound - offset {
                let cut = min(first.upperBound, (first.lowerBound + excess + step - 1) / step * step)
                punch(first.lowerBound..<cut)
                ranges[0] = cut..<first.upperBound
            } else {
                let cut = max(last.lowerBound, (last.upperBound - excess) / step * step)
                punch(cut..<last.upperBound)
                ranges[ranges.count - 1] = last.lowerBound..<cut
            }
            ranges.removeAll(where: \.isEmpty)
            stored = ranges.reduce(0) { $0 + Int64($1.count) }
        }
    }

    /// Gives these bytes' disk space back: whole blocks only, the file
    /// system frees no part of one.
    private func punch(_ bytes: Range<Int64>) {
        let block: Int64 = 4096
        let from = (bytes.lowerBound + block - 1) / block * block, to = bytes.upperBound / block * block
        guard to > from else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(from), fp_length: off_t(to - from))
        _ = fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole)
    }

    #if DEBUG
    /// The rule before (-oldRelayCache YES, a real run before and after):
    /// only runs ending 64 MB before `offset` went. A film read straight
    /// through is one run, so full, it kept nothing new until the player was
    /// 64 MB further, then let all of it go.
    private static let oldRule = UserDefaults.standard.bool(forKey: "oldRelayCache")

    private func oldMakeRoom(for count: Int64, near offset: Int64) {
        guard stored + count > limit else { return }
        for range in ranges where range.upperBound <= offset - (64 << 20) { punch(range) }
        ranges.removeAll { $0.upperBound <= offset - (64 << 20) }
        stored = ranges.reduce(0) { $0 + Int64($1.count) }
    }
    #endif
}


/// Just enough of Matroska (EBML) to find a file's index.
enum Matroska {
    private static let ebmlID: UInt32 = 0x1A45DFA3
    private static let segmentID: UInt32 = 0x18538067
    private static let seekHeadID: UInt32 = 0x114D9B74
    private static let seekID: UInt32 = 0x4DBB
    private static let seekTargetID: UInt32 = 0x53AB
    private static let seekPositionID: UInt32 = 0x53AC
    private static let clusterID: UInt32 = 0x1F43B675
    static let cuesID: UInt32 = 0x1C53BB6B

    private static let infoID: UInt32 = 0x1549A966
    private static let timecodeScaleID: UInt32 = 0x2AD7B1
    private static let cuePointID: UInt32 = 0xBB
    private static let cueTimeID: UInt32 = 0xB3
    private static let cueTrackPositionsID: UInt32 = 0xB7
    private static let cueClusterPositionID: UInt32 = 0xF1

    struct Layout {
        let segmentStart: Int64
        let firstCluster: Int64?
        let cues: Int64?
        /// Earliest SeekHead offset after the clusters. libmpv reads that tail on open.
        let pastClusters: Int64?
        let timecodeScale: UInt64
    }

    static func layout(in d: [UInt8]) -> Layout? {
        guard let (ebml, il) = id(d, 0), ebml == ebmlID, let (headerSize, sl) = self.size(d, il), let header = headerSize else { return nil }
        var i = il + sl + Int(header)
        guard let (segment, gl) = id(d, i), segment == segmentID, let (_, zl) = self.size(d, i + gl) else { return nil }
        let segmentStart = i + gl + zl
        i = segmentStart
        var listed: [(UInt32, UInt64)]?
        var firstCluster: Int64?
        var scale: UInt64 = 1_000_000
        while let (element, el) = id(d, i) {
            if element == clusterID {
                firstCluster = Int64(i)
                break
            }
            guard let (length, ll) = self.size(d, i + el), let length, length < 1 << 31 else { break }
            let body = i + el + ll
            if element == seekHeadID, listed == nil { listed = seeks(d, from: body, to: min(body + Int(length), d.count)) }
            if element == infoID {
                for (child, value) in children(d, from: body, to: min(body + Int(length), d.count)) where child == timecodeScaleID {
                    if let unit = uint(value), unit > 0 { scale = unit }
                }
            }
            i = body + Int(length)
        }
        let positions = (listed ?? []).map { (target: $0.0, at: Int64(segmentStart) + Int64($0.1)) }
        let pastClusters = firstCluster.flatMap { first in
            positions.filter { $0.target != clusterID && $0.at > first }.map(\.at).min()
        }
        return Layout(segmentStart: Int64(segmentStart), firstCluster: firstCluster, cues: positions.first { $0.target == cuesID }?.at,
                      pastClusters: pastClusters, timecodeScale: scale)
    }

    /// libmpv's CueClusterPosition for `seconds`, counted from the segment:
    /// the last keyframe at or before it, else the next.
    static func clusterPosition(in d: [UInt8], at seconds: Double, scale: UInt64) -> Int64? {
        guard let (element, el) = id(d, 0), element == cuesID, let (length, sl) = size(d, el), let length else { return nil }
        let target = UInt64(max(0, seconds) * 1_000_000_000 / Double(scale))
        var before: (time: UInt64, position: UInt64)?, after: (time: UInt64, position: UInt64)?
        for (child, point) in children(d, from: el + sl, to: min(d.count, el + sl + Int(length))) where child == cuePointID {
            let fields = children(d, from: point.startIndex, to: point.endIndex)
            guard let time = fields.first(where: { $0.0 == cueTimeID }).flatMap({ uint($0.1) }),
                  let positions = fields.first(where: { $0.0 == cueTrackPositionsID }),
                  let position = children(d, from: positions.1.startIndex, to: positions.1.endIndex)
                      .first(where: { $0.0 == cueClusterPositionID }).flatMap({ uint($0.1) })
            else { continue }
            if time <= target, before.map({ time >= $0.time }) ?? true { before = (time, position) }
            if time > target, after.map({ time < $0.time }) ?? true { after = (time, position) }
        }
        return (before ?? after).map { Int64($0.position) }
    }

    /// The elements inside `from..<to`, each with its contents.
    private static func children(_ d: [UInt8], from: Int, to end: Int) -> [(UInt32, ArraySlice<UInt8>)] {
        var found: [(UInt32, ArraySlice<UInt8>)] = []
        var j = from
        while j < end, let (element, el) = id(d, j), let (length, ll) = size(d, j + el), let length, length < 1 << 31 {
            let body = j + el + ll
            guard body + Int(length) <= d.count else { break }
            found.append((element, d[body..<body + Int(length)]))
            j = body + Int(length)
        }
        return found
    }

    private static func uint(_ value: ArraySlice<UInt8>) -> UInt64? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        return value.reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Where the Cues start in the file, from the SeekHead at its start.
    static func cuesOffset(in d: [UInt8]) -> Int64? {
        guard let (ebml, il) = id(d, 0), ebml == ebmlID, let (headerSize, sl) = self.size(d, il), let header = headerSize else { return nil }
        var i = il + sl + Int(header)
        guard let (segment, gl) = id(d, i), segment == segmentID, let (_, zl) = self.size(d, i + gl) else { return nil }
        let segmentStart = i + gl + zl
        i = segmentStart
        while let (element, el) = id(d, i), let (length, ll) = self.size(d, i + el), let length, length < 1 << 31 {
            let body = i + el + ll
            if element == clusterID { return nil }
            if element == seekHeadID {
                for (target, position) in seeks(d, from: body, to: min(body + Int(length), d.count)) where target == cuesID {
                    return Int64(segmentStart) + Int64(position)
                }
                return nil
            }
            i = body + Int(length)
        }
        return nil
    }

    /// The SeekHead's entries: an element's ID and where it is.
    private static func seeks(_ d: [UInt8], from: Int, to end: Int) -> [(UInt32, UInt64)] {
        var found: [(UInt32, UInt64)] = []
        var j = from
        while j < end, let (element, el) = id(d, j), let (length, ll) = size(d, j + el), let length, length < 1 << 16 {
            let body = j + el + ll
            if element == seekID {
                var target: UInt32?, position: UInt64?
                var k = body
                let stop = min(body + Int(length), d.count)
                while k < stop, let (child, cl) = id(d, k), let (size, sl) = self.size(d, k + cl), let size, size <= 8 {
                    let value = k + cl + sl
                    guard value + Int(size) <= d.count else { break }
                    if child == seekTargetID { target = d[value..<value + Int(size)].reduce(0) { $0 << 8 | UInt32($1) } }
                    if child == seekPositionID { position = d[value..<value + Int(size)].reduce(0) { $0 << 8 | UInt64($1) } }
                    k = value + Int(size)
                }
                if let target, let position { found.append((target, position)) }
            }
            j = body + Int(length)
        }
        return found
    }

    private static let largest: Int64 = 32 << 20

    static func fetchStart(at seconds: Double, fetch: (Int64, Int64) async -> (data: Data, total: Int64)?) async -> Bool {
        let first = StreamRelay.firstRead
        guard let (head, total) = await fetch(0, first), let layout = layout(in: [UInt8](head)), let cues = layout.cues, cues < total
        else { return false }
        var header = min(first, total)
        if let cluster = layout.firstCluster, cluster < largest {
            let to = min(cluster + first, total)
            if to > header {
                guard await fetch(header, to - header) != nil else { return false }
                header = to
            }
        }
        let tailAt = layout.pastClusters.flatMap { total - $0 <= largest ? $0 : nil } ?? total
        var tail: Data?
        if tailAt < total {
            guard let fetched = await fetch(tailAt, total - tailAt) else { return false }
            tail = fetched.data
        }
        let index: [UInt8]
        if let tail, cues >= tailAt {
            index = [UInt8](tail.dropFirst(Int(cues - tailAt)))
        } else {
            guard let probe = await fetch(cues, min(1 << 16, total - cues)), let length = elementLength([UInt8](probe.data.prefix(16))),
                  let whole = await fetch(cues, min(length, min(largest, total - cues))) else { return false }
            index = [UInt8](whole.data)
        }
        guard let cluster = clusterPosition(in: index, at: seconds, scale: layout.timecodeScale) else { return false }
        let at = layout.segmentStart + cluster
        let from = max(at, header), to = min(at + first + StreamRelay.readSize, tailAt)
        guard from < to else { return true }
        return await fetch(from, to - from) != nil
    }

    #if DEBUG
    /// The old ranges, but the cluster is the new choice. A film from the
    /// start gets its first cluster, which the old fetch skipped.
    static func fetchStartAsBefore(at seconds: Double, fetch: (Int64, Int64) async -> (data: Data, total: Int64)?) async -> Bool {
        guard let (head, total) = await fetch(0, 1 << 18), let layout = layout(in: [UInt8](head)), let cues = layout.cues, cues < total,
              let first = await fetch(cues, min(1 << 16, total - cues)), let length = elementLength([UInt8](first.data.prefix(16))),
              let index = await fetch(cues, min(length, min(largest, total - cues))),
              let cluster = clusterPosition(in: [UInt8](index.data), at: seconds, scale: layout.timecodeScale)
        else { return false }
        let at = layout.segmentStart + cluster
        guard at < total else { return false }
        return await fetch(at, min(StreamRelay.readSize, total - at)) != nil
    }
    #endif

    /// The whole length (header and contents) of the element at the start.
    static func elementLength(_ d: [UInt8]) -> Int64? {
        guard let (element, el) = id(d, 0), element == cuesID, let (contents, sl) = self.size(d, el), let contents else { return nil }
        return Int64(el + sl) + Int64(contents)
    }

    /// An element ID (1-4 bytes, its length marker kept) and its length.
    private static func id(_ d: [UInt8], _ i: Int) -> (UInt32, Int)? {
        guard i >= 0, i < d.count, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard length <= 4, i + length <= d.count else { return nil }
        return (d[i..<i + length].reduce(0) { $0 << 8 | UInt32($1) }, length)
    }

    /// A size (1-8 bytes, its marker removed; nil: unknown) and its length.
    private static func size(_ d: [UInt8], _ i: Int) -> (UInt64?, Int)? {
        guard i >= 0, i < d.count, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard i + length <= d.count else { return nil }
        let marker = UInt8(0x80) >> (length - 1)
        var value = UInt64(d[i] & (marker &- 1))
        var unknown = value == UInt64(marker &- 1)
        for k in 1..<length {
            value = value << 8 | UInt64(d[i + k])
            unknown = unknown && d[i + k] == 0xFF
        }
        return (unknown ? nil : value, length)
    }
}

struct FileStart: Hashable, Sendable {
    let itemId: String
    /// The tenth of a second MPVPlayer.load tells mpv. A whole second is the
    /// keyframe before, when one falls between.
    let seconds: Double
    let url: URL
    let headers: [String]

    init(_ playback: EmbyPlayback) {
        itemId = playback.itemId
        seconds = Double(String(format: "%.1f", playback.startSeconds ?? 0)) ?? 0
        url = playback.url
        headers = playback.headers
    }

    static func == (a: FileStart, b: FileStart) -> Bool { a.itemId == b.itemId && a.seconds == b.seconds }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        hasher.combine(seconds)
    }
}

extension FileStart: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "file start" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["seconds": seconds]) }
}

extension Lane {
    static let fileStarts = Lane(.bytes, atOnce: 2, conditions: Conditions.current)
}

@MainActor
enum FileStarts {
    static let shelf = shelf(lane: .fileStarts) { start in
        await StreamRelay.shared.fetchStart(url: start.url, headers: start.headers, at: start.seconds)
    }

    static func shelf(lane: Lane, fetch: @escaping @Sendable (FileStart) async -> Bool) -> Shelf<FileStart, Bool> {
        Shelf(.init(lane: lane, lifetime: .seconds(300), failureKept: .zero)) { start in
            guard await fetch(start) else { throw SourceError.unexpected("The film's start wasn't fetched.") }
            return true
        }
    }
}
