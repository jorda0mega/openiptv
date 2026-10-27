import Foundation
import Sentry

enum SentryGate {
    static func start(_ build: Outbound.Build) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let dsn = Outbound.dsn(build, environment: ProcessInfo.processInfo.environment, info: info) else { return false }
        SentrySDK.start(options: options(dsn: dsn, build: build, release: info["CFBundleVersion"] as? String))
        return true
    }

    static func send(_ sample: Metric.Sample) {
        let attributes = Dictionary(uniqueKeysWithValues: sample.states.map { ($0.key.rawValue, $0.value) })
        SentrySDK.metrics.distribution(key: sample.name.rawValue, value: sample.seconds, unit: .second, attributes: attributes)
    }

    static func send(_ problem: Problem, platform: Metric.Platform, network: Metric.Network) {
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: problem.kind.rawValue)
        event.tags = [problemReason: problem.reasonWord, Metric.Key.platform.rawValue: platform.rawValue,
                      Metric.Key.network.rawValue: network.rawValue]
        event.fingerprint = [problem.kind.rawValue, problem.reasonWord]
        SentrySDK.capture(event: event)
    }

    private static let problemReason = "reason"
    private static let tagKeys: Set<String> = [problemReason, Metric.Key.platform.rawValue, Metric.Key.network.rawValue]

    private static func options(dsn: String, build: Outbound.Build, release: String?) -> Options {
        let options = Options()
        options.dsn = dsn
        options.releaseName = release
        #if os(tvOS)
        options.dist = "tvos"
        #else
        options.dist = "ios"
        #endif
        options.environment = build == .release ? "release" : "debug"
        options.debug = false
        options.sendDefaultPii = false
        options.enableSwizzling = false
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableCaptureFailedRequests = false
        options.failedRequestTargets = []
        options.tracePropagationTargets = []
        options.enablePropagateTraceparent = false
        options.enableGraphQLOperationTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.maxBreadcrumbs = 0
        options.enableAutoPerformanceTracing = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableTimeToFullDisplayTracing = false
        options.tracesSampleRate = nil
        options.tracesSampler = nil
        options.enableLogs = false
        options.enableSpotlight = false
        options.enableUIViewControllerTracing = false
        options.enableUserInteractionTracing = false
        options.enablePreWarmedAppStartTracing = false
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        options.reportAccessibilityIdentifier = false
        options.sessionReplay.sessionSampleRate = 0
        options.sessionReplay.onErrorSampleRate = 0
        #if os(iOS)
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        #endif
        options.beforeSend = { event($0) }
        options.beforeSendMetric = { metric($0) }
        options.beforeBreadcrumb = { _ in nil }
        options.beforeSendLog = { _ in nil }
        options.beforeSendSpan = { _ in nil }
        options.beforeCaptureScreenshot = { _ in false }
        options.beforeCaptureViewHierarchy = { _ in false }
        return options
    }

    private static func event(_ event: Event) -> Event? {
        guard event.type != "transaction" else { return nil }
        event.breadcrumbs = nil
        event.request = nil
        event.extra = nil
        event.modules = nil
        event.serverName = nil
        event.logger = nil
        event.transaction = nil
        event.error = nil
        event.user = Outbound.installID(event.user?.userId).map { User(userId: $0) }
        event.tags = event.tags?.filter { tagKeys.contains($0.key) }.mapValues(Redaction.clean)
        event.context = event.context.map(Outbound.contexts)
        event.fingerprint = event.fingerprint?.map(Redaction.clean)
        event.message = event.message.map { SentryMessage(formatted: Redaction.clean($0.formatted)) }
        for exception in event.exceptions ?? [] {
            exception.type = exception.type.map(Redaction.clean)
            exception.value = exception.value.map(Redaction.clean)
            exception.module = nil
            exception.mechanism?.desc = exception.mechanism?.desc.map(Redaction.clean)
            exception.mechanism?.data = nil
            exception.mechanism?.helpLink = nil
            if let error = exception.mechanism?.meta?.error { error.domain = Redaction.clean(error.domain) }
            scrub(exception.stacktrace)
        }
        for thread in event.threads ?? [] {
            thread.name = thread.name.map(Redaction.clean)
            scrub(thread.stacktrace)
        }
        scrub(event.stacktrace)
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map(Redaction.fileName)
        }
        guard let text = serialized(event), !Outbound.stillHoldsAddress(text) else { return nil }
        return event
    }

    private static func scrub(_ stacktrace: SentryStacktrace?) {
        for frame in stacktrace?.frames ?? [] {
            frame.package = frame.package.map(Redaction.fileName)
            frame.function = frame.function.flatMap { Redaction.holdsAddress($0) ? nil : $0 }
            frame.fileName = nil
            frame.module = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }

    private static func serialized(_ event: Event) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: event.serialize(), options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func metric(_ metric: SentryMetric) -> SentryMetric? {
        let strings = metric.attributes.compactMapValues { value in
            if case let .string(text) = value { text } else { nil }
        }
        guard case .distribution = metric.value, let kept = Outbound.metricAttributes(name: metric.name, strings) else { return nil }
        var sent = metric
        sent.unit = .second
        sent.attributes = kept.mapValues { .string($0) }
        return sent
    }
}
