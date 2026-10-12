import UIKit

/// Loads and decodes images off the main thread. Image URLs include Emby's
/// image tag, so they never change for the same picture: a large on-disk
/// URLCache keeps covers instant after the first view.
actor ImagePipeline {
    static let shared = ImagePipeline()

    // NSCache is thread-safe; read directly for images already decoded.
    private nonisolated(unsafe) let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    /// Loads under way: a picture asked for twice at once (a row and its
    /// prefetch, two rows with the same title) downloads and decodes once.
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        // By decoded size (a 4K backdrop is 30 MB, a poster under 1 MB), so
        // a page of backdrops can't push out every poster, or the memory.
        memory.totalCostLimit = 300 << 20
        memory.countLimit = 800
    }

    /// Loads these (up to eight at a time) so they're ready when shown.
    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = urls[...]
            for _ in 0..<8 {
                guard let url = queue.popFirst() else { break }
                group.addTask { _ = try? await self.image(for: url) }
            }
            for await _ in group {
                if let url = queue.popFirst() { group.addTask { _ = try? await self.image(for: url) } }
            }
        }
    }

    /// An image already decoded, without waiting (rows scrolling back in).
    nonisolated func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The picture, decoded for display. A view that goes away doesn't
    /// cancel the load: it's kept for when the view comes back.
    func image(for url: URL) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] { return try await running.value }
        let session = session, memory = memory
        let load = Task<UIImage, Error> {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            let ready = await image.byPreparingForDisplay() ?? image
            let bytes = ready.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            memory.setObject(ready, forKey: url as NSURL, cost: bytes)
            return ready
        }
        inFlight[url] = load
        defer { inFlight[url] = nil }
        return try await load.value
    }
}
