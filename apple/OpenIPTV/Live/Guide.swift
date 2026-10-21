import Compression
import Foundation

/// The full TV guide (XMLTV). Providers' guides run to hundreds of MB, so it
/// is downloaded to a temporary file, parsed as a stream keeping only the
/// user's channels and the next few hours, and cached on device so later
/// launches have titles instantly. Contains programme data only — no
/// credentials (the guide URL itself is never stored here).
actor GuideStore {
    enum State: Equatable {
        case idle
        case loading
        case ready(programmes: Int, fetchedAt: Date)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var programmes: [String: [Programme]] = [:] {
        didSet {
            searchIndex = nil
            generation += 1
        }
    }
    /// Which `programmes` a search index built in the background is for.
    private var generation = 0
    private var fetchedAt: Date?
    /// Every programme with its title folded for matching, in start order
    /// (built on the first search after the guide changes).
    private var searchIndex: [(epgId: String, programme: Programme, folded: String)]?
    /// Each guide id's channel name, folded: words can match the channel
    /// as well as the programme ("simpsons fox").
    private var channelNames: [String: String] = [:]

    private struct Cache: Codable {
        let fetchedAt: Date
        let programmes: [String: [Programme]]
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "guide.json")
    }

    /// Decoded off this actor (a big guide takes a while), so now/next
    /// lookups aren't held up meanwhile.
    func loadCache() async {
        guard programmes.isEmpty else { return }
        let url = cacheURL
        let cache = await Task.detached(priority: .userInitiated) { () -> Cache? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Cache.self, from: data)
        }.value
        guard let cache, programmes.isEmpty else { return }
        programmes = cache.programmes
        fetchedAt = cache.fetchedAt
        state = .ready(programmes: programmes.values.reduce(0) { $0 + $1.count }, fetchedAt: cache.fetchedAt)
        prepareSearchInBackground()
    }

    func isStale(maxAge: TimeInterval = 6 * 3600) -> Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > maxAge
    }

    /// Downloads and parses every guide URL, keeping programmes for `keep`
    /// (XMLTV channel ids) from 2 h ago to `hoursAhead` from now (today and
    /// tomorrow, so search finds what's coming up too).
    func refresh(from requests: [URLRequest], keep: Set<String>, hoursAhead: Int64 = 24) async {
        guard !requests.isEmpty, state != .loading else { return }
        state = .loading
        let now = Int64(Date().timeIntervalSince1970)
        var merged: [String: [Programme]] = [:]
        var lastError: String?
        for request in requests {
            do {
                let parsed = try await Self.fetch(request, keep: keep, from: now - 7200, to: now + hoursAhead * 3600)
                merged.merge(parsed) { $0 + $1 }
            } catch {
                lastError = SourceError.wrap(error).localizedDescription
            }
        }
        guard !merged.isEmpty else {
            state = .failed(lastError ?? "The guide had no programmes for your channels.")
            return
        }
        let unsorted = merged
        merged = await Task.detached(priority: .utility) {
            var sorted = unsorted
            for key in sorted.keys { sorted[key]?.sort { ($0.start, $0.stop) < ($1.start, $1.stop) } }
            return sorted
        }.value
        programmes = merged
        let at = Date()
        fetchedAt = at
        state = .ready(programmes: merged.values.reduce(0) { $0 + $1.count }, fetchedAt: at)
        prepareSearchInBackground()
        // Saved off this actor too.
        let saved = merged, url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(Cache(fetchedAt: at, programmes: saved)) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    /// O(log n) lookup in the sorted list for one channel.
    func nowNext(_ epgId: String, at now: Int64 = Int64(Date().timeIntervalSince1970)) -> NowNext? {
        guard let list = programmes[epgId], !list.isEmpty else { return nil }
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].start <= now { lo = mid + 1 } else { hi = mid }
        }
        let current = lo > 0 && now < list[lo - 1].stop ? list[lo - 1] : nil
        let upcoming = lo < list.count ? list[lo] : nil
        guard current != nil || upcoming != nil else { return nil }
        return NowNext.from([current, upcoming].compactMap { $0 }, at: now, source: .guide)
    }

    /// Everything kept for one channel (from 2 h ago), in order.
    func programmes(_ epgId: String) -> [Programme] {
        programmes[epgId] ?? []
    }

    func setChannelNames(_ names: [String: String]) {
        channelNames = names
    }

    /// Programmes on now or later whose title has the query's words (each
    /// word in the title or the channel's name, at least one in the title):
    /// the ones on now first, then by start time.
    /// The search index, built in the background when the guide arrives
    /// rather than on the first letter typed (it folds every title: a
    /// moment for a big guide).
    private func prepareSearchInBackground() {
        let snapshot = programmes, built = generation
        let task = Task.detached(priority: .utility) { GuideStore.index(snapshot) }
        indexBuild = (built, task)
        Task { await install(await task.value, for: built) }
    }

    /// The background build under way, and which guide it's for.
    private var indexBuild: (generation: Int, task: Task<[(epgId: String, programme: Programme, folded: String)], Never>)?

    private func install(_ index: [(epgId: String, programme: Programme, folded: String)], for built: Int) {
        if built == generation, searchIndex == nil { searchIndex = index }
    }

    /// Searching before the background index is ready: build it here.
    private func prepareSearch() {
        guard searchIndex == nil else { return }
        searchIndex = Self.index(programmes)
    }

    private nonisolated static func index(_ programmes: [String: [Programme]]) -> [(epgId: String, programme: Programme, folded: String)] {
        programmes.flatMap { id, list in
            list.map { (epgId: id, programme: $0, folded: SharedGuideRule.fold($0.title)) }
        }.sorted { $0.programme.start < $1.programme.start }
    }

    /// Stops early when the search that asked is cancelled (the next letter
    /// was typed), so letters typed quickly don't queue up whole scans.
    func search(_ words: [String], now: Int64 = Int64(Date().timeIntervalSince1970), limit: Int = 300) async
        -> [(epgId: String, programme: Programme)] {
        guard !words.isEmpty else { return [] }
        // The index still being built in the background: wait for it rather
        // than build a second one here.
        if searchIndex == nil, let build = indexBuild, build.generation == generation {
            install(await build.task.value, for: build.generation)
        }
        prepareSearch()
        var onNow: [(String, Programme)] = [], later: [(String, Programme)] = []
        for (offset, item) in (searchIndex ?? []).enumerated() {
            if offset & 4095 == 0, Task.isCancelled { return [] }
            guard SharedGuideRule.findsProgramme(words, title: item.folded, channel: channelNames[item.epgId],
                                       stop: item.programme.stop, now: now) else { continue }
            if item.programme.start <= now { onNow.append((item.epgId, item.programme)) } else { later.append((item.epgId, item.programme)) }
            if onNow.count + later.count >= limit { break }
        }
        return (onNow + later).map { (epgId: $0.0, programme: $0.1) }
    }

    func clear() {
        programmes = [:]
        fetchedAt = nil
        state = .idle
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Download + parse

    private static func fetch(_ request: URLRequest, keep: Set<String>, from: Int64, to: Int64) async throws -> [String: [Programme]] {
        let (downloaded, response) = try await HTTP.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SourceError.http(code) }

        var file = downloaded
        if try isGzip(downloaded) {
            let plain = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try gunzip(downloaded, to: plain)
            file = plain
        }
        defer { if file != downloaded { try? FileManager.default.removeItem(at: file) } }

        return try await Task.detached(priority: .utility) {
            let delegate = XMLTVDelegate(keep: keep, from: from, to: to)
            guard let parser = XMLParser(contentsOf: file) else { throw SourceError.unexpected("The guide couldn't be read.") }
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            if !parser.parse(), delegate.programmes.isEmpty {
                throw SourceError.unexpected("The guide isn't valid XMLTV.")
            }
            return delegate.programmes
        }.value
    }

    private static func isGzip(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 2) ?? Data()
        return magic == Data([0x1f, 0x8b])
    }

    /// Streaming gunzip: skip the gzip header, inflate the raw deflate body.
    private static func gunzip(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        guard let header = try input.read(upToCount: 10), header.count == 10 else { throw SourceError.unexpected("Bad gzip file.") }
        let flags = header[3]
        if flags & 0x04 != 0, let len = try input.read(upToCount: 2), len.count == 2 {
            _ = try input.read(upToCount: Int(len[0]) | Int(len[1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            while let byte = try input.read(upToCount: 1), byte.count == 1, byte[0] != 0 {}
        }
        if flags & 0x02 != 0 { _ = try input.read(upToCount: 2) }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SourceError.unexpected("Couldn't decompress the guide.")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        // compression_stream needs a valid pointer even for an empty final chunk.
        let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { empty.deallocate() }

        var status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            let chunk = try input.read(upToCount: capacity) ?? Data()
            let last = chunk.isEmpty
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(empty)
                stream.pointee.src_size = chunk.count
                repeat {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = capacity
                    status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    if status == COMPRESSION_STATUS_ERROR { throw SourceError.unexpected("The guide is corrupt.") }
                    output.write(Data(bytes: buffer, count: capacity - stream.pointee.dst_size))
                    // Loop while output filled the buffer (more pending) or input remains.
                } while status == COMPRESSION_STATUS_OK && (stream.pointee.dst_size == 0 || stream.pointee.src_size > 0)
            }
            if last { break }
        }
    }
}

