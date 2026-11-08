import Foundation

/// Whether a one-pixel nudge is measured in export pixels or on-screen pixels.
public enum NudgeBasis: String, Codable, CaseIterable {
    case export
    case screen

    public var displayName: String {
        switch self {
        case .export: return "Export pixels"
        case .screen: return "Screen pixels"
        }
    }
}

/// User-adjustable application settings. Persisted as JSON in UserDefaults.
public struct AppSettings: Codable, Equatable {
    /// Double-tap Spacebar window in milliseconds (previous image).
    public var doubleTapMs: Int
    /// Rotation step in degrees per scroll notch while R is held.
    public var rotateStep: Double
    /// Scroll-to-zoom sensitivity multiplier.
    public var scrollZoomSpeed: Double
    /// Scroll-to-rotate sensitivity multiplier.
    public var scrollRotateSpeed: Double
    /// Pixel basis for arrow-key nudges.
    public var nudgeBasis: NudgeBasis
    /// Tooltip delay in seconds (0 disables tooltips).
    public var tooltipDelay: Double
    /// Filename-scan mode serialised string, e.g. `text=right`.
    public var scanMode: String
    /// Saved scan modes shown in the one-click popup.
    public var savedScanModes: [String]
    /// Name of the PSD text layer targeted for layer 2 (default "TEXT").
    public var psdTextLayerName: String
    /// Minimum scale the layer-2 text may shrink to (fraction of natural size).
    public var minTextScale: Double
    /// Absolute path to the Photoshop `.app` bundle; empty = auto-detect.
    public var photoshopPath: String
    /// Absolute path to the cwebp binary; empty = resolve from known locations.
    public var cwebpPath: String
    /// RAM cache cap for previews, in megabytes (LRU eviction once exceeded).
    public var cacheRAMCapMB: Int
    /// Project JSON autosave interval in seconds.
    public var autosaveSeconds: Int
    /// Export defaults (formats, quality, sizing, filename pattern).
    public var export: ExportSettings
    /// CPU-core limit for the export queue (0 = all cores).
    public var cpuLimit: Int

    public static let defaults = AppSettings(
        doubleTapMs: 300,
        rotateStep: 0.1,
        scrollZoomSpeed: 1.0,
        scrollRotateSpeed: 1.0,
        nudgeBasis: .export,
        tooltipDelay: 0.5,
        scanMode: "text=right",
        savedScanModes: ["text=right", "text=left,watermark=right", "text=none,watermark=left"],
        psdTextLayerName: "TEXT",
        minTextScale: 0.4,
        photoshopPath: "",
        cwebpPath: "",
        cacheRAMCapMB: 1536,
        autosaveSeconds: 3,
        export: .defaults,
        cpuLimit: 0
    )

    public init(
        doubleTapMs: Int,
        rotateStep: Double,
        scrollZoomSpeed: Double,
        scrollRotateSpeed: Double,
        nudgeBasis: NudgeBasis,
        tooltipDelay: Double,
        scanMode: String = "text=right",
        savedScanModes: [String] = ["text=right", "text=left,watermark=right", "text=none,watermark=left"],
        psdTextLayerName: String = "TEXT",
        minTextScale: Double = 0.4,
        photoshopPath: String = "",
        cwebpPath: String = "",
        cacheRAMCapMB: Int = 1536,
        autosaveSeconds: Int = 3,
        export: ExportSettings = .defaults,
        cpuLimit: Int = 0
    ) {
        self.doubleTapMs = doubleTapMs
        self.rotateStep = rotateStep
        self.scrollZoomSpeed = scrollZoomSpeed
        self.scrollRotateSpeed = scrollRotateSpeed
        self.nudgeBasis = nudgeBasis
        self.tooltipDelay = tooltipDelay
        self.scanMode = scanMode
        self.savedScanModes = savedScanModes
        self.psdTextLayerName = psdTextLayerName
        self.minTextScale = minTextScale
        self.photoshopPath = photoshopPath
        self.cwebpPath = cwebpPath
        self.cacheRAMCapMB = max(1, cacheRAMCapMB)
        self.autosaveSeconds = max(1, autosaveSeconds)
        self.export = export
        self.cpuLimit = max(0, cpuLimit)
    }

    // MARK: - Codable (backward-compatible: new keys are optional on decode)

