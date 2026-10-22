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
    #if DEBUG
    /// The film's requests the server answered with a redirect.
    static let redirects = Locked(RedirectCount())
    #endif

    /// The key goes only to the server the film was asked from.
    static func redirected(_ request: URLRequest, for task: URLSessionTask) -> URLRequest {
        HTTP.redirected(request, from: task.originalRequest?.url)
    }

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
        let read = noteStartRead(range, cache: cache, device: max(0, cachedNow ?? 0))
        lock.withLock { startReadOf[ObjectIdentifier(connection)] = read }
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
        weak var cache: ByteCache?
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

    struct StartReadKey {
        let start: Int
        let index: Int
    }

    private var startLog: [StartRead] = []
    private var startReadOf: [ObjectIdentifier: StartReadKey] = [:]
    private var startBegan = CFAbsoluteTimeGetCurrent()
    private var starts = 0

    func beginStartReads() {
        lock.withLock {
            starts += 1
            startReads = (0, 0, 0, 0, 0)
            startLog = []
            startReadOf = [:]
            startBegan = CFAbsoluteTimeGetCurrent()
        }
    }

    func noteStartRead(_ range: String?, cache: ByteCache?, device: Int64) -> StartReadKey {
        lock.withLock {
            startReads.requests += 1
            startReads.cached += device
            startLog.append(StartRead(at: CFAbsoluteTimeGetCurrent() - startBegan, range: range, cache: cache, device: device))
            return StartReadKey(start: starts, index: startLog.count - 1)
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

    fileprivate func startRead(for connection: NWConnection) -> StartReadKey? {
        lock.withLock { startReadOf[ObjectIdentifier(connection)] }
    }

    func noteFetch(firstByteAfter seconds: Double, for read: StartReadKey?) {
        lock.withLock {
            guard read?.start == starts else { return }
            startReads.fetches += 1
            startReads.firstByte = max(startReads.firstByte, seconds)
        }
    }

    func noteFetched(_ count: Int, for read: StartReadKey?) {
        lock.withLock {
            guard let read, read.start == starts else { return }
            startReads.fetched += Int64(count)
            startLog[read.index].server += Int64(count)
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

    func fetchStart(_ file: FileStart) async -> Bool {
        start()
        let key = cacheKey(file.url)
        // Asked a moment after something started playing: not now.
        let allowed = lock.withLock { () -> Bool in
            guard !PlaybackActivity.isPlaying || key == playingFile else { return false }
            stoppedAhead.remove(key)
            aheadFiles.insert(key)
            return true
        }
        let route = Self.route(file.url, file.headers)
        guard allowed, let cache = cache(for: route.url) else { return false }
        let fetch = fetcher(route, cache, ahead: key)
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        let fetched = Self.oldReadyStart ? await file.fetchAsBefore(through: fetch) : await file.fetch(through: fetch)
        if fetched {
            NSLog("%@", String(format: "PERF relay start fetched ahead at %.0f s in %.0f ms", file.seconds, (CFAbsoluteTimeGetCurrent() - started) * 1000))
        }
        return fetched
        #else
        return await file.fetch(through: fetch)
        #endif
    }

    #if DEBUG
    static var oldReadyStart: Bool { UserDefaults.standard.bool(forKey: "oldReadyStart") }
    #endif

    private func fetcher(_ route: (url: URL, headers: [(String, String)]), _ cache: ByteCache, ahead key: String? = nil) -> Matroska.Fetch {
        { [self] from, count in
            await withCheckedContinuation { done in
                queue.async { [self] in
                    ensure(route, cache, from: from, count: count, ahead: key) { bytes, total in
                        done.resume(returning: bytes.flatMap { data in total.map { (data, $0) } })
                    }
                }
            }
        }
    }

    /// These bytes of the file in the cache (fetched unless already there),
    /// then `then` with them and the file's size (nil: failed). `ahead`:
    /// fetched ahead of a tap for this file (low priority; nothing more once
    /// something else plays, see stopAhead).
    private func ensure(_ route: (url: URL, headers: [(String, String)]), _ cache: ByteCache, from: Int64, count: Int64,
                        ahead key: String? = nil, then: @escaping @Sendable (Data?, Int64?) -> Void) {
        if count > 0, cache.available(from: from) >= count, let kept = cache.read(from, Int(count)) {
            cache.keep(from..<from + count)
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
        guard let layout = Matroska.layout(in: [UInt8](head), total: total), let cues = layout.cues else { return }
        cache.keep(layout.tail)
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let fetch = fetcher(route, cache)
        Task {
            guard let index = await Matroska.fetchIndex(at: cues, total: total, fetch: fetch) else { return }
            #if DEBUG
            NSLog("%@", String(format: "PERF relay index %lld bytes at %lld in %.0f ms", Int64(index.count), cues,
                               (CFAbsoluteTimeGetCurrent() - started) * 1000))
            #else
            _ = index
            #endif
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
    #if DEBUG
    weak var relay: StreamRelay?
    var read: StreamRelay.StartReadKey?
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
        relay?.noteFetch(firstByteAfter: CFAbsoluteTimeGetCurrent() - asked, for: read)
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

struct FileStart: Hashable, Sendable {
    let itemId: String
    /// The tenth of a second MPVPlayer.load tells mpv. A whole second is the
    /// keyframe before, when one falls between.
    let seconds: Double
    /// How far before it mpv reads for the subtitle line on, with cue
    /// durations: the larger of the two it is told (demux_mkv.c,
    /// seek_with_cues). 0: no subtitles planned.
    let subtitlePreroll: Double
    #if DEBUG
    /// -oldReadyStart: the whole second the old fetch took, and kept it by.
    let second: Int
    #endif
    let url: URL
    let headers: [String]

    init(_ playback: EmbyPlayback) {
        itemId = playback.itemId
        seconds = Double(Self.mpvStart(playback.startSeconds ?? 0)) ?? 0
        subtitlePreroll = TrackChoice.subtitlePreroll(playback.tracks, reopening: false).compactMap { Double($0.value) }.max() ?? 0
        #if DEBUG
        second = Int(exactly: (playback.startSeconds ?? 0).rounded(.towardZero)) ?? 0
        #endif
        url = playback.url
        headers = playback.headers
    }

    static func mpvStart(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    func fetch(through fetch: Matroska.Fetch) async -> Bool {
        await Matroska.fetchStart(at: seconds, subtitlePreroll: subtitlePreroll, fetch: fetch)
    }

    #if DEBUG
    func fetchAsBefore(through fetch: Matroska.Fetch) async -> Bool {
        await Matroska.fetchStartAsBefore(at: Double(second), fetch: fetch)
    }
    #endif

    static func == (a: FileStart, b: FileStart) -> Bool {
        #if DEBUG
        if StreamRelay.oldReadyStart { return a.itemId == b.itemId && a.second == b.second }
        #endif
        return a.itemId == b.itemId && a.seconds == b.seconds && a.subtitlePreroll == b.subtitlePreroll
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        #if DEBUG
        if StreamRelay.oldReadyStart { return hasher.combine(second) }
        #endif
        hasher.combine(seconds)
        hasher.combine(subtitlePreroll)
    }
}

extension FileStart: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "file start" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["seconds": seconds, "subtitlePreroll": subtitlePreroll]) }
}

extension Lane {
    static let fileStarts = Lane(.bytes, atOnce: 2, conditions: Conditions.current)
}

@MainActor
enum FileStarts {
    static let shelf = shelf(lane: .fileStarts) { start in
        await StreamRelay.shared.fetchStart(start)
    }

    static func shelf(lane: Lane, fetch: @escaping @Sendable (FileStart) async -> Bool) -> Shelf<FileStart, Bool> {
        Shelf(.init(lane: lane, lifetime: .seconds(300), failureKept: .zero)) { start in
            guard await fetch(start) else { throw SourceError.unexpected("The film's start wasn't fetched.") }
            return true
        }
    }
}

#if DEBUG
/// Debug builds: requests the server answered with a redirect, and those
/// sent to another server than the one asked.
struct RedirectCount: Sendable {
    private(set) var redirected = 0, elsewhere = 0

    mutating func note(_ target: URL?, from asked: URL?) {
        redirected += 1
        if let target, let asked, HTTP.sameServer(target, asked) { return }
        elsewhere += 1
    }

    var readout: String { "\(redirected) (\(elsewhere) elsewhere)" }
}
#endif