/// SAX handler: keeps only wanted channels and the time window, first title
/// per programme.
private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    let keep: Set<String>
    let from: Int64
    let to: Int64
    var programmes: [String: [Programme]] = [:]

    private var channel: String?
    private var start: Int64 = 0
    private var stop: Int64 = 0
    private var title: String?
    private var readingTitle = false
    private var text = ""

    init(keep: Set<String>, from: Int64, to: Int64) {
        self.keep = keep
        self.from = from
        self.to = to
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "programme" {
            channel = nil
            title = nil
            guard let id = attributes["channel"], keep.isEmpty || keep.contains(id),
                  let s = attributes["start"].flatMap(Self.time), let e = attributes["stop"].flatMap(Self.time),
                  e > from, s < to, e > s else { return }
            channel = id
            start = s
            stop = e
        } else if name == "title", channel != nil, title == nil {
            readingTitle = true
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingTitle { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if readingTitle, let s = String(data: data, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "title", readingTitle {
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            readingTitle = false
        } else if name == "programme", let channel {
            programmes[channel, default: []].append(Programme(start: start, stop: stop, title: title ?? ""))
            self.channel = nil
        }
    }

    /// `YYYYMMDDhhmm[ss] [+-hhmm]`; a missing offset means UTC.
    static func time(_ s: String) -> Int64? {
        let bytes = Array(s.utf8)
        var digits = 0
        while digits < bytes.count, (48...57).contains(bytes[digits]) { digits += 1 }
        guard digits >= 12 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int64 {
            bytes[a..<b].reduce(0) { $0 * 10 + Int64($1 - 48) }
        }
        var c = DateComponents()
        c.year = Int(num(0, 4)); c.month = Int(num(4, 6)); c.day = Int(num(6, 8))
        c.hour = Int(num(8, 10)); c.minute = Int(num(10, 12)); c.second = digits >= 14 ? Int(num(12, 14)) : 0
        c.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: c) else { return nil }
        var offset: Int64 = 0
        let rest = bytes[digits...].drop { $0 == 32 }
        if let sign = rest.first, sign == 43 || sign == 45 {
            let d = Array(rest.dropFirst().filter { $0 != 58 })
            if d.count >= 4 {
                let h = Int64(d[0] - 48) * 10 + Int64(d[1] - 48)
                let m = Int64(d[2] - 48) * 10 + Int64(d[3] - 48)
                offset = (h * 3600 + m * 60) * (sign == 45 ? -1 : 1)
            }
        }
        return Int64(date.timeIntervalSince1970) - offset
    }
}
