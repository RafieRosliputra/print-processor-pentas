import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Thread-safe preview cache for layer-4 photos.
///
/// - Previews (downscaled) live in a RAM LRU capped at `ramCapBytes`.
/// - Evicted / not-yet-decoded previews are backed by a per-process temp disk
///   cache (`NSTemporaryDirectory()/PrintProcessorCache-<pid>`), which is
///   deleted on normal quit and reclaimed from crashed runs at next launch.
/// - All decoding happens on the caller's (background) queue; this type never
///   forces work onto the main thread. `prime` warms the first N files eagerly
///   and builds the rest on a low-priority utility queue.
/// - `loadOriginal` always decodes the original file at full quality and is
///   never cached, so export never uses a preview.
public final class ImageCache {
    /// Longest edge used for editing previews.
    public static let previewMaxDimension: CGFloat = 2048

    /// Number of files decoded eagerly on import before the background build.
    public static let eagerCount = 10

    /// Number of images prefetched ahead of / behind the current one.
    public static let prefetchAhead = 3
    public static let prefetchBehind = 2

    private var ramCapBytes: Int
    private let diskRoot: URL

    private let lock = NSLock()
    private var entries: [String: CGImage] = [:]
    private var byteSizes: [String: Int] = [:]
    private var order: [String] = []       // least-recently-used at index 0
    private var currentBytes = 0
    private var prefetchGeneration = 0

    private let decodeQueue = DispatchQueue(label: "com.johorstudio.printprocessor.decode", qos: .userInitiated)
    private let utilityQueue = DispatchQueue(label: "com.johorstudio.printprocessor.prefetch", qos: .utility)

    public init(ramCapBytes: Int) {
        self.ramCapBytes = max(1, ramCapBytes)
        self.diskRoot = Self.diskCacheRoot()
        try? FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    // MARK: - Static disk management

    /// Per-process disk cache directory.
    public static func diskCacheRoot(in base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent("PrintProcessorCache-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Delete `PrintProcessorCache-*` directories left behind by crashed runs.
    /// The current process's own directory is preserved.
    public static func removeStaleDiskCaches(in base: URL = FileManager.default.temporaryDirectory) {
        let current = "PrintProcessorCache-\(ProcessInfo.processInfo.processIdentifier)"
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        for item in items where item.hasPrefix("PrintProcessorCache-") && item != current {
            try? fm.removeItem(at: base.appendingPathComponent(item))
        }
    }

    /// Delete every disk cache directory (normal quit).
    public static func removeAllDiskCaches(in base: URL = FileManager.default.temporaryDirectory) {
        removeStaleDiskCaches(in: base)
        try? FileManager.default.removeItem(at: diskCacheRoot(in: base))
    }

    // MARK: - RAM LRU

    private func ramKey(_ url: URL, maxDimension: CGFloat) -> String {
        "\(url.standardizedFileURL.path)#\(Int(maxDimension))"
    }

    private func lookup(_ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let image = entries[key] else { return nil }
        touch(key)
        return image
    }

    private func store(_ key: String, image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        let size = image.bytesPerRow * image.height
        entries[key] = image
        byteSizes[key] = size
        currentBytes += size
        touch(key)
        evictLocked()
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
    }

    private func evictLocked() {
        while currentBytes > ramCapBytes, let oldest = order.first {
            order.removeFirst()
            if let image = entries.removeValue(forKey: oldest) {
                let size = byteSizes.removeValue(forKey: oldest) ?? (image.bytesPerRow * image.height)
                currentBytes -= size
            }
        }
    }

    /// Current RAM usage in bytes (for tests / status).
    public func ramUsageBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return currentBytes
    }

    /// Whether a preview is currently held in RAM.
    public func isCachedInRAM(_ url: URL, maxDimension: CGFloat = previewMaxDimension) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[ramKey(url, maxDimension: maxDimension)] != nil
    }

    /// Update the RAM cap and evict immediately if over it.
    public func setRAMCap(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        ramCapBytes = max(1, bytes)
        evictLocked()
    }

    // MARK: - Decode

    /// Decode a downscaled preview (RAM → disk → original), never cached at full
    /// quality. Must be called off the main thread.
    public func preview(url: URL, maxDimension: CGFloat = previewMaxDimension) -> CGImage? {
        let key = ramKey(url, maxDimension: maxDimension)
        if let image = lookup(key) { return image }

        let file = diskRoot.appendingPathComponent(diskFileName(for: url, maxDimension: maxDimension))
        if FileManager.default.fileExists(atPath: file.path), let image = decodePNG(at: file) {
            store(key, image: image)
            return image
        }

        guard let image = decodeThumbnail(url: url, maxDimension: maxDimension) else { return nil }
        store(key, image: image)

        let path = file.path
        utilityQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.writePNG(image, to: path)
        }
        return image
    }

    /// Decode the ORIGINAL file at full quality. Never cached; export must call
    /// this (off the main thread) so it always uses original pixels.
    public func loadOriginal(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Warm / prefetch (background only)

    /// Warm the cache: decode the first `firstCount` files eagerly (user-initiated
    /// queue) and build the rest on a low-priority utility queue. Call from the
    /// main thread; no decode happens on the caller's thread.
    public func prime(files: [URL], firstCount: Int = ImageCache.eagerCount) {
        lock.lock(); prefetchGeneration += 1; lock.unlock()
        let gen = prefetchGeneration

        let head = Array(files.prefix(firstCount))
        let tail = Array(files.dropFirst(firstCount))

        for url in head {
            decodeQueue.async { [weak self] in
                guard let self = self, self.currentGeneration() == gen else { return }
                _ = self.preview(url: url)
            }
        }
        for url in tail {
            utilityQueue.async { [weak self] in
                guard let self = self, self.currentGeneration() == gen else { return }
                _ = self.preview(url: url)
            }
        }
    }

    /// Prefetch the next `prefetchAhead` and previous `prefetchBehind` images on
    /// a utility queue.
    public func prefetch(urls: [URL], around index: Int) {
        guard !urls.isEmpty else { return }
        let gen = currentGeneration()
        let lower = max(0, index - Self.prefetchBehind)
        let upper = min(urls.count - 1, index + Self.prefetchAhead)
        guard lower <= upper else { return }
        for i in lower...upper {
            let url = urls[i]
            utilityQueue.async { [weak self] in
                guard let self = self, self.currentGeneration() == gen else { return }
                _ = self.preview(url: url)
            }
        }
    }

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return prefetchGeneration
    }

    // MARK: - Disk helpers

    private func diskFileName(for url: URL, maxDimension: CGFloat) -> String {
        let source = "\(url.standardizedFileURL.path)#\(Int(maxDimension))"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func decodeThumbnail(url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func decodePNG(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writePNG(_ image: CGImage, to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
