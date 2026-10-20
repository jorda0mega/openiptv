import Foundation

/// The provider's rate rules are built in: OPENIPTV_PROBE_GAP (3 s) between
/// opens, OPENIPTV_PROBE_ROUND_GAP (600 s) between rounds, and a pause of
/// OPENIPTV_PROBE_PAUSE_SECONDS (300) before the requests would pass
/// OPENIPTV_PROBE_PAUSE_EVERY (10) since the last long wait.
enum LiveProbe {
    enum Ext: String { case ts, m3u8 }
    enum Agent: String { case mpv, app }
    enum Failure: String { case none, dns, refused, reset, timeout, no_data, tls, cancelled, redirect_loop, other }

    struct Login {
        let server: URL
        let username: String
        let password: String

        func stream(_ id: String, _ ext: Ext) -> URL {
            var url = server
            for segment in ["live", username, password, "\(id).\(ext.rawValue)"] { url.append(path: segment) }
            return url
        }

        func api(_ action: String? = nil) -> URL? {
            var parts = URLComponents(url: server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
            if let action { items.append(URLQueryItem(name: "action", value: action)) }
            parts?.queryItems = items
            return parts?.url
        }
    }

    static func envValue(_ key: String, _ env: [String: String]) -> String? {
        env[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    struct Open {
        var tok = "", ext = Ext.ts, ua = Agent.mpv, round = 0
        /// URLSession hands over the status only with the first body byte:
        /// an answer whose body hasn't started reads `status=0 headers=yes`.
        var status = 0, headers = false
        var hops = 0, redirectMs = -1, crossHost = false
        var dns = -1, tcp = -1, tls = -1
        var ttfb = -1, firstData = -1
        var rateKbps = -1, first1sKB = -1, rateTailKbps = -1
        var gapMax = 0.0, gaps1s = 0, stoppedAt = 0.0, bytes = 0
        var ctype = "other"
        /// URLSession takes a reset of a close-delimited body
        /// for its end, so there `error=none` before the cap is an end or a
        /// reset.
        var framing = "none"
        var error = Failure.none
        var capped = false
        var playlist: Playlist?

        var line: String {
            var line = "PROBE open tok=\(tok) ext=\(ext.rawValue) ua=\(ua.rawValue) round=\(round) status=\(status) headers=\(yes(headers))"
                + " hops=\(hops) redirect_ms=\(redirectMs) cross_host=\(yes(crossHost)) dns=\(dns) tcp=\(tcp) tls=\(tls)"
                + " ttfb=\(ttfb) first_data=\(firstData) rate_kbps=\(rateKbps) first_1s_kb=\(first1sKB) rate_tail_kbps=\(rateTailKbps)"
                + " gap_max=\(fixed(gapMax, 2)) gaps_1s=\(gaps1s) stopped_at=\(fixed(stoppedAt, 1)) bytes=\(bytes)"
                + " ctype=\(ctype) framing=\(framing) error=\(error.rawValue)"
            if let p = playlist {
                line += " master=\(yes(p.master)) segments=\(p.segments) target=\(fixed(p.target, 1)) seg_first_data=\(p.segmentFirstData)"
            }
            return line
        }

        var endsByDesign: Bool { ext == .m3u8 || framing == "length" }
        var endedEarly: Bool { !endsByDesign && status == 200 && bytes > 0 && !capped }
    }

    struct Playlist {
        var master = false, segments = 0, target = 0.0, segmentFirstData = -1
    }

    static var refusedLines = 0

    static let fieldCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=.>- ")
    static let longestWord = 32

    /// The provider's stream addresses carry the login.
    static func holdsNoAddress(_ line: String) -> Bool {
        if isPickedIdsForTheShell(line) { return true }
        guard line.unicodeScalars.allSatisfy(fieldCharacters.contains) else { return false }
        return line.split(separator: " ").allSatisfy { word in
            word.count <= longestWord && (!word.contains(".") || isDecimalField(word))
        }
    }

    static func isPickedIdsForTheShell(_ line: String) -> Bool {
        line.range(of: #"\AOPENIPTV_PROBE_IDS=(?:[0-9]{1,12}(?:,[0-9]{1,12}){0,19})?\z"#, options: .regularExpression) != nil
    }

    static func isDecimalField(_ word: Substring) -> Bool {
        word.range(of: "^[a-z0-9_]+=-?[0-9]+[.][0-9]+$", options: .regularExpression) != nil
    }

    static func say(_ line: String) {
        if holdsNoAddress(line) {
            print(line)
        } else {
            refusedLines += 1
            print("PROBE line_refused")
        }
    }

    static func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
    static func fixed(_ x: Double, _ places: Int) -> String { String(format: "%.\(places)f", x) }

    final class Reader: NSObject, URLSessionDataDelegate {
        let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        let keep: Int
        var started = Date()
        var redirects = 0
        var response: HTTPURLResponse?
        var metrics: URLSessionTaskMetrics?
        var firstByte: Date?, lastByte: Date?
        var arrivals: [(at: Date, bytes: Int)] = []
        var bytes = 0, gapMax = 0.0, gaps1s = 0
        var body = Data()
        var capped: Date?, finished: Date?
        var error: Error?
        var done: (() -> Void)?

        init(keep: Int) { self.keep = keep }

        var stopped: Date { capped ?? finished ?? Date() }

        func gap(until now: Date) {
            guard let last = lastByte else { return }
            let gap = now.timeIntervalSince(last)
            gapMax = max(gapMax, gap)
            if gap > 1 { gaps1s += 1 }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let now = Date()
            if firstByte == nil { firstByte = now }
            gap(until: now)
            lastByte = now
            arrivals.append((now, data.count))
            bytes += data.count
            if body.count < keep { body.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            self.metrics = metrics
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finished = Date()
            self.error = error
            gap(until: stopped)
            done?()
        }
    }

    static var requests = 0

    static func read(_ url: URL, agent: String, cap: Double, keep: Int = 0) async -> Reader {
        requests += 1
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        // Past the cap, so the cap ends every read: URLSession's idle timer
        // would end a dead feed or a long stall at 60 s.
        config.timeoutIntervalForRequest = cap + 5
        config.httpMaximumConnectionsPerHost = 1
        let reader = Reader(keep: keep)
        let session = URLSession(configuration: config, delegate: reader, delegateQueue: reader.queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        // A tight leeway: asyncAfter's default let a 10 s cap run 0.7 s over.
        let cutoff = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        cutoff.schedule(deadline: .now() + cap, leeway: .milliseconds(5))
        cutoff.setEventHandler {
            reader.queue.addOperation {
                guard reader.finished == nil else { return }
                reader.capped = Date()
                task.cancel()
            }
        }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            reader.queue.addOperation {
                reader.done = { finished.resume() }
                reader.started = Date()
                task.resume()
            }
            cutoff.resume()
        }
        cutoff.cancel()
        return reader
    }

    static func failure(_ r: Reader, headers: Bool) -> Failure {
        if r.capped != nil { return !headers ? .timeout : r.bytes == 0 ? .no_data : .none }
        guard let error = r.error else { return .none }
        guard let code = (error as? URLError)?.code else { return .other }
        switch code {
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost: return .refused
        case .networkConnectionLost: return .reset
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired: return .tls
        case .httpTooManyRedirects: return .redirect_loop
        case .cancelled: return .cancelled
        default: return .other
        }
    }

    static func ms(_ from: Date?, _ to: Date?) -> Int {
        guard let from, let to else { return -1 }
        return Int((to.timeIntervalSince(from) * 1000).rounded())
    }

    static func open(_ login: Login, id: String, ext: Ext, ua: Agent, round: Int, cap: Double) async -> Open {
        let r = await read(login.stream(id, ext), agent: agent(ua), cap: cap, keep: ext == .m3u8 ? 1 << 20 : 0)
        let hops = r.metrics?.transactionMetrics ?? []
        let origin = hops.first?.fetchStartDate ?? r.started
        let response = r.response ?? hops.last?.response as? HTTPURLResponse
        var o = Open(tok: id, ext: ext, ua: ua, round: round)
        o.status = response?.statusCode ?? 0
        o.headers = response != nil || hops.last?.responseStartDate != nil
        o.hops = hops.isEmpty ? r.redirects : hops.count - 1
        if hops.count > 1 { o.redirectMs = ms(hops[0].fetchStartDate, hops[0].responseStartDate) }
        let firstHost = hops.first?.request.url?.host() ?? login.server.host()
        let lastHost = hops.last?.request.url?.host() ?? response?.url?.host()
        o.crossHost = lastHost != nil && firstHost != lastHost
        let fresh = hops.filter { !$0.isReusedConnection }
        func total(_ spans: [Int]) -> Int { spans.isEmpty ? -1 : spans.reduce(0, +) }
        func span(_ start: Date?, _ end: Date?) -> Int? { start == nil || end == nil ? nil : max(0, ms(start, end)) }
        o.dns = total(fresh.compactMap { span($0.domainLookupStartDate, $0.domainLookupEndDate) })
        o.tls = total(fresh.compactMap { span($0.secureConnectionStartDate, $0.secureConnectionEndDate) })
        o.tcp = total(fresh.compactMap { hop in
            span(hop.connectStartDate, hop.connectEndDate).map { $0 - (span(hop.secureConnectionStartDate, hop.secureConnectionEndDate) ?? 0) }
        })
        o.ttfb = ms(origin, hops.last?.responseStartDate)
        o.firstData = ms(origin, r.firstByte)
        if let first = r.firstByte {
            let length = r.stopped.timeIntervalSince(first)
            if length > 0.05 { o.rateKbps = Int(Double(r.bytes) * 8 / 1000 / length) }
            if length >= 1 { o.first1sKB = r.arrivals.filter { $0.at <= first + 1 }.reduce(0) { $0 + $1.bytes } / 1024 }
            if length >= 6 {
                let tail = r.arrivals.filter { $0.at > r.stopped - 5 }.reduce(0) { $0 + $1.bytes }
                o.rateTailKbps = Int(Double(tail) * 8 / 1000 / 5)
            }
        }
        o.gapMax = r.gapMax
        o.gaps1s = r.gaps1s
        o.stoppedAt = r.stopped.timeIntervalSince(origin)
        o.bytes = r.bytes
        o.capped = r.capped != nil
        let mime = response?.mimeType?.lowercased() ?? ""
        o.ctype = mime == "video/mp2t" ? "mp2t" : mime.hasSuffix("mpegurl") ? "mpegurl" : "other"
        if let response {
            // URLSession hides Transfer-Encoding; chunks show as more bytes
            // on the wire than it hands over.
            let wire = hops.last.map { $0.countOfResponseBodyBytesReceived > $0.countOfResponseBodyBytesAfterDecoding } ?? false
            o.framing = response.value(forHTTPHeaderField: "Content-Length") != nil ? "length" : wire ? "chunked" : "close"
        }
        o.error = failure(r, headers: o.headers)
        if ext == .m3u8, o.status == 200 {
            o.playlist = await playlistAndFirstSegment(r, agent: agent(ua), cap: cap)
        }
        return o
    }

    static func playlistAndFirstSegment(_ r: Reader, agent: String, cap: Double) async -> Playlist {
        let lines = String(decoding: r.body, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var p = Playlist()
        p.master = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }
        let target = "#EXT-X-TARGETDURATION:"
        p.target = lines.first { $0.hasPrefix(target) }.flatMap { Double($0.dropFirst(target.count)) } ?? 0
        guard !p.master else { return p }
        let segments = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        p.segments = segments.count
        if let first = segments.first, let url = URL(string: first, relativeTo: r.response?.url) {
            let segment = await read(url.absoluteURL, agent: agent, cap: cap)
            p.segmentFirstData = ms(segment.metrics?.transactionMetrics.first?.fetchStartDate ?? segment.started, segment.firstByte)
        }
        return p
    }

    static func account(_ login: Login) async -> String {
        guard let url = login.api() else { return "PROBE account error=other" }
        let r = await read(url, agent: agent(.app), cap: 30, keep: 1 << 20)
        let http = r.response?.statusCode ?? 0
        guard http == 200, let root = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let info = root["user_info"] as? [String: Any]
        else {
            let headers = r.response != nil || r.metrics?.transactionMetrics.last?.responseStartDate != nil
            return "PROBE account http=\(http) error=\(failure(r, headers: headers).rawValue)"
        }
        func number(_ any: Any?) -> Int? {
            if let n = any as? NSNumber { return n.intValue }
            return (any as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard number(info["auth"]) == 1 else { return "PROBE account auth=no" }
        // Xtream panels say 0 for no limit.
        let max = number(info["max_connections"]).map { $0 == 0 ? "unlimited" : $0 == 1 ? "one" : $0 > 1 ? "many" : "unknown" } ?? "unknown"
        let active = number(info["active_cons"]).map { $0 == 0 ? "0" : $0 > 0 ? ">0" : "unknown" } ?? "unknown"
        let formats = info["allowed_output_formats"] as? [String]
        let allows = { (format: String) in formats.map { yes($0.contains(format)) } ?? "unknown" }
        let status = (info["status"] as? String)?.lowercased() == "active" ? "active" : "other"
        let expires = number(info["exp_date"]).map { String(Int(floor((Double($0) - Date().timeIntervalSince1970) / 86400))) } ?? "none"
        return "PROBE account max_conn=\(max) active=\(active) ts=\(allows("ts")) m3u8=\(allows("m3u8")) status=\(status) expires_days=\(expires)"
    }

    /// `mpv`: what the app's player sends the stream server. The app sets no
    /// user agent, so it is libmpv's default, its version string; this one
    /// is in MPVKit 1.0.0's Libmpv (apple/mpvkit.lock), iPhone, Apple TV and
    /// simulator slices alike. OPENIPTV_PROBE_MPV_UA replaces it. `app`: what
    /// the app sends its API calls (Flex.swift), with the version run.sh
    /// compiles in.
    static let libmpvAgent = "mpv v0.41.0-dirty"
    static var agents: [Agent: String] = [:]
    static func agent(_ ua: Agent) -> String { agents[ua] ?? libmpvAgent }

    static func login(_ env: [String: String]) async -> Login? {
        if let holder = env["OPENIPTV_SMOKE_FEED"].flatMap(URL.init(string:)) { return await loginFromHolder(holder) }
        return loginFromEnvironment(env)
    }

    static func loginFromHolder(_ holder: URL) async -> Login? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: holder), (response as? HTTPURLResponse)?.statusCode == 200,
              let source = try? JSONDecoder().decode(IPTVSource.self, from: data),
              case let .xtream(server, username, password) = source.kind else { return nil }
        return Login(server: server, username: username, password: password)
    }

    static func loginFromEnvironment(_ env: [String: String]) -> Login? {
        guard let server = env["OPENIPTV_XTREAM_URL"].flatMap({ XtreamProvider.parse($0)?.server }),
              let username = env["OPENIPTV_XTREAM_USER"], let password = env["OPENIPTV_XTREAM_PASS"] else { return nil }
        return Login(server: server, username: username, password: password)
    }

    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted.isEmpty ? -1 : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }

    static func summary(_ opens: [Open]) {
        var keys: [String] = []
        var groups: [String: [Open]] = [:]
        for o in opens {
            let key = "tok=\(o.tok) ext=\(o.ext.rawValue) ua=\(o.ua.rawValue)"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(o)
        }
        for key in keys {
            let group = groups[key]!
            let flowing = group.filter { $0.bytes > 0 }
            let first = flowing.map(\.firstData), rate = flowing.map(\.rateKbps).filter { $0 >= 0 }
            var line = "PROBE summary \(key) opens=\(group.count) with_data=\(flowing.count)"
                + " ended_early=\(group.filter(\.endedEarly).count)"
                + " first_data_med=\(median(first)) first_data_min=\(first.min() ?? -1) first_data_max=\(first.max() ?? -1)"
                + " rate_kbps_med=\(median(rate)) rate_kbps_min=\(rate.min() ?? -1) rate_kbps_max=\(rate.max() ?? -1)"
            for (status, count) in Dictionary(grouping: group, by: \.status).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
                line += " status_\(status)=\(count)"
            }
            for (error, count) in Dictionary(grouping: group, by: \.error.rawValue).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
                line += " error_\(error)=\(count)"
            }
            say(line)
        }
    }

    static func run(_ env: [String: String]) async -> Int32 {
        func value(_ key: String) -> String? { envValue(key, env) }
        if value("OPENIPTV_PROBE_SELFTEST") == "1" { return selfTest() }
        func isId(_ s: Substring) -> Bool { (1...12).contains(s.count) && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }
        func ids(_ s: Substring) -> [String]? {
            let list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces)[...] }
            return list.allSatisfy(isId) ? list.map(String.init) : nil
        }
        func number(_ key: String, _ fallback: Double) -> Double? { value(key).map { Double($0) } ?? fallback }
        guard let channels = ids((value("OPENIPTV_PROBE_IDS") ?? "")[...]) else { say("PROBE config bad_ids"); return 1 }
        guard let rounds = number("OPENIPTV_PROBE_ROUNDS", 3).flatMap({ Int(exactly: $0) }), let seconds = number("OPENIPTV_PROBE_SECONDS", 20),
              let gap = number("OPENIPTV_PROBE_GAP", 3), let roundGap = number("OPENIPTV_PROBE_ROUND_GAP", 600),
              let pauseEvery = number("OPENIPTV_PROBE_PAUSE_EVERY", 10).flatMap({ Int(exactly: $0) }), pauseEvery > 0,
              let pauseSeconds = number("OPENIPTV_PROBE_PAUSE_SECONDS", 300)
        else { say("PROBE config bad_number"); return 1 }
        guard let exts = ["ts": [Ext.ts], "m3u8": [.m3u8], "both": [.ts, .m3u8]][value("OPENIPTV_PROBE_EXT") ?? "ts"],
              let uas = ["mpv": [Agent.mpv], "app": [.app], "both": [.mpv, .app]][value("OPENIPTV_PROBE_UA") ?? "mpv"]
        else { say("PROBE config bad_ext_or_ua"); return 1 }
        let mpvAgent = value("OPENIPTV_PROBE_MPV_UA")
        var sustained: [(String, Double)] = []
        for spec in (value("OPENIPTV_PROBE_SUSTAIN") ?? "").split(separator: ",") {
            let parts = spec.split(separator: ":")
            guard parts.count == 2, isId(parts[0]), let length = Double(parts[1]) else { say("PROBE config bad_sustain"); return 1 }
            sustained.append((String(parts[0]), length))
        }
        var pair: (a: String, b: String, delays: [Double])?
        if let spec = value("OPENIPTV_PROBE_PAIR") {
            let parts = spec.split(separator: ",")
            let delays = parts.dropFirst(2).compactMap { Double($0) }
            guard parts.count >= 3, isId(parts[0]), isId(parts[1]), delays.count == parts.count - 2 else {
                say("PROBE config bad_pair"); return 1
            }
            pair = (String(parts[0]), String(parts[1]), delays.sorted())
        }
        guard let login = await login(env) else { say("PROBE config no_login"); return 1 }
        agents = [.mpv: mpvAgent ?? libmpvAgent, .app: "Openreel/\(appVersion)"]
        say("PROBE start login=\(value("OPENIPTV_SMOKE_FEED") == nil ? "env" : "holder") mpv_ua=\(mpvAgent == nil ? "vendored" : "given")"
            + " seconds=\(fixed(seconds, 1)) gap=\(fixed(gap, 1)) rounds=\(rounds) round_gap=\(fixed(roundGap, 1))"
            + " pause_every=\(pauseEvery) pause_seconds=\(fixed(pauseSeconds, 1))")

