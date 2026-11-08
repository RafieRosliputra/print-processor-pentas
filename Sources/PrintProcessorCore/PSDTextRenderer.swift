import Foundation
import CoreGraphics
import CoreImage
import CoreText
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
    /// Measure the single-line typographic width of `text` with CoreText at
    /// `fontSize` (a proxy size; callers calibrate against the rendered width).
    public static func measureWidth(_ text: String, fontSize: CGFloat = 100, fontName: String = ".SFUI-Bold") -> CGFloat {
        let font = Compositor.resolveFont(name: fontName, size: fontSize)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    /// Greedy, width-aware wrap: append words while the line's measured width
    /// fits `maxWidth`; once the line budget is reached the remaining words are
    /// joined onto the final line. Units of `maxWidth` match `measureWidth`.
    public static func wrap(_ text: String, maxLines: Int, maxWidth: CGFloat) -> String {
        guard maxLines > 1 else { return text }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard words.count > 1 else { return text }
        var lines: [String] = []
        var current = ""
        var index = 0
        while index < words.count {
            let word = words[index]
            let candidate = current.isEmpty ? word : current + " " + word
            if measureWidth(candidate) <= maxWidth || current.isEmpty {
                current = candidate
                index += 1
            } else if lines.count + 1 >= maxLines {
                lines.append(words[index...].joined(separator: " "))
                index = words.count
                current = ""
            } else {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? text : lines.joined(separator: "\n")
    }
}

/// Renders layer-2 text wrapping width-aware (up to `maxLines`) so its natural
/// width fits the box, then shrinks the rendered result uniformly down to
/// `minTextScale` when it is still too large (wide or tall), leaving the final
/// fit/align to the compositor.
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

    /// Render text wrapping width-aware to <= maxLines and shrinking (uniformly,
    /// down to `minTextScale`) so the trimmed image fits `boxSize` (both width
    /// and height — a short box constrains the shrink too). Falls back to the
    /// unwrapped text on failure.
    public func render(psdPath: String, text: String, boxSize: CGSize) -> CGImage? {
        guard let natural = textRenderer.render(psdPath: psdPath, text: text) else { return nil }
        let nw = CGFloat(natural.width)
        let nh = CGFloat(natural.height)
        if nw <= boxSize.width && nh <= boxSize.height { return natural }

        // Calibrate CoreText proxy widths against the actual rendered width so
        // the wrap can operate in rendered-pixel space.
        let measured = PSDTextFit.measureWidth(text)
        let calibration = measured > 0 ? nw / measured : 1
        let wrapped = PSDTextFit.wrap(text, maxLines: maxLines, maxWidth: boxSize.width / calibration)
        if wrapped != text, let wrappedImage = textRenderer.render(psdPath: psdPath, text: wrapped) {
            if CGFloat(wrappedImage.width) <= boxSize.width && CGFloat(wrappedImage.height) <= boxSize.height {
                return wrappedImage
            }
            return shrink(wrappedImage, boxSize: boxSize)
        }
        return shrink(natural, boxSize: boxSize)
    }

    /// Uniform scale factor to bring `imageSize` within `boxSize` (both axes),
    /// never below `minScale`. Returns 1 when it already fits.
    public static func shrinkScale(imageSize: CGSize, boxSize: CGSize, minScale: Double) -> Double {
        guard boxSize.width > 0, boxSize.height > 0 else { return 1 }
        let sx = imageSize.width > 0 ? Double(boxSize.width) / Double(imageSize.width) : Double.greatestFiniteMagnitude
        let sy = imageSize.height > 0 ? Double(boxSize.height) / Double(imageSize.height) : Double.greatestFiniteMagnitude
        let needed = min(sx, sy)
        guard needed < 1 else { return 1 }
        return max(minScale, needed)
    }

    /// Width-only variant: bring `imageWidth` within `boxWidth`, never below
    /// `minScale`. Returns 1 when it already fits.
    public static func shrinkScale(imageWidth: CGFloat, boxWidth: CGFloat, minScale: Double) -> Double {
        guard boxWidth > 0, imageWidth > boxWidth else { return 1 }
        return max(minScale, Double(boxWidth / imageWidth))
    }

    private func shrink(_ image: CGImage, boxSize: CGSize) -> CGImage? {
        let scale = Self.shrinkScale(imageSize: CGSize(width: image.width, height: image.height),
                                     boxSize: boxSize, minScale: minTextScale)
        guard scale < 1 else { return image }
        return Self.scaleImage(image, scale: CGFloat(scale))
    }

    static func scaleImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
