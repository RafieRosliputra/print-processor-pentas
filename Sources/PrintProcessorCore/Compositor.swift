import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO

/// Derives the layer-1 watermark text from a file name. The default rule takes
/// the right part after the last " - " (extension stripped), which matches
/// `"Tingkatan 1C - 01.jpg" -> "01"`. Full scan modes arrive in a later
/// milestone; swap `current` to change the behaviour app-wide.
public enum WatermarkTextProvider {
    public typealias Provider = (String) -> String

    /// The provider used everywhere. Replace it to change how watermark text is
    /// derived from a file name.
    public static var current: Provider = defaultText

    /// Default rule: right part of the file name split on " - ", extension
    /// removed, or empty when no " - " separator is present.
    public static func defaultText(for fileName: String) -> String {
        let parts = fileName.components(separatedBy: " - ")
        guard parts.count >= 2 else { return "" }
        let right = parts[parts.count - 1]
        let url = URL(fileURLWithPath: right)
        let stem = url.deletingPathExtension().lastPathComponent
        return stem
    }
}

/// Geometry shared by the renderer and the canvas so that preview and export
/// place layers identically. All coordinates are canvas points with the origin
/// at the bottom-left (positive Y up), matching `ImageEdit`.
public enum LayerGeometry {
    /// Scale image to fit entirely inside `canvas` (letterbox / contain).
    public static func fittedRect(canvas: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        return centeredRect(size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale), canvas: canvas)
    }

    /// Scale image to cover `canvas` (crop / cover).
    public static func filledRect(canvas: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        return centeredRect(size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale), canvas: canvas)
    }

    /// Transform mapping a rect centred on the canvas centre through offset /
    /// rotate / scale about that centre (scale applied first, then rotation,
    /// then translation — identical to the layer-4 free transform).
    public static func centeredTransform(
        canvas: CGSize,
        offsetX: Double,
        offsetY: Double,
        scaleX: Double,
        scaleY: Double,
        rotationDeg: Double
    ) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2)
        t = t.concatenating(CGAffineTransform(translationX: CGFloat(offsetX), y: CGFloat(offsetY)))
        t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(rotationDeg * .pi / 180)))
        t = t.concatenating(CGAffineTransform(scaleX: CGFloat(scaleX), y: CGFloat(scaleY)))
        return t
    }

    /// Axis-aligned bounding box of `rect` under `transform`.
    public static func boundingBox(of rect: CGRect, transform: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.minY).applying(transform),
            CGPoint(x: rect.minX, y: rect.maxY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.maxY).applying(transform),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// Axis-aligned bounding box of a list of points (empty → .zero).
    public static func boundingBox(of corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The four corners of `rect` under `transform`, ordered bottom-left,
    /// bottom-right, top-right, top-left (canvas coordinates, y-up).
    public static func corners(of rect: CGRect, transform: CGAffineTransform) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.minY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.maxY).applying(transform),
            CGPoint(x: rect.minX, y: rect.maxY).applying(transform),
        ]
    }

    /// The four corners of a rect centred on the origin (size `baseSize`) after
    /// the Compositor's scale → rotate → offset-about-centre pipeline. This is
    /// the exact drawn quad for layers 3/4, so the canvas selection box can be
    /// drawn and hit-tested against the real transformed shape.
    public static func centeredCorners(
        canvas: CGSize,
        baseSize: CGSize,
        offsetX: Double,
        offsetY: Double,
        scaleX: Double,
        scaleY: Double,
        rotationDeg: Double
    ) -> [CGPoint] {
        let local = CGRect(x: -baseSize.width / 2, y: -baseSize.height / 2,
                           width: baseSize.width, height: baseSize.height)
        let t = centeredTransform(canvas: canvas, offsetX: offsetX, offsetY: offsetY,
                                  scaleX: scaleX, scaleY: scaleY, rotationDeg: rotationDeg)
        return corners(of: local, transform: t)
    }

    /// Layer-3 overlay's drawn corners (fit/fill + free transform), matching the
    /// renderer's `drawOverlay`. `offsetScale` converts stored paper-pixel
    /// offsets into the requested canvas space (1 when canvas == paper).
    public static func overlayCorners(canvas: CGSize, imageSize: CGSize,
                                      overlay: OverlaySettings, offsetScale: Double = 1) -> [CGPoint] {
        let base = overlay.fit ? fittedRect(canvas: canvas, imageSize: imageSize)
                               : filledRect(canvas: canvas, imageSize: imageSize)
        return centeredCorners(canvas: canvas, baseSize: base.size,
                               offsetX: overlay.transform.offsetX * offsetScale,
                               offsetY: overlay.transform.offsetY * offsetScale,
                               scaleX: overlay.transform.scaleX,
                               scaleY: overlay.transform.scaleY,
                               rotationDeg: overlay.transform.rotationDeg)
    }

    /// Layer-1 watermark's drawn corners (bottom-right anchor + rotation),
    /// matching the renderer's `drawWatermark`.
    public static func watermarkCorners(canvas: CGSize, watermark: WatermarkSettings) -> [CGPoint] {
        let base = watermarkBaseSize(canvas: canvas, watermark: watermark)
        guard base.width > 0, base.height > 0 else { return [] }
        let w = base.width * CGFloat(watermark.transform.scaleX)
        let h = base.height * CGFloat(watermark.transform.scaleY)
        let ax = canvas.width * (1 - CGFloat(watermark.transform.offsetFractionX))
        let ay = canvas.height * CGFloat(watermark.transform.offsetFractionY)
        let rect = CGRect(x: -w, y: 0, width: w, height: h)
        let t = CGAffineTransform(translationX: ax, y: ay)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(watermark.transform.rotationDeg * .pi / 180)))
        return corners(of: rect, transform: t)
    }

    /// Bounding rect of layer 4 (subject photo) under `edit`.
    public static func photoRect(canvas: CGSize, imageSize: CGSize, edit: ImageEdit) -> CGRect {
        let fit = fittedRect(canvas: canvas, imageSize: imageSize)
        let local = CGRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height)
        let t = centeredTransform(canvas: canvas, offsetX: edit.offsetX, offsetY: edit.offsetY,
                                  scaleX: edit.scale, scaleY: edit.scale, rotationDeg: edit.rotationDeg)
        return boundingBox(of: local, transform: t)
    }

    /// Bounding rect of layer 3 (overlay) under its fit/fill + transform.
    public static func overlayRect(canvas: CGSize, imageSize: CGSize, overlay: OverlaySettings) -> CGRect {
        let base = overlay.fit ? fittedRect(canvas: canvas, imageSize: imageSize)
                               : filledRect(canvas: canvas, imageSize: imageSize)
        let local = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
        let t = centeredTransform(canvas: canvas, offsetX: overlay.transform.offsetX,
                                  offsetY: overlay.transform.offsetY,
                                  scaleX: overlay.transform.scaleX,
                                  scaleY: overlay.transform.scaleY,
                                  rotationDeg: overlay.transform.rotationDeg)
        return boundingBox(of: local, transform: t)
    }

    /// Size of the watermark text box at scale 1 (transform.scale not applied),
    /// in the given canvas coordinate space.
    public static func watermarkBaseSize(canvas: CGSize, watermark: WatermarkSettings) -> CGSize {
        guard !watermark.text.isEmpty else { return .zero }
        let fontSize = CGFloat(watermark.sizeFraction * Double(canvas.width))
        guard fontSize > 0 else { return .zero }
        let font = Compositor.resolveFont(name: watermark.fontName, size: fontSize)
        let attributed = NSAttributedString(string: watermark.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent)
    }

    /// Bounding rect of layer 1 (watermark text) under its transform.
    public static func watermarkRect(canvas: CGSize, watermark: WatermarkSettings) -> CGRect {
        guard !watermark.text.isEmpty else { return .zero }
        let fontSize = CGFloat(watermark.sizeFraction * Double(canvas.width))
        guard fontSize > 0 else { return .zero }
        let font = Compositor.resolveFont(name: watermark.fontName, size: fontSize)
        let attributed = NSAttributedString(string: watermark.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)) * CGFloat(watermark.transform.scaleX)
        let height = (ascent + descent) * CGFloat(watermark.transform.scaleY)

        let ax = CGFloat(Double(canvas.width) * (1 - watermark.transform.offsetFractionX))
        let ay = CGFloat(Double(canvas.height) * watermark.transform.offsetFractionY)
        let rect = CGRect(x: -width, y: 0, width: width, height: height)
        let t = CGAffineTransform(translationX: ax, y: ay)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(watermark.transform.rotationDeg * .pi / 180)))
        return boundingBox(of: rect, transform: t)
    }

    private static func centeredRect(size: CGSize, canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - size.width) / 2,
               y: (canvas.height - size.height) / 2,
               width: size.width,
               height: size.height)
    }
}