        var started = false
        var sincePause = 0
        func pace(_ upcoming: Int, wait: Double, reason: String? = nil) async {
            defer { started = true }
            guard started else { return }
            var seconds = wait
            if requests - sincePause + upcoming > pauseEvery, wait < pauseSeconds {
                seconds = pauseSeconds
                say("PROBE wait seconds=\(fixed(seconds, 1)) reason=pause after=\(requests - sincePause)")
            } else if let reason {
                say("PROBE wait seconds=\(fixed(seconds, 1)) reason=\(reason)")
            }
            try? await Task.sleep(for: .seconds(seconds))
            if seconds >= pauseSeconds { sincePause = requests }
        }
        var opens: [Open] = []
        if !channels.isEmpty {
            say("PROBE block rounds")
            for round in 1...max(1, rounds) {
                for (n, id) in channels.enumerated() {
                    for (m, ext) in exts.enumerated() {
                        for (k, ua) in uas.enumerated() {
                            let next = round > 1 && n == 0 && m == 0 && k == 0
                            await pace(ext == .m3u8 ? 2 : 1, wait: next ? roundGap : gap, reason: next ? "round" : nil)
                            let o = await open(login, id: id, ext: ext, ua: ua, round: round, cap: seconds)
                            say(o.line)
                            opens.append(o)
                        }
                    }
                }
            }
        }
        if !sustained.isEmpty { say("PROBE block sustain") }
        for (id, length) in sustained {
            await pace(1, wait: gap)
            say(await open(login, id: id, ext: .ts, ua: uas[0], round: 0, cap: length).line)
        }
        if let pair {
            say("PROBE block pair")
            await pace(1 + pair.delays.count, wait: gap)
            let a = await open(login, id: pair.a, ext: .ts, ua: uas[0], round: 0, cap: 10)
            say(a.line)
            let closed = Date()
            for delay in pair.delays {
                try? await Task.sleep(for: .seconds(max(0, delay - Date().timeIntervalSince(closed))))
                let b = await open(login, id: pair.b, ext: .ts, ua: uas[0], round: 0, cap: seconds)
                say(b.line)
                say("PROBE pair delay=\(fixed(delay, 1)) a_status=\(a.status) b_status=\(b.status) b_bytes=\(b.bytes) b_first_data=\(b.firstData)")
                if b.bytes > 0 { break }
            }
        }
        if value("OPENIPTV_PROBE_ACCOUNT") == "1" {
            await pace(1, wait: gap)
            say(await account(login))
        }
        summary(opens)
        say("PROBE done opens=\(opens.count) requests=\(requests) refused_lines=\(refusedLines)")
        return refusedLines == 0 ? 0 : 2
    }

