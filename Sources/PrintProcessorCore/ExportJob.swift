import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Output formats supported by the export engine.
public enum ExportFormat: String, Codable, CaseIterable {
    case jpg
    case webp

    public var displayName: String {
        switch self {
        case .jpg: return "JPG"
        case .webp: return "WebP"
        }
    }

    /// Sub-folder name under the export root.
    public var folderName: String { displayName }

    /// File extension (no dot).
    public var fileExtension: String {
        switch self {
        case .jpg: return "jpg"
        case .webp: return "webp"
        }
    }
}

/// How the JPG output size is chosen.
public enum JPGSizing: String, Codable, CaseIterable {
    /// Paper size at 300 dpi (inches × 300).
    case inch
    /// Longest edge fixed to a pixel count, aspect ratio preserved.
    case longEdge

    public var displayName: String {
        switch self {
        case .inch: return "Inch (300 dpi)"
        case .longEdge: return "Long edge (px)"
        }
    }
}

/// How an existing output file is handled during export.
public enum CollisionPolicy: String, CaseIterable {
    case replace
    case skip
    case keepBoth
}

/// User-adjustable export defaults. Persisted inside `AppSettings`.
public struct ExportSettings: Codable, Equatable {
    public var exportJPG: Bool
    public var exportWebP: Bool
    /// Photoshop-scale quality 0…12 (mapped to ImageIO 0…1 on write).
    public var jpgQuality: Int
    /// JPG sizing mode (inch at 300 dpi, or fixed long edge).
    public var jpgSizing: JPGSizing
    /// JPG long-edge in pixels (only used when `jpgSizing == .longEdge`).
    public var jpgLongEdge: Int
    /// WebP quality percentage 0…100.
    public var webpQuality: Int
    /// WebP long-edge in pixels (0 = full paper size at 300 dpi).
    public var webpLongEdge: Int
    /// Filename pattern with `{name}`, `{size}`, `{number}`, `{index}`.
    public var filenamePattern: String

    public init(
        exportJPG: Bool = true,
        exportWebP: Bool = true,
        jpgQuality: Int = 10,
        jpgSizing: JPGSizing = .inch,
        jpgLongEdge: Int = 2400,
        webpQuality: Int = 50,
        webpLongEdge: Int = 0,
        filenamePattern: String = "{name}"
    ) {
        self.exportJPG = exportJPG
        self.exportWebP = exportWebP
        self.jpgQuality = min(12, max(0, jpgQuality))
        self.jpgSizing = jpgSizing
        self.jpgLongEdge = max(0, jpgLongEdge)
        self.webpQuality = min(100, max(0, webpQuality))
        self.webpLongEdge = max(0, webpLongEdge)
        self.filenamePattern = filenamePattern
    }

    public static let defaults = ExportSettings()
}

/// Expands the filename pattern and derives collision-safe names.
public enum ExportNaming {
    /// The base output file name (without folder), e.g. `name_4x6.jpg`.
    public static func fileName(
        sourceName: String,
        pattern: String,
        sizeLabel: String,
        index: Int,
        format: ExportFormat
    ) -> String {
        let stem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let number = TextSourceResolver.leadingNumber(sourceName)
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmed.isEmpty ? "{name}" : trimmed
        name = name.replacingOccurrences(of: "{name}", with: stem)
        name = name.replacingOccurrences(of: "{size}", with: sizeLabel)
        name = name.replacingOccurrences(of: "{number}", with: number)
        name = name.replacingOccurrences(of: "{index}", with: String(index + 1))
        // Sanitise path-hostile characters that could escape the export folder.
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? stem : cleaned) + "." + format.fileExtension
    }

    /// First non-existing `base-1.ext`, `base-2.ext`, … beside `url`.
    public static func uniqueURL(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}

