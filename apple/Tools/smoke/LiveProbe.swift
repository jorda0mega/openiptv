import Foundation

/// `OPENIPTV_SMOKE_MODE=live-probe`: how a provider's live streams answer
/// from this Mac, for the Live TV start and stall measurements
/// (.audit/live-perf/fable-plan.md §4.2). Channels by stream id only
/// (OPENIPTV_PROBE_IDS), one stream at a time; nothing else is asked for
/// but the account, when OPENIPTV_PROBE_ACCOUNT=1.
///
/// The login comes from the holder's address (OPENIPTV_SMOKE_FEED, as the
/// app's debug sign-in fetches it) or from OPENIPTV_XTREAM_URL, _USER and
/// _PASS. Every line goes out through `say`: numbers, fixed words and the
/// stream id only, never an address, host, header, login or error text.
enum LiveProbe {
    enum Ext: String { case ts, m3u8 }
    enum Agent: String { case mpv, app }
    enum Failure: String { case none, dns, refused, reset, timeout, tls, cancelled, redirect_loop, other }

    struct Login {
        let server: URL
        let username: String
        let password: String

        func stream(_ id: String, _ ext: Ext) -> URL {
            var url = server
            for segment in ["live", username, password, "\(id).\(ext.rawValue)"] { url.append(path: segment) }
            return url
        }
    }

    /// One stream open, as printed.
    struct Open {
        var tok = "", ext = Ext.ts, ua = Agent.mpv, round = 0
        var status = 0, hops = 0, crossHost = false
        var dns = 0, connect = 0, tls = 0, ttfb = -1, firstData = -1
        var rateKbps = 0, gapMax = 0.0, gaps1s = 0, stoppedAt = 0.0, bytes = 0
        var ctype = "other", error = Failure.none
        /// How the body is delimited: length, chunked or close (none: no
        /// answer). URLSession takes a reset of a close-delimited body for
        /// its end, so there `error=none` before the cap is an end or a reset.
        var framing = "none"
        var playlist: Playlist?

        var line: String {
            var line = "PROBE open tok=\(tok) ext=\(ext.rawValue) ua=\(ua.rawValue) round=\(round) status=\(status) hops=\(hops)"
                + " cross_host=\(yes(crossHost)) dns=\(dns) connect=\(connect) tls=\(tls) ttfb=\(ttfb) first_data=\(firstData)"
                + " rate_kbps=\(rateKbps) gap_max=\(fixed(gapMax, 2)) gaps_1s=\(gaps1s) stopped_at=\(fixed(stoppedAt, 1))"
                + " bytes=\(bytes) ctype=\(ctype) framing=\(framing) error=\(error.rawValue)"
            if let p = playlist {
                line += " master=\(yes(p.master)) segments=\(p.segments) target=\(fixed(p.target, 1)) seg_first_data=\(p.segmentFirstData)"
            }
            return line
        }
    }

    struct Playlist {
        var master = false, segments = 0, target = 0.0, segmentFirstData = -1
    }

    // MARK: Output

    static var refusedLines = 0

    /// Lines that could carry an address, host, login or free text are
    /// refused: any character outside letters, digits, space and `_=.>-`
    /// (so no `/`, `:`, `@`), a dot anywhere but in a decimal number after
    /// `=` (so no host name or IP address), or a word over 32 characters.
    static func safe(_ line: String) -> Bool {
        let alphabet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=.>- ")
        guard line.unicodeScalars.allSatisfy(alphabet.contains) else { return false }
        return line.split(separator: " ").allSatisfy { word in
            word.count <= 32 && (!word.contains(".") || word.range(of: "^[a-z0-9_]+=-?[0-9]+[.][0-9]+$", options: .regularExpression) != nil)
        }
    }

    static func say(_ line: String) {
        if safe(line) {
            print(line)
        } else {
            refusedLines += 1
            print("PROBE line_refused")
        }
    }

    static func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
    static func fixed(_ x: Double, _ places: Int) -> String { String(format: "%.\(places)f", x) }

    // MARK: Reading a stream