/// Renders a project's layers bottom→top into a single `CGImage`. Uses only
/// CoreGraphics / CoreImage / CoreText / ImageIO (no AppKit), so it works for
/// both full-resolution export and downscaled previews.
public final class Compositor {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Layer-2 styled text image (trimmed), set by the controller after a
    /// background Photoshop render. Drawn fitted into `layer2Box`.
    public var layer2Image: CGImage?
    /// Normalised layer-2 bounding box (per-image override already applied).
    public var layer2Box: PSDTextBox = .defaults
    /// Horizontal alignment for layer 2.
    public var layer2Align: TextAlign = .centre
    /// Filename-scan mode used to derive layer-1/2 text.
    public var scanMode: String = "text=right"

    public init() {}

    /// Drop cached decoded images (e.g. after loading a new overlay file).
    public func invalidateCache() {
        DecodedImageCache.shared.invalidateAll()
    }

    /// Render one image of a project at `canvasPixelSize`.
    ///
    /// - Parameters:
    ///   - project: The project (layer settings, edit store, selected size).
    ///   - imageIndex: Index into `project.files` for the layer-4 photo.
    ///   - canvasPixelSize: Output size in pixels (paper pixels for export,
    ///     smaller for preview).
    ///   - photoSource: Returns the decoded layer-4 photo for a file index.
    public func render(
        project: ProjectModel,
        imageIndex: Int,
        canvasPixelSize: CGSize,
        photoSource: (Int) -> CGImage?
    ) -> CGImage? {
        let width = Int(canvasPixelSize.width.rounded())
        let height = Int(canvasPixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: Self.colorSpace!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let ls = project.layerSettings
        let canvas = canvasPixelSize

        // Pixel offsets are stored in paper-pixel units; scale them to the
        // requested output size so preview and full-res export agree.
        let offsetScale = Self.offsetScale(project: project, canvas: canvas)

        // Layer 6 — final background (bottom).
        if ls.enabled.layer6 {
            drawFinalBackground(ctx, ls.bg6, canvas)
        }
        // Layer 5 — background image with alpha.
        if ls.enabled.layer5, let image = image(atPath: ls.bg5.path) {
            ctx.draw(image, in: LayerGeometry.filledRect(canvas: canvas, imageSize: CGSize(width: image.width, height: image.height)))
        }
        // Layer 4 — subject photo, then its gradient.
        if ls.enabled.layer4, let photo = photoSource(imageIndex) {
            let edit = photoEdit(for: project, imageIndex: imageIndex)
            let scaledEdit = ImageEdit(scale: edit.scale,
                                       offsetX: edit.offsetX * offsetScale,
                                       offsetY: edit.offsetY * offsetScale,
                                       rotationDeg: edit.rotationDeg)
            let photoSize = CGSize(width: photo.width, height: photo.height)
            drawPhoto(ctx, photo, canvas: canvas, photoSize: photoSize, edit: scaledEdit)
            if ls.gradient.enabled {
                drawGradient(ctx, ls.gradient, canvas: canvas, photoSize: photoSize, edit: scaledEdit)
            }
        }
        // Layer 3 — overlay.
        if ls.enabled.layer3, let image = image(atPath: ls.overlay.path) {
            drawOverlay(ctx, image, canvas: canvas, overlay: ls.overlay, offsetScale: offsetScale)
        }
        // Layer 2 — PSD styled text (trimmed image fitted into the box).
        if ls.enabled.layer2, let image = layer2Image {
            let boxRect = layer2Box.pixelRect(canvas: canvas)
            let drawRect = PSDTextLayout.fittedRect(
                box: boxRect,
                imageSize: CGSize(width: image.width, height: image.height),
                align: layer2Align
            )
            ctx.draw(image, in: drawRect)
        }
        // Layer 1 — watermark text (manual edit → list → filename scan).
        if ls.enabled.layer1 {
            var watermark = ls.watermark
            if watermark.text.isEmpty {
                let fileName = project.files.indices.contains(imageIndex) ? project.files[imageIndex] : ""
                watermark.text = resolveText(project: project, fileName: fileName).watermark
            }
            drawWatermark(ctx, watermark, canvas: canvas)
        }

        return ctx.makeImage()
    }

    // MARK: - Text resolution

    private func resolveText(project: ProjectModel, fileName: String) -> TextResolution {
        let sizeKey = project.selectedSize?.rawValue ?? ""
        let manualText = project.edits.manualText(sizeKey: sizeKey, fileName: fileName) ?? ""
        return TextSourceResolver.resolve(
            fileName: fileName,
            manualText: manualText,
            list: project.psdTextList,
            scanMode: ScanMode.parse(scanMode)
        )
    }

    // MARK: - Photo edit lookup

    private func photoEdit(for project: ProjectModel, imageIndex: Int) -> ImageEdit {
        guard let size = project.selectedSize else { return .identity }
        let fileName = project.files.indices.contains(imageIndex) ? project.files[imageIndex] : ""
        return project.edits.edit(sizeKey: size.rawValue, fileName: fileName) ?? .identity
    }

    /// Ratio between the requested canvas width and the canonical paper width
    /// (orientation-aware), used to rescale stored pixel offsets.
    static func offsetScale(project: ProjectModel, canvas: CGSize) -> Double {
        guard let size = project.selectedSize, canvas.width > 0 else { return 1 }
        var paperW = Double(size.pixelWidth)
        var paperH = Double(size.pixelHeight)
        let canvasLandscape = Double(canvas.width) >= Double(canvas.height)
        let paperLandscape = paperW >= paperH
        if canvasLandscape != paperLandscape {
            swap(&paperW, &paperH)
        }
        guard paperW > 0 else { return 1 }
        return Double(canvas.width) / paperW
    }

    // MARK: - Image loading

    private func image(atPath path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        return DecodedImageCache.shared.decode(path)
    }

    // MARK: - Layer drawing

    private func drawFinalBackground(_ ctx: CGContext, _ bg: FinalBackground, _ canvas: CGSize) {
        switch bg {
        case .colour(let colour):
            ctx.setFillColor(cgColor(colour))
            ctx.fill(CGRect(origin: .zero, size: canvas))
        case .image(let path):
            if let image = image(atPath: path) {
                ctx.draw(image, in: LayerGeometry.filledRect(canvas: canvas, imageSize: CGSize(width: image.width, height: image.height)))
            }
        }
    }

    private func drawPhoto(_ ctx: CGContext, _ image: CGImage, canvas: CGSize, photoSize: CGSize, edit: ImageEdit) {
        let fit = LayerGeometry.fittedRect(canvas: canvas, imageSize: photoSize)
        let local = CGRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height)
        ctx.saveGState()
        ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        ctx.translateBy(x: CGFloat(edit.offsetX), y: CGFloat(edit.offsetY))
        ctx.rotate(by: CGFloat(edit.rotationDeg * .pi / 180))
        ctx.scaleBy(x: CGFloat(edit.scale), y: CGFloat(edit.scale))
        ctx.draw(image, in: local)
        ctx.restoreGState()
    }

