import XCTest

/// How films start and buffer on the real feeds: Continue Watching's
/// cards started cold and ready, a film played on (its jumps, another
/// audio track, each kind of subtitles), a film heard in a language only
/// another copy has, and the converted version's start. Counts and times
/// only.
final class RealFeedFilmTests: RealFeedCase {
    func testFilmBufferingAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        let playFor = ProcessInfo.processInfo.environment["FILM_BUFFERING_SECONDS"].flatMap(Double.init) ?? 240
        app.launchArguments = shipped
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let ids = cards.allElementsBoundByIndex.prefix(3).map(\.identifier)
        say("REAL Continue Watching: \(ids.count) cards to start")
        shot("home at launch")
        app.terminate()

        try startCards(ids, shipped)

        for old in [true, false] {
            try playAndSwitch(ids[0], launch: shipped + (old ? ["-oldRelayCache", "YES"] : []), for: playFor, way: old ? " (old way)" : "")
        }

        app.launchArguments = shipped + ["-debugPlayCopyFilm", "YES"]
        app.launch()
        let found = app.staticTexts["debug-copy-film"].firstMatch
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !(found.exists && !found.label.isEmpty) { sleep(1) }
        say("REAL other copy: \(found.exists ? found.label : "not searched")")
        if found.label.hasSuffix("found yes"), waitForPosition(timeout: 45) != nil {
            sleep(5)
            let other = app.buttons.matching(identifier: "audio-other-copy").firstMatch
            if openTrackMenu(), other.exists {
                other.tap()
                let switched = app.staticTexts["debug-copy-switch"].firstMatch
                for _ in 0..<60 where !(switched.exists && !switched.label.isEmpty) { usleep(500_000) }
                say("REAL other copy's language: \(switched.exists && !switched.label.isEmpty ? switched.label : "no switch in 30 s")")
            } else {
                say("REAL other copy's language: not in the menu")
            }
        }
        app.terminate()

        for old in [true, false] { try sayConvertedStart(ids[0], launch: shipped, old: old) }
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
        let buffering = app.staticTexts["debug-buffering"].firstMatch
        let relay = app.staticTexts["debug-relay"].firstMatch
        let quality = app.staticTexts["debug-quality"].firstMatch
        let began = Date(), fromServer = serverMB()
        while Date().timeIntervalSince(began) < seconds {
            sleep(30)
            say(String(format: "REAL playback\(way) at %.0f s: %@ | %@ | %@", Date().timeIntervalSince(began), buffering.label,
                       quality.label, relay.label))
        }
        let played = Date().timeIntervalSince(began), read = serverMB() - fromServer
        say(String(format: "REAL playback\(way) after %.0f s: %.1f MB from the server, %.2f MB/s on average", played, read, read / played))

        for _ in 0..<90 where field("jumps", in: buffering.label).count < 2 { usleep(500_000) }
        for (jump, name) in zip(field("jumps", in: buffering.label) + ["none", "none"], ["+5 min", "-30 s"]) {
            say("REAL jump\(way) \(name): \(jump) to the next frame (MB from the server)")
        }

        let readsBack = app.staticTexts["debug-reads-back"].firstMatch
        if !openTrackMenu() {
            say("REAL audio\(way), another track in the file: not measured, the menu didn't open")
        } else if let other = app.buttons.matching(identifier: "audio-track").allElementsBoundByIndex.first {
            let back = Int(readsBack.label) ?? 0, rebuffers = count("rebuffers", in: buffering.label)
            other.tap()
            for _ in 0..<40 where !buffering.label.contains("audio:") { usleep(250_000) }
            sleep(3)
            say("REAL audio\(way), another track in the file: \(last("audio", in: buffering.label)) to its sound, "
                + "rebuffers \(count("rebuffers", in: buffering.label) - rebuffers), reads back \((Int(readsBack.label) ?? 0) - back)")
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            say("REAL audio\(way), another track in the file: none")
        }

