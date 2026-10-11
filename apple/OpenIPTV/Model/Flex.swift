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
    case network(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .rejected: "The login was rejected. Check the details and try again."
        case let .http(code): "The server answered with an error (HTTP \(code))."
        case let .network(message): message
        case let .unexpected(message): message
        }
    }

    /// Wraps any error without leaking the URL it may contain.
    static func wrap(_ error: Error) -> SourceError {
        if let error = error as? SourceError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return .network("No internet connection.")
            case .timedOut: return .network("The server took too long to answer.")
            case .cannotFindHost, .dnsLookupFailed: return .network("That server address couldn't be found.")
            case .cannotConnectToHost: return .network("Couldn't connect to the server.")
            case .secureConnectionFailed, .serverCertificateUntrusted: return .network("The server's secure connection failed.")
            default: return .network("Network error (\(error.code.rawValue)).")
            }
        }
        if error is DecodingError { return .unexpected("The server's answer wasn't in the expected format.") }
        return .unexpected("Something went wrong.")
    }
}

/// Shared HTTP plumbing: no cookies, no URL caching of API answers, and
/// status codes mapped to `SourceError`.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Openreel/\(appVersion)"]
        return URLSession(configuration: config)
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func data(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw SourceError.rejected }
            guard (200..<300).contains(code) else { throw SourceError.http(code) }
            return data
        } catch {
            throw SourceError.wrap(error)
        }
    }

    static func data(_ url: URL) async throws -> Data {
        try await data(URLRequest(url: url))
    }
}
