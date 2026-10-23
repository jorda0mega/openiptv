import XCTest

/// How films start and buffer on the real feeds: Continue Watching's
/// cards started cold and ready, a film played on (its jumps, another
/// audio track, each kind of subtitles), a film heard in a language only
/// another copy has, and the converted version's start. Counts and times
/// only.
final class RealFeedFilmTests: RealFeedCase, FilmLink {
    func testFilmBufferingAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        let playFor = ProcessInfo.processInfo.environment["FILM_BUFFERING_SECONDS"].flatMap(Double.init) ?? 240
        app.launchArguments = shipped
        app.launch()
        XCTAssertTrue(continueCards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let ids = Array(cardIds().prefix(3))
        say("REAL Continue Watching: \(ids.count) cards to start")
        shot("home at launch")
        app.terminate()

        try startCards(ids, shipped)

        for old in [true, false] {
            try playAndSwitch(ids[0], launch: shipped + (old ? ["-oldRelayCache", "YES"] : []), for: playFor, way: old ? " (old way)" : "")
        }

        app.launchArguments = shipped + ["-debugPlayCopyFilm", "YES"]
        app.launch()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, readout("debug-copy-film")?.isEmpty ?? true { sleep(1) }
        let found = readout("debug-copy-film")
        say("REAL other copy: \(found ?? "not searched")")
        if found?.hasSuffix("found yes") == true, waitForPosition(timeout: 45) != nil {
            sleep(5)
            if openTrackMenu(), let other = buttonsOnScreen({ $0.identifier == "audio-other-copy" }).first {
                tap(other.frame)
                for _ in 0..<60 where readout("debug-copy-switch")?.isEmpty ?? true { usleep(500_000) }
                let switched = readout("debug-copy-switch") ?? ""
                say("REAL other copy's language: \(switched.isEmpty ? "no switch in 30 s" : switched)")
            } else {
                say("REAL other copy's language: not in the menu")
            }
        }
        app.terminate()

        for old in [true, false] { try sayConvertedStart(ids[0], launch: shipped, old: old) }
    }

