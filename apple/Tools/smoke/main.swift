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
