import Foundation
import Observation

/// One IPTV subscription, in whichever format the provider gives out.
struct IPTVSource: Codable, Hashable, Identifiable {
    enum Kind: Codable, Hashable {
        /// Xtream Codes API: server, username, password.
        case xtream(server: URL, username: String, password: String)
        /// M3U playlist URL, optionally with an XMLTV guide URL.
        case m3u(playlist: URL, guide: URL?)
        /// Stalker / Ministra middleware portal, identified by MAC address.
        case stalker(portal: URL, mac: String)
    }

    var id = UUID()
    var name: String
    var kind: Kind

    var formatName: String {
        switch kind {
        case .xtream: "Xtream Codes"
        case .m3u: "M3U playlist"
        case .stalker: "Stalker portal"
        }
    }

    /// Same subscription, even if its password or name changed since.
    func isSameSubscription(as other: IPTVSource) -> Bool {
        switch (kind, other.kind) {
        case let (.xtream(a, userA, _), .xtream(b, userB, _)): a == b && userA == userB
        case let (.m3u(a, _), .m3u(b, _)): a == b
        case let (.stalker(a, macA), .stalker(b, macB)): a == b && macA == macB
        default: false
        }
    }

    /// Host only, for display. Never shows usernames, passwords or tokens.
    var safeDescription: String {
        switch kind {
        case let .xtream(server, _, _): server.host() ?? "Xtream server"
        case let .m3u(playlist, _): playlist.host() ?? "Playlist"
        case let .stalker(portal, _): portal.host() ?? "Portal"
        }
    }
}

/// An Emby sign-in. The password is never kept: only the session token the
/// server issues, which can be revoked from Emby's dashboard.
struct EmbyAccount: Codable, Hashable {
    var serverURL: URL
    var serverName: String
    var userId: String
    var userName: String
    var accessToken: String
}

/// The user's accounts, persisted only in the device Keychain.
@Observable
@MainActor
final class SourceStore {
    private(set) var emby: EmbyAccount?
    private(set) var iptv: [IPTVSource]

    /// Stable per-install identifier Emby uses to tell devices apart.
    let deviceId: String

    init() {
        emby = Keychain.load(EmbyAccount.self, for: "emby")
        iptv = Keychain.load([IPTVSource].self, for: "iptv") ?? []
        if let existing = Keychain.load(String.self, for: "deviceId") {
            deviceId = existing
        } else {
            deviceId = UUID().uuidString
            Keychain.save(deviceId, for: "deviceId")
        }
    }

    var isEmpty: Bool { emby == nil && iptv.isEmpty }

    func setEmby(_ account: EmbyAccount?) {
        emby = account
        Keychain.save(account, for: "emby")
    }

    #if DEBUG
    /// Debug builds only: use a session for this run without saving it.
    func useTemporaryEmby(_ account: EmbyAccount) {
        emby = account
    }
    #endif

    /// Adding a subscription that's already here updates it in place (new
    /// password, say) and keeps its id, so favourites still point at it.
    func add(_ source: IPTVSource) {
        if let index = iptv.firstIndex(where: { $0.isSameSubscription(as: source) }) {
            iptv[index].kind = source.kind
        } else {
            iptv.append(source)
        }
        Keychain.save(iptv, for: "iptv")
    }

    func remove(_ source: IPTVSource) {
        iptv.removeAll { $0.id == source.id }
        Keychain.save(iptv, for: "iptv")
    }

    /// Wipes every account, token and preference from this device.
    func forgetEverything() {
        Keychain.deleteAll()
        emby = nil
        iptv = []
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)
            .forEach { try? FileManager.default.removeItem(at: $0) }
        URLCache.shared.removeAllCachedResponses()
    }
}
