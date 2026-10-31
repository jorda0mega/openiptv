import Foundation

/// IPTV panels disagree on whether a number is a number, a numeric string,
/// an empty string, `false` or `null`. These decoders accept all of them so
/// one odd row never fails a whole channel list.
extension KeyedDecodingContainer {
    func flexInt(_ key: Key) -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespaces)
            return Int64(t) ?? Double(t).map { Int64($0) }
        }
        return nil
    }

    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        }
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }

    func flexBool(_ key: Key) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes", "active"].contains(s.lowercased().trimmingCharacters(in: .whitespaces))
        }
        return false
    }
}

/// Decodes `T` or nothing, so arrays can skip malformed rows.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension JSONDecoder {
    /// A list where rows that don't decode are dropped. Panels return `[]`,
    /// `{}`, `false` or `null` for "nothing"; all become an empty list.
    func lenientList<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        if let rows = try? decode([Lenient<T>].self, from: data) {
            return rows.compactMap(\.value)
        }
        if let map = try? decode([String: Lenient<T>].self, from: data) {
            return map.values.compactMap(\.value)
        }
        return []
    }
}

/// Errors shown to the user. Messages never include URLs, because IPTV URLs
/// carry usernames and passwords.
enum SourceError: LocalizedError {
    case rejected
    case http(Int)
    /// No connection: the request never reached the server.
    case offline
    /// The app itself stopped the request (its task cancelled): nothing
    /// the server did.
    case cancelled
    case network(String, URLError.Code? = nil)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .rejected: "The login was rejected. Check the details and try again."
        case .http(429): "Your provider is busy right now (too many requests)."
        case let .http(code): "The server answered with an error (HTTP \(code))."
        case .offline: "No internet connection."
        case .cancelled: "The request was stopped."
        case let .network(message, _): message
        case let .unexpected(message): message
        }
    }

    /// Wraps any error without leaking the URL it may contain.
    static func wrap(_ error: Error) -> SourceError {
        if let error = error as? SourceError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return .offline
            case .cancelled: return .cancelled
            case .timedOut: return .network("The server took too long to answer.", error.code)
            case .cannotFindHost, .dnsLookupFailed: return .network("That server address couldn't be found.", error.code)
            case .cannotConnectToHost: return .network("Couldn't connect to the server.", error.code)
            case .secureConnectionFailed, .serverCertificateUntrusted: return .network("The server's secure connection failed.", error.code)
            default: return .network("Network error (\(error.code.rawValue)).", error.code)
            }
        }
        if error is DecodingError { return .unexpected("The server's answer wasn't in the expected format.") }
        return .unexpected("Something went wrong.")
    }
}

/// Shared HTTP plumbing: no cookies, no URL caching of API answers, and
/// status codes mapped to `SourceError`.
///
/// Two sets of connections: what's on screen or asked for, and what's
/// fetched ahead of time (tasks at utility priority or lower: pages,
/// playback info and stills got ready in case they're opened). A burst of
/// the second used to fill every connection to a slow server, and a search
/// typed meanwhile waited three seconds behind it.
enum HTTP {
    static let session = make(connections: 8)
    static let ahead = make(connections: 4)
    static let turns = ServerTurns(atOnce: 4)
    /// Emby converts a stretch of the film's sound for each answer.
    static let patient = make(connections: 2, wait: 300)
    /// Emby reads the whole film to take out one of its subtitle tracks
    /// (over a minute for Asterix the Gaul).
    static let extraction = make(connections: 2, wait: 300)