    static func selfTest() -> Int32 {
        let leaks = ["PROBE x=http://10.0.0.1", "PROBE a/b", "PROBE user@example", "PROBE x://y", "PROBE host=provider.example",
                     "PROBE ip=192.168.1.20", "PROBE port=host:8080", "PROBE ::1", "PROBE v=61.7.100",
                     "PROBE host=cdn1.example", "PROBE s2.host7.tv", "PROBE edge-3.example9", "PROBE x=1.example",
                     "PROBE tok=" + String(repeating: "a", count: 33), "PROBE name=Café", "PROBE tab\there", "PROBE newline\nhere",
                     "OPENIPTV_PROBE_IDS=1,abc", "OPENIPTV_PROBE_IDS=1,2 x", "OPENIPTV_PROBE_IDS=1;2", "OPENIPTV_PROBE_IDS=1,host.example",
                     "OPENIPTV_PROBE_IDS=1,1234567890123", "OPENIPTV_PROBE_IDS=" + (1...21).map(String.init).joined(separator: ","),
                     "OPENIPTV_PROBE_IDS=1,2\nhttp://x", "OPENIPTV_PROBE_IDS=1,2\n", "X OPENIPTV_PROBE_IDS=1,2", "OPENIPTV_PROBE_IDS=1,,2"]
        var open = Open(tok: "2001", ext: .m3u8, ua: .app, round: 3)
        (open.status, open.headers, open.hops, open.redirectMs, open.crossHost, open.ttfb, open.firstData) = (403, true, 1, 120, true, 3012, -1)
        (open.gapMax, open.stoppedAt, open.error) = (5.04, 20.3, .no_data)
        open.playlist = Playlist(master: false, segments: 5, target: 6, segmentFirstData: 52)
        let lines = [open.line, "PROBE account max_conn=unlimited active=>0 ts=no m3u8=yes status=active expires_days=-3",
                     "PROBE summary tok=123456789012 ext=ts ua=mpv opens=3 with_data=2 ended_early=1 first_data_med=310 error_redirect_loop=1",
                     "PROBE pair delay=1.0 a_status=200 b_status=403 b_bytes=0 b_first_data=-1",
                     "PROBE wait seconds=300.0 reason=pause after=10", "PROBE done opens=3 requests=4 refused_lines=0",
                     "PICK live=6 twins=2 always=4 requests=2", "OPENIPTV_PROBE_IDS=3011,3031,123456789012", "OPENIPTV_PROBE_IDS=",
                     "OPENIPTV_PROBE_IDS=" + (1...20).map(String.init).joined(separator: ",")]
        var wrong = leaks.filter(holdsNoAddress).count + lines.filter { !holdsNoAddress($0) }.count
        let before = refusedLines
        say("PROBE leak=a/b")
        if refusedLines != before + 1 { wrong += 1 }
        refusedLines = before
        say("PROBE selftest cases=\(leaks.count + lines.count + 1) wrong=\(wrong)")
        return wrong == 0 ? 0 : 1
    }
}