    private func drawGradient(_ ctx: CGContext, _ gradient: GradientSettings, canvas: CGSize, photoSize: CGSize, edit: ImageEdit) {
        let fit = LayerGeometry.fittedRect(canvas: canvas, imageSize: photoSize)
        let local = CGRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height)
        ctx.saveGState()
        ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        ctx.translateBy(x: CGFloat(edit.offsetX), y: CGFloat(edit.offsetY))
        ctx.rotate(by: CGFloat(edit.rotationDeg * .pi / 180))
        ctx.scaleBy(x: CGFloat(edit.scale), y: CGFloat(edit.scale))
        ctx.clip(to: local)

        ctx.setBlendMode(blendMode(gradient.blend))
        ctx.setAlpha(CGFloat(gradient.opacity))

        let radius = hypot(local.width, local.height) / 2
        let angle = gradient.angle * .pi / 180
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let start = CGPoint(x: -dir.x * radius, y: -dir.y * radius)
        let end = CGPoint(x: dir.x * radius, y: dir.y * radius)

        let colors = [cgColor(gradient.colorA), cgColor(gradient.colorB)] as CFArray
        if let grad = CGGradient(colorsSpace: Self.colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    private func drawOverlay(_ ctx: CGContext, _ image: CGImage, canvas: CGSize, overlay: OverlaySettings, offsetScale: Double) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let base = overlay.fit ? LayerGeometry.fittedRect(canvas: canvas, imageSize: imageSize)
                               : LayerGeometry.filledRect(canvas: canvas, imageSize: imageSize)
        let local = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
        ctx.saveGState()
        ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        ctx.translateBy(x: CGFloat(overlay.transform.offsetX * offsetScale), y: CGFloat(overlay.transform.offsetY * offsetScale))
        ctx.rotate(by: CGFloat(overlay.transform.rotationDeg * .pi / 180))
        ctx.scaleBy(x: CGFloat(overlay.transform.scaleX), y: CGFloat(overlay.transform.scaleY))
        ctx.draw(image, in: local)
        ctx.restoreGState()
    }

