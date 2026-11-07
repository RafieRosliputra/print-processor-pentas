import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Renders the layer-2 PSD text through an injectable `PhotoshopRunnerProtocol`
/// and caches the result so the same text is never re-rendered. Cache key is a
/// hash of (PSD path + mtime + text).
public final class PSDTextRenderer {
    public let runner: PhotoshopRunnerProtocol
    public let cacheDirectory: String
    public let layerName: String

    public init(runner: PhotoshopRunnerProtocol, cacheDirectory: String, layerName: String = "TEXT") {
        self.runner = runner
        self.cacheDirectory = cacheDirectory
        self.layerName = layerName
    }

    /// Render `text` onto the PSD and return the trimmed PNG. Same text + same
    /// PSD mtime returns a cache hit (runner not called).
    public func render(psdPath: String, text: String) -> CGImage? {
        guard let mtime = Self.modificationDate(psdPath) else { return nil }
        let key = Self.cacheKey(psdPath: psdPath, mtime: mtime, text: text)
        let cacheURL = URL(fileURLWithPath: cacheDirectory).appendingPathComponent(key + ".png")

        if let cached = Self.decode(cacheURL) {
            return cached
        }

        guard runner.renderPNG(psdPath: psdPath, text: text, layerName: layerName, outputPNG: cacheURL.path),
              let image = Self.decode(cacheURL) else {
            return nil
        }
        return Self.trim(image)
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Stable FNV-1a 64-bit hash of `path|mtime|text` (hex).
    public static func cacheKey(psdPath: String, mtime: Date, text: String) -> String {
        let s = "\(psdPath)|\(mtime.timeIntervalSince1970)|\(text)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Crop away fully-transparent border rows/columns.
    public static func trim(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return image }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let row = height - 1 - y
            return pixels[row * bytesPerRow + x * 4 + 3]
        }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: rect) ?? image
    }
}

/// Wraps text into balanced lines (<= maxLines) for the layer-2 fit fallback.
public enum PSDTextFit {
    public static func wrap(_ text: String, maxLines: Int) -> String {
        guard maxLines > 1 else { return text }
        let words = text.split(separator: " ")
        guard words.count > maxLines else { return text }
        let perLine = (words.count + maxLines - 1) / maxLines
        var lines: [String] = []
        var i = 0
        while i < words.count {
            let end = min(i + perLine, words.count)
            lines.append(words[i..<end].joined(separator: " "))
            i = end
        }
        return lines.joined(separator: "\n")
    }
}

/// Renders layer-2 text wrapping (up to 3 lines) so its natural width fits the
/// box, leaving the final fit/align to the compositor.
public final class PSDTextLayerRenderer {
    public let textRenderer: PSDTextRenderer
    public let maxLines: Int
    public let minTextScale: Double

    public init(runner: PhotoshopRunnerProtocol, cacheDirectory: String,
                layerName: String = "TEXT", maxLines: Int = 3, minTextScale: Double = 0.4) {
        self.textRenderer = PSDTextRenderer(runner: runner, cacheDirectory: cacheDirectory, layerName: layerName)
        self.maxLines = max(1, maxLines)
        self.minTextScale = max(0.05, min(1, minTextScale))
    }

    /// Render text wrapping to <= maxLines, returning the trimmed image whose
    /// natural width best fits `boxWidth` pixels. Falls back to the unwrapped
    /// text on failure.
    public func render(psdPath: String, text: String, boxWidth: CGFloat) -> CGImage? {
        var fallback: CGImage?
        for lines in 1...maxLines {
            let candidate = PSDTextFit.wrap(text, maxLines: lines)
            guard let image = textRenderer.render(psdPath: psdPath, text: candidate) else { continue }
            if fallback == nil { fallback = image }
            if CGFloat(image.width) <= boxWidth { return image }
        }
        return fallback
    }
}
