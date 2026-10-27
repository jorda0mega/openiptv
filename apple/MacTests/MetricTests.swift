import XCTest
@testable import OpenIPTV

final class MetricTests: XCTestCase {
    private typealias Name = Metric.Name

    func testTheNamesStayAsTheyAre() {
        XCTAssertEqual(Name.allCases.map(\.rawValue), [
            "film.start.first_tap", "film.start.prepared", "film.start.resume", "film.start.from_beginning",
            "film.jump.forward_10s", "film.jump.back_10s", "film.jump.forward_5min",
            "film.pip.start_gap", "film.pip.return_gap", "live.start", "live.switch",
        ])
        XCTAssertEqual(Problem.Kind.allCases.map(\.rawValue),
                       ["film_did_not_start", "film_stopped", "live_did_not_start", "live_stopped"])
    }

    private func start(_ recorder: inout Metric.Recorder, prepared: Bool, resumes: Bool, seconds: Double = 0.5) -> Metric.Sample? {
        recorder.sample(.filmStarted(prepared: prepared, resumes: resumes, picture: .software, seconds: seconds), network: .wifi)
    }

    func testTheFirstFilmAfterLaunchIsTheFirstTapWhateverElseItIs() {
        for prepared in [false, true] {
            for resumes in [false, true] {
                var recorder = Metric.Recorder(platform: .iphone)
                let first = start(&recorder, prepared: prepared, resumes: resumes)
                XCTAssertEqual(first?.name, .filmStartFirstTap)
                XCTAssertEqual(first?.states[.prepared], prepared ? "yes" : "no")
                XCTAssertEqual(first?.states[.resumed], resumes ? "yes" : "no")
            }
        }
    }

    func testEveryLaterStartLandsUnderExactlyOneName() {
        var recorder = Metric.Recorder(platform: .iphone)
        _ = start(&recorder, prepared: false, resumes: false)
        XCTAssertEqual(start(&recorder, prepared: true, resumes: true)?.name, .filmStartPrepared)
        XCTAssertEqual(start(&recorder, prepared: true, resumes: false)?.name, .filmStartPrepared)
        XCTAssertEqual(start(&recorder, prepared: false, resumes: true)?.name, .filmStartResume)
        XCTAssertEqual(start(&recorder, prepared: false, resumes: false)?.name, .filmStartFromBeginning)
    }

    func testAStartSaysWhereItRanAndWhetherItsLoadingShowed() {
        var recorder = Metric.Recorder(platform: .appletv)
        let quick = recorder.sample(.filmStarted(prepared: true, resumes: false, picture: .gpu,
                                                 seconds: LoadProgress.ringAfter - 0.01), network: .phone)
        XCTAssertEqual(quick, Metric.Sample(name: .filmStartFirstTap, seconds: LoadProgress.ringAfter - 0.01, states: [
            .platform: "appletv", .network: "phone", .picture: "gpu", .prepared: "yes", .resumed: "no", .loadingShown: "no",
        ]))
        let slow = start(&recorder, prepared: false, resumes: false, seconds: LoadProgress.ringAfter)
        XCTAssertEqual(slow?.states[.loadingShown], "yes")
    }

    func testOnlyTheNamedJumpsAreTimed() {
        var recorder = Metric.Recorder(platform: .iphone)
        func jump(_ by: Double, _ seconds: Double = 0.4) -> Metric.Sample? {
            recorder.sample(.filmJumped(by: by, picture: .software, seconds: seconds), network: .wifi)
        }
        XCTAssertEqual(jump(10)?.name, .filmJumpForward10s)
        XCTAssertEqual(jump(-10)?.name, .filmJumpBack10s)
        XCTAssertEqual(jump(300)?.name, .filmJumpForward5min)
        XCTAssertNil(jump(-30))
        XCTAssertNil(jump(30))
        XCTAssertEqual(jump(10, LoadProgress.dropShownAfter - 0.01)?.states[.loadingShown], "no")
        XCTAssertEqual(jump(10, LoadProgress.dropShownAfter)?.states[.loadingShown], "yes")
        XCTAssertEqual(jump(10)?.states[.picture], "software")
    }