/// Writes a rendered `CGImage` to JPEG with 300-dpi metadata, an embedded sRGB
/// ICC profile, and no EXIF / XMP metadata. ImageIO cannot omit the minimal
/// Exif APP1 it adds (nor does it write an ICC APP2), so the encoded file is
/// rewritten segment-by-segment: drop APP1, force JFIF to 300 dpi, and embed
/// the sRGB profile as an APP2 ICC_PROFILE marker.
public enum JPEGWriter {
    /// Map Photoshop-scale quality (0…12) to ImageIO's 0…1 compression value.
    public static func compressionQuality(photoshop: Int) -> Double {
        let q = min(12, max(0, photoshop))
        return Double(q) / 12.0
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL, quality: Int, dpi: Int = 300) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        let imageProps: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName: "sRGB IEC61966-2.1",
        ]
        CGImageDestinationAddImage(dest, image, imageProps as CFDictionary)
        let destProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality(photoshop: quality),
        ]
        CGImageDestinationSetProperties(dest, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }

        // Rewrite the encoded JPEG: strip APP1 Exif/XMP, embed ICC APP2, force
        // JFIF density to `dpi` dots/inch. Metadata rewriting is best-effort —
        // the encoded JPEG is still valid and already written if it fails.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".pp-strip-\(UUID().uuidString).jpg")
        guard JPEGMetadataStripper.strip(source: url, destination: tmp, dpi: dpi) else {
            return true
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return true
        }
    }
}

/// Byte-level JPEG segment rewriter: keeps SOI, JFIF APP0 (density forced to
/// `dpi` dots/inch), an embedded ICC APP2, and every other segment, while
/// dropping every APP1 marker (Exif and XMP).
public enum JPEGMetadataStripper {
    @discardableResult
    public static func strip(source: URL, destination: URL, dpi: Int = 300) -> Bool {
        guard let data = try? Data(contentsOf: source) else { return false }
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        let icc = ICCProfile.sRGBData()

        var out: [UInt8] = [0xFF, 0xD8]
        var iccInjected = false
        func injectICCIfNeeded() {
            guard !iccInjected, let icc = icc else { return }
            out.append(contentsOf: ICCProfile.jpegICCAPP2(icc))
            iccInjected = true
        }

        var i = 2
        while i < bytes.count {
            guard bytes[i] == 0xFF else { return false }
            var j = i + 1
            while j < bytes.count && bytes[j] == 0xFF { j += 1 }
            guard j < bytes.count else { return false }
            let marker = bytes[j]

            if marker == 0xD9 {         // EOI (standalone, no length field)
                injectICCIfNeeded()
                out.append(0xFF); out.append(0xD9)
                break
            }
            if marker == 0xDA {         // SOS: entropy-coded data through EOI
                injectICCIfNeeded()
                out.append(contentsOf: bytes[(j - 1)...])
                break
            }
            if marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                out.append(0xFF); out.append(marker)
                i = j + 1
                continue
            }
            guard j + 2 < bytes.count else { return false }
            let length = (Int(bytes[j + 1]) << 8) | Int(bytes[j + 2])
            guard length >= 2 else { return false }
            let end = j + 1 + length
            guard end <= bytes.count else { return false }

            if marker == 0xE1 {         // APP1: Exif / XMP — drop
                i = end
                continue
            }
            if marker == 0xE0 {
                var seg = Array(bytes[(j - 1)..<end])
                // Force the JFIF density header to dots/inch at `dpi`.
                if seg.count >= 16, seg[4] == 0x4A, seg[5] == 0x46, seg[6] == 0x49, seg[7] == 0x46, seg[8] == 0x00 {
                    seg[11] = 1                                        // units = dots/inch
                    seg[12] = UInt8((dpi >> 8) & 0xFF)                 // Xdensity hi
                    seg[13] = UInt8(dpi & 0xFF)                        // Xdensity lo
                    seg[14] = UInt8((dpi >> 8) & 0xFF)                 // Ydensity hi
                    seg[15] = UInt8(dpi & 0xFF)                        // Ydensity lo
                }
                out.append(contentsOf: seg)
                injectICCIfNeeded()                                     // ICC right after JFIF
                i = end
                continue
            }
            out.append(contentsOf: bytes[(j - 1)..<end])
            i = end
        }

        do {
            try Data(out).write(to: destination)
            return true
        } catch {
            return false
        }
    }
}

/// One planned output: a source photo and the files the export will produce.
public struct ExportItem {
    public let sourceURL: URL
    public let index: Int
    public let jpgURL: URL?
    public let webpURL: URL?
    public var jpgExists: Bool
    public var webpExists: Bool
}

/// Aggregate result of an export run.
public struct ExportSummary: Equatable {
    public var jpgWritten = 0
    public var webpWritten = 0
    public var skipped = 0
    public var failed = 0
    public var cancelled = false
    /// Total output units (files × formats) planned for this run, so the UI can
    /// render "Cancelled n/total" after a cancel.
    public var total = 0

    public init() {}

    public var totalWritten: Int { jpgWritten + webpWritten }
}

