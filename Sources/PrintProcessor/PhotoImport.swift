import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PrintProcessorCore

/// Helpers for collecting supported photo files and decoding downscaled previews.
enum PhotoImport {
    /// Extensions accepted for layer 4 (case-insensitive).
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "webp", "png"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && supportedExtensions.contains(ext)
    }

    /// Expand a mix of files and folders into a flat, de-duplicated, natural-sorted
    /// list of supported photo file URLs. Folders are scanned recursively and
    /// hidden files/folders are skipped.
    static func collectFiles(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for url in urls {
            collect(from: url, into: &result, seen: &seen)
        }
        return naturalSorted(result)
    }

    /// Depth-first, recursive collection of supported photos under `url`.
    private static func collect(from url: URL, into result: inout [URL], seen: inout Set<String>) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children {
                collect(from: child, into: &result, seen: &seen)
            }
        } else if isSupported(url) {
            add(url, to: &result, seen: &seen)
        }
    }

    private static func add(_ url: URL, to result: inout [URL], seen: inout Set<String>) {
        let key = url.standardizedFileURL.path
        if seen.insert(key).inserted {
            result.append(url)
        }
    }

    /// Sort file URLs by natural filename order.
    static func naturalSorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            NaturalSort.isOrderedBefore($0.lastPathComponent, $1.lastPathComponent)
        }
    }

    /// Decode a downscaled preview CGImage off the caller's thread using ImageIO.
    /// `maxDimension` bounds the longest edge in pixels.
    static func decodePreview(url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size of the decoded preview (falls back to file header).
    static func previewPixelSize(url: URL, maxDimension: CGFloat) -> CGSize {
        guard let image = decodePreview(url: url, maxDimension: maxDimension) else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }
}
