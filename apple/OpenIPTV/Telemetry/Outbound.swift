import Foundation

enum Outbound {
    enum Build: Sendable { case debug, release }

    static let debugDSNKey = "OPENREEL_DEBUG_SENTRY_DSN"
    static let plistDSNKey = "SentryDSN"

    static func dsn(_ build: Build, environment: [String: String], info: [String: Any]) -> String? {
        switch build {
        case .debug:
            guard let dsn = environment[debugDSNKey], let host = URL(string: dsn)?.host(),
                  ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
            return dsn
        case .release:
            guard environment[debugDSNKey] == nil, let dsn = info[plistDSNKey] as? String, let url = URL(string: dsn), url.scheme == "https", url.host() != nil else { return nil }
            return dsn
        }
    }

    static let sdkMetricKeys: Set<String> = [
        "sentry.release", "sentry.environment", "sentry.sdk.name", "sentry.sdk.version",
        "os.name", "os.version", "device.brand", "device.model", "device.family",
    ]

    static func metricAttributes(name: String, _ attributes: [String: String]) -> [String: String]? {
        guard Metric.Name(rawValue: name) != nil else { return nil }
        var kept: [String: String] = [:]
        for (key, value) in attributes {
            if let ours = Metric.Key(rawValue: key) {
                guard ours.values.contains(value) else { return nil }
                kept[key] = value
            } else if key == "user.id" {
                kept[key] = installID(value)
            } else if sdkMetricKeys.contains(key), !stillHoldsAddress(value) {
                kept[key] = value
            }
        }
        return kept
    }

    static let contextKeys: [String: Set<String>] = [
        "device": ["family", "model", "model_id", "arch", "simulator", "memory_size", "free_memory", "usable_memory",
                   "processor_count", "thermal_state", "battery_level", "charging", "orientation", "low_memory", "low_power_mode"],
        "os": ["name", "version", "build", "rooted"],
        "app": ["app_build", "app_version", "build_type", "in_foreground", "app_memory"],
    ]

    static func contexts(_ contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        contexts.reduce(into: [:]) { kept, context in
            guard let keys = contextKeys[context.key] else { return }
            kept[context.key] = context.value.filter { keys.contains($0.key) }.mapValues { value in
                (value as? String).map { Redaction.holdsAddress($0) ? Redaction.removed : $0 } ?? value
            }
        }
    }

    static let sdkWrittenMechanisms: Set<String> = [
        "AppHang", "watchdog_termination", "MXCrashDiagnostic", "mx_disk_write_exception", "mx_cpu_exception", "mx_hang_diagnostic",
    ]
    static let crashMechanisms: Set<String> = ["mach", "signal"]

    static func exceptionText(_ text: String?, mechanism: String?) -> String? {
        guard let text, let mechanism else { return nil }
        if sdkWrittenMechanisms.contains(mechanism) { return Redaction.clean(text) }
        guard crashMechanisms.contains(mechanism) else { return nil }
        let parts = text.components(separatedBy: " >\n")
        guard parts.count <= 2, parts[0].wholeMatch(of: sdkCrashShape) != nil else { return fatalErrorWords(text) }
        guard parts.count == 2 else { return text }
        return sdkDiagnoses.contains(parts[1]) || parts[1].wholeMatch(of: pointerDiagnosis) != nil ? text : parts[0]
    }

    private static let sdkCrashShape = #/(?:Exception|Signal) (?:-?\d+|\(null\)), Code (?:-?\d+|\(null\))(?:, Subcode (?:-?\d+|\(null\)))?/#
    private static let pointerDiagnosis = #/(?:Attempted to dereference garbage pointer|(?:KERN|EXC)_[A-Z_]+) at 0x[0-9a-fA-F]+\./#
    private static let sdkDiagnoses: Set<String> = [
        "Attempted to dereference null pointer.", "Stack overflow", "Rogue memory write has corrupted memory.",
        "Math error (usually caused from division by 0).", "Graceful OS termination requested.",
    ]

    private static func fatalErrorWords(_ text: String) -> String? {
        let opening = "Fatal error:"
        guard let start = text.range(of: opening) else { return nil }
        let words = text[start.upperBound...].split(whereSeparator: \.isWhitespace).prefix { !$0.contains { ":'\"".contains($0) } }
        return Redaction.clean(([opening] + words.map(String.init)).joined(separator: " "))
    }

    static func installID(_ id: String?) -> String? {
        id.flatMap { $0.wholeMatch(of: uuid) == nil ? nil : $0 }
    }

    static func stillHoldsAddress(_ serialized: String) -> Bool {
        serialized.contains("://") || serialized.contains(#":\/\/"#) || serialized.contains(credential)
            || serialized.matches(of: #/[\d.]+/#).contains { $0.output.wholeMatch(of: ipv4) != nil }
    }

    private static let uuid = #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#
    private static let ipv4 = #/\d{1,3}(?:\.\d{1,3}){3}/#
    private static let credential = #/(?i)(?:api_?key|x-emby-token|x-emby-authorization|access_?token|password|passwd|username)["']?\s*[=:]/#
}
