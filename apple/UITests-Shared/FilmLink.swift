import XCTest

/// What the film runner prints for one link, the same lines on iPhone and
/// Apple TV: Continue Watching's start ready and cold, two minutes of play
/// (each pause), a lower quality (when decided, its first frame), a jump,
/// an audio switch and a subtitle switch, with the server's own state at
/// each launch (-debugServerProbe YES) on every line. Each platform brings
/// its card to the viewer, plays it and opens the track menus its own way.
protocol FilmLink: AnyObject {
    var app: XCUIApplication { get }
    func say(_ line: String)
    func readout(_ id: String) -> String?
    /// Continue Watching's first card, once Home shows it.
    func firstCard() throws -> String
    /// Where a card gets ready: on screen (iPhone) or focused (Apple TV).
    func bring(_ id: String) throws
    func play(_ id: String)
    /// The audio menu open on another of the file's own tracks.
    func audioPick() -> TrackPick
    /// The subtitle menu open on its entry under Off.
    func subtitlePick(_ entry: Int) -> TrackPick
}

enum TrackPick {
    case noMenu
    case nothing
    /// Picks it, the measuring begun.
    case ready(() -> Void)
}

extension FilmLink {
    func filmOnThisLink() throws {
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES", "-debugServerProbe", "YES"]
        app.launchArguments = shipped
        app.launch()
        let id = try firstCard()
        let build = readout("debug-build") ?? "no readout", tree = ProcessInfo.processInfo.environment["TREE"]
        say("REAL app build \(build)" + (tree.map { $0 == build ? ", this tree" : ", not this tree (\($0))" } ?? ""))
        app.terminate()

        for (kind, arguments) in [("ready", [String]()), ("cold", ["-noPrepareAhead", "YES"])] {
            app.launchArguments = shipped + arguments
            app.launch()
            try bring(id)
            let server = serverState()
            if kind == "ready" { sleep(3) }
            play(id)
            say("REAL link start \(kind): \(startParts(within: 180)) | \(server)")
            app.terminate()
        }

        // The jump comes this long after the tap, after the first two minutes unless the start took long.
        let jumpAt: Double = 200
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = String(Int(jumpAt))
        app.launchArguments = shipped
        app.launch()
        try bring(id)
        let server = serverState()
        play(id)
        let tapped = Date()
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = nil
        say("REAL link playback start: \(startParts(within: 180)) | \(server)")
        func buffering() -> String { readout("debug-buffering") ?? "" }
        var decided: Double?, lowerFrame: Double?
        let playing = min(120, jumpAt - 2 - Date().timeIntervalSince(tapped)), began = Date()
        while Date().timeIntervalSince(began) < playing {
            usleep(500_000)
            if decided == nil, readout("debug-quality")?.hasPrefix("converted") == true { decided = Date().timeIntervalSince(tapped) }
            if lowerFrame == nil, field("opens", in: buffering()).contains(where: { $0.hasPrefix("converted") }) {
                lowerFrame = Date().timeIntervalSince(tapped)
            }
        }
        // "rebuffers 2: 1234 567 ms": how many, and each one's length.
        let pauses = buffering().components(separatedBy: " | ").first { $0.hasPrefix("rebuffers") } ?? "rebuffers: no readout"
        let read = serverMB()
        say("REAL link first \(Int(playing)) s: \(pauses.replacingOccurrences(of: "rebuffers", with: "pauses")) | "
            + String(format: "film %.1f MB from the server, %.2f MB/s since the tap | ", read, read / Date().timeIntervalSince(tapped))
            + "\(readout("debug-quality") ?? "no readout") | \(server)")
        say("REAL link lower quality: " + (decided.map { String(format: "decided %.1f s after the tap, ", $0) } ?? "not decided, ")
            + (lowerFrame.map { String(format: "its first frame %.1f s after the tap", $0) } ?? "no frame of it") + " | \(server)")

        while field("jumps", in: buffering()).isEmpty, Date().timeIntervalSince(tapped) < jumpAt + 60 { usleep(500_000) }
        say("REAL link jump +5 min: \(field("jumps", in: buffering()).first ?? "none in 60 s") to the next frame (MB from the server) | \(server)")
        sleep(25)

        switch audioPick() {
        case .noMenu:
            say("REAL link audio: not measured, the menu didn't open | \(server)")
        case .nothing:
            say("REAL link audio: no other track | \(server)")
        case let .ready(pick):
            let rebuffers = count("rebuffers", in: buffering())
            pick()
            for _ in 0..<40 where !buffering().contains("audio:") { usleep(250_000) }
            sleep(3)
            say("REAL link audio, another track in the file: \(last("audio", in: buffering())) to its sound, "
                + "pauses \(count("rebuffers", in: buffering()) - rebuffers) | \(server)")
        }
        say("REAL link subtitles: \(subtitleSwitch(1) ?? "none") | \(server)")
        app.terminate()
    }

