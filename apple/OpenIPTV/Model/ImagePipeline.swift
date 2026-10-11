import UIKit

/// Loads and decodes images off the main thread. Image URLs include Emby's
/// image tag, so they never change for the same picture: a large on-disk
/// URLCache keeps covers instant after the first view.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        memory.countLimit = 400
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

    func image(for url: URL) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        let ready = await image.byPreparingForDisplay() ?? image
        memory.setObject(ready, forKey: url as NSURL)
        return ready
    }
}
