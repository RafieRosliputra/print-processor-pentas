import Foundation
import CoreGraphics

/// Scope of a global (absolute) layer-4 edit.
/// - `.none`: only the current image.
/// - `.all`: every image (Cmd+Shift held).
/// - `.after`: only images after the current one (Shift held, no Cmd).
public enum GlobalEditScope: Equatable {
    case none
    case all
    case after
}

/// Per-image, per-size placement for layer 4 (subject photo).
///
/// `scale` is a zoom multiplier relative to "Fit" (1.0 = fit inside the canvas).
/// `offsetX` / `offsetY` are pan offsets in canvas points (positive X = right,
/// positive Y = up). `rotationDeg` is clockwise rotation in degrees.
public struct ImageEdit: Codable, Equatable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var rotationDeg: Double

    /// Fit placement: no zoom, no pan, no rotation.
    public static let identity = ImageEdit(scale: 1, offsetX: 0, offsetY: 0, rotationDeg: 0)

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, rotationDeg: Double = 0) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDeg = rotationDeg
    }

    /// Proportionally rescale this edit from one canvas size to another, so a
    /// placement stored for one paper size carries over to a new size instead of
    /// resetting to Fit. `scale` (zoom relative to Fit) and rotation are
    /// size-independent; pixel offsets scale with the canvas dimensions.
    public func scaled(fromCanvas old: CGSize, toCanvas new: CGSize) -> ImageEdit {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return self }
        return ImageEdit(
            scale: scale,
            offsetX: offsetX * Double(new.width / old.width),
            offsetY: offsetY * Double(new.height / old.height),
            rotationDeg: rotationDeg
        )
    }
}
