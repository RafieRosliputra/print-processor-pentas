import Foundation

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
}