        var kinds: [String: String] = [:]
        for entry in 1...6 {
            guard let line = pickSubtitles(entry), !line.hasPrefix("not measured") else { break }
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
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching")
        let id = card.identifier
        app.terminate()
        let runs = ProcessInfo.processInfo.environment["CONVERTED_RUNS"].flatMap(Int.init) ?? 1
        for _ in 0..<runs {
            for old in [true, false] { try sayConvertedStart(id, launch: shipped, old: old) }
        }
    }

    private func sayConvertedStart(_ id: String, launch arguments: [String], old: Bool) throws {
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "10"
        app.launchArguments = arguments + (old ? ["-oldConvertedStart", "YES"] : [])
        app.launch()
        try bringOnScreen(id, at: 0)
        app.buttons[id].tap()
        _ = startParts()
        let buffering = app.staticTexts["debug-buffering"].firstMatch
        for _ in 0..<60 where !buffering.label.contains("converted ") { sleep(1) }
        sleep(3)
        say("REAL converted start\(old ? " (old way)" : ""): \(last("opens", in: buffering.label)) | \(app.staticTexts["debug-quality"].firstMatch.label)")
        app.terminate()
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = nil
    }

    /// FILM_START_AT is the resume point. A server's place falls between whole seconds.
    func testFilmStartsAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_START_AT"] = ProcessInfo.processInfo.environment["FILM_START_AT"]
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        app.launchArguments = shipped
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let ids = Array(cards.allElementsBoundByIndex.prefix(2).map(\.identifier))
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