    private static func make(connections: Int, wait: TimeInterval = 20) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = wait
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Zapline/\(appVersion)"]
        config.httpMaximumConnectionsPerHost = connections
        #if DEBUG
        throughDebugProxy(config)
        config.httpAdditionalHeaders?["X-Openreel-Launch"] = launch
        asOnHTTP2(config)
        #endif
        return URLSession(configuration: config)
    }

    #if DEBUG
    /// This launch, for the test server's request log (GET /mock/requests).
    private static let launch = UUID().uuidString

    /// UI tests: `-connectionsAsOnHTTP2 YES` sends every request at once, as HTTP/2 does over one connection;
    /// the test server speaks HTTP/1.1, where the connections per server cap the requests under way.
    static func asOnHTTP2(_ config: URLSessionConfiguration) {
        if UserDefaults.standard.bool(forKey: "connectionsAsOnHTTP2") { config.httpMaximumConnectionsPerHost = 100 }
    }
    #endif

    #if DEBUG
    /// UI tests (OPENREEL_DEBUG_PROXY=127.0.0.1:8859): the throttling proxy
    /// (scripts/throttle_proxy.py) every request to a server goes through,
    /// a slow network on purpose. HTTPS goes through it as a tunnel.
    static func debugProxy(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> (host: String, port: Int)? {
        guard let address = environment["OPENREEL_DEBUG_PROXY"], let colon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: colon)...]) else { return nil }
        return (String(address[..<colon]), port)
    }

    static func throughDebugProxy(_ config: URLSessionConfiguration,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let (host, port) = debugProxy(environment) else { return }
        config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        if plainThroughDebugProxy(environment) {
            config.connectionProxyDictionary?.merge(["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port]) { $1 }
        }
    }

    /// Plain HTTP carries the key in clear: through the proxy only for the
    /// test server (OPENREEL_DEBUG_PROXY_PLAIN=1), a real server's only as a
    /// TLS tunnel.
    static func plainThroughDebugProxy(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["OPENREEL_DEBUG_PROXY_PLAIN"] == "1"
    }
    #endif

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The build: when it was made, to the minute ("202610151425"), set by
    /// the TestFlight upload. One version has many builds.
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// "0.2.0 (202610151425)", as TestFlight lists a build.
    static var appVersionAndBuild: String { "\(appVersion) (\(appBuild))" }

    /// When the build was made, in words ("Oct 15, 2026 at 2:25 PM");
    /// nil for a build number that isn't a time (a local build's "1").
    static var appBuildDate: String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMddHHmm"
        guard appBuild.count == 12, let date = parser.date(from: appBuild) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The system logs the address of a request that fails or is stopped,
    /// key and all.
    static func keyInHeader(_ request: URLRequest) -> URLRequest {
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fields = parts.queryItems, fields.contains(where: isKey) else { return request }
        parts.queryItems = fields.filter { !isKey($0) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        var moved = request
        moved.url = parts.url ?? url
        if let key = fields.first(where: { isKey($0) && $0.value?.isEmpty == false })?.value {
            moved.setValue(key, forHTTPHeaderField: "X-Emby-Token")
        }
        return moved
    }

    private static func isKey(_ field: URLQueryItem) -> Bool { field.name.lowercased() == "api_key" }

    static func form(_ url: URL, _ fields: [URLQueryItem]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(formEncoded($0.name))=\(formEncoded($0.value ?? ""))" }.joined(separator: "&").utf8)
        return request
    }

    static func loginInForm(_ url: URL) -> URLRequest {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fields = parts.queryItems, fields.contains(where: { ["username", "password"].contains($0.name.lowercased()) })
        else { return URLRequest(url: url) }
        parts.queryItems = nil
        return form(parts.url!, fields)
    }

    private static let formSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: formSafe) ?? ""
    }

    /// The address a server redirects to is the server's choice.
    static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard let target = request.url, let original, !sameServer(target, original) else { return keyInHeader(request) }
        var elsewhere = request
        elsewhere.setValue(nil, forHTTPHeaderField: "X-Emby-Token")
        if var parts = URLComponents(url: target, resolvingAgainstBaseURL: false), parts.queryItems != nil {
            parts.queryItems = parts.queryItems?.filter { !isKey($0) }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
            elsewhere.url = parts.url ?? target
        }
        return elsewhere
    }

    static func sameServer(_ a: URL, _ b: URL) -> Bool { server(a) == server(b) }

    private static func server(_ url: URL) -> (scheme: String?, host: String?, port: Int?) {
        let scheme = url.scheme?.lowercased()
        var host = url.host()?.lowercased()
        if host?.hasSuffix(".") == true { host?.removeLast() }
        return (scheme, host, url.port ?? ["http": 80, "https": 443][scheme ?? ""])
    }

    static let keyOutOfRedirects = KeyOutOfRedirects()

    final class KeyOutOfRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            HTTP.redirected(request, from: task.originalRequest?.url)
        }
    }

    static func data(_ request: URLRequest, aheadOn aheadSession: URLSession = ahead) async throws -> Data {
        #if DEBUG
        let measured = PlanClock.current?.sending(request)
        let mark = UUID(), kind = PlanClock.kind(of: request, ahead: Task.currentPriority <= .utility)
        PlanClock.underWay.mutate { $0[mark] = kind }
        defer {
            PlanClock.underWay.mutate { $0[mark] = nil }
            measured?.answered()
        }
        #else
        let measured: (any URLSessionTaskDelegate)? = nil
        #endif
        do {
            // A POST (playback info, progress reports) goes on the main connections.
            let read = (request.httpMethod ?? "GET") == "GET"
            let (data, response) = try await Task.currentPriority <= .utility
                ? fetchAhead(request, measured, on: read ? aheadSession : session) : session.data(for: request, delegate: measured)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw SourceError.rejected }
            guard (200..<300).contains(code) else { throw SourceError.http(code) }
            return data
        } catch {
            throw SourceError.wrap(error)
        }
    }

    /// A request fetched ahead, once it has its turn (ServerTurns). If something on screen starts waiting for it
    /// before then (its task's priority rises: a page opened while it was being prefetched, a tap), it goes at once,
    /// on the main connections.
    private static func fetchAhead(_ request: URLRequest, _ measured: (any URLSessionTaskDelegate)?,
                                   on aheadSession: URLSession) async throws -> (Data, URLResponse) {
        let owner = request.value(forHTTPHeaderField: "X-Emby-Token")?.hashValue
        return try await turns.taking(.current, at: ServerTurns.server(of: request.url), owner: owner) { now in
            try await (now ? session : aheadSession).data(for: request, delegate: measured)
        }
    }

    static func data(_ url: URL) async throws -> Data {
        try await data(URLRequest(url: url))
    }

    static func atOnce(_ request: URLRequest) async throws -> Data {
        try await ServerTurns.atOnce { try await data(request) }
    }
}