    /// The server's own state at this launch, read before the tap.
    func serverState() -> String {
        for _ in 0..<120 where (readout("debug-server") ?? "").isEmpty { usleep(250_000) }
        return readout("debug-server").flatMap { $0.isEmpty ? nil : $0 } ?? "server: no reading in 30 s"
    }

    func startParts(within seconds: Int = 60) -> String {
        var parts: [Substring] = []
        var instead: String?
        let tapped = Date()
        for _ in 0..<(seconds * 4) where parts.count < 4 && instead == nil {
            usleep(250_000)
            parts = readout("debug-start")?.split(separator: " ") ?? []
            instead = shownInstead()
        }
        if let instead { return String(format: "no start: %@, %.1f s after the tap", instead, Date().timeIntervalSince(tapped)) }
        guard parts.count == 4 else {
            return "no start in \(seconds) s | on screen: " + (app.staticTexts["debug-item"].exists ? "the player's spinner" : "the card's spinner")
        }
        let player = parts[0] == "warm" ? "a kept player" : "a new player"
        return "tap to first frame \(parts[1]) s at \(parts[3]) s (\(player)) | \(readout("debug-start-parts") ?? "no parts")"
    }

    /// What the viewer is shown in place of a start: the "Couldn't play" alert, or the player's message.
    func shownInstead() -> String? {
        let alert = app.alerts.firstMatch
        if alert.exists {
            return "the \"\(alert.label)\" alert (\(alert.staticTexts.allElementsBoundByIndex.dropFirst().first?.label ?? ""))"
        }
        return readout("debug-start-error").flatMap { $0.isEmpty ? nil : "the player's message (\($0))" }
    }

    /// The subtitle menu's entry under Off, picked, and what followed: the
    /// switch, its first line shown, any stall, and the reads it took.
    func subtitleSwitch(_ entry: Int) -> String? {
        let events = { self.readout("debug-subs-timing")?.components(separatedBy: " | ") ?? [] }
        func readsBack() -> Int { Int(readout("debug-reads-back") ?? "") ?? 0 }
        let before = events().filter { $0.hasPrefix("switch ") }.count
        let pick: () -> Void
        switch subtitlePick(entry) {
        case .noMenu: return "not measured, the menu didn't open"
        case .nothing: return nil
        case let .ready(picking): pick = picking
        }
        let (device, server, back) = (relayMB("from the device"), serverMB(), readsBack())
        pick()
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
                          serverMB() - server, readsBack() - back)
        return ([switched ?? "no switch", after] + (stalls.isEmpty ? ["no stall"] : stalls) + [read]).joined(separator: " ; ")
    }

    func relayMB(_ part: String) -> Double {
        guard let relay = readout("debug-relay"), let range = relay.range(of: part + #" ([0-9.]+) MB"#, options: .regularExpression) else { return 0 }
        return Double(relay[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    func serverMB() -> Double {
        guard let relay = readout("debug-relay"), let range = relay.range(of: #"from the server \d+ reads ([0-9.]+) MB"#, options: .regularExpression)
        else { return 0 }
        return Double(relay[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    func count(_ part: String, in readout: String) -> Int {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        return Int(field.split(separator: " ").dropFirst().first?.trimmingCharacters(in: [":", ","]) ?? "") ?? 0
    }

    func field(_ part: String, in readout: String) -> [String] {
        guard let field = readout.components(separatedBy: " | ").first(where: { $0.hasPrefix(part + ":") }) else { return [] }
        return field.dropFirst(part.count + 2).components(separatedBy: ", ")
    }

    func last(_ part: String, in readout: String) -> String {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        if part == "opens" { return field.components(separatedBy: ", ").last ?? "none" }
        return field.split(separator: " ").dropLast().last.map { "\($0) ms" } ?? "none"
    }
}
