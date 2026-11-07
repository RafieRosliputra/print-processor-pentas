import Foundation

/// A device-independent RGBA colour (components 0…1). Codable so it round-trips
/// through the project JSON.
public struct RGBAColor: Codable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Blend mode for the photo gradient. Mirrors the Core Graphics blend modes
/// usable for the layer-4 gradient.
public enum GradientBlend: String, Codable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        }
    }
}

/// Two-stop linear gradient drawn only inside the photo's transformed rect.
public struct GradientSettings: Codable, Equatable {
    public var enabled: Bool
    public var colorA: RGBAColor
    public var colorB: RGBAColor
    /// Direction in degrees: 0 = left→right, 90 = bottom→top, 180 = right→left.
    public var angle: Double
    /// Overall gradient opacity 0…1.
    public var opacity: Double
    public var blend: GradientBlend

    public init(
        enabled: Bool = true,
        colorA: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5),
        colorB: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0),
        angle: Double = 0,
        opacity: Double = 1,
        blend: GradientBlend = .normal
    ) {
        self.enabled = enabled
        self.colorA = colorA
        self.colorB = colorB
        self.angle = angle
        self.opacity = opacity
        self.blend = blend
    }

    public static let defaults = GradientSettings()
}

/// Free-transform placement for the watermark, expressed as fractions of the
/// canvas width/height measured from the bottom-right corner, plus scale and
/// clockwise rotation in degrees.
public struct WatermarkTransform: Codable, Equatable {
    /// Distance from the right edge, as a fraction of canvas width.
    public var offsetFractionX: Double
    /// Distance from the bottom edge, as a fraction of canvas height.
    public var offsetFractionY: Double
    /// Additional size multiplier (1 = the `sizeFraction` text size).
    public var scale: Double
    /// Clockwise rotation in degrees about the text's bottom-right anchor.
    public var rotationDeg: Double

    public init(offsetFractionX: Double = 0.05, offsetFractionY: Double = 0.05,
                scale: Double = 1, rotationDeg: Double = 0) {
        self.offsetFractionX = offsetFractionX
        self.offsetFractionY = offsetFractionY
        self.scale = scale
        self.rotationDeg = rotationDeg
    }

    public static let identity = WatermarkTransform()
}

/// Watermark (layer 1) settings.
public struct WatermarkSettings: Codable, Equatable {
    public var text: String
    /// CoreText PostScript font name. Defaults to the system bold UI font.
    public var fontName: String
    /// Text size as a fraction of the canvas width.
    public var sizeFraction: Double
    public var colour: RGBAColor
    /// Text opacity 0…1 (multiplied with `colour.alpha`).
    public var opacity: Double
    public var transform: WatermarkTransform

    public init(
        text: String = "",
        fontName: String = ".SFUI-Bold",
        sizeFraction: Double = 0.04,
        colour: RGBAColor = .white,
        opacity: Double = 0.6,
        transform: WatermarkTransform = .identity
    ) {
        self.text = text
        self.fontName = fontName
        self.sizeFraction = sizeFraction
        self.colour = colour
        self.opacity = opacity
        self.transform = transform
    }

    public static let defaults = WatermarkSettings()
}

/// Free-transform placement for the overlay: offset in canvas points (positive
/// X right, positive Y up), scale relative to fit/fill, and clockwise rotation.
public struct OverlayTransform: Codable, Equatable {
    public var offsetX: Double
    public var offsetY: Double
    public var scale: Double
    public var rotationDeg: Double

    public init(offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1, rotationDeg: Double = 0) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.rotationDeg = rotationDeg
    }

    public static let identity = OverlayTransform()
}

/// Overlay (layer 3) settings. The overlay image (PNG/WebP with alpha) is
/// fitted or filled to the canvas, then free-transformed.
public struct OverlaySettings: Codable, Equatable {
    public var path: String
    /// true = fit (letterbox inside canvas), false = fill (cover the canvas).
    public var fit: Bool
    public var transform: OverlayTransform

    public init(path: String = "", fit: Bool = true, transform: OverlayTransform = .identity) {
        self.path = path
        self.fit = fit
        self.transform = transform
    }

    public static let defaults = OverlaySettings()
}

/// Background image (layer 5) — an image file with alpha drawn under the photo.
public struct BackgroundSettings: Codable, Equatable {
    public var path: String

