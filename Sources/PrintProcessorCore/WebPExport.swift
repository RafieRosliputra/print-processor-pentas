import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Never-reuse numbering for `<name>-NN.webp` files beside a PSD. `counter` is
/// the highest number ever used (stored in the project JSON).
public enum WebPNumbering {
    /// Absolute URL for the numbered webp: `<dir>/<stem>-NN.webp` (two-digit min).
    public static func outputURL(psdURL: URL, number: Int) -> URL {
        let dir = psdURL.deletingLastPathComponent()
        let base = psdURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)-\(String(format: "%02d", number)).webp")
    }

    /// Every existing `NN` for `<stem>-NN.webp` beside the PSD.
    public static func existingNumbers(psdURL: URL) -> [Int] {
        let dir = psdURL.deletingLastPathComponent()
        let base = psdURL.deletingPathExtension().lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix = base + "-"
        let suffix = ".webp"
        var numbers: [Int] = []
        for name in files where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
            if let n = Int(middle) { numbers.append(n) }
        }
        return numbers
    }

    /// Next number = max(highest existing, counter) + 1, bumped past collisions
    /// so an existing file is never overwritten.
    public static func nextNumber(psdURL: URL, counter: Int) -> Int {
        let highest = existingNumbers(psdURL: psdURL).max() ?? -1
        var n = max(highest, counter) + 1
        while FileManager.default.fileExists(atPath: outputURL(psdURL: psdURL, number: n).path) {
            n += 1
        }
        return n
    }
}

/// Encodes a CGImage to WebP via the `cwebp` command-line tool.
public final class WebPEncoder {
    /// Absolute cwebp path; empty = resolve from `AppSettings.cwebpPath`, then
    /// `/opt/homebrew/bin/cwebp`, then PATH.
    public let cwebpPath: String
    public let quality: Int

    public init(cwebpPath: String = "", quality: Int = 95) {
        self.cwebpPath = cwebpPath
        self.quality = quality
    }

    public static var isAvailable: Bool { resolveCWebP() != nil }

    /// Resolve the cwebp binary the same way the app does.
    public static func resolveCWebP() -> String? {
        let candidates: [String]
        let override = AppSettings.load().cwebpPath
        if !override.isEmpty {
            candidates = [override, "/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]
        } else {
            candidates = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return findInPath("cwebp")
    }

    private static func findInPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Encode `image` to `url` (lossless-alpha aware: quality 95 + `-alpha_q 100`).
    @discardableResult
    public func encode(image: CGImage, to url: URL) -> Bool {
        guard let cwebp = cwebpPath.isEmpty ? Self.resolveCWebP() : cwebpPath,
              FileManager.default.isExecutableFile(atPath: cwebp) else { return false }
        guard let tmp = Self.writeTempPNG(image, in: url.deletingLastPathComponent()) else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cwebp)
        process.arguments = ["-q", String(quality), "-alpha_q", "100", tmp, "-o", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    /// Encode for final export: alpha channel disabled, the sRGB ICC profile
    /// embedded, and EXIF / XMP / GPS stripped (`-metadata icc` copies only the
    /// ICC profile from the source PNG). The image is written at its current
    /// size; sizing to a long edge is handled by the caller's render step.
    @discardableResult
    public func encodeExport(image: CGImage, to url: URL) -> Bool {
        guard let cwebp = cwebpPath.isEmpty ? Self.resolveCWebP() : cwebpPath,
              FileManager.default.isExecutableFile(atPath: cwebp) else { return false }
        guard let tmp = Self.writeTempPNG(image, in: url.deletingLastPathComponent()) else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cwebp)
        process.arguments = ["-q", String(quality), "-noalpha", "-metadata", "icc", tmp, "-o", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    /// Write the image as a temp PNG and embed the sRGB ICC profile as an iCCP
    /// chunk so `cwebp -metadata icc` can copy it into the WebP's ICCP chunk.
    private static func writeTempPNG(_ image: CGImage, in directory: URL) -> String? {
        let url = directory.appendingPathComponent(".pp-cwebp-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        if let icc = ICCProfile.sRGBData() {
            ICCProfile.injectICC(intoPNGAt: url, icc: icc)
        }
        return url.path
    }
}

/// Exports `<name>-NN.webp` beside a PSD from a flattened composite. The flatten
/// and encode steps are injectable so the Check target can test numbering with a
/// temp file and no external tools.
public final class PSDOverlayExporter {
    public var flatten: (String) -> CGImage?
    public var encode: (CGImage, URL) -> Bool

    public init(flatten: @escaping (String) -> CGImage?,
                encode: @escaping (CGImage, URL) -> Bool) {
        self.flatten = flatten
        self.encode = encode
    }

    /// Convenience: flatten via ImageIO, encode via cwebp.
    public static func standard(cwebpPath: String = "") -> PSDOverlayExporter {
        PSDOverlayExporter(
            flatten: { PSDFlatten.composite(psdPath: $0) },
            encode: { image, url in WebPEncoder(cwebpPath: cwebpPath).encode(image: image, to: url) }
        )
    }

    /// Export the next numbered webp and return its URL (nil on failure).
    @discardableResult
    public func export(psdURL: URL, counter: Int) -> URL? {
        let number = WebPNumbering.nextNumber(psdURL: psdURL, counter: counter)
        guard let image = flatten(psdURL.path) else { return nil }
        let out = WebPNumbering.outputURL(psdURL: psdURL, number: number)
        guard encode(image, out) else { return nil }
        return out
    }
}
