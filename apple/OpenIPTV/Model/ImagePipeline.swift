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
    private var inFlight: [URL: Load] = [:]

    private struct Load {
        let task: Task<UIImage, Error>
        let request: RequestHandle
    }

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

    /// Loads these (up to eight at a time) so they're ready when shown;
    /// not while something plays (the stream comes first). Low priority:
    /// a picture on screen waiting goes first.
    func prefetch(_ urls: [URL]) async {
        guard !PlaybackActivity.isPlaying else { return }
        await withTaskGroup(of: Void.self) { group in
            var queue = urls[...]
            for _ in 0..<8 {
                guard let url = queue.popFirst() else { break }
                group.addTask { _ = try? await self.image(for: url, visible: false) }
            }
            for await _ in group {
                if let url = queue.popFirst() { group.addTask { _ = try? await self.image(for: url, visible: false) } }
            }
        }
    }

    /// An image already decoded, without waiting (rows scrolling back in).
    nonisolated func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The picture, decoded for display. `visible`: something on screen is
    /// waiting for it, so it goes ahead of pictures fetched ahead of time
    /// (and lifts one of those already under way). A view that goes away
    /// doesn't cancel the load: it's kept for when the view comes back.
    func image(for url: URL, visible: Bool = true) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] {
            if visible { running.request.raise() }
            return try await running.task.value
        }
        let session = session, memory = memory
        let request = RequestHandle(priority: visible ? URLSessionTask.highPriority : URLSessionTask.lowPriority)
        let load = Task<UIImage, Error>(priority: visible ? .userInitiated : .utility) {
            let (data, response) = try await request.fetch(url, with: session)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            let ready = await image.byPreparingForDisplay() ?? image
            let bytes = ready.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            memory.setObject(ready, forKey: url as NSURL, cost: bytes)
            return ready
        }
        inFlight[url] = Load(task: load, request: request)
        defer { inFlight[url] = nil }
        return try await load.value
    }
}

/// One download whose priority can be raised while it's under way (the
/// async URLSession calls don't expose their task).
private final class RequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var priority: Float
    private var task: URLSessionDataTask?

    init(priority: Float) { self.priority = priority }

    func raise() {
        lock.withLock {
            priority = URLSessionTask.highPriority
            task?.priority = URLSessionTask.highPriority
        }
    }

    func fetch(_ url: URL, with session: URLSession) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                }
            }
            lock.withLock {
                task.priority = priority
                self.task = task
            }
            task.resume()
        }
    }
}
