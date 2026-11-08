import AppKit
import PrintProcessorCore

/// A layer that can be selected on the canvas and free-transformed with the red
/// box + handles: 1 = watermark, 2 = PSD text, 3 = overlay, or one of the extra
/// user layers (identified by its UUID).
enum SelectedLayer: Equatable {
    case watermark
    case psdText
    case overlay
    case extraLayer(UUID)
}

/// Interactive canvas. Draws the composited preview (all layers) into the paper
/// rect, keeps the layer-4 gestures (pan / zoom / rotate / nudge / navigation),
/// and lets the user select and free-transform layer 1 (watermark) and layer 3
/// (overlay) with a red box, 8 handles and a rotate zone outside the corners.
final class CanvasView: NSView {
    // MARK: - Display state (owned by the controller)

    /// True until a paper size is chosen.
    var locked: Bool = true {
        didSet { needsDisplay = true; needsLayout = true; updateHint() }
    }

    /// Display width/height ratio of the paper rect.
    var paperAspect: CGFloat? {
        didSet { needsLayout = true }
    }

    /// Paper export-pixel size (used for export-pixel nudges).
    var paperPixelSize: CGSize? {
        didSet { needsLayout = true }
    }

    /// Composited preview image (all layers) to draw into the paper rect.
    var compositedImage: CGImage? {
        didSet { compositeLayer.contents = compositedImage; needsLayout = true; updateHint() }
    }

    /// Pixel size the composited image was rendered at (canvas coordinates).
    var compositePixelSize: CGSize = CGSize(width: 1, height: 1) {
        didSet { needsLayout = true }
    }

    /// Current layer-4 placement (mutating reports upward via `onEdit`).
    var edit: ImageEdit = .identity {
        didSet { needsDisplay = true }
    }

    /// Live settings for zoom/rotate speed, rotate step and nudge basis.
    var settings: AppSettings = .defaults
    /// Live keyboard bindings (read on every key event, no restart needed).
    var shortcuts: ShortcutStore = .shared

    // Layer 1 / 3 selection state (canvas coordinates, y-up).
    var watermarkBaseSize: CGSize?
    var overlayBaseSize: CGSize?
    var watermarkTransform: WatermarkTransform = .identity {
        didSet { needsDisplay = true }
    }
    var overlayTransform: OverlayTransform = .identity {
        didSet { needsDisplay = true }
    }

    /// Per-extra-layer canvas state (base size + current transform), in preview
    /// space. List order matches the panel: top of list = top of stack.
    struct ExtraLayerCanvasState {
        let id: UUID
        var baseSize: CGSize?
        var transform: OverlayTransform
    }
    var extraLayerStates: [ExtraLayerCanvasState] = [] {
        didSet { needsDisplay = true }
    }

    // Layer 2 (PSD text) box state (normalised 0…1; nil = no PSD loaded).
    var psdTextBox: PSDTextBox? {
        didSet { needsDisplay = true; updateSelectionLayer() }
    }
    var psdTextAlign: TextAlign = .centre

    // MARK: - Callbacks

    /// Layer-4 edit produced by user input (`commit` = discrete/undoable).
    /// `scope` reports whether Cmd+Shift / Shift requested a global edit.
    var onEdit: ((ImageEdit, Bool, GlobalEditScope) -> Void)?
    /// A continuous layer-4 gesture just started — record an undo baseline.
    var onGestureBegan: (() -> Void)?

    /// Whether the current photo is flagged "NO EXPORT" (canvas-only visual).
    var noExport: Bool = false {
        didSet { updateNoExportOverlay() }
    }
    var onNextFile: (() -> Void)?
    var onPreviousFile: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onRender: (() -> Void)?
    var onProcess: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onToggleNoExport: (() -> Void)?
    var onTogglePreviewFull: (() -> Void)?

    /// The selection changed (nil = deselected). Carries the full selection so
    /// the controller can also track which extra layer (if any) is selected.
    var onSelectionChanged: ((SelectedLayer?) -> Void)?
    /// Layer-1 transform changed. `commit` = gesture finished; `option` = the
    /// Option key was held (write a per-image override).
    var onWatermarkChanged: ((WatermarkTransform, Bool, Bool) -> Void)?
    /// Layer-3 transform changed (same commit/option convention).
    var onOverlayChanged: ((OverlayTransform, Bool, Bool) -> Void)?
    /// Extra-layer transform changed. `option` = write a per-image override.
    var onExtraLayerChanged: ((UUID, OverlayTransform, Bool, Bool) -> Void)?
    /// Layer-2 bounding box changed. `commit` = gesture finished; `option` =
    /// Option was held (write a per-image override).
    var onPSDTextBoxChanged: ((PSDTextBox, Bool, Bool) -> Void)?
    /// Middle-click (button 2) hit a layer element: 2 / 3 / 4.
    var onMiddleClick: ((Int) -> Void)?

    // MARK: - Internal state

    private let paperLayer = CALayer()
    private let compositeLayer = CALayer()
    private let selectionLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let hintLabel = NSTextField(labelWithString: "")

    // "NO EXPORT" canvas-only overlay (never part of the rendered output).
    private let noExportDimLayer = CALayer()
    private let noExportXLayer = CAShapeLayer()
    private let noExportLabel = PassthroughLabel()

    private var selection: SelectedLayer? {
        didSet {
            updateSelectionLayer()
            onSelectionChanged?(selection)
        }
    }

    private var isMouseOver = false
    private var isRDown = false
    private var lastDragPoint: NSPoint?
    private var spacePending: DispatchWorkItem?
    private var commitWorkItem: DispatchWorkItem?
    private var lastCommittedEdit: ImageEdit?
    private var preciseRotateAccum: Double = 0
    private var gestureActive = false
    private var gestureEndWorkItem: DispatchWorkItem?
    private var lastGestureScope: GlobalEditScope = .none

    // Layer 1 / 3 free-transform gesture state.
    private enum TransformMode { case move, scale, rotate }
    private var transformGestureLayer: SelectedLayer?
    private var transformGestureMode: TransformMode = .move
    private var transformGestureStart: CGPoint = .zero      // canvas coordinates
    private var transformGestureOption = false
    private var transformGestureShift = false
    private var transformGestureScaleHandle: Int? = nil
    private var transformGestureAnchor: CGPoint = .zero
    private var transformGestureStartWatermark = WatermarkTransform.identity
    private var transformGestureStartOverlay = OverlayTransform.identity
    private var transformGestureStartPSDBox = PSDTextBox.defaults
    private var transformGestureStartExtra = OverlayTransform.identity
    private var transformGestureExtraID: UUID?
    // Rotation pivot (element centre) captured at mouseDown.
    private var transformGesturePivot: CGPoint = .zero
    // Scale-gesture snapshot (canvas coordinates), recomputed from the
    // mouseDown transforms every drag so the box never drifts or accumulates.
    private var transformGestureStartCorners: [CGPoint] = []
    private var transformGestureStartCenter: CGPoint = .zero
    private var transformGestureHandleCenter: CGPoint = .zero
    private var transformGestureGrabOffset: CGPoint = .zero
    private var transformGestureRotation: Double = 0

