import Foundation
import CoreGraphics

/// Fast, low-resolution interactive preview renderer.
///
/// Static layers (5/6 below the photo and 3/2/1 above it) are rendered ONCE per
/// image + canvas size into cached `CGImage`s. Every subsequent frame only
/// draws those two cached images plus the transformed subject photo, so a
/// scroll/pan/rotate gesture never re-decodes or re-composites the static
/// layers or the full-resolution photo.
public final class InteractivePreviewRenderer {
    private let compositor: Compositor

    private var project: ProjectModel?
    private var below: CGImage?
    private var above: CGImage?
    private var canvas: CGSize = .zero
    private var imageIndex: Int = 0

    public init(compositor: Compositor = Compositor()) {
        self.compositor = compositor
    }

    /// Whether static layers have been prepared for a size/image.
    public var isPrepared: Bool { below != nil || above != nil }

    /// Pre-render (and cache) the static layers for `canvasPixelSize`. Call once
    /// per image + size, then again only when a static-layer setting changes.
    public func prepare(project: ProjectModel, imageIndex: Int, canvasPixelSize: CGSize) {
        self.project = project
        self.imageIndex = imageIndex
        self.canvas = canvasPixelSize
        self.below = compositor.renderStaticBelow(project: project, imageIndex: imageIndex, canvasPixelSize: canvasPixelSize)
        self.above = compositor.renderStaticAbove(project: project, imageIndex: imageIndex, canvasPixelSize: canvasPixelSize)
    }

    /// Invalidate the cached static layers (e.g. after a settings change).
    public func invalidateStatic() {
        below = nil
        above = nil
    }

    /// Render one frame: cached static layers + the transformed photo. This is
    /// the per-frame hot path for gestures; it does no full-res decode and no
    /// static-layer recomposition.
    public func renderFrame(edit: ImageEdit, photo: CGImage) -> CGImage? {
        guard let project, canvas.width > 0, canvas.height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvas.width.rounded()),
            height: Int(canvas.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(origin: .zero, size: canvas)
        if let below { ctx.draw(below, in: rect) }
        compositor.drawPhotoInto(ctx, photo: photo, edit: edit, project: project, canvas: canvas, imageIndex: imageIndex)
        if let above { ctx.draw(above, in: rect) }

        return ctx.makeImage()
    }
}