    private enum CodingKeys: String, CodingKey {
        case doubleTapMs, rotateStep, scrollZoomSpeed, scrollRotateSpeed
        case nudgeBasis, tooltipDelay, scanMode, savedScanModes
        case psdTextLayerName, minTextScale, photoshopPath, cwebpPath
        case cacheRAMCapMB, autosaveSeconds, export, cpuLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doubleTapMs = try c.decodeIfPresent(Int.self, forKey: .doubleTapMs) ?? 300
        rotateStep = try c.decodeIfPresent(Double.self, forKey: .rotateStep) ?? 0.1
        scrollZoomSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollZoomSpeed) ?? 1.0
        scrollRotateSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollRotateSpeed) ?? 1.0
        nudgeBasis = try c.decodeIfPresent(NudgeBasis.self, forKey: .nudgeBasis) ?? .export
        tooltipDelay = try c.decodeIfPresent(Double.self, forKey: .tooltipDelay) ?? 0.5
        scanMode = try c.decodeIfPresent(String.self, forKey: .scanMode) ?? "text=right"
        savedScanModes = try c.decodeIfPresent([String].self, forKey: .savedScanModes) ?? ["text=right", "text=left,watermark=right", "text=none,watermark=left"]
        // Migration: older settings files lack the "watermark = whole file name" preset.
        if !savedScanModes.contains("text=none,watermark=left") { savedScanModes.append("text=none,watermark=left") }
        psdTextLayerName = try c.decodeIfPresent(String.self, forKey: .psdTextLayerName) ?? "TEXT"
        minTextScale = try c.decodeIfPresent(Double.self, forKey: .minTextScale) ?? 0.4
        photoshopPath = try c.decodeIfPresent(String.self, forKey: .photoshopPath) ?? ""
        cwebpPath = try c.decodeIfPresent(String.self, forKey: .cwebpPath) ?? ""
        cacheRAMCapMB = try c.decodeIfPresent(Int.self, forKey: .cacheRAMCapMB) ?? 1536
        autosaveSeconds = try c.decodeIfPresent(Int.self, forKey: .autosaveSeconds) ?? 3
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? .defaults
        cpuLimit = try c.decodeIfPresent(Int.self, forKey: .cpuLimit) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(doubleTapMs, forKey: .doubleTapMs)
        try c.encode(rotateStep, forKey: .rotateStep)
        try c.encode(scrollZoomSpeed, forKey: .scrollZoomSpeed)
        try c.encode(scrollRotateSpeed, forKey: .scrollRotateSpeed)
        try c.encode(nudgeBasis, forKey: .nudgeBasis)
        try c.encode(tooltipDelay, forKey: .tooltipDelay)
        try c.encode(scanMode, forKey: .scanMode)
        try c.encode(savedScanModes, forKey: .savedScanModes)
        try c.encode(psdTextLayerName, forKey: .psdTextLayerName)
        try c.encode(minTextScale, forKey: .minTextScale)
        try c.encode(photoshopPath, forKey: .photoshopPath)
        try c.encode(cwebpPath, forKey: .cwebpPath)
        try c.encode(cacheRAMCapMB, forKey: .cacheRAMCapMB)
        try c.encode(autosaveSeconds, forKey: .autosaveSeconds)
        try c.encode(export, forKey: .export)
        try c.encode(cpuLimit, forKey: .cpuLimit)
    }

    /// Clamp every numeric field to its documented bounds so out-of-range input
    /// (e.g. typed in the Settings tab) can never produce an invalid value.
    /// rotateStep 0.01…1.5, scroll speeds > 0, doubleTapMs 100…1000,
    /// tooltipDelay >= 0, minTextScale 0.05…1.
    public func clamped() -> AppSettings {
        var s = self
        s.doubleTapMs = min(1000, max(100, doubleTapMs))
        s.rotateStep = min(1.5, max(0.01, rotateStep))
        s.scrollZoomSpeed = max(0.01, scrollZoomSpeed)
        s.scrollRotateSpeed = max(0.01, scrollRotateSpeed)
        s.tooltipDelay = max(0, tooltipDelay)
        s.minTextScale = min(1, max(0.05, minTextScale))
        return s
    }

    private static let storageKey = "com.johorstudio.printprocessor.AppSettings"

    /// Load the persisted settings, falling back to defaults when nothing is stored yet.
    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    /// Persist these settings to UserDefaults.
    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

public extension Notification.Name {
    /// Posted when persisted AppSettings change (e.g. the Settings tab Apply
    /// button) so live views can reload them without restarting.
    static let appSettingsDidChange = Notification.Name("com.johorstudio.printprocessor.appSettingsDidChange")
}