    /// One request read for at most `cap` seconds: when each piece of the
    /// body came, the answer and the timings. Its callbacks and the cap run
    /// on one serial queue.
    final class Reader: NSObject, URLSessionDataDelegate {
        let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        let keepBody: Bool
        var started = Date()
        var redirects = 0
        var response: HTTPURLResponse?
        var metrics: URLSessionTaskMetrics?
        var firstByte: Date?, lastByte: Date?
        var bytes = 0, gapMax = 0.0, gaps1s = 0
        var body = Data()
        var capped: Date?, finished: Date?
        var error: Error?
        var done: (() -> Void)?

        init(keepBody: Bool) { self.keepBody = keepBody }

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
            bytes += data.count
            if keepBody, body.count < 1 << 20 { body.append(data) }
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

    static func read(_ url: URL, agent: String, cap: Double, keepBody: Bool = false) async -> Reader {
        requests += 1
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 1
        let reader = Reader(keepBody: keepBody)
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

    static func failure(_ r: Reader) -> Failure {
        if r.capped != nil { return r.response == nil ? .timeout : .none }
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

    static func ms(_ from: Date, _ to: Date?) -> Int { to.map { Int(($0.timeIntervalSince(from) * 1000).rounded()) } ?? -1 }
    static func span(_ start: Date?, _ end: Date?) -> Int {
        guard let start, let end else { return 0 }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func open(_ login: Login, id: String, ext: Ext, ua: Agent, round: Int, cap: Double) async -> Open {
        let r = await read(login.stream(id, ext), agent: agent(ua), cap: cap, keepBody: ext == .m3u8)
        let hops = r.metrics?.transactionMetrics ?? []
        let origin = hops.first?.fetchStartDate ?? r.started
        var o = Open(tok: id, ext: ext, ua: ua, round: round)
        o.status = r.response?.statusCode ?? 0
        o.hops = hops.isEmpty ? r.redirects : hops.count - 1
        let firstHost = hops.first?.request.url?.host() ?? login.server.host()
        let lastHost = hops.last?.request.url?.host() ?? r.response?.url?.host()
        o.crossHost = lastHost != nil && firstHost != lastHost
        if let last = hops.last {
            o.dns = span(last.domainLookupStartDate, last.domainLookupEndDate)
            o.connect = span(last.connectStartDate, last.connectEndDate)
            o.tls = span(last.secureConnectionStartDate, last.secureConnectionEndDate)
            o.ttfb = ms(origin, last.responseStartDate)
        }
        o.firstData = ms(origin, r.firstByte)
        if let first = r.firstByte, r.stopped.timeIntervalSince(first) > 0.05 {
            o.rateKbps = Int(Double(r.bytes) * 8 / 1000 / r.stopped.timeIntervalSince(first))
        }
        o.gapMax = r.gapMax
        o.gaps1s = r.gaps1s
        o.stoppedAt = r.stopped.timeIntervalSince(origin)
        o.bytes = r.bytes
        let mime = r.response?.mimeType?.lowercased() ?? ""
        o.ctype = mime == "video/mp2t" ? "mp2t" : mime.hasSuffix("mpegurl") ? "mpegurl" : "other"
        if let response = r.response {
            // URLSession hides Transfer-Encoding; chunks show as more bytes
            // on the wire than it hands over.
            let wire = hops.last.map { $0.countOfResponseBodyBytesReceived > $0.countOfResponseBodyBytesAfterDecoding } ?? false
            o.framing = response.value(forHTTPHeaderField: "Content-Length") != nil ? "length" : wire ? "chunked" : "close"
        }
        o.error = failure(r)
        if ext == .m3u8, o.status == 200 {
            o.playlist = await playlist(r, agent: agent(ua), cap: cap)
        }
        return o
    }

    /// The playlist's segments and target duration, and how long its first
    /// segment takes to start (one more request). A master playlist is only
    /// marked: its variants are not asked for.
    static func playlist(_ r: Reader, agent: String, cap: Double) async -> Playlist {
        let lines = String(decoding: r.body, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var p = Playlist()
        p.master = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }
        let target = "#EXT-X-TARGETDURATION:"
        p.target = lines.first { $0.hasPrefix(target) }.flatMap { Double($0.dropFirst(target.count)) } ?? 0
        let segments = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !p.master else { return p }
        p.segments = segments.count
        if let first = segments.first, let url = URL(string: first, relativeTo: r.response?.url) {
            let segment = await read(url.absoluteURL, agent: agent, cap: cap)
            p.segmentFirstData = ms(segment.metrics?.transactionMetrics.first?.fetchStartDate ?? segment.started, segment.firstByte)
        }
        return p
    }

    // MARK: Account

    /// One player_api.php call, printed as categories only.
    static func account(_ login: Login) async -> String {
        var parts = URLComponents(url: login.server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [.init(name: "username", value: login.username), .init(name: "password", value: login.password)]
        guard let url = parts?.url else { return "PROBE account error=other" }
        let r = await read(url, agent: agent(.app), cap: 30, keepBody: true)
        let http = r.response?.statusCode ?? 0
        guard http == 200, let root = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let info = root["user_info"] as? [String: Any]
        else { return "PROBE account http=\(http) error=\(failure(r).rawValue)" }
        func number(_ any: Any?) -> Int? {
            if let n = any as? NSNumber { return n.intValue }
            return (any as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard number(info["auth"]) == 1 else { return "PROBE account auth=no" }
        let max = number(info["max_connections"]).map { $0 == 1 ? "one" : $0 > 1 ? "many" : "unknown" } ?? "unknown"
        let active = number(info["active_cons"]).map { $0 == 0 ? "0" : $0 > 0 ? ">0" : "unknown" } ?? "unknown"
        let formats = info["allowed_output_formats"] as? [String]
        let allows = { (format: String) in formats.map { yes($0.contains(format)) } ?? "unknown" }
        let status = (info["status"] as? String)?.lowercased() == "active" ? "active" : "other"
        let expires = number(info["exp_date"]).map { String(Int(floor((Double($0) - Date().timeIntervalSince1970) / 86400))) } ?? "none"
        return "PROBE account max_conn=\(max) active=\(active) ts=\(allows("ts")) m3u8=\(allows("m3u8")) status=\(status) expires_days=\(expires)"
    }

    // MARK: Run

    /// `mpv`: what the app's player sends the stream server, libmpv's own
    /// user agent (the app sets none), exact only from OPENIPTV_PROBE_MPV_UA;
    /// else a guess. `app`: what the app sends its API calls (Flex.swift),
    /// with the version run.sh compiles in.
    static var agents: [Agent: String] = [:]
    static func agent(_ ua: Agent) -> String { agents[ua] ?? "mpv" }

    static func login(_ env: [String: String]) async -> Login? {
        if let holder = env["OPENIPTV_SMOKE_FEED"].flatMap(URL.init(string:)) {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            guard let (data, response) = try? await session.data(from: holder), (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = try? JSONDecoder().decode(IPTVSource.self, from: data),
                  case let .xtream(server, username, password) = source.kind else { return nil }
            return Login(server: server, username: username, password: password)
        }
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
            let first = flowing.map(\.firstData), rate = flowing.map(\.rateKbps)
            var line = "PROBE summary \(key) opens=\(group.count) with_data=\(flowing.count)"
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
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        if value("OPENIPTV_PROBE_SELFTEST") == "1" { return selfTest() }
        func isId(_ s: Substring) -> Bool { (1...12).contains(s.count) && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }
        func ids(_ s: Substring) -> [String]? {
            let list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces)[...] }
            return list.allSatisfy(isId) ? list.map(String.init) : nil
        }
        guard let channels = ids((value("OPENIPTV_PROBE_IDS") ?? "")[...]) else { say("PROBE config bad_ids"); return 1 }
        let rounds = Int(value("OPENIPTV_PROBE_ROUNDS") ?? "3") ?? 3
        let seconds = Double(value("OPENIPTV_PROBE_SECONDS") ?? "10") ?? 10
        let gap = Double(value("OPENIPTV_PROBE_GAP") ?? "3") ?? 3
        guard let exts = ["ts": [Ext.ts], "m3u8": [.m3u8], "both": [.ts, .m3u8]][value("OPENIPTV_PROBE_EXT") ?? "ts"],
              let uas = ["mpv": [Agent.mpv], "app": [.app], "both": [.mpv, .app]][value("OPENIPTV_PROBE_UA") ?? "mpv"]
        else { say("PROBE config bad_ext_or_ua"); return 1 }
        let mpvAgent = value("OPENIPTV_PROBE_MPV_UA")
        // Comparing user agents against a guessed one spends requests on an
        // answer that can't be read.
        guard mpvAgent != nil || uas.count == 1 else { say("PROBE config mpv_ua_unknown"); return 1 }
        // "<id>:<seconds>[,<id>:<seconds>…]"
        var sustained: [(String, Double)] = []
        for spec in (value("OPENIPTV_PROBE_SUSTAIN") ?? "").split(separator: ",") {
            let parts = spec.split(separator: ":")
            guard parts.count == 2, isId(parts[0]), let length = Double(parts[1]) else { say("PROBE config bad_sustain"); return 1 }
            sustained.append((String(parts[0]), length))
        }
        // "<idA>,<idB>,<delay s>[,<delay s>…]": B after each delay from A's
        // close, until B plays.
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
        agents = [.mpv: mpvAgent ?? "mpv", .app: "Openreel/\(appVersion)"]

        var opened = false
        func pace() async {
            if opened { try? await Task.sleep(for: .seconds(gap)) }
            opened = true
        }
        var opens: [Open] = []
        if !channels.isEmpty {
            say("PROBE block rounds")
            for round in 1...max(1, rounds) {
                for id in channels {
                    for ext in exts {
                        for ua in uas {
                            await pace()
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
            await pace()
            say(await open(login, id: id, ext: exts[0], ua: uas[0], round: 0, cap: length).line)
        }
        if let pair {
            say("PROBE block pair")
            await pace()
            let a = await open(login, id: pair.a, ext: .ts, ua: uas[0], round: 0, cap: 10)
            say(a.line)
            let closed = Date()
            for delay in pair.delays {
                try? await Task.sleep(for: .seconds(max(0, delay - Date().timeIntervalSince(closed))))
                let b = await open(login, id: pair.b, ext: .ts, ua: uas[0], round: 0, cap: seconds)
                say(b.line)
                say("PROBE pair delay=\(fixed(delay, 1)) a_status=\(a.status) b_status=\(b.status) b_first_data=\(b.firstData)")
                if b.status == 200 { break }
            }
        }
        if value("OPENIPTV_PROBE_ACCOUNT") == "1" {
            await pace()
            say(await account(login))
        }
        summary(opens)
        say("PROBE done opens=\(opens.count) requests=\(requests) refused_lines=\(refusedLines)")
        return refusedLines == 0 ? 0 : 2
    }

    // MARK: Self-test

    /// OPENIPTV_PROBE_SELFTEST=1: `say` refuses what could leak and lets the
    /// probe's own lines through. No network.
    static func selfTest() -> Int32 {
        let leaks = ["PROBE x=http://10.0.0.1", "PROBE a/b", "PROBE user@example", "PROBE x://y", "PROBE host=provider.example",
                     "PROBE ip=192.168.1.20", "PROBE port=host:8080", "PROBE ::1", "PROBE v=61.7.100",
                     "PROBE host=cdn1.example", "PROBE s2.host7.tv", "PROBE edge-3.example9", "PROBE x=1.example",
                     "PROBE tok=" + String(repeating: "a", count: 33), "PROBE name=Café", "PROBE tab\there", "PROBE newline\nhere"]
        var open = Open(tok: "2001", ext: .m3u8, ua: .app, round: 3)
        (open.status, open.hops, open.crossHost, open.ttfb, open.firstData, open.gapMax, open.stoppedAt) = (403, 1, true, 3012, -1, 5.04, 20.3)
        open.playlist = Playlist(master: false, segments: 5, target: 6, segmentFirstData: 52)
        let lines = [open.line, "PROBE account max_conn=one active=>0 ts=no m3u8=yes status=active expires_days=-3",
                     "PROBE summary tok=123456789012 ext=ts ua=mpv opens=3 with_data=2 first_data_med=310 error_redirect_loop=1",
                     "PROBE pair delay=1.0 a_status=200 b_status=403 b_first_data=-1", "PROBE done opens=3 requests=4 refused_lines=0"]
        var wrong = leaks.filter(safe).count + lines.filter { !safe($0) }.count
        let before = refusedLines
        say("PROBE leak=a/b")
        if refusedLines != before + 1 { wrong += 1 }
        refusedLines = before
        say("PROBE selftest cases=\(leaks.count + lines.count + 1) wrong=\(wrong)")
        return wrong == 0 ? 0 : 1
    }
}
