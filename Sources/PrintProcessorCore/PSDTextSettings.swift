import Foundation
import CoreGraphics

/// Horizontal alignment for the layer-2 PSD text inside its bounding box.
public enum TextAlign: String, Codable, CaseIterable {
    case left, centre, right

    public var displayName: String {
        switch self {
        case .left: return "Left"
        case .centre: return "Centre"
        case .right: return "Right"
        }
    }
}

/// A normalised bounding box for the layer-2 text: x/y are the top-left corner
/// and width/height are fractions of the canvas (0…1). Canvas-independent, so
/// the same box maps onto any preview or export size.
public struct PSDTextBox: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0.1, y: Double = 0.05, width: Double = 0.8, height: Double = 0.2) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let defaults = PSDTextBox()

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Map the normalised box onto a concrete canvas (origin bottom-left, y-up).
    public func pixelRect(canvas: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * canvas.width,
               y: CGFloat(1 - y - height) * canvas.height,
               width: CGFloat(width) * canvas.width,
               height: CGFloat(height) * canvas.height)
    }

    /// Clamp a box built from two raw screen fractions into valid 0…1 ranges.
    public func clamped() -> PSDTextBox {
        var b = self
        b.x = min(max(0, x), 0.999)
        b.y = min(max(0, y), 0.999)
        b.width = min(max(0.001, width), 1 - b.x)
        b.height = min(max(0.001, height), 1 - b.y)
        return b
    }
}

/// Layer-2 (PSD styled text) settings.
public struct PSDTextSettings: Codable, Equatable {
    public var path: String
    public var align: TextAlign
    public var box: PSDTextBox

    public init(path: String = "", align: TextAlign = .centre, box: PSDTextBox = .defaults) {
        self.path = path
        self.align = align
        self.box = box
    }

    public static let defaults = PSDTextSettings()
}

/// Geometry for fitting a trimmed text image inside a box with alignment.
public enum PSDTextLayout {
    /// Fit (contain) `imageSize` inside `box` and align horizontally.
    public static func fittedRect(box: CGRect, imageSize: CGSize, align: TextAlign) -> CGRect {
        guard box.width > 0, box.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return box
        }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let x: CGFloat
        switch align {
        case .left: x = box.minX
        case .right: x = box.maxX - w
        case .centre: x = box.midX - w / 2
        }
        let y = box.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