    // Layer-2 box rubber-band drawing state (armed by the panel's Draw box).
    private var psdBoxDrawingEnabled = false
    private var psdBoxDrawStart: CGPoint? = nil

    // Hover glow (layer 2 / 3).
    private var hoveredLayer: Int? {
        didSet { if hoveredLayer != oldValue { needsDisplay = true; updateGlow() } }
    }

    private static let padding: CGFloat = 28
    private static let minScale = 0.05
    private static let maxScale = 50.0
    /// Free-transform resize scale limits (2% … 2000%), per the handle-drag spec.
    private static let minResizeScale = 0.02
    private static let maxResizeScale = 20.0
    private static let gestureIdleMs = 400
    private static let handleSize: CGFloat = 8
    private static let rotateHandleRadius: CGFloat = 7
    private static let rotateOffset: CGFloat = 22
    private static let hitThreshold: CGFloat = 8

    // MARK: - Resize / rotate cursors

    private enum CursorGlyph { case diagNWSE, diagNESW, rotate }

    private static let diagNWSECursor: NSCursor = makeCursor(.diagNWSE)
    private static let diagNESWCursor: NSCursor = makeCursor(.diagNESW)
    private static let rotateCursor: NSCursor = makeCursor(.rotate)

    /// Draw a small double-headed arrow cursor (black with a white halo so it
    /// stays visible over dark canvas pixels).
    private static func makeCursor(_ glyph: CursorGlyph) -> NSCursor {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setLineCap(.round)
            func stroke(_ pts: [CGPoint], _ color: NSColor, _ width: CGFloat) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(width)
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
            func draw(_ pts: [CGPoint]) {
                stroke(pts, .white, 2.4)
                stroke(pts, .black, 1.0)
            }
            switch glyph {
            case .diagNWSE: // backslash "\" — NW ⇄ SE
                draw([CGPoint(x: 2.5, y: 13.5), CGPoint(x: 13.5, y: 2.5)])
                draw([CGPoint(x: 2.5, y: 13.5), CGPoint(x: 7.5, y: 13.5)])
                draw([CGPoint(x: 2.5, y: 13.5), CGPoint(x: 2.5, y: 8.5)])
                draw([CGPoint(x: 13.5, y: 2.5), CGPoint(x: 8.5, y: 2.5)])
                draw([CGPoint(x: 13.5, y: 2.5), CGPoint(x: 13.5, y: 7.5)])
            case .diagNESW: // slash "/" — NE ⇄ SW
                draw([CGPoint(x: 2.5, y: 2.5), CGPoint(x: 13.5, y: 13.5)])
                draw([CGPoint(x: 2.5, y: 2.5), CGPoint(x: 7.5, y: 2.5)])
                draw([CGPoint(x: 2.5, y: 2.5), CGPoint(x: 2.5, y: 7.5)])
                draw([CGPoint(x: 13.5, y: 13.5), CGPoint(x: 8.5, y: 13.5)])
                draw([CGPoint(x: 13.5, y: 13.5), CGPoint(x: 13.5, y: 8.5)])
            case .rotate: // circular arrow
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.0)
                ctx.addArc(center: CGPoint(x: 8, y: 8), radius: 5, startAngle: 0.4, endAngle: .pi * 1.75, clockwise: true)
                ctx.strokePath()
                draw([CGPoint(x: 12.8, y: 6.2), CGPoint(x: 12.8, y: 11.4)])
                draw([CGPoint(x: 12.8, y: 11.4), CGPoint(x: 7.6, y: 11.4)])
            }
        }
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.canvas.cgColor

        paperLayer.backgroundColor = NSColor(hex: "#262626").cgColor
        paperLayer.borderColor = NSColor.border.cgColor
        paperLayer.borderWidth = 1
        paperLayer.cornerRadius = 2
        layer?.addSublayer(paperLayer)

        compositeLayer.contentsGravity = .resize
        paperLayer.addSublayer(compositeLayer)

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.systemRed.cgColor
        selectionLayer.lineWidth = 1.5
        layer?.addSublayer(selectionLayer)

        hoverLayer.fillColor = NSColor.glow.withAlphaComponent(0.12).cgColor
        hoverLayer.strokeColor = NSColor.glow.cgColor
        hoverLayer.lineWidth = 2
        layer?.addSublayer(hoverLayer)

        noExportDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.addSublayer(noExportDimLayer)
        noExportXLayer.strokeColor = NSColor(hex: "#FF3B30").cgColor
        noExportXLayer.lineWidth = 8
        noExportXLayer.lineCap = .round
        noExportXLayer.fillColor = nil
        layer?.addSublayer(noExportXLayer)

        noExportLabel.stringValue = "NO EXPORT"
        noExportLabel.font = NSFont.boldSystemFont(ofSize: 28)
        noExportLabel.textColor = NSColor(hex: "#FF3B30")
        noExportLabel.alignment = .center
        noExportLabel.isEditable = false
        noExportLabel.isSelectable = false
        noExportLabel.drawsBackground = false
        noExportLabel.isBezeled = false
        addSubview(noExportLabel)
        updateNoExportOverlay()

        hintLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .dimText
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 0
        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.widthAnchor.constraint(equalToConstant: 380),
        ])

        registerForDraggedTypes([.fileURL])
        updateHint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        paperLayer.frame = paperRect()
        compositeLayer.frame = paperLayer.bounds
        updateSelectionLayer()
        updateHoverLayer()
        updateNoExportOverlay()
    }

    /// The paper rectangle fitted into the view bounds.
    func paperRect() -> CGRect {
        let bounds = self.bounds.insetBy(dx: Self.padding, dy: Self.padding)
        guard let aspect = paperAspect, aspect > 0 else {
            return bounds
        }
        var w = bounds.width
        var h = w / aspect
        if h > bounds.height {
            h = bounds.height
            w = h * aspect
        }
        return CGRect(
            x: (self.bounds.width - w) / 2,
            y: (self.bounds.height - h) / 2,
            width: w,
            height: h
        )
    }

    /// Screen points per canvas point (composite pixel).
    private func screenScale() -> CGFloat {
        guard compositePixelSize.width > 0 else { return 1 }
        return paperRect().width / compositePixelSize.width
    }

    /// Ratio composite-pixel width → canonical paper-pixel width, used to
    /// rescale stored pixel offsets (layer 4 / overlay) into preview space.
    private func canvasOffsetScale() -> CGFloat {
        guard let paper = paperPixelSize, paper.width > 0, compositePixelSize.width > 0 else { return 1 }
        return compositePixelSize.width / paper.width
    }

    private func canvasPoint(_ p: NSPoint) -> CGPoint {
        let rect = paperRect()
        let s = screenScale()
        return CGPoint(x: (p.x - rect.minX) / s, y: (p.y - rect.minY) / s)
    }

    private func screenPoint(_ p: CGPoint) -> CGPoint {
        let rect = paperRect()
        let s = screenScale()
        return CGPoint(x: rect.minX + p.x * s, y: rect.minY + p.y * s)
    }

    // MARK: - Layer quads (canvas coordinates, y-up)

    /// Layer-3 overlay's four drawn corners (fit/fill + free transform), using
    /// the same pivot/scale/rotation the Compositor's `drawOverlay` uses.
    private func overlayCorners() -> [CGPoint] {
        guard let base = overlayBaseSize, base.width > 0, base.height > 0 else { return [] }
        let s = Double(canvasOffsetScale())
        return LayerGeometry.centeredCorners(
            canvas: compositePixelSize,
            baseSize: base,
            offsetX: overlayTransform.offsetX * s,
            offsetY: overlayTransform.offsetY * s,
            scaleX: overlayTransform.scaleX,
            scaleY: overlayTransform.scaleY,
            rotationDeg: overlayTransform.rotationDeg
        )
    }

    /// Layer-1 watermark's four drawn corners (bottom-right anchor + rotation).
    private func watermarkCorners() -> [CGPoint] {
        guard let base = watermarkBaseSize, base.width > 0, base.height > 0 else { return [] }
        let w = base.width * CGFloat(watermarkTransform.scaleX)
        let h = base.height * CGFloat(watermarkTransform.scaleY)
        let ax = CGFloat(Double(compositePixelSize.width) * (1 - watermarkTransform.offsetFractionX))
        let ay = CGFloat(Double(compositePixelSize.height) * watermarkTransform.offsetFractionY)
        let rect = CGRect(x: -w, y: 0, width: w, height: h)
        let t = CGAffineTransform(rotationAngle: CGFloat(watermarkTransform.rotationDeg * .pi / 180))
            .concatenating(CGAffineTransform(translationX: ax, y: ay))
        return LayerGeometry.corners(of: rect, transform: t)
    }

    /// An extra layer's four drawn corners (fit + free transform), matching the
    /// compositor's `drawExtraLayer`.
    private func extraLayerCorners(_ state: ExtraLayerCanvasState) -> [CGPoint] {
        guard let base = state.baseSize, base.width > 0, base.height > 0 else { return [] }
        let s = Double(canvasOffsetScale())
        return LayerGeometry.centeredCorners(
            canvas: compositePixelSize,
            baseSize: base,
            offsetX: state.transform.offsetX * s,
            offsetY: state.transform.offsetY * s,
            scaleX: state.transform.scaleX,
            scaleY: state.transform.scaleY,
            rotationDeg: state.transform.rotationDeg
        )
    }

    private func extraLayerState(_ id: UUID) -> ExtraLayerCanvasState? {
        extraLayerStates.first { $0.id == id }
    }

    /// The four corners of the selected layer, in canvas (composite pixel)
    /// coordinates, ordered bottom-left, bottom-right, top-right, top-left.
    private func selectionCorners() -> [CGPoint] {
        switch selection {
        case .overlay: return overlayCorners()
        case .watermark: return watermarkCorners()
        case .psdText: return rectCorners(psdTextBoxCanvasRect())
        case .extraLayer(let id): return extraLayerState(id).map(extraLayerCorners) ?? []
        case nil: return []
        }
    }

    /// The selected layer's corners converted to screen (view) coordinates.
    private func selectionScreenQuad() -> [CGPoint] {
        let s = screenScale()
        let paper = paperRect()
        return selectionCorners().map {
            CGPoint(x: paper.minX + $0.x * s, y: paper.minY + $0.y * s)
        }
    }

    /// Convert a canvas-space rect into its four corners.
    private func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    /// Layer-2 box in canvas (preview pixel) coordinates.
    private func psdTextBoxCanvasRect() -> CGRect {
        guard let box = psdTextBox else { return .zero }
        return box.pixelRect(canvas: compositePixelSize)
    }

    /// Whether `p` lies inside the convex quad (point-in-polygon via winding).
    private func quadContains(_ quad: [CGPoint], _ p: CGPoint) -> Bool {
        guard quad.count == 4 else { return false }
        var sign = 0
        for i in 0..<4 {
            let a = quad[i]
            let b = quad[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                let s: Int = cross > 0 ? 1 : -1
                if sign == 0 { sign = s } else if sign != s { return false }
            }
        }
        return true
    }

    /// Convert canvas-space corners into screen (view) coordinates.
    private func screenQuad(_ corners: [CGPoint]) -> [CGPoint] {
        let s = screenScale()
        let paper = paperRect()
        return corners.map { CGPoint(x: paper.minX + $0.x * s, y: paper.minY + $0.y * s) }
    }

    // MARK: - Selection drawing

    private func updateSelectionLayer() {
        guard selection != nil else {
            selectionLayer.path = nil
            return
        }
        let quad = selectionScreenQuad()
        guard quad.count == 4 else {
            selectionLayer.path = nil
            return
        }

        let path = CGMutablePath()
        path.move(to: quad[0])
        for i in 1..<4 { path.addLine(to: quad[i]) }
        path.closeSubpath()

        for handle in scaleHandles(in: quad) {
            path.addRect(CGRect(x: handle.x - Self.handleSize / 2, y: handle.y - Self.handleSize / 2,
                                width: Self.handleSize, height: Self.handleSize))
        }
        if selection != .psdText, let rotate = rotateHandle(quad: quad) {
            path.addEllipse(in: CGRect(x: rotate.x - Self.rotateHandleRadius, y: rotate.y - Self.rotateHandleRadius,
                                       width: Self.rotateHandleRadius * 2, height: Self.rotateHandleRadius * 2))
        }
        selectionLayer.path = path
    }

    /// The 8 free-transform scale handles for a rotated quad: 4 corners first
    /// (0…3, bottom-left → top-left), then 4 edge midpoints (4…7, bottom →
    /// right → top → left).
    private func scaleHandles(in quad: [CGPoint]) -> [CGPoint] {
        guard quad.count == 4 else { return [] }
        let mid = [
            CGPoint(x: (quad[0].x + quad[1].x) / 2, y: (quad[0].y + quad[1].y) / 2),
            CGPoint(x: (quad[1].x + quad[2].x) / 2, y: (quad[1].y + quad[2].y) / 2),
            CGPoint(x: (quad[2].x + quad[3].x) / 2, y: (quad[2].y + quad[3].y) / 2),
            CGPoint(x: (quad[3].x + quad[0].x) / 2, y: (quad[3].y + quad[0].y) / 2),
        ]
        return quad + mid
    }

    /// Orange glow around a hovered layer-2/3 element (drawn as the real quad).
    private func updateHoverLayer() {
        guard let hovered = hoveredLayer else {
            hoverLayer.path = nil
            return
        }
        let quad: [CGPoint]
        switch hovered {
        case 2: quad = rectCorners(psdTextBoxCanvasRect())
        case 3: quad = overlayCorners()
        default: quad = []
        }
        guard quad.count == 4 else {
            hoverLayer.path = nil
            return
        }
        let s = screenScale()
        let paper = paperRect()
        let screen = quad.map { CGPoint(x: paper.minX + $0.x * s, y: paper.minY + $0.y * s) }
        let path = CGMutablePath()
        path.move(to: screen[0])
        for i in 1..<4 { path.addLine(to: screen[i]) }
        path.closeSubpath()
        hoverLayer.path = path
    }

    /// The single rotate handle: just above the top edge, along the quad's
    /// outward "up" direction (Photoshop-style rotate affordance).
    private func rotateHandle(quad: [CGPoint]) -> CGPoint? {
        guard quad.count == 4 else { return nil }
        let center = CGPoint(x: (quad[0].x + quad[1].x + quad[2].x + quad[3].x) / 4,
                             y: (quad[0].y + quad[1].y + quad[2].y + quad[3].y) / 4)
        let topMid = CGPoint(x: (quad[2].x + quad[3].x) / 2, y: (quad[2].y + quad[3].y) / 2)
        let dx = topMid.x - center.x
        let dy = topMid.y - center.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return nil }
        return CGPoint(x: topMid.x + dx / len * Self.rotateOffset,
                       y: topMid.y + dy / len * Self.rotateOffset)
    }

    // MARK: - Rendering

    private func updateHint() {
        if locked {
            hintLabel.stringValue = "Choose a paper size to unlock the canvas.\nThen add photos to begin."
            hintLabel.isHidden = false
        } else if compositedImage == nil {
            hintLabel.stringValue = "Drop photos here or use “Add photos…”"
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
        }
    }

    private func updateNoExportOverlay() {
        let rect = paperRect()
        noExportDimLayer.frame = rect
        noExportDimLayer.isHidden = !noExport

        noExportXLayer.frame = rect
        if noExport {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.move(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            noExportXLayer.path = p
        } else {
            noExportXLayer.path = nil
        }
        noExportXLayer.isHidden = !noExport

        noExportLabel.frame = CGRect(x: rect.minX, y: rect.midY - 22, width: rect.width, height: 44)
        noExportLabel.isHidden = !noExport
    }

    private func updateGlow() {
        let focused = (window?.isKeyWindow ?? false) && (window?.firstResponder === self)
        let on = isMouseOver || focused
        paperLayer.borderColor = (on ? NSColor.glow : NSColor.border).cgColor
        paperLayer.borderWidth = on ? 2 : 1
        paperLayer.shadowColor = on ? NSColor.glow.cgColor : nil
        paperLayer.shadowOpacity = on ? 0.85 : 0
        paperLayer.shadowRadius = on ? 10 : 0
        paperLayer.shadowOffset = .zero
    }

    // MARK: - Focus / glow tracking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        if let window = window {
            nc.addObserver(self, selector: #selector(windowKeyChanged),
                           name: NSWindow.didBecomeKeyNotification, object: window)
            nc.addObserver(self, selector: #selector(windowKeyChanged),
                           name: NSWindow.didResignKeyNotification, object: window)
        }
        updateGlow()
    }

    @objc private func windowKeyChanged() { updateGlow() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateGlow()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateGlow()
        return ok
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseOver = true
        updateGlow()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseOver = false
        hoveredLayer = nil
        updateGlow()
        resetCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !locked else { hoveredLayer = nil; resetCursor(); return }
        let screenPoint = convert(event.locationInWindow, from: nil)
        if let psdBox = psdTextBox,
           quadContains(screenQuad(rectCorners(psdBox.pixelRect(canvas: compositePixelSize))), screenPoint) {
            hoveredLayer = 2
        } else if overlayCorners().count == 4 && quadContains(screenQuad(overlayCorners()), screenPoint) {
            hoveredLayer = 3
        } else {
            hoveredLayer = nil
        }
        updateCursor(at: screenPoint)
    }

    /// Set the resize/rotate cursor when hovering a selected element's handles.
    private func updateCursor(at p: CGPoint) {
        guard let sel = selection else { resetCursor(); return }
        let quad = selectionScreenQuad()
        guard quad.count == 4 else { resetCursor(); return }
        if sel != .psdText, hitRotateHandle(p, quad: quad) {
            Self.rotateCursor.set()
            return
        }
        if let handle = hitScaleHandle(p, quad: quad) {
            switch scaleHandleKind(handle) {
            case .corner:
                // Corners 0/2 sit on the NW–SE diagonal, 1/3 on NE–SW.
                let diag = (handle == 0 || handle == 2) ? Self.diagNWSECursor : Self.diagNESWCursor
                diag.set()
            case .edgeX: NSCursor.resizeLeftRight.set()
            case .edgeY: NSCursor.resizeUpDown.set()
            }
            return
        }
        resetCursor()
    }

    private func resetCursor() {
        NSCursor.arrow.set()
    }

    /// Middle-click (button 2) opens the hovered layer element in Photoshop.
    override func otherMouseDown(with event: NSEvent) {
        guard !locked else { super.otherMouseDown(with: event); return }
        if event.buttonNumber == 2 {
            let screenPoint = convert(event.locationInWindow, from: nil)
            var layer: Int? = nil
            if let psdBox = psdTextBox,
               quadContains(screenQuad(rectCorners(psdBox.pixelRect(canvas: compositePixelSize))), screenPoint) {
                layer = 2
            } else if overlayCorners().count == 4 && quadContains(screenQuad(overlayCorners()), screenPoint) {
                layer = 3
            } else if paperRect().contains(screenPoint) {
                layer = 4
            }
            if let layer = layer { onMiddleClick?(layer) }
            return
        }
        super.otherMouseDown(with: event)
    }

    /// Arm the next canvas drag to draw the layer-2 bounding box.
    func armPSDBoxDrawing() {
        psdBoxDrawingEnabled = true
        selection = .psdText
    }

    /// Select an extra layer on the canvas (shows the red box + handles).
    func selectExtraLayer(_ id: UUID) {
        guard !locked else { return }
        selection = .extraLayer(id)
    }

    // MARK: - Mouse (selection + layer-4 pan)

    override func mouseDown(with event: NSEvent) {
        if locked {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let screenPoint = convert(event.locationInWindow, from: nil)
        let canvas = canvasPoint(screenPoint)

        // 0. Rubber-band draw of the layer-2 box (armed by the panel).
        if psdBoxDrawingEnabled {
            psdBoxDrawingEnabled = false
            psdBoxDrawStart = screenPoint
            selection = .psdText
            updateSelectionLayer()
            return
        }

        // 1. Handle an existing selection (rotate / scale / move / deselect).
        if let sel = selection {
            let shift = event.modifierFlags.contains(.shift)
            let quad = selectionScreenQuad()
            if sel != .psdText, hitRotateHandle(screenPoint, quad: quad) {
                beginTransform(sel, mode: .rotate, start: canvas, option: event.modifierFlags.contains(.option), shift: shift)
                return
            }
            if let handle = hitScaleHandle(screenPoint, quad: quad) {
                beginTransform(sel, mode: .scale, start: canvas, option: event.modifierFlags.contains(.option), shift: shift, scaleHandle: handle)
                return
            }
            if quadContains(quad, screenPoint) {
                beginTransform(sel, mode: .move, start: canvas, option: event.modifierFlags.contains(.option), shift: shift)
                return
            }
            // Click outside → deselect, then fall through to layer-4 pan.
            selection = nil
        }

        // 2. Select psd text box, overlay (above photo), or watermark when clicked.
        if let psdBox = psdTextBox,
           quadContains(screenQuad(rectCorners(psdBox.pixelRect(canvas: compositePixelSize))), screenPoint) {
            selection = .psdText
            beginTransform(.psdText, mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
            return
        }
        let overlayQ = overlayCorners()
        if overlayQ.count == 4 && quadContains(screenQuad(overlayQ), screenPoint) {
            selection = .overlay
            beginTransform(.overlay, mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
            return
        }
        // Extra layers (below the overlay, above the photo); list order = top.
        for state in extraLayerStates {
            let q = extraLayerCorners(state)
            if q.count == 4 && quadContains(screenQuad(q), screenPoint) {
                selection = .extraLayer(state.id)
                beginTransform(.extraLayer(state.id), mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
                return
            }
        }
        let watermarkQ = watermarkCorners()
        if watermarkQ.count == 4 && quadContains(screenQuad(watermarkQ), screenPoint) {
            selection = .watermark
            beginTransform(.watermark, mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
            return
        }

        // 3. Otherwise: layer-4 pan.
        lastDragPoint = screenPoint
        lastGestureScope = scope(for: event)
        beginGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        let screenPoint = convert(event.locationInWindow, from: nil)
        let canvas = canvasPoint(screenPoint)

        // Rubber-band layer-2 box drawing.
        if let start = psdBoxDrawStart {
            let rect = paperRect()
            let minX = min(start.x, screenPoint.x)
            let maxX = max(start.x, screenPoint.x)
            let minY = min(start.y, screenPoint.y)
            let maxY = max(start.y, screenPoint.y)
            let clampedX = max(rect.minX, minX)
            let clampedMaxX = min(rect.maxX, maxX)
            let clampedBottom = max(rect.minY, minY)
            let clampedTop = min(rect.maxY, maxY)
            // View coords are y-up, so the top edge maps to rect.maxY.
            let box = PSDTextBox(
                x: Double((clampedX - rect.minX) / rect.width),
                y: Double((rect.maxY - clampedTop) / rect.height),
                width: Double((clampedMaxX - clampedX) / rect.width),
                height: Double((clampedTop - clampedBottom) / rect.height)
            ).clamped()
            psdTextBox = box
            onPSDTextBoxChanged?(box, false, false)
            return
        }

        if let layer = transformGestureLayer {
            // Shift toggles uniform ↔ single-axis live during the gesture.
            transformGestureShift = event.modifierFlags.contains(.shift)
            applyTransformDrag(layer, canvas: canvas, commit: false)
            return
        }

        guard !locked, let last = lastDragPoint else { return }
        lastGestureScope = scope(for: event)
        let dx = Double(screenPoint.x - last.x) / Double(screenScale())
        let dy = Double(screenPoint.y - last.y) / Double(screenScale())
        lastDragPoint = screenPoint
        var e = edit
        e.offsetX += dx
        e.offsetY += dy
        applyEdit(e, commit: false, scope: lastGestureScope)
    }

    override func mouseUp(with event: NSEvent) {
        if psdBoxDrawStart != nil {
            psdBoxDrawStart = nil
            if let box = psdTextBox {
                onPSDTextBoxChanged?(box, true, false)
            }
            return
        }

        if let layer = transformGestureLayer {
            let canvas = canvasPoint(convert(event.locationInWindow, from: nil))
            applyTransformDrag(layer, canvas: canvas, commit: true)
            endTransform()
            return
        }

        guard !locked, lastDragPoint != nil else {
            super.mouseUp(with: event)
            return
        }
        lastDragPoint = nil
        applyEdit(edit, commit: true, scope: lastGestureScope)
    }

    // MARK: - Free-transform plumbing

    private func beginTransform(_ layer: SelectedLayer, mode: TransformMode, start: CGPoint, option: Bool,
                                shift: Bool = false, scaleHandle: Int? = nil) {
        transformGestureLayer = layer
        transformGestureMode = mode
        transformGestureStart = start
        transformGestureOption = option
        transformGestureShift = shift
        transformGestureScaleHandle = scaleHandle
        transformGestureStartWatermark = watermarkTransform
        transformGestureStartOverlay = overlayTransform
        transformGestureStartPSDBox = psdTextBox ?? .defaults
        transformGestureExtraID = nil
        transformGestureStartExtra = .identity
        if case .extraLayer(let id) = layer {
            transformGestureExtraID = id
            transformGestureStartExtra = extraLayerState(id)?.transform ?? .identity
        }

        // Snapshot the selected element's geometry from the mouseDown transforms
        // so every drag recomputes from a fixed frame (no drift, correct under
        // any rotation).
        let corners = snapshotCorners(for: layer)
        transformGestureStartCorners = corners
        transformGestureRotation = snapshotRotationDeg(for: layer)
        transformGesturePivot = Self.centroid(corners)
        transformGestureStartCenter = transformGesturePivot
        transformGestureHandleCenter = transformGesturePivot
        transformGestureGrabOffset = .zero
        transformGestureAnchor = transformGesturePivot

        if mode == .scale, corners.count == 4, let handle = scaleHandle {
            let handles = scaleHandles(in: corners)
            guard handle >= 0, handle < handles.count else { beginGesture(); return }
            let handleCenter = handles[handle]
            transformGestureHandleCenter = handleCenter
            transformGestureGrabOffset = CGPoint(x: start.x - handleCenter.x, y: start.y - handleCenter.y)
            // Opposite anchor: corner for a corner handle, edge midpoint for an
            // edge handle. This stays fixed while the dragged handle lands on
            // the cursor target.
            transformGestureAnchor = Self.oppositeScaleAnchor(handle: handle, in: handles)
        }
        beginGesture()
    }

    private func endTransform() {
        transformGestureLayer = nil
        transformGestureOption = false
        transformGestureShift = false
        transformGestureScaleHandle = nil
        transformGestureExtraID = nil
        transformGestureStartCorners = []
        transformGestureGrabOffset = .zero
    }

    /// Whether the given scale handle is a corner or an edge midpoint.
    private enum ScaleHandleKind { case corner, edgeX, edgeY }

    private func scaleHandleKind(_ index: Int) -> ScaleHandleKind {
        switch index {
        case 0, 1, 2, 3: return .corner
        case 4, 6: return .edgeY
        default: return .edgeX
        }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in points { x += p.x; y += p.y }
        let n = CGFloat(points.count)
        return CGPoint(x: x / n, y: y / n)
    }

    /// The fixed point opposite the dragged handle (corner → opposite corner,
    /// edge midpoint → opposite edge midpoint).
    private static func oppositeScaleAnchor(handle: Int, in handles: [CGPoint]) -> CGPoint {
        let opposite: Int
        if handle < 4 {
            opposite = (handle + 2) % 4
        } else {
            opposite = 4 + ((handle - 4 + 2) % 4)
        }
        return handles.indices.contains(opposite) ? handles[opposite] : .zero
    }

    /// The selected element's four corners at mouseDown, computed from the
    /// snapshot transforms (not the live, drifting ones).
    private func snapshotCorners(for layer: SelectedLayer) -> [CGPoint] {
        switch layer {
        case .overlay:
            guard let base = overlayBaseSize, base.width > 0, base.height > 0 else { return [] }
            let s = Double(canvasOffsetScale())
            let t = transformGestureStartOverlay
            return LayerGeometry.centeredCorners(
                canvas: compositePixelSize, baseSize: base,
                offsetX: t.offsetX * s, offsetY: t.offsetY * s,
                scaleX: t.scaleX, scaleY: t.scaleY, rotationDeg: t.rotationDeg)
        case .watermark:
            guard let base = watermarkBaseSize, base.width > 0, base.height > 0 else { return [] }
            let t = transformGestureStartWatermark
            let w = base.width * CGFloat(t.scaleX)
            let h = base.height * CGFloat(t.scaleY)
            let ax = CGFloat(Double(compositePixelSize.width) * (1 - t.offsetFractionX))
            let ay = CGFloat(Double(compositePixelSize.height) * t.offsetFractionY)
            let rect = CGRect(x: -w, y: 0, width: w, height: h)
            let tr = CGAffineTransform(rotationAngle: CGFloat(t.rotationDeg * .pi / 180))
                .concatenating(CGAffineTransform(translationX: ax, y: ay))
            return LayerGeometry.corners(of: rect, transform: tr)
        case .psdText:
            return rectCorners(transformGestureStartPSDBox.pixelRect(canvas: compositePixelSize))
        case .extraLayer(let id):
            guard let base = extraLayerState(id)?.baseSize, base.width > 0, base.height > 0 else { return [] }
            let s = Double(canvasOffsetScale())
            let t = transformGestureStartExtra
            return LayerGeometry.centeredCorners(
                canvas: compositePixelSize, baseSize: base,
                offsetX: t.offsetX * s, offsetY: t.offsetY * s,
                scaleX: t.scaleX, scaleY: t.scaleY, rotationDeg: t.rotationDeg)
        }
    }

    private func snapshotRotationDeg(for layer: SelectedLayer) -> Double {
        switch layer {
        case .overlay: return transformGestureStartOverlay.rotationDeg
        case .watermark: return transformGestureStartWatermark.rotationDeg
        case .psdText: return 0
        case .extraLayer: return transformGestureStartExtra.rotationDeg
        }
    }

    /// The point the dragged handle centre should land on, after removing the
    /// grab offset captured at mouseDown (so the cursor never slips off the
    /// handle).
    private func transformTarget(canvas: CGPoint) -> CGPoint {
        CGPoint(x: canvas.x - transformGestureGrabOffset.x, y: canvas.y - transformGestureGrabOffset.y)
    }

    /// Relative scale factors (x, y) that place the dragged handle exactly on
    /// `target` while the fixed anchor stays put, measured in the element's
    /// rotated frame. Corners project onto the original diagonal (uniform);
    /// edge handles stretch one axis unless Shift is held (uniform).
    private func scaleFactors(target: CGPoint) -> (x: Double, y: Double) {
        let anchor = transformGestureAnchor
        let handle = transformGestureHandleCenter
        let rad = transformGestureRotation * .pi / 180
        let d = rotateVector(CGPoint(x: handle.x - anchor.x, y: handle.y - anchor.y), -rad)
        let u = rotateVector(CGPoint(x: target.x - anchor.x, y: target.y - anchor.y), -rad)
        let denom = Double(d.x * d.x + d.y * d.y)
        let uniformF = denom > 1e-12 ? Double(u.x * d.x + u.y * d.y) / denom : 1
        switch transformGestureScaleHandle.map(scaleHandleKind) ?? .corner {
        case .corner:
            return (uniformF, uniformF)
        case .edgeX:
            if transformGestureShift { return (uniformF, uniformF) }
            guard abs(Double(d.x)) > 1e-12 else { return (1, 1) }
            return (Double(u.x) / Double(d.x), 1)
        case .edgeY:
            if transformGestureShift { return (uniformF, uniformF) }
            guard abs(Double(d.y)) > 1e-12 else { return (1, 1) }
            return (1, Double(u.y) / Double(d.y))
        }
    }

    /// Rotate a canvas vector by `radians` (same convention as
    /// `CGAffineTransform(rotationAngle:)`).
    private func rotateVector(_ v: CGPoint, _ radians: Double) -> CGPoint {
        v.applying(CGAffineTransform(rotationAngle: CGFloat(radians)))
    }

    /// Map a canvas point through the scale-about-anchor transform: rotate into
    /// the element frame, scale x/y, rotate back. The anchor is the fixed point.
    private func scaledPoint(_ p: CGPoint, fx: Double, fy: Double) -> CGPoint {
        let anchor = transformGestureAnchor
        let rad = transformGestureRotation * .pi / 180
        let v = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
        let vRot = rotateVector(v, -rad)
        let vNew = CGPoint(x: vRot.x * CGFloat(fx), y: vRot.y * CGFloat(fy))
        let vOut = rotateVector(vNew, rad)
        return CGPoint(x: anchor.x + vOut.x, y: anchor.y + vOut.y)
    }

    private func applyTransformDrag(_ layer: SelectedLayer, canvas: CGPoint, commit: Bool) {
        let dx = Double(canvas.x - transformGestureStart.x)
        let dy = Double(canvas.y - transformGestureStart.y)

        switch layer {
        case .overlay:
            var t = transformGestureStartOverlay
            switch transformGestureMode {
            case .move:
                let s = Double(canvasOffsetScale())
                t.offsetX += dx / s
                t.offsetY += dy / s
            case .scale:
                applyScale(to: &t, transform: transformGestureStartOverlay, canvasScale: Double(canvasOffsetScale()), target: transformTarget(canvas: canvas))
            case .rotate:
                t.rotationDeg += rotateDelta(canvas: canvas)
            }
            overlayTransform = t
            onOverlayChanged?(t, commit, transformGestureOption)

        case .watermark:
            var t = transformGestureStartWatermark
            switch transformGestureMode {
            case .move:
                t.offsetFractionX -= dx / Double(compositePixelSize.width)
                t.offsetFractionY += dy / Double(compositePixelSize.height)
            case .scale:
                let target = transformTarget(canvas: canvas)
                let f = scaleFactors(target: target)
                let startSX = transformGestureStartWatermark.scaleX
                let startSY = transformGestureStartWatermark.scaleY
                let newSX = clampScale(startSX * f.x)
                let newSY = clampScale(startSY * f.y)
                t.scaleX = newSX
                t.scaleY = newSY
                let effFX = startSX > 0 ? newSX / startSX : 1
                let effFY = startSY > 0 ? newSY / startSY : 1
                let cw = Double(compositePixelSize.width)
                let ch = Double(compositePixelSize.height)
                // Watermark origin = local bottom-right corner (index 1); move
                // it so the fixed anchor stays put.
                let newOrigin = scaledPoint(transformGestureStartCorners[1], fx: effFX, fy: effFY)
                t.offsetFractionX = 1 - Double(newOrigin.x) / cw
                t.offsetFractionY = Double(newOrigin.y) / ch
            case .rotate:
                t.rotationDeg += rotateDelta(canvas: canvas)
            }
            watermarkTransform = t
            onWatermarkChanged?(t, commit, transformGestureOption)

        case .psdText:
            var b = transformGestureStartPSDBox
            let cw = Double(compositePixelSize.width)
            let ch = Double(compositePixelSize.height)
            switch transformGestureMode {
            case .move:
                b.x += dx / cw
                b.y -= dy / ch
            case .scale:
                let target = transformTarget(canvas: canvas)
                let f = scaleFactors(target: target)
                let startW = transformGestureStartPSDBox.width
                let startH = transformGestureStartPSDBox.height
                let newW = max(0.001, min(1.0, startW * f.x))
                let newH = max(0.001, min(1.0, startH * f.y))
                let effFX = startW > 0 ? newW / startW : 1
                let effFY = startH > 0 ? newH / startH : 1
                let newBL = scaledPoint(transformGestureStartCorners[0], fx: effFX, fy: effFY)
                b.x = Double(newBL.x) / cw
                b.y = 1 - newH - Double(newBL.y) / ch
                b.width = newW
                b.height = newH
                b = b.clamped()
            case .rotate:
                break
            }
            psdTextBox = b
            onPSDTextBoxChanged?(b, commit, transformGestureOption)

        case .extraLayer(let id):
            var t = transformGestureStartExtra
            switch transformGestureMode {
            case .move:
                let s = Double(canvasOffsetScale())
                t.offsetX += dx / s
                t.offsetY += dy / s
            case .scale:
                applyScale(to: &t, transform: transformGestureStartExtra, canvasScale: Double(canvasOffsetScale()), target: transformTarget(canvas: canvas))
            case .rotate:
                t.rotationDeg += rotateDelta(canvas: canvas)
            }
            updateExtraLayerTransform(id: id, transform: t)
            onExtraLayerChanged?(id, t, commit, transformGestureOption)
        }
        updateSelectionLayer()
    }

    /// Apply a scale gesture to a centred `OverlayTransform` (overlay / extra
    /// layer): scale both axes from the snapshot, then move the centre so the
    /// fixed anchor corner stays put.
    private func applyScale(to t: inout OverlayTransform, transform start: OverlayTransform,
                            canvasScale s: Double, target: CGPoint) {
        let f = scaleFactors(target: target)
        let startSX = start.scaleX
        let startSY = start.scaleY
        let newSX = clampScale(startSX * f.x)
        let newSY = clampScale(startSY * f.y)
        t.scaleX = newSX
        t.scaleY = newSY
        let effFX = startSX > 0 ? newSX / startSX : 1
        let effFY = startSY > 0 ? newSY / startSY : 1
        let newCenter = scaledPoint(transformGestureStartCenter, fx: effFX, fy: effFY)
        let cw = Double(compositePixelSize.width)
        let ch = Double(compositePixelSize.height)
        t.offsetX = (Double(newCenter.x) - cw / 2) / s
        t.offsetY = (Double(newCenter.y) - ch / 2) / s
    }

    private func updateExtraLayerTransform(id: UUID, transform: OverlayTransform) {
        guard let idx = extraLayerStates.firstIndex(where: { $0.id == id }) else { return }
        extraLayerStates[idx].transform = transform
    }

    private func clampScale(_ v: Double) -> Double {
        min(Self.maxResizeScale, max(Self.minResizeScale, v))
    }

    private func rotateDelta(canvas: CGPoint) -> Double {
        let pivot = transformGesturePivot
        let startAngle = atan2(Double(transformGestureStart.y - pivot.y), Double(transformGestureStart.x - pivot.x))
        let nowAngle = atan2(Double(canvas.y - pivot.y), Double(canvas.x - pivot.x))
        return (nowAngle - startAngle) * 180 / .pi
    }

    private func hitRotateHandle(_ p: CGPoint, quad: [CGPoint]) -> Bool {
        guard let h = rotateHandle(quad: quad) else { return false }
        return hypot(h.x - p.x, h.y - p.y) <= Self.hitThreshold
    }

    private func hitScaleHandle(_ p: CGPoint, quad: [CGPoint]) -> Int? {
        let handles = scaleHandles(in: quad)
        for (i, h) in handles.enumerated() where hypot(h.x - p.x, h.y - p.y) <= Self.hitThreshold {
            return i
        }
        return nil
    }

    // MARK: - Layer-4 gesture plumbing

    private func beginGesture() {
        if !gestureActive {
            gestureActive = true
            onGestureBegan?()
        }
        gestureEndWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.gestureActive = false
            self?.gestureEndWorkItem = nil
            self?.preciseRotateAccum = 0
        }
        gestureEndWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.gestureIdleMs), execute: item)
    }

    // MARK: - Scroll (zoom or R+rotate)

    override func scrollWheel(with event: NSEvent) {
        guard !locked else { return }
        lastGestureScope = scope(for: event)
        beginGesture()
        if isRDown {
            applyRotation(with: event)
        } else {
            zoom(with: event)
        }
    }

    /// macOS swaps the wheel to the X axis while Shift is held, so Shift and
    /// Cmd+Shift scrolls would read deltaY == 0. Use whichever axis is larger.
    static func wheelDelta(_ event: NSEvent) -> Double {
        let y = Double(event.scrollingDeltaY)
        let x = Double(event.scrollingDeltaX)
        return abs(x) > abs(y) ? x : y
    }

    private func zoom(with event: NSEvent) {
        var e = edit
        let speed = max(0.0, settings.scrollZoomSpeed)
        let delta = Self.wheelDelta(event)
        let factor: Double
        if event.hasPreciseScrollingDeltas {
            factor = exp(delta * 0.008 * speed)
        } else {
            factor = exp(delta * 0.2 * speed)
        }
        e.scale = min(Self.maxScale, max(Self.minScale, e.scale * factor))
        applyEdit(e, commit: false, scope: lastGestureScope)
        scheduleCommit()
    }

    private func applyRotation(with event: NSEvent) {
        var e = edit
        let step = max(0.01, min(1.5, settings.rotateStep))
        let speed = max(0.0, settings.scrollRotateSpeed)
        if event.hasPreciseScrollingDeltas {
            preciseRotateAccum += Self.wheelDelta(event)
            let whole = (preciseRotateAccum / 30.0).rounded(.towardZero)
            if whole != 0 {
                e.rotationDeg += whole * step * speed
                preciseRotateAccum -= whole * 30.0
                applyEdit(e, commit: true, scope: lastGestureScope)
            }
        } else {
            let wd = Self.wheelDelta(event)
            let direction: Double = wd > 0 ? 1 : (wd < 0 ? -1 : 0)
            if direction != 0 {
                e.rotationDeg += direction * step * speed
                applyEdit(e, commit: true, scope: lastGestureScope)
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !locked else {
            super.keyDown(with: event)
            return
        }
        let store = shortcuts
        let scope = self.scope(for: event)

        // Render / Process (Cmd+R / Cmd+P by default, live-rebindable).
        if let s = store.entry(.render), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onRender?()
            return
        }
        if let s = store.entry(.process), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onProcess?()
            return
        }
        // Undo / redo (Cmd+Z / Cmd+Shift+Z by default).
        if let s = store.entry(.undo), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onUndo?()
            return
        }
        if let s = store.entry(.redo), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onRedo?()
            return
        }
        // Next photo (Space by default, live-rebindable).
        if let s = store.entry(.next), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            if !event.isARepeat { handleSpace() }
            return
        }
        // Rotate modifier (R by default, live-rebindable).
        if let s = store.entry(.rotate), event.keyCode == s.keyCode {
            isRDown = true
            return
        }
        // NO EXPORT (X by default, live-rebindable).
        if let s = store.entry(.noExport), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onToggleNoExport?()
            return
        }
        // Preview full (P by default, live-rebindable).
        if let s = store.entry(.previewFull), ShortcutStore.matches(event, keyCode: s.keyCode, modifiers: s.modifiers) {
            onTogglePreviewFull?()
            return
        }
        // Nudge (arrow keys, fixed 1 px / Shift 10 px).
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: nudge(dx: shift ? -10 : -1, dy: 0, scope: scope)
        case 124: nudge(dx: shift ? 10 : 1, dy: 0, scope: scope)
        case 126: nudge(dx: 0, dy: shift ? 10 : 1, scope: scope)
        case 125: nudge(dx: 0, dy: shift ? -10 : -1, scope: scope)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let s = shortcuts.entry(.rotate), event.keyCode == s.keyCode {
            isRDown = false
        } else {
            super.keyUp(with: event)
        }
    }

    private func nudge(dx: Double, dy: Double, scope: GlobalEditScope) {
        beginGesture()
        var e = edit
        if settings.nudgeBasis == .screen {
            e.offsetX += dx
            e.offsetY += dy
        } else {
            let perPixel = pointPerExportPixel()
            e.offsetX += dx * perPixel
            e.offsetY += dy * perPixel
        }
        applyEdit(e, commit: true, scope: scope)
    }

    private func pointPerExportPixel() -> Double {
        let rect = paperRect()
        guard let px = paperPixelSize, px.width > 0, rect.width > 0 else { return 1 }
        return Double(rect.width) / Double(px.width)
    }

    private func handleSpace() {
        if spacePending != nil {
            spacePending?.cancel()
            spacePending = nil
            onPreviousFile?()
        } else {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.spacePending = nil
                self.onNextFile?()
            }
            spacePending = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(max(0, settings.doubleTapMs)),
                execute: item)
        }
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !locked, readFileURLs(from: sender.draggingPasteboard).isEmpty == false else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !locked else { return false }
        let urls = readFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
            return []
        }
        return objects.map { $0 as URL }
    }

    // MARK: - Edit plumbing

    private func applyEdit(_ newEdit: ImageEdit, commit: Bool, scope: GlobalEditScope = .none) {
        edit = newEdit
        if commit {
            commitWorkItem?.cancel()
            commitWorkItem = nil
            lastCommittedEdit = newEdit
        }
        onEdit?(newEdit, commit, scope)
    }

    private func scheduleCommit() {
        commitWorkItem?.cancel()
        let scope = lastGestureScope
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.commitWorkItem = nil
            // A discrete commit may already have captured this exact edit (e.g.
            // a nudge or rotate within the 0.35 s debounce window); skip so the
            // debounced commit never pushes a second undo step for the same value.
            guard self.edit != self.lastCommittedEdit else { return }
            self.lastCommittedEdit = self.edit
            self.onEdit?(self.edit, true, scope)
        }
        commitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    /// Cancel any pending gesture/commit timers (call before switching images so
    /// a stale debounced commit cannot land on the newly selected image).
    func cancelPendingCommits() {
        commitWorkItem?.cancel()
        commitWorkItem = nil
        lastCommittedEdit = nil
        gestureEndWorkItem?.cancel()
        gestureEndWorkItem = nil
        gestureActive = false
        preciseRotateAccum = 0
        spacePending?.cancel()
        spacePending = nil
    }

    /// Determine the global-edit scope from the current modifier keys:
    /// Cmd+Shift → all files; Shift alone → files after the current one.
    private func scope(for event: NSEvent) -> GlobalEditScope {
        let flags = event.modifierFlags
        if flags.contains(.command) && flags.contains(.shift) { return .all }
        if flags.contains(.shift) { return .after }
        return .none
    }
}

extension SelectedLayer {
    var layerNumber: Int {
        switch self {
        case .watermark: return 1
        case .psdText: return 2
        case .overlay: return 3
        case .extraLayer: return 0
        }
    }
}

/// A label that never intercepts mouse events, so the canvas-only "NO EXPORT"
/// overlay does not block pan/zoom/rotate on flagged photos.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func toScreen(scale: CGFloat, paper: CGRect) -> CGRect {
        CGRect(x: paper.minX + minX * scale,
               y: paper.minY + minY * scale,
               width: width * scale,
               height: height * scale)
    }
}