    /// The baseline on one link (the runner's LINKS, through the throttling
    /// proxy): the shared flow (FilmLink), a card on screen and a tap.
    func testFilmOnThisLink() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        try filmOnThisLink()
    }

    private func playAndSwitch(_ id: String, launch arguments: [String], for seconds: Double, way: String) throws {
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = String(Int(seconds) + 15)
        app.launchArguments = arguments
        app.launch()
        try bringOnScreen(id, at: 0)
        sleep(3)
        app.buttons[id].tap()
        say("REAL playback\(way) start: " + startParts())
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = nil
        func buffering() -> String { readout("debug-buffering") ?? "" }
        func readsBack() -> Int { Int(readout("debug-reads-back") ?? "") ?? 0 }
        let began = Date(), fromServer = serverMB()
        while Date().timeIntervalSince(began) < seconds {
            sleep(30)
            say(String(format: "REAL playback\(way) at %.0f s: %@ | %@ | %@", Date().timeIntervalSince(began), readout("debug-buffering") ?? "no readout",
                       readout("debug-quality") ?? "no readout", readout("debug-relay") ?? "no readout"))
        }
        let played = Date().timeIntervalSince(began), read = serverMB() - fromServer
        say(String(format: "REAL playback\(way) after %.0f s: %.1f MB from the server, %.2f MB/s on average", played, read, read / played))

        for _ in 0..<90 where field("jumps", in: buffering()).count < 2 { usleep(500_000) }
        for (jump, name) in zip(field("jumps", in: buffering()) + ["none", "none"], ["+5 min", "-30 s"]) {
            say("REAL jump\(way) \(name): \(jump) to the next frame (MB from the server)")
        }

        switch audioPick() {
        case .noMenu:
            say("REAL audio\(way), another track in the file: not measured, the menu didn't open")
        case .nothing:
            say("REAL audio\(way), another track in the file: none")
        case let .ready(pick):
            let back = readsBack(), rebuffers = count("rebuffers", in: buffering())
            pick()
            for _ in 0..<40 where !buffering().contains("audio:") { usleep(250_000) }
            sleep(3)
            say("REAL audio\(way), another track in the file: \(last("audio", in: buffering())) to its sound, "
                + "rebuffers \(count("rebuffers", in: buffering()) - rebuffers), reads back \(readsBack() - back)")
        }

        var kinds: [String: String] = [:]
        for entry in 1...6 {
            guard let line = subtitleSwitch(entry), !line.hasPrefix("not measured") else { break }
            let kind = line.split(separator: " ").first { $0.hasPrefix("to=") }.map(String.init) ?? "to=?"
            let hidden = line.contains("hidden=yes") ? " hidden" : ""
            if kinds[kind + hidden] == nil { kinds[kind + hidden] = line }
        }
        for (kind, line) in kinds.sorted(by: { $0.key < $1.key }) { say("REAL subtitles\(way) \(kind): \(line)") }
        app.terminate()
    }

    /// Shell: TEST_RUNNER_CONVERTED_RUNS (pairs, 1 unless set) and
    /// TEST_RUNNER_CONVERTED_AT (the film's second). The test sees them
    /// without the TEST_RUNNER_ prefix.
    func testConvertedStartAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_START_AT"] = ProcessInfo.processInfo.environment["CONVERTED_AT"]
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        app.launchArguments = shipped
        app.launch()
        XCTAssertTrue(continueCards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let id = try XCTUnwrap(cardIds().first, "no Continue Watching")
        app.terminate()
        let runs = ProcessInfo.processInfo.environment["CONVERTED_RUNS"].flatMap(Int.init) ?? 1
        for _ in 0..<runs {
            for old in [true, false] { try sayConvertedStart(id, launch: shipped, old: old) }
        }
    }

    private func sayConvertedStart(_ id: String, launch arguments: [String], old: Bool) throws {
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "10"
        app.launchArguments = arguments + ["-debugRedirectCounts", "YES"] + (old ? ["-oldConvertedStart", "YES"] : [])
        app.launch()
        try bringOnScreen(id, at: 0)
        app.buttons[id].tap()
        _ = startParts()
        for _ in 0..<60 where !(readout("debug-buffering") ?? "").contains("converted ") { sleep(1) }
        sleep(3)
        say("REAL converted start\(old ? " (old way)" : ""): \(last("opens", in: readout("debug-buffering") ?? "")) | \(readout("debug-quality") ?? "no readout")")
        say("REAL redirects\(old ? " (old way)" : ""): \(readout("debug-redirects") ?? "no readout")")
        app.terminate()
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = nil
    }

    /// FILM_START_AT is the resume point. A server's place falls between whole seconds.
    /// FILM_START_ARGUMENTS: launch arguments for every start ("-noPreconnect YES");
    /// FILM_START_CARDS: how many of Continue Watching's cards (2).
    func testFilmStartsAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_START_AT"] = ProcessInfo.processInfo.environment["FILM_START_AT"]
        let extra = ProcessInfo.processInfo.environment["FILM_START_ARGUMENTS"]?.split(separator: " ").map(String.init) ?? []
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"] + extra
        app.launchArguments = shipped
        app.launch()
        XCTAssertTrue(continueCards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let ids = Array(cardIds().prefix(ProcessInfo.processInfo.environment["FILM_START_CARDS"].flatMap(Int.init) ?? 2))
        app.terminate()
        let rounds = ProcessInfo.processInfo.environment["FILM_START_ROUNDS"].flatMap(Int.init) ?? 2
        for _ in 0..<rounds { try startCards(ids, shipped) }
    }

    private func startCards(_ ids: [String], _ shipped: [String]) throws {
        let kinds: [(name: String, arguments: [String])] = [
            ("cold", ["-noPrepareAhead", "YES"]), ("ready", []), ("ready (old way)", ["-oldReadyStart", "YES"]),
        ]
        for (n, id) in ids.enumerated() {
            // Swap the order each card, so one kind is not always first.
            for kind in n.isMultiple(of: 2) ? kinds : kinds.reversed() {
                app.launchArguments = shipped + kind.arguments
                app.launch()
                try bringOnScreen(id, at: n)
                if kind.name != "cold" { sleep(3) }
                app.buttons[id].tap()
                say("REAL start card \(n + 1) \(kind.name): " + startParts())
                app.terminate()
            }
        }
    }

    private var continueCards: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")) }

    private func cardIds() -> [String] {
        buttonsOnScreen { $0.identifier.hasPrefix("continue-") }.map(\.identifier)
    }

    /// Home draws in parts, so a card still moving is left alone. How much
    /// of a card counts as on screen is the app's own rule (PreparesAhead).
    private func bringOnScreen(_ id: String, at index: Int) throws {
        let card = app.buttons[id]
        XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching card")
        let screen = app.windows.firstMatch.frame
        func frame(_ element: XCUIElement) -> CGRect? { (try? element.snapshot())?.frame }
        func visible() -> CGRect {
            let bottom = frame(app.tabBars.firstMatch)?.minY ?? screen.maxY
            return CGRect(x: screen.minX, y: screen.minY + 100, width: screen.width, height: bottom - screen.minY - 100)
        }
        func seen(_ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            let shown = frame.intersection(visible())
            return !shown.isNull && shown.width * shown.height >= 0.6 * frame.width * frame.height
        }
        func drag(from point: CGPoint, by offset: CGVector) {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(offset), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let deadline = Date().addingTimeInterval(30)
        var before = CGRect.null
        while Date() < deadline {
            let cardFrame = frame(card)
            if seen(cardFrame) { break }
            guard let target = cardFrame ?? frame(continueCards.firstMatch) else { sleep(1); continue }
            let area = visible()
            if target != before {
                before = target
                sleep(1)
                continue
            }
            if target.minY < area.minY || target.maxY > area.maxY {
                drag(from: CGPoint(x: area.midX, y: area.midY), by: CGVector(dx: 0, dy: max(-400, min(400, area.midY - target.midY))))
            } else {
                let left = cardFrame == nil || target.midX > area.midX
                drag(from: CGPoint(x: area.midX, y: target.midY), by: CGVector(dx: left ? -150 : 150, dy: 0))
            }
            before = .null
        }
        let last = frame(card)
        if !seen(last) { shot("card \(index + 1) not on screen") }
        let shown = last ?? .null, area = visible()
        XCTAssertTrue(seen(last), String(format: "card %d didn't come on screen in 30 s (card %.0f-%.0f down, %.0f-%.0f across; screen %.0f-%.0f down)",
                                         index + 1, shown.minY, shown.maxY, shown.minX, shown.maxX, area.minY, area.maxY))
    }

    private func buttonsOnScreen(_ keep: (XCUIElementSnapshot) -> Bool = { _ in true }) -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .button, keep(element) { found.append(element) }
            element.children.forEach(collect)
        }
        if let screen = try? app.snapshot() { collect(screen) }
        return found
    }

    private func tap(_ frame: CGRect) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// One snapshot, then a tap there. The controls can hide between two reads.
    private func openTrackMenu() -> Bool {
        let menu = app.buttons["Audio and Subtitles"].firstMatch
        let off = app.buttons["Off"].firstMatch
        for _ in 0..<6 where !off.exists {
            guard let place = (try? menu.snapshot())?.frame else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
                continue
            }
            tap(place)
            _ = off.waitForExistence(timeout: 3)
        }
        return off.exists
    }

    /// The menu is read from one snapshot and tapped where its entry was:
    /// it's built again when a track arrives.
    func subtitlePick(_ entry: Int) -> TrackPick {
        guard openTrackMenu() else { return .noMenu }
        let buttons = buttonsOnScreen()
        guard let off = buttons.first(where: { $0.label == "Off" || $0.identifier == "Off" })?.frame else { return .nothing }
        let below = buttons.filter { $0.frame.minY > off.minY && abs($0.frame.minX - off.minX) < 1 && abs($0.frame.width - off.width) < 1 }
            .map(\.frame).sorted { $0.minY < $1.minY }
        guard entry <= below.count else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            return .nothing
        }
        return .ready { self.tap(below[entry - 1]) }
    }

    func audioPick() -> TrackPick {
        guard openTrackMenu() else { return .noMenu }
        guard let other = buttonsOnScreen({ $0.identifier == "audio-track" }).first else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            return .nothing
        }
        return .ready { self.tap(other.frame) }
    }

    func firstCard() throws -> String {
        XCTAssertTrue(continueCards.firstMatch.waitForExistence(timeout: 90), "no Continue Watching")
        return try XCTUnwrap(cardIds().first, "no Continue Watching")
    }

    func bring(_ id: String) throws { try bringOnScreen(id, at: 0) }

    func play(_ id: String) { app.buttons[id].tap() }
}