    private func drawWatermark(_ ctx: CGContext, _ watermark: WatermarkSettings, canvas: CGSize) {
        guard !watermark.text.isEmpty else { return }
        let fontSize = CGFloat(watermark.sizeFraction * Double(canvas.width))
        guard fontSize > 0 else { return }

        let font = Self.resolveFont(name: watermark.fontName, size: fontSize)
        let attributed = NSAttributedString(string: watermark.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(watermark.colour),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let ax = CGFloat(Double(canvas.width) * (1 - watermark.transform.offsetFractionX))
        let ay = CGFloat(Double(canvas.height) * watermark.transform.offsetFractionY)

        ctx.saveGState()
        ctx.setAlpha(CGFloat(watermark.opacity))
        ctx.translateBy(x: ax, y: ay)
        ctx.rotate(by: CGFloat(watermark.transform.rotationDeg * .pi / 180))
        ctx.scaleBy(x: CGFloat(watermark.transform.scaleX), y: CGFloat(watermark.transform.scaleY))
        ctx.textPosition = CGPoint(x: -width, y: descent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Helpers

    /// Resolve a font name to a CoreText font, falling back to the system UI
    /// font when the name is unknown (which CTFontCreateWithName signals by
    /// returning the "LastResort" font).
    static func resolveFont(name: String, size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let psName = CTFontCopyPostScriptName(font) as String
        if psName == "LastResort" || psName.isEmpty {
            return CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
        }
        return font
    }

    private func cgColor(_ colour: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(colour.red), green: CGFloat(colour.green),
                blue: CGFloat(colour.blue), alpha: CGFloat(colour.alpha))
    }

    private func blendMode(_ blend: GradientBlend) -> CGBlendMode {
        switch blend {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        }
    }
}
