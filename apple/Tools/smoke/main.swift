// Smoke-tests the app's own provider code (compiled from OpenIPTV/) against
// real or mock services, without the UI. Logins come from environment
// variables — set them however you like (typed, a password manager, CI
// secrets). Nothing is stored, and output never includes credentials or
// stream URLs: only counts, names, timings and hostnames.
//
//   apple/Tools/smoke/run.sh                 # whichever services are configured
//   OPENIPTV_SMOKE_GUIDE=1 apple/Tools/smoke/run.sh   # also download the full guide
import Foundation

let env = ProcessInfo.processInfo.environment
func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
func ms(_ start: Date) -> String { "\(Int(Date().timeIntervalSince(start) * 1000)) ms" }
var failures = 0

func check(_ source: IPTVSource) async {
    print("\n== \(source.formatName) (\(source.safeDescription))")
    let provider = Providers.make(source)
    let started = Date()
    do {
        let lineup = try await provider.load()
        print("  lineup        \(lineup.channels.count) channels, \(lineup.categories.count) categories, \(lineup.guideURLs.count) guide URL(s) in \(ms(started))")
        let withEPG = lineup.channels.filter { $0.epgId != nil }.count
        print("  with guide id \(withEPG)")
        let leaked = lineup.channels.filter { AccountInfoFilter.looksLikeAccountInfo($0.name) }.count
        print("  account-info  \(leaked == 0 ? "none shown ✓" : "⚠ \(leaked) visible")")
        if leaked > 0 { failures += 1 }
        let sample = Array(lineup.channels.prefix(4))
        for channel in sample {
            let epgStart = Date()
            let list = await provider.shortEPG(for: channel)
            let nn = NowNext.from(list, source: .provider)
            print("  \(channel.name.prefix(28).padding(toLength: 28, withPad: " ", startingAt: 0)) now: \(nn.now?.title ?? "—") (\(ms(epgStart)))")
        }
        if let first = sample.first {
            let playStart = Date()
            let stream = try await provider.playable(first)
            print("  playable      \(stream.url.scheme ?? "?")://\(stream.url.host() ?? "?") with \(stream.headers.count) header(s) in \(ms(playStart))")
        }
        if value("OPENIPTV_SMOKE_GUIDE") != nil, !lineup.guideURLs.isEmpty {
            let guide = GuideStore()
            let guideStart = Date()
            await guide.refresh(from: lineup.guideURLs, keep: Set(lineup.channels.compactMap(\.epgId)))
            print("  guide         \(await guide.state) in \(ms(guideStart))")
            var covered = 0
            for channel in lineup.channels.prefix(200) {
                if let id = channel.epgId, await guide.nowNext(id)?.now != nil { covered += 1 }
            }
            print("  guide now     \(covered) of first 200 channels have a current show")
            await guide.clear()
        }
    } catch {
        failures += 1
        print("  ✗ \(SourceError.wrap(error).localizedDescription)")
    }
}

if let server = value("OPENIPTV_XTREAM_URL").flatMap({ XtreamProvider.parse($0.split(separator: " ").first.map(String.init) ?? $0) }),
   let user = value("OPENIPTV_XTREAM_USER"), let pass = value("OPENIPTV_XTREAM_PASS") {
    await check(IPTVSource(name: "Xtream", kind: .xtream(server: server.server, username: user, password: pass)))
}
if let raw = value("OPENIPTV_M3U_URL"), let url = URL(string: raw) {
    await check(IPTVSource(name: "M3U", kind: .m3u(playlist: url, guide: value("OPENIPTV_M3U_GUIDE").flatMap(URL.init(string:)))))
}
if let portal = value("OPENIPTV_STALKER_PORTAL").flatMap(StalkerProvider.normalisePortal),
   let mac = value("OPENIPTV_STALKER_MAC").flatMap(StalkerProvider.normaliseMAC) {
    await check(IPTVSource(name: "Stalker", kind: .stalker(portal: portal, mac: mac)))
}

let deviceId = "openiptv-smoke"
var emby: EmbyAccount?

