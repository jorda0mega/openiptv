import Foundation

enum Outbound {
    enum Build: Sendable { case debug, release }

    static let debugDSNKey = "OPENREEL_DEBUG_SENTRY_DSN"
    static let plistDSNKey = "SentryDSN"

    static func dsn(_ build: Build, environment: [String: String], info: [String: Any]) -> String? {
        environment[debugDSNKey] ?? info[plistDSNKey] as? String
    }

    static func metricAttributes(name: String, _ attributes: [String: String]) -> [String: String]? {
        attributes
    }

    static func contexts(_ contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        contexts
    }

    static func installID(_ id: String?) -> String? {
        id
    }

    static func stillHoldsAddress(_ serialized: String) -> Bool {
        false
    }
}
