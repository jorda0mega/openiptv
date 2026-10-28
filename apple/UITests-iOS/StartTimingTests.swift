import XCTest

/// iPhone: how long Continue Watching's titles take to start, each from a
/// fresh launch of an installed app. Kinds, in each of START_ROUNDS rounds
/// (3 unless set), by Metric's names: the first tap with nothing prepared
/// (film.start.unprepared, -noPrepareAhead), a tap as soon as the card shows
/// (film.start.first_tap), a card tapped once its plan and start are fetched
/// ahead, at most 30 s (film.start.prepared), and another card after the
/// first played and closed (film.start.resume). The install's first launch
/// comes first (film.start.first_tap too). Each start prints a METRIC line
/// and a START line with the app's parts.
/// Continue Watching needs two cards.
final class StartTimingTests: TimingCase {
    func testStarts() throws {
        let shipped = launchBase + ["-forgetTrackChoices", "YES"]
        app.launchArguments = shipped
        app.launch()
        let first = try firstCard()
        app.buttons[first].tap()
        say("install_tap", "film.start.first_tap", start())
        app.terminate()
        // The rest of the install's first launches, which a busy server answers late.
        for _ in 0..<3 {
            app.launch()
            _ = try firstCard()
            app.terminate()
        }
        let rounds = ProcessInfo.processInfo.environment["START_ROUNDS"].flatMap(Int.init) ?? 3
        for _ in 0..<rounds {
            app.launchArguments = shipped + ["-noPrepareAhead", "YES"]
            app.launch()
            app.buttons[try firstCard()].tap()
            say("unprepared", "film.start.unprepared", start())
            app.terminate()

            app.launchArguments = shipped
            app.launch()
            app.buttons[try firstCard()].tap()
            say("first_tap", "film.start.first_tap", start())
            app.terminate()

            app.launch()
            let card = try firstCard()
            let began = Date()
            while Date().timeIntervalSince(began) < 30, !prepared() { sleep(1) }
            let ahead = app.staticTexts["debug-ahead"].firstMatch.label
            app.buttons[card].tap()
            say("prepared", "film.start.prepared", start(), note: String(format: "waited %.0f s, %@", Date().timeIntervalSince(began),
                                                                         ahead.replacingOccurrences(of: " | ", with: "; ")))
            sleep(8)
            close()
            let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).allElementsBoundByIndex
                .map(\.identifier).first { $0 != card }
            if let other {
                sleep(2)
                app.buttons[other].tap()
                say("resume", "film.start.resume", start())
            } else {
                print("START resume: no second card")
            }
            app.terminate()
        }
    }

    private func firstCard() throws -> String {
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no Continue Watching card")
        for _ in 0..<20 where !card.isHittable { usleep(250_000) }
        return card.identifier
    }

    /// "held 1 plans 1 starts 1 warmed 1 ...": the card's plan and its start fetched ahead.
    private func prepared() -> Bool {
        let words = app.staticTexts["debug-ahead"].firstMatch.label.split(separator: " ")
        func count(_ name: String) -> Int { words.firstIndex(of: Substring(name)).flatMap { Int(words[$0 + 1]) } ?? 0 }
        return count("plans") > 0 && count("starts") > 0
    }

    /// Seconds from the tap to the first frame, and the app's own parts; nil when no start in 120 s.
    private func start() -> (seconds: Double?, parts: String) {
        let readout = app.staticTexts["debug-start"].firstMatch, failed = app.staticTexts["debug-start-error"].firstMatch
        let tapped = Date()
        var words: [Substring] = []
        while Date().timeIntervalSince(tapped) < 120, words.count < 4, !(failed.exists && !failed.label.isEmpty) {
            usleep(250_000)
            words = readout.exists ? readout.label.split(separator: " ") : []
        }
        if words.count < 4 { print(String(format: "START none after %.0f s", Date().timeIntervalSince(tapped))) }
        let parts = app.staticTexts["debug-start-parts"].firstMatch
        return (words.count == 4 ? Double(words[1]) : nil, parts.exists ? parts.label : "no parts")
    }

    private func say(_ kind: String, _ metric: String, _ start: (seconds: Double?, parts: String), note: String = "") {
        guard let seconds = start.seconds else {
            print("START \(kind): no start in 120 s")
            return sayWhyNoStart()
        }
        print(String(format: "METRIC %@ %.2f s", metric, seconds))
        print(String(format: "START %@: %.2f s%@ | %@", kind, seconds, note.isEmpty ? "" : " (\(note))", start.parts))
    }

    private func close() {
        let button = app.buttons["Close player"].firstMatch
        if !button.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            _ = button.waitForExistence(timeout: 3)
        }
        button.tap()
        sleep(2)
    }
}