// Dev-only modes for testing the app with a real account without its
// password ever reaching the app or disk: `session` signs in with Emby
// Connect and writes the session (JSON) to stdout for a pipe; `logout`
// reads that session from stdin and ends it on the server.
if value("OPENIPTV_SMOKE_MODE") == "logout" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let account = try? JSONDecoder().decode(EmbyAccount.self, from: data) {
        await EmbyClient(account: account, deviceId: deviceId).logout()
    }
    exit(0)
}
// `perf`: what a tap and a seek cost on the real server, using a session
// from `session` (stdin). Titles to try in OPENIPTV_SMOKE_TITLES, separated
// by ";". Prints timings, sizes and bitrates only.
if value("OPENIPTV_SMOKE_MODE") == "perf" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let account = try? JSONDecoder().decode(EmbyAccount.self, from: data) else { print("perf: no session"); exit(1) }
    let client = EmbyClient(account: account, deviceId: deviceId)

    /// Time to the first byte and to `length` bytes of a range, plus the file size.
    func fetch(_ url: URL, headers: [String], from offset: Int64, length: Int64, session: URLSession) async
        -> (first: Double, all: Double, bytes: Int, total: Int64?, status: Int)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        for header in headers {
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
        }
        let start = Date()
        guard let (stream, response) = try? await session.bytes(for: request) else { return nil }
        var first: Double?
        var count = 0
        do {
            for try await _ in stream {
                if first == nil { first = Date().timeIntervalSince(start) }
                count += 1
                if count >= length { break }
            }
        } catch {}
        let http = response as? HTTPURLResponse
        let total = http?.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last.flatMap { Int64($0) } }
        return (first ?? 0, Date().timeIntervalSince(start), count, total, http?.statusCode ?? 0)
    }
    func s(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

    for title in (value("OPENIPTV_SMOKE_TITLES") ?? "The Goonies").split(separator: ";").map(String.init) {
        print("\n== \(title)")
        var t = Date()
        let found = (try? await client.search(title, cardWidth: 300)) ?? []
        print("  search          \(found.count) results in \(ms(t))")
        guard let card = found.first(where: { $0.kind == "Movie" }) ?? found.first(where: { $0.kind == "Episode" }) ?? found.first
        else { continue }
        t = Date()
        guard let playback = try? await client.playback(itemId: card.id, kind: card.kind) else { print("  resolve failed"); continue }
        print("  resolve         \(playback.method) in \(ms(t)) · \(card.kind) · bitrate \(playback.bitrate.map { String(format: "%.1f Mbps", Double($0) / 1e6) } ?? "?")")
        t = Date()
        let info = try? await client.playbackInfo(playback.itemId, startSeconds: nil)
        let width = info?.MediaSources?.first?.videoWidth
        print("  playbackinfo    alone in \(ms(t)) · video width \(width.map(String.init) ?? "?") · container \(info?.MediaSources?.first?.Container ?? "?")")

        // Opening: a new connection (DNS, TCP, TLS) for the first 512 KB.
        let fresh = URLSession(configuration: .ephemeral)
        guard let open = await fetch(playback.url, headers: playback.headers, from: 0, length: 524_288, session: fresh) else {
            print("  open            failed"); continue
        }
        let size = open.total ?? 0
        print("  open            HTTP \(open.status) first byte \(s(open.first)), 512 KB in \(s(open.all)) · file \(String(format: "%.2f GB", Double(size) / 1e9))")
        // Throughput: 16 MB from the start, same connection.
        if let speed = await fetch(playback.url, headers: playback.headers, from: 524_288, length: 16_777_216, session: fresh) {
            print("  throughput      \(String(format: "%.0f Mbps", Double(speed.bytes) * 8 / max(speed.all, 0.001) / 1e6)) (16 MB in \(s(speed.all)))")
        }
        // Seeks: a range far into the file, reusing the connection, then on a new one.
        var reused: [Double] = [], newConnection: [Double] = []
        for _ in 0..<5 where size > 50_000_000 {
            let at = Int64.random(in: 10_000_000...(size - 10_000_000))
            if let r = await fetch(playback.url, headers: playback.headers, from: at, length: 2_097_152, session: fresh) { reused.append(r.first) }
            if let r = await fetch(playback.url, headers: playback.headers, from: at, length: 2_097_152, session: URLSession(configuration: .ephemeral)) {
                newConnection.append(r.first)
            }
        }
        func summary(_ values: [Double]) -> String {
            values.isEmpty ? "—" : "median \(s(values.sorted()[values.count / 2])), worst \(s(values.max()!))"
        }
        print("  seek, same conn first byte \(summary(reused))")
        print("  seek, new conn  first byte \(summary(newConnection))")
        // The stream without a media source id (could start before PlaybackInfo answers).
        if var parts = URLComponents(url: playback.url, resolvingAgainstBaseURL: false) {
            parts.queryItems = parts.queryItems?.filter { $0.name != "MediaSourceId" && $0.name != "PlaySessionId" }
            if let url = parts.url, let r = await fetch(url, headers: playback.headers, from: 0, length: 65_536, session: fresh) {
                print("  no source id    HTTP \(r.status), first byte \(s(r.first))")
            }
        }
        // ffmpeg (inside libmpv) opening it: headers, index, first video packet.
        if let ffprobe = value("OPENIPTV_SMOKE_FFPROBE") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffprobe)
            let headerArg = playback.headers.map { $0 + "\r\n" }.joined()
            task.arguments = ["-v", "error", "-headers", headerArg, "-select_streams", "v:0", "-show_entries", "stream=codec_name,width",
                              "-read_intervals", "%+#1", "-of", "csv=p=0", playback.url.absoluteString]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            let begun = Date()
            try? task.run()
            task.waitUntilExit()
            print("  ffprobe open    \(s(Date().timeIntervalSince(begun))) (exit \(task.terminationStatus))")
        }
        // A server-converted version: how long until its first video segment.
        let converted = client.hlsURL(playback.itemId, mediaSourceId: playback.mediaSourceId ?? playback.itemId,
                                      playSessionId: playback.playSessionId, start: 600, bitrate: 8_000_000)
        t = Date()
        var request = URLRequest(url: converted)
        request.timeoutInterval = 60
        if let (master, _) = try? await fresh.data(for: request),
           let variant = String(decoding: master, as: UTF8.self).split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
           let variantURL = URL(string: String(variant), relativeTo: converted) {
            var vr = URLRequest(url: variantURL)
            vr.timeoutInterval = 60
            if let (list, _) = try? await fresh.data(for: vr),
               let segment = String(decoding: list, as: UTF8.self).split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
               let segmentURL = URL(string: String(segment), relativeTo: variantURL) {
                var sr = URLRequest(url: segmentURL)
                sr.timeoutInterval = 60
                let ok = (try? await fresh.data(for: sr)) != nil
                print("  converted       first segment \(ok ? "after" : "failed after") \(ms(t))")
            } else { print("  converted       no segment list after \(ms(t))") }
        } else { print("  converted       no playlist after \(ms(t))") }
    }
    exit(0)
}
// `survey`: what an Xtream provider's live lineup looks like, to design
// grouping and source ranking: catch-up support, categories, name
// prefixes and quality tags, duplicates, PPV and event naming. Prints
// names and counts only, never the server, login or stream addresses.
if value("OPENIPTV_SMOKE_MODE") == "survey" {
    guard let server = value("OPENIPTV_XTREAM_URL").flatMap({ XtreamProvider.parse($0.split(separator: " ").first.map(String.init) ?? $0) }),
          let user = value("OPENIPTV_XTREAM_USER"), let pass = value("OPENIPTV_XTREAM_PASS") else { print("survey: no Xtream login"); exit(1) }
    func api(_ action: String) async -> (Data?, Double) {
        var parts = URLComponents(url: server.server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "username", value: user), .init(name: "password", value: pass), .init(name: "action", value: action)]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 120
        let start = Date()
        let data = try? await URLSession.shared.data(for: request).0
        return (data, Date().timeIntervalSince(start))
    }
    let (categoryData, categoryTime) = await api("get_live_categories")
    let (streamData, streamTime) = await api("get_live_streams")
    let categories = (categoryData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? [])
    let streams = (streamData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? [])
    func str(_ any: Any?) -> String { any.map { "\($0)" } ?? "" }
    let categoryName = Dictionary(categories.map { (str($0["category_id"]), str($0["category_name"])) }, uniquingKeysWith: { a, _ in a })
    print("== Lineup")
    print("  categories     \(categories.count) in \(String(format: "%.1f", categoryTime)) s")
    print("  channels       \(streams.count) in \(String(format: "%.1f", streamTime)) s (\((streamData?.count ?? 0) / 1_000_000) MB)")
    print("  with guide id  \(streams.filter { !str($0["epg_channel_id"]).isEmpty && str($0["epg_channel_id"]) != "<null>" }.count)")
    let archived = streams.filter { str($0["tv_archive"]) == "1" }
    var durations: [String: Int] = [:]
    for s in archived { durations[str(s["tv_archive_duration"]), default: 0] += 1 }
    print("\n== Catch-up")
    print("  channels with archive \(archived.count)")
    print("  days kept      \(durations.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) d: \($0.value)" }.joined(separator: ", "))")
    var archivedByCategory: [String: Int] = [:]
    for s in archived { archivedByCategory[categoryName[str(s["category_id"])] ?? "?", default: 0] += 1 }
    print("  by category    \(archivedByCategory.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) (\($0.value))" }.joined(separator: "; "))")

    var perCategory: [String: Int] = [:]
    for s in streams { perCategory[categoryName[str(s["category_id"])] ?? "?", default: 0] += 1 }
    print("\n== Categories (largest 70)")
    for (name, count) in perCategory.sorted(by: { $0.value > $1.value }).prefix(70) { print("  \(count)\t\(name)") }

    let names = streams.map { str($0["name"]) }
    var prefixes: [String: Int] = [:]
    for name in names {
        if let cut = name.firstIndex(where: { $0 == ":" || $0 == "|" }), name.distance(from: name.startIndex, to: cut) <= 12 {
            prefixes[name[..<cut].trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
    }
    print("\n== Name prefixes (before : or |)")
    print("  " + prefixes.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    var tags: [String: Int] = [:]
    let known = ["HD", "FHD", "UHD", "4K", "SD", "HEVC", "H265", "1080P", "720P", "60FPS", "BACKUP", "RAW", "VIP", "PLUS", "EAST", "WEST", "ᴴᴰ", "ᵁᴴᴰ", "ᶠᴴᴰ", "ʀᴀᴡ", "(S)", "(B)"]
    for name in names {
        let upper = name.uppercased()
        for tag in known where upper.contains(tag) { tags[tag, default: 0] += 1 }
    }
    print("\n== Quality and variant tags")
    print("  " + tags.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

    // Same channel under several names: strip prefix, tags and symbols.
    func base(_ name: String) -> String {
        var n = name
        if let cut = n.firstIndex(where: { $0 == ":" || $0 == "|" }), n.distance(from: n.startIndex, to: cut) <= 12 { n = String(n[n.index(after: cut)...]) }
        n = n.uppercased()
        for tag in known { n = n.replacingOccurrences(of: tag, with: " ") }
        n = n.replacingOccurrences(of: "[^A-Z0-9 ]", with: " ", options: .regularExpression)
        return n.split(separator: " ").joined(separator: " ")
    }
    var groups: [String: Int] = [:]
    for name in names { groups[base(name), default: 0] += 1 }
    let dupes = groups.filter { $0.value > 1 && !$0.key.isEmpty }
    print("\n== Duplicates after cleaning names")
    print("  \(dupes.count) names appear more than once, covering \(dupes.values.reduce(0, +)) channels")
    print("  " + dupes.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))

    print("\n== Event / PPV categories and samples")
    let eventWords = ["PPV", "EVENT", "LIVE", "UFC", "BOX", "NFL", "NBA", "MLB", "NHL", "SPORT", "PEACOCK", "ESPN+", "DAZN", "FLO"]
    let eventCategories = categoryName.filter { entry in eventWords.contains { entry.value.uppercased().contains($0) } }
    for (id, name) in eventCategories.sorted(by: { $0.value < $1.value }).prefix(40) {
        let inCategory = streams.filter { str($0["category_id"]) == id }.map { str($0["name"]) }
        print("  [\(name)] \(inCategory.count) channels: " + inCategory.prefix(8).joined(separator: " · "))
    }
    print("\n== Separator / placeholder names")
    print("  " + names.filter { $0.contains("---") || $0.contains("###") || $0.contains("===") || $0.uppercased().contains("NO EVENT") }.prefix(20).joined(separator: " · "))
    exit(0)
}
if value("OPENIPTV_SMOKE_MODE") == "session" {
    guard let user = value("OPENIPTV_EMBY_CONNECT_USER"), let pass = value("OPENIPTV_EMBY_CONNECT_PASS"),
          let session = try? await EmbyClient.connectLogin(email: user, password: pass),
          let server = session.servers.first,
          let account = try? await EmbyClient.exchange(server, session: session, deviceId: deviceId),
          let json = try? JSONEncoder().encode(account)
    else { exit(1) }
    FileHandle.standardOutput.write(json)
    exit(0)
}
do {
    if let user = value("OPENIPTV_EMBY_CONNECT_USER"), let pass = value("OPENIPTV_EMBY_CONNECT_PASS") {
        print("\n== Emby Connect")
        let started = Date()
        let session = try await EmbyClient.connectLogin(email: user, password: pass)
        print("  connect       \(session.servers.count) server(s) in \(ms(started))")
        if let server = session.servers.first {
            let exchangeStart = Date()
            emby = try await EmbyClient.exchange(server, session: session, deviceId: deviceId)
            print("  exchange      \(server.name) in \(ms(exchangeStart))")
        }
    } else if let url = value("OPENIPTV_EMBY_URL").flatMap(EmbyClient.normalise), let user = value("OPENIPTV_EMBY_USER") {
        print("\n== Emby (\(url.host() ?? "?"))")
        let started = Date()
        emby = try await EmbyClient.login(server: url, username: user, password: value("OPENIPTV_EMBY_PASS") ?? "", deviceId: deviceId)
        print("  login         \(emby!.serverName) in \(ms(started))")
    }
    if let emby {
        let client = EmbyClient(account: emby, deviceId: deviceId)
        let started = Date()
        let home = try await client.homeSources()
        print("  home          \(home.watching.count) watching, \(home.nextUp.count) next up, \(home.played.count) played, \(home.added.count) added in \(ms(started))")
        let withIds = (home.watching + home.added).filter { $0.kind == "Movie" || $0.kind == "Series" }
        print("    provider ids  \(withIds.filter { $0.imdb != nil }.count) IMDb, \(withIds.filter { $0.tmdb != nil }.count) TMDb of \(withIds.count) movies/shows")
        if let seed = (home.played + home.watching).first.map({ $0.seriesId ?? $0.id }) {
            let similarStart = Date()
            let similar = await client.similar(to: seed)
            print("  similar       \(similar.count) titles in \(ms(similarStart))")
        }
        let homeCards = (home.watching + home.added).map { client.card(for: $0, landscape: false, width: 360) }
        if let card = homeCards.first(where: \.playable) {
            let playStart = Date()
            let playback = try await client.playback(itemId: card.id)
            print("  playback      \(playback.title) from \(playback.startSeconds.map { "\(Int($0)) s" } ?? "start") via \(playback.url.host() ?? "?") (\(playback.method), \(playback.url.scheme ?? "?")) in \(ms(playStart))")
            // Diagnose: what the server says about this item, and how each
            // way of opening it answers (status and type only, never URLs).
            if let info = try? await client.playbackInfo(playback.itemId, startSeconds: nil), let source = info.MediaSources?.first {
                let remote = source.Path.map { $0.hasPrefix("http") ? "http path" : "local path" } ?? "no path"
                print("  playbackinfo  protocol \(source.Protocol ?? "?"), container \(source.Container ?? "?"), \(remote), directPlay \(source.SupportsDirectPlay.map(String.init) ?? "?"), directStream \(source.SupportsDirectStream.map(String.init) ?? "?"), transcodeUrl \(source.TranscodingUrl == nil ? "no" : "yes"), sourceId \(source.Id == playback.itemId ? "= item" : "differs")")
            } else {
                print("  playbackinfo  failed")
            }
            func probe(_ label: String, _ url: URL, _ headers: [String: String]) async {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                let start = Date()
                do {
                    let (bytes, response) = try await URLSession.shared.data(for: request)
                    let http = response as? HTTPURLResponse
                    let body = (http?.statusCode ?? 0) >= 400 ? " body: " + String(decoding: bytes.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: " ") : ""
                    print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) HTTP \(http?.statusCode ?? 0), \(http?.value(forHTTPHeaderField: "Content-Type") ?? "?"), \(bytes.count) bytes, \(response.url?.host() == url.host() ? "same host" : "redirected") in \(ms(start))\(body)")
                } catch {
                    print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(SourceError.wrap(error).localizedDescription)")
                }
            }
            let token = ["X-Emby-Token": playback.url.query()?.components(separatedBy: "&").first { $0.hasPrefix("api_key=") }?.replacingOccurrences(of: "api_key=", with: "") ?? ""]
            let headerDict = Dictionary(uniqueKeysWithValues: playback.headers.compactMap { h -> (String, String)? in
                let p = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return p.count == 2 ? (p[0], p[1]) : nil
            })
            await probe("chosen (\(playback.method))", playback.url, headerDict)
            await probe("chosen + token header", playback.url, headerDict.merging(token) { a, _ in a })
            // Open the chosen stream with ffmpeg (the engine inside libmpv)
            // and list its tracks: proof it decodes, not just that it answers.
            if let ffprobe = value("OPENIPTV_SMOKE_FFPROBE") {
                func tracks(_ label: String, _ url: URL, _ headers: [String]) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: ffprobe)
                    var args = ["-v", "error", "-rw_timeout", "15000000", "-show_entries", "stream=codec_type,codec_name,width,height", "-of", "csv=p=0"]
                    if !headers.isEmpty { args += ["-headers", headers.joined(separator: "\r\n") + "\r\n"] }
                    task.arguments = args + [url.absoluteString]
                    let out = Pipe(), err = Pipe()
                    task.standardOutput = out
                    task.standardError = err
                    let start = Date()
                    do { try task.run() } catch { print("  ffprobe       couldn't start"); return }
                    task.waitUntilExit()
                    let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .split(separator: "\n").map { $0.replacingOccurrences(of: ",", with: " ") }.prefix(3).joined(separator: "; ")
                    let failed = task.terminationStatus != 0
                    print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(failed ? "✗ couldn't open (exit \(task.terminationStatus))" : found) in \(ms(start))")
                    if failed { failures += 1 }
                }
                tracks("decode (\(playback.method))", playback.url, playback.headers)
                if let hls = playback.fallbacks.last { tracks("decode converted hls", hls, playback.fallbackHeaders) }
            }
            let ms0 = playback.mediaSourceId ?? playback.itemId
            await probe("plain stream", client.directStreamURL(playback.itemId, mediaSourceId: ms0, playSessionId: nil), [:])
            await probe("plain stream + header", client.directStreamURL(playback.itemId, mediaSourceId: ms0, playSessionId: nil), token)
            await probe("hls master", client.hlsURL(playback.itemId, mediaSourceId: ms0, playSessionId: playback.playSessionId, start: nil), [:])
            await probe("hls master + header", client.hlsURL(playback.itemId, mediaSourceId: ms0, playSessionId: playback.playSessionId, start: nil), token)
        }
        let indexStart = Date()
        let entries = try await client.libraryIndex()
        print("  index         \(entries.count) movies and shows in \(ms(indexStart))")
        let buildStart = Date()
        let corpus = SearchCorpus(entries, name: \.name)
        print("  index build   \(ms(buildStart))")
        let term = value("OPENIPTV_SMOKE_SEARCH") ?? "forensic files"
        var previous: SearchCorpus<LibraryEntry>.Match?
        var typed = ""
        var slowest = 0.0
        for character in term {
            typed.append(character)
            let keyStart = Date()
            previous = corpus.search(typed, refining: previous)
            slowest = max(slowest, Date().timeIntervalSince(keyStart))
        }
        let top = previous?.ranked.prefix(3).map { corpus.items[$0].name } ?? []
        print("  search        \"\(term)\" typed key by key, slowest keystroke \(Int(slowest * 1000)) ms → \(previous?.ranked.count ?? 0) matches: \(top.joined(separator: ", "))")
        let serverStart = Date()
        let cards = try await client.search(term, cardWidth: 200)
        print("  server search \(cards.count) results (\(cards.filter { $0.kind == "Episode" }.count) episodes) in \(ms(serverStart))")
        await client.logout()
        print("  logged out    session ended on the server")
    }
} catch {
    failures += 1
    print("  ✗ \(SourceError.wrap(error).localizedDescription)")
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
