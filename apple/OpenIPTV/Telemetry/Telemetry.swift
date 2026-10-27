import UIKit

@MainActor
enum Telemetry {
    private static var on = false
    private static let recorder = Metric.Recorder(platform: .current)

    static func start() {
        #if DEBUG
        on = SentryGate.start(.debug)
        if on, let place = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_TELEMETRY_CRASH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { fatalError("telemetry test crash at \(place)") }
        }
        #else
        on = SentryGate.start(.release)
        #endif
    }

    static func note(_ reading: Metric.Reading) {
        guard on, let sample = recorder.sample(reading, network: network) else { return }
        SentryGate.send(sample)
    }

    static func report(_ problem: Problem) {
        guard on else { return }
        SentryGate.send(problem, platform: recorder.platform, network: network)
    }

    private static var network: Metric.Network { Metric.Network(NetworkStatus.shared.network) }
}

extension Metric.Platform {
    @MainActor static var current: Self {
        #if os(tvOS)
        .appletv
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }
}