    func testPictureInPictureGapsAndLiveStarts() {
        var recorder = Metric.Recorder(platform: .iphone)
        let gap = recorder.sample(.pipGap(.return, seconds: 0.2), network: .wifi)
        XCTAssertEqual(gap?.name, .pipReturnGap)
        XCTAssertEqual(gap?.states[.picture], "software")
        XCTAssertNil(gap?.states[.loadingShown])
        XCTAssertEqual(recorder.sample(.pipGap(.start, seconds: 0.2), network: .wifi)?.name, .pipStartGap)
        let live = recorder.sample(.liveOpened(.start, seconds: 1.2), network: .unknown)
        XCTAssertEqual(live?.name, .liveStart)
        XCTAssertEqual(live?.states[.picture], "gpu")
        XCTAssertEqual(live?.states[.loadingShown], "yes")
        XCTAssertEqual(recorder.sample(.liveOpened(.switch, seconds: 0.3), network: .wifi)?.name, .liveSwitch)
    }

    func testEverySampleGoesOutWhole() {
        var recorder = Metric.Recorder(platform: .ipad)
        let readings: [Metric.Reading] = [
            .filmStarted(prepared: false, resumes: true, picture: .software, seconds: 2), .filmJumped(by: -10, picture: .gpu, seconds: 4),
            .pipGap(.start, seconds: 0.1), .liveOpened(.switch, seconds: 0.5),
        ]
        for reading in readings {
            for network in Metric.Network.allCases {
                let sample = try? XCTUnwrap(recorder.sample(reading, network: network))
                let attributes = Dictionary(uniqueKeysWithValues: (sample?.states ?? [:]).map { ($0.key.rawValue, $0.value) })
                XCTAssertEqual(Outbound.metricAttributes(name: sample?.name.rawValue ?? "", attributes), attributes)
            }
        }
    }

    func testNetworkWords() {
        XCTAssertEqual(Metric.Network(.unmetered), .wifi)
        XCTAssertEqual(Metric.Network(.expensive), .phone)
        XCTAssertEqual(Metric.Network(.constrained), .lowData)
        XCTAssertEqual(Metric.Network(.unknown), .unknown)
    }

    func testAProblemIsAKindAndAReasonWord() {
        XCTAssertEqual(Problem.liveDidNotStart(.http_404).kind, .liveDidNotStart)
        XCTAssertEqual(Problem.liveDidNotStart(.http_404).reason, .http_404)
        XCTAssertEqual(Problem.filmStopped(.reset).kind, .filmStopped)
        XCTAssertEqual(Problem.filmDidNotStart(.no_frame).reason, .no_frame)
        XCTAssertEqual(Problem.liveStopped(.timeout).kind, .liveStopped)
    }

    func testAFrameGapIsTheLongestWaitBetweenFrames() {
        var gap = Metric.FrameGap(began: 10)
        for i in 1...50 { gap.frame(at: 10 + Double(i) * 0.04) }
        XCTAssertEqual(gap.longest(until: 12.02) ?? -1, 0.04, accuracy: 1e-9)
        gap.frame(at: 12.5)
        XCTAssertEqual(gap.longest(until: 12.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(gap.longest(until: 14) ?? -1, 1.5, accuracy: 1e-9)
    }

    func testAFrameGapCountsFromTheSwitchAndIgnoresEarlierFrames() {
        var gap = Metric.FrameGap(began: 10)
        gap.frame(at: 9.9)
        gap.frame(at: 10.7)
        XCTAssertEqual(gap.longest(until: 10.8) ?? -1, 0.7, accuracy: 1e-9)
    }

    func testAPausedFilmHasNoGap() {
        var gap = Metric.FrameGap(began: 10)
        gap.frame(at: 10.04)
        gap.held()
        XCTAssertNil(gap.longest(until: 14))
    }
}