    /// Home draws in parts, so a card still moving is left alone. How much
    /// of a card counts as on screen is the app's own rule (PreparesAhead).
    private func bringOnScreen(_ id: String, at index: Int) throws {
        let card = app.buttons[id]
        XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching card")
        let screen = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        func visible() -> CGRect {
            let bottom = tabBar.exists ? tabBar.frame.minY : screen.maxY
            return CGRect(x: screen.minX, y: screen.minY + 100, width: screen.width, height: bottom - screen.minY - 100)
        }
        func seen() -> Bool {
            guard card.exists else { return false }
            let frame = card.frame, shown = frame.intersection(visible())
            return !shown.isNull && shown.width * shown.height >= 0.6 * frame.width * frame.height
        }
        func drag(from point: CGPoint, by offset: CGVector) {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(offset), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let deadline = Date().addingTimeInterval(30)
        var before = CGRect.null
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        while Date() < deadline, !seen() {
            let target = card.exists ? card : row
            guard target.exists else { sleep(1); continue }
            let frame = target.frame, area = visible()
            if frame != before {
                before = frame
                sleep(1)
                continue
            }
            if frame.minY < area.minY || frame.maxY > area.maxY {
                drag(from: CGPoint(x: area.midX, y: area.midY), by: CGVector(dx: 0, dy: max(-400, min(400, area.midY - frame.midY))))
            } else {
                let left = !card.exists || frame.midX > area.midX
                drag(from: CGPoint(x: area.midX, y: frame.midY), by: CGVector(dx: left ? -150 : 150, dy: 0))
            }
            before = .null
        }
        if !seen() { shot("card \(index + 1) not on screen") }
        let frame = card.exists ? card.frame : .null, area = visible()
        XCTAssertTrue(seen(), String(format: "card %d didn't come on screen in 30 s (card %.0f-%.0f down, %.0f-%.0f across; screen %.0f-%.0f down)",
                                     index + 1, frame.minY, frame.maxY, frame.minX, frame.maxX, area.minY, area.maxY))
    }

    private func startParts() -> String {
        let start = app.staticTexts["debug-start"].firstMatch
        var parts: [Substring] = []
        for _ in 0..<240 where parts.count < 4 {
            usleep(250_000)
            parts = start.exists ? start.label.split(separator: " ") : []
        }
        guard parts.count == 4 else { return "no start in 60 s" }
        let split = app.staticTexts["debug-start-parts"].firstMatch
        let player = parts[0] == "warm" ? "a kept player" : "a new player"
        return "tap to first frame \(parts[1]) s (\(player)) | \(split.exists ? split.label : "no parts")"
    }

    private func relayMB(_ part: String) -> Double {
        let relay = app.staticTexts["debug-relay"].firstMatch
        guard relay.exists, let range = relay.label.range(of: part + #" ([0-9.]+) MB"#, options: .regularExpression) else { return 0 }
        return Double(relay.label[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    private func serverMB() -> Double {
        let relay = app.staticTexts["debug-relay"].firstMatch
        guard relay.exists, let range = relay.label.range(of: #"from the server \d+ reads ([0-9.]+) MB"#, options: .regularExpression)
        else { return 0 }
        return Double(relay.label[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    private func count(_ part: String, in readout: String) -> Int {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        return Int(field.split(separator: " ").dropFirst().first?.trimmingCharacters(in: [":", ","]) ?? "") ?? 0
    }

    private func field(_ part: String, in readout: String) -> [String] {
        guard let field = readout.components(separatedBy: " | ").first(where: { $0.hasPrefix(part + ":") }) else { return [] }
        return field.dropFirst(part.count + 2).components(separatedBy: ", ")
    }

    private func last(_ part: String, in readout: String) -> String {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        if part == "opens" { return field.components(separatedBy: ", ").last ?? "none" }
        return field.split(separator: " ").dropLast().last.map { "\($0) ms" } ?? "none"
    }

    /// Tapped where it is. The controls are brought up again when they hid.
    private func openTrackMenu() -> Bool {
        let menu = app.buttons["Audio and Subtitles"].firstMatch
        let off = app.buttons["Off"].firstMatch
        for _ in 0..<4 where !off.exists {
            if !(menu.exists && menu.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
            }
            if menu.exists, menu.isHittable {
                let frame = menu.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            _ = off.waitForExistence(timeout: 3)
        }
        return off.exists
    }

    /// The menu is read from one snapshot and tapped where its entry was:
    /// it's built again when a track arrives.
    private func pickSubtitles(_ entry: Int) -> String? {
        let timing = app.staticTexts["debug-subs-timing"].firstMatch
        let events = { timing.exists ? timing.label.components(separatedBy: " | ") : [] }
        let before = events().filter { $0.hasPrefix("switch ") }.count
        guard openTrackMenu() else { return "not measured, the menu didn't open" }
        var buttons: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .button { buttons.append(element) }
            element.children.forEach(collect)
        }
        if let screen = try? app.snapshot() { collect(screen) }
        guard let off = buttons.first(where: { $0.label == "Off" || $0.identifier == "Off" })?.frame else { return nil }
        let below = buttons.filter { $0.frame.minY > off.minY && abs($0.frame.minX - off.minX) < 1 && abs($0.frame.width - off.width) < 1 }
            .map(\.frame).sorted { $0.minY < $1.minY }
        guard entry <= below.count else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            return nil
        }
        let place = below[entry - 1]
        let readsBack = app.staticTexts["debug-reads-back"].firstMatch
        let (device, server, back) = (relayMB("from the device"), serverMB(), Int(readsBack.label) ?? 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: place.midX, dy: place.midY)).tap()
        var switched: String?, shown: String?
        for _ in 0..<80 where shown == nil {
            usleep(250_000)
            switched = events().filter { $0.hasPrefix("switch ") }.dropFirst(before).first
            let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
            shown = n.flatMap { n in events().first { $0.hasPrefix("shown ") && $0.split(separator: " ").contains(n) } }
        }
        sleep(2)
        let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
        let stalls = events().filter { $0.hasPrefix("rebuffer ") && n.map($0.split(separator: " ").contains) == true }
        let after = shown?.split(separator: " ").first { $0.hasPrefix("after=") }.map(String.init) ?? "no line in 20 s"
        let read = String(format: "read %.1f MB from the device, %.1f MB from the server, %d reads back", relayMB("from the device") - device,
                          serverMB() - server, (Int(readsBack.label) ?? 0) - back)
        return ([switched ?? "no switch", after] + (stalls.isEmpty ? ["no stall"] : stalls) + [read]).joined(separator: " ; ")
    }
}