/// A value guarded by a lock, for small caches shared across threads.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

#if DEBUG
/// UI tests (-debugServerProbe YES): the server's own state beside each
/// start, read just before the tap on a session of its own (not the app's
/// warm connection, not the throttling proxy). Two tiny reads, the first on
/// a new connection and the second on the same one. Times only.
enum ServerProbe {
    struct Reading: Equatable {
        /// What a new connection adds before its first answer: DNS, TCP and
        /// TLS, and any wait the server puts on a new one.
        let connect: Double
        /// A tiny read's answer on a connection already open.
        let firstByte: Double
        /// The film's own file read for its first byte, then again, on that
        /// connection: a server's disk woken by the first.
        var file: Double?, fileAgain: Double?

        var readout: String {
            let file = film.map { String(format: "server file: first byte %.2f s, again %.2f s | ", $0.first, $0.again) } ?? ""
            return file + String(format: "server: connect %.2f s, first byte %.2f s", connect, firstByte)
        }

        private var film: (first: Double, again: Double)? {
            guard let file, let fileAgain else { return nil }
            return (file, fileAgain)
        }
    }

    /// The key goes in a header, and only to `account`'s server: a redirect isn't followed.
    static func measure(_ account: EmbyAccount, film: String? = nil) async -> Reading? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: EmbyClient.api(account.serverURL, "Users/\(account.userId)"))
        request.setValue(account.accessToken, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 30
        guard let fresh = await answered(request, on: session), let again = await answered(request, on: session) else { return nil }
        var reading = Reading(connect: max(0, fresh - again), firstByte: again)
        if let film {
            var read = URLRequest(url: EmbyClient.api(account.serverURL, "Videos/\(film)/stream")
                .appending(queryItems: [.init(name: "Static", value: "true"), .init(name: "MediaSourceId", value: film)]))
            read.setValue(account.accessToken, forHTTPHeaderField: "X-Emby-Token")
            read.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            read.timeoutInterval = 30
            reading.file = await answered(read, on: session)
            reading.fileAgain = await answered(read, on: session)
        }
        return reading
    }

    private static func answered(_ request: URLRequest, on session: URLSession) async -> Double? {
        let asked = Date()
        guard (try? await session.data(for: request, delegate: Unredirected())) != nil else { return nil }
        return Date().timeIntervalSince(asked)
    }

    private final class Unredirected: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
#endif