/// Running per-format progress, emitted on the main thread.
public struct ExportProgress: Equatable {
    public var jpgDone = 0
    public var jpgTotal = 0
    public var webpDone = 0
    public var webpTotal = 0

    public init() {}
}

/// Thread-safe running per-format completion counters.
private final class ProgressBox {
    private let lock = NSLock()
    private var jpgDone = 0
    private var webpDone = 0

    func record(_ format: ExportFormat) {
        lock.lock()
        switch format {
        case .jpg: jpgDone += 1
        case .webp: webpDone += 1
        }
        lock.unlock()
    }

    func snapshot(jpgTotal: Int, webpTotal: Int) -> ExportProgress {
        lock.lock()
        defer { lock.unlock() }
        var p = ExportProgress()
        p.jpgDone = jpgDone
        p.webpDone = webpDone
        p.jpgTotal = jpgTotal
        p.webpTotal = webpTotal
        return p
    }
}

/// One unit of work in the export run (one file × one format).
private struct ExportUnit {
    let index: Int
    let format: ExportFormat
    let destination: URL
}

/// Thread-safe mutable box for an `ExportSummary`.
private final class SummaryBox {
    private let lock = NSLock()
    private var value = ExportSummary()

    func record(written: ExportFormat?) {
        lock.lock()
        if let written {
            switch written {
            case .jpg: value.jpgWritten += 1
            case .webp: value.webpWritten += 1
            }
        } else {
            value.failed += 1
        }
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        value.cancelled = true
        lock.unlock()
    }

