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
    /// hidden files/folders are skipped. Symlinked directory loops are guarded by
    /// a visited set of resolved (symlink-free) paths.
    static func collectFiles(from urls: [URL]) -> [URL] {
        naturalSorted(DirectoryScan.collectFiles(from: urls, isIncluded: isSupported))
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
