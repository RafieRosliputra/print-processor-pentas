import Foundation
import CoreGraphics
import ImageIO

/// Thread-safe decoded-image cache keyed by path + modification time, shared
/// between the compositor and the preview controller so overlay/background
/// images are never re-decoded on the main thread on every navigation.
public final class DecodedImageCache {
    public static let shared = DecodedImageCache()

    private struct Entry {
        let mtime: Date
        let image: CGImage
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "com.johorstudio.printprocessor.layerdecode", qos: .userInitiated)

    public init() {}

    /// Return the cached image only when the file's mtime still matches.
    public func cached(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path] else { return nil }
        guard Self.mtime(path) == entry.mtime else {
            entries.removeValue(forKey: path)
            return nil
        }
        return entry.image
    }

    /// Decode on the caller's thread (use from a background queue); caches the
    /// result keyed by path + mtime.
    public func decode(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let image = cached(path) { return image }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        store(path: path, image: image)
        return image
    }

    /// Decode on a background queue and deliver the result on the main thread.
    public func load(_ path: String, completion: @escaping (CGImage?) -> Void) {
        guard !path.isEmpty else { completion(nil); return }
        if let image = cached(path) {
            completion(image)
            return
        }
        queue.async { [weak self] in
            let image = self?.decode(path)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Drop the cached entry for one path (e.g. after the file changes).
    public func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: path)
    }

    public func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    private func store(path: String, image: CGImage) {
        guard let mtime = Self.mtime(path) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[path] = Entry(mtime: mtime, image: image)
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