    var snapshot: ExportSummary {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Renders every project file at full paper resolution and writes JPG/WebP into
/// `JPG/` and `WebP/` folders, in parallel on all CPU cores.
///
/// The render closure is provided by the UI layer (it owns the compositor and
/// the original-image cache) and must be safe to call concurrently. `plan()`
/// computes output paths + collision status so the UI can resolve collisions
/// before any work starts; `run(resolutions:)` then performs the export.
public final class ExportJob {
    /// Per-format progress — called on the main thread.
    public var onProgress: ((ExportProgress) -> Void)?

    public private(set) var isRunning = false

    private let files: [URL]
    private let formats: [ExportFormat]
    private let exportRoot: URL
    private let settings: ExportSettings
    private let paperPixelSize: CGSize
    private let sizeLabel: String
    private let cwebpPath: String
    private let cpuLimit: Int
    private let render: (Int, CGSize) -> CGImage?
    /// Basenames of photos flagged "NO EXPORT" — these are skipped entirely.
    private let noExport: Set<String>

    private let stateLock = NSLock()
    private var cancelledFlag = false

    public init(
        files: [URL],
        formats: [ExportFormat],
        exportRoot: URL,
        settings: ExportSettings,
        paperPixelSize: CGSize,
        sizeLabel: String,
        cwebpPath: String,
        cpuLimit: Int,
        render: @escaping (Int, CGSize) -> CGImage?,
        noExport: Set<String> = []
    ) {
        self.files = files
        self.formats = formats
        self.exportRoot = exportRoot
        self.settings = settings
        self.paperPixelSize = paperPixelSize
        self.sizeLabel = sizeLabel
        self.cwebpPath = cwebpPath
        self.cpuLimit = cpuLimit
        self.render = render
        self.noExport = noExport
    }

    public func cancel() {
        stateLock.lock()
        cancelledFlag = true
        stateLock.unlock()
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledFlag
    }

    /// Whether a source photo is flagged "NO EXPORT".
    private func isSkipped(_ url: URL) -> Bool {
        noExport.contains(url.lastPathComponent)
    }

    // MARK: - Paths

    private func destinationURL(sourceName: String, index: Int, format: ExportFormat) -> URL {
        let name = ExportNaming.fileName(
            sourceName: sourceName,
            pattern: settings.filenamePattern,
            sizeLabel: sizeLabel,
            index: index,
            format: format
        )
        return exportRoot.appendingPathComponent(format.folderName).appendingPathComponent(name)
    }

    /// Compute every planned output and whether it already exists. Photos flagged
    /// "NO EXPORT" produce no items (they are skipped before collision handling).
    public func plan() -> [ExportItem] {
        files.enumerated().compactMap { index, url in
            guard !isSkipped(url) else { return nil }
            let name = url.lastPathComponent
            let jpgURL = formats.contains(.jpg) ? destinationURL(sourceName: name, index: index, format: .jpg) : nil
            let webpURL = formats.contains(.webp) ? destinationURL(sourceName: name, index: index, format: .webp) : nil
            return ExportItem(
                sourceURL: url,
                index: index,
                jpgURL: jpgURL,
                webpURL: webpURL,
                jpgExists: jpgURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                webpExists: webpURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            )
        }
    }

    // MARK: - Sizing

    private func canvasSize(for format: ExportFormat) -> CGSize {
        switch format {
        case .jpg:
            switch settings.jpgSizing {
            case .inch: return paperPixelSize
            case .longEdge: return scaledCanvas(longEdge: settings.jpgLongEdge)
            }
        case .webp:
            return scaledCanvas(longEdge: settings.webpLongEdge)
        }
    }

    private func scaledCanvas(longEdge: Int) -> CGSize {
        guard longEdge > 0, paperPixelSize.width > 0, paperPixelSize.height > 0 else {
            return paperPixelSize
        }
        let maxDim = max(paperPixelSize.width, paperPixelSize.height)
        guard maxDim > 0 else { return paperPixelSize }
        let scale = CGFloat(longEdge) / maxDim
        return CGSize(width: (paperPixelSize.width * scale).rounded(),
                      height: (paperPixelSize.height * scale).rounded())
    }

    // MARK: - Run

    /// Run the export. `resolutions` maps an *existing* destination URL to how
    /// it should be handled; files not present in the map are written normally.
    public func run(resolutions: [URL: CollisionPolicy], completion: @escaping (ExportSummary) -> Void) {
        isRunning = true
        stateLock.lock()
        cancelledFlag = false
        stateLock.unlock()

        var units: [ExportUnit] = []
        for item in plan() {
            if let dest = item.jpgURL,
               let unit = resolvedUnit(index: item.index, format: .jpg, destination: dest,
                                       exists: item.jpgExists, resolutions: resolutions) {
                units.append(unit)
            }
            if let dest = item.webpURL,
               let unit = resolvedUnit(index: item.index, format: .webp, destination: dest,
                                       exists: item.webpExists, resolutions: resolutions) {
                units.append(unit)
            }
        }

        let summary = SummaryBox()
        let progress = ProgressBox()
        let group = DispatchGroup()

        // Photos flagged "NO EXPORT" are skipped before any work is planned.
        let skippedCount = files.filter { isSkipped($0) }.count

        var jpgTotal = 0
        var webpTotal = 0
        for unit in units {
            switch unit.format {
            case .jpg: jpgTotal += 1
            case .webp: webpTotal += 1
            }
        }
        let totalUnits = units.count

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, cpuLimit > 0 ? cpuLimit : ProcessInfo.processInfo.activeProcessorCount)

        for unit in units {
            group.enter()
            queue.addOperation { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                if self.isCancelled() {
                    summary.markCancelled()
                    progress.record(unit.format)
                    let snapshot = progress.snapshot(jpgTotal: jpgTotal, webpTotal: webpTotal)
                    DispatchQueue.main.async { self.onProgress?(snapshot) }
                    return
                }
                let dir = unit.destination.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let canvas = self.canvasSize(for: unit.format)
                var written: ExportFormat? = nil
                if let image = self.render(unit.index, canvas) {
                    switch unit.format {
                    case .jpg:
                        if JPEGWriter.write(image, to: unit.destination, quality: self.settings.jpgQuality) {
                            written = .jpg
                        }
                    case .webp:
                        if WebPEncoder(cwebpPath: self.cwebpPath, quality: self.settings.webpQuality)
                            .encodeExport(image: image, to: unit.destination) {
                            written = .webp
                        }
                    }
                }
                summary.record(written: written)
                progress.record(unit.format)
                let snapshot = progress.snapshot(jpgTotal: jpgTotal, webpTotal: webpTotal)
                DispatchQueue.main.async { self.onProgress?(snapshot) }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isRunning = false
            var result = summary.snapshot
            result.total = totalUnits
            result.skipped = skippedCount
            completion(result)
        }
    }

    private func resolvedUnit(
        index: Int,
        format: ExportFormat,
        destination: URL,
        exists: Bool,
        resolutions: [URL: CollisionPolicy]
    ) -> ExportUnit? {
        guard exists else {
            return ExportUnit(index: index, format: format, destination: destination)
        }
        switch resolutions[destination] ?? .replace {
        case .skip:
            return nil
        case .keepBoth:
            return ExportUnit(index: index, format: format, destination: ExportNaming.uniqueURL(destination))
        case .replace:
            return ExportUnit(index: index, format: format, destination: destination)
        }
    }
}
