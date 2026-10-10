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
