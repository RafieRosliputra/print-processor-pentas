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

    public static let defaults = AppSettings(
        doubleTapMs: 300,
        rotateStep: 0.1,
        scrollZoomSpeed: 1.0,
        scrollRotateSpeed: 1.0,
        nudgeBasis: .export,
        tooltipDelay: 0.5,
        scanMode: "text=right",
        savedScanModes: ["text=right", "text=left,watermark=right"],
        psdTextLayerName: "TEXT",
        minTextScale: 0.4,
        photoshopPath: "",
        cwebpPath: ""
    )

    public init(
        doubleTapMs: Int,
        rotateStep: Double,
        scrollZoomSpeed: Double,
        scrollRotateSpeed: Double,
        nudgeBasis: NudgeBasis,
        tooltipDelay: Double,
        scanMode: String = "text=right",
        savedScanModes: [String] = ["text=right", "text=left,watermark=right"],
        psdTextLayerName: String = "TEXT",
        minTextScale: Double = 0.4,
        photoshopPath: String = "",
        cwebpPath: String = ""
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
