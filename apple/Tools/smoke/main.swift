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
        let rows = try await client.home(cardWidth: 360)
        print("  home          \(rows.count) rows in \(ms(started))")
        for row in rows.prefix(4) {
            let covers = row.cards.filter { !$0.images.isEmpty }.count
            print("    \(row.title.prefix(30).padding(toLength: 30, withPad: " ", startingAt: 0)) \(row.cards.count) cards, \(covers) with covers, \(row.shape)")
        }
        if let card = rows.flatMap(\.cards).first(where: \.playable) {
            let playStart = Date()
            let playback = try await client.playback(itemId: card.id)
            print("  playback      \(playback.title) from \(playback.startSeconds.map { "\(Int($0)) s" } ?? "start") via \(playback.url.host() ?? "?") in \(ms(playStart))")
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