    public init(path: String = "") {
        self.path = path
    }

    public static let defaults = BackgroundSettings()
}

/// Final background (layer 6) — either a solid colour or an image, both filling
/// the canvas.
public enum FinalBackground: Codable, Equatable {
    case colour(RGBAColor)
    case image(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case colour
        case path
    }

    private enum Kind: String, Codable {
        case colour
        case image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .colour:
            self = .colour(try c.decode(RGBAColor.self, forKey: .colour))
        case .image:
            self = .image(try c.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .colour(let colour):
            try c.encode(Kind.colour, forKey: .kind)
            try c.encode(colour, forKey: .colour)
        case .image(let path):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(path, forKey: .path)
        }
    }

    public static let defaults = FinalBackground.colour(.white)
}

/// On/off flags for layers 1–6.
public struct LayerVisibility: Codable, Equatable {
    public var layer1: Bool
    public var layer2: Bool
    public var layer3: Bool
    public var layer4: Bool
    public var layer5: Bool
    public var layer6: Bool

    public init(layer1: Bool = true, layer2: Bool = true, layer3: Bool = true,
                layer4: Bool = true, layer5: Bool = true, layer6: Bool = true) {
        self.layer1 = layer1
        self.layer2 = layer2
        self.layer3 = layer3
        self.layer4 = layer4
        self.layer5 = layer5
        self.layer6 = layer6
    }

    public static let defaults = LayerVisibility()

    /// 1-based accessor (1…6) for the layer flags.
    public subscript(layer: Int) -> Bool {
        get {
            switch layer {
            case 1: return layer1
            case 2: return layer2
            case 3: return layer3
            case 4: return layer4
            case 5: return layer5
            case 6: return layer6
            default: return false
            }
        }
        set {
            switch layer {
            case 1: layer1 = newValue
            case 2: layer2 = newValue
            case 3: layer3 = newValue
            case 4: layer4 = newValue
            case 5: layer5 = newValue
            case 6: layer6 = newValue
            default: break
            }
        }
    }
}

/// All layer-related settings, persisted as `layerSettings` on the project.
public struct LayerSettings: Codable, Equatable {
    public var enabled: LayerVisibility
    public var watermark: WatermarkSettings
    public var overlay: OverlaySettings
    public var gradient: GradientSettings
    public var bg5: BackgroundSettings
    public var bg6: FinalBackground
    /// Layer-2 PSD styled text settings.
    public var psdText: PSDTextSettings

    public init(
        enabled: LayerVisibility = .defaults,
        watermark: WatermarkSettings = .defaults,
        overlay: OverlaySettings = .defaults,
        gradient: GradientSettings = .defaults,
        bg5: BackgroundSettings = .defaults,
        bg6: FinalBackground = .defaults,
        psdText: PSDTextSettings = .defaults
    ) {
        self.enabled = enabled
        self.watermark = watermark
        self.overlay = overlay
        self.gradient = gradient
        self.bg5 = bg5
        self.bg6 = bg6
        self.psdText = psdText
    }

    public static let defaults = LayerSettings()

    // MARK: Codable (backward-compatible with pre-psdText projects)

    private enum CodingKeys: String, CodingKey {
        case enabled, watermark, overlay, gradient, bg5, bg6, psdText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(LayerVisibility.self, forKey: .enabled) ?? .defaults
        watermark = try c.decodeIfPresent(WatermarkSettings.self, forKey: .watermark) ?? .defaults
        overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? .defaults
        gradient = try c.decodeIfPresent(GradientSettings.self, forKey: .gradient) ?? .defaults
        bg5 = try c.decodeIfPresent(BackgroundSettings.self, forKey: .bg5) ?? .defaults
        bg6 = try c.decodeIfPresent(FinalBackground.self, forKey: .bg6) ?? .defaults
        psdText = try c.decodeIfPresent(PSDTextSettings.self, forKey: .psdText) ?? .defaults
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(watermark, forKey: .watermark)
        try c.encode(overlay, forKey: .overlay)
        try c.encode(gradient, forKey: .gradient)
        try c.encode(bg5, forKey: .bg5)
        try c.encode(bg6, forKey: .bg6)
        try c.encode(psdText, forKey: .psdText)
    }
}
