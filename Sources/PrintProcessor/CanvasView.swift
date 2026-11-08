import AppKit
import PrintProcessorCore

/// A layer (1 = watermark, 2 = PSD text, 3 = overlay) that can be selected on
/// the canvas and free-transformed with the red box + handles.
enum SelectedLayer {
    case watermark
    case psdText
    case overlay
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
    var onNextFile: (() -> Void)?
    var onPreviousFile: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onRender: (() -> Void)?
    var onProcess: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    /// The selection changed (nil = deselected). `1`/`3` map to the layer.
    var onSelectionChanged: ((Int?) -> Void)?
    /// Layer-1 transform changed. `commit` = gesture finished; `option` = the
    /// Option key was held (write a per-image override).
    var onWatermarkChanged: ((WatermarkTransform, Bool, Bool) -> Void)?
    /// Layer-3 transform changed (same commit/option convention).
    var onOverlayChanged: ((OverlayTransform, Bool, Bool) -> Void)?
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

    private var selection: SelectedLayer? {
        didSet {
            updateSelectionLayer()
            onSelectionChanged?(selection?.layerNumber)
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
    private static let gestureIdleMs = 400
    private static let handleSize: CGFloat = 8
    private static let rotateHandleRadius: CGFloat = 7
    private static let rotateOffset: CGFloat = 22
    private static let hitThreshold: CGFloat = 8

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
        let t = CGAffineTransform(translationX: ax, y: ay)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(watermarkTransform.rotationDeg * .pi / 180)))
        return LayerGeometry.corners(of: rect, transform: t)
    }

    /// The four corners of the selected layer, in canvas (composite pixel)
    /// coordinates, ordered bottom-left, bottom-right, top-right, top-left.
    private func selectionCorners() -> [CGPoint] {
        switch selection {
        case .overlay: return overlayCorners()
        case .watermark: return watermarkCorners()
        case .psdText: return rectCorners(psdTextBoxCanvasRect())
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
    }

    override func mouseMoved(with event: NSEvent) {
        guard !locked else { hoveredLayer = nil; return }
        let screenPoint = convert(event.locationInWindow, from: nil)
        if let psdBox = psdTextBox,
           quadContains(screenQuad(rectCorners(psdBox.pixelRect(canvas: compositePixelSize))), screenPoint) {
            hoveredLayer = 2
        } else if overlayCorners().count == 4 && quadContains(screenQuad(overlayCorners()), screenPoint) {
            hoveredLayer = 3
        } else {
            hoveredLayer = nil
        }
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
        transformGestureAnchor = scaleAnchor(for: layer)
        beginGesture()
    }

    private func endTransform() {
        transformGestureLayer = nil
        transformGestureOption = false
        transformGestureShift = false
        transformGestureScaleHandle = nil
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

    /// Fixed pivot for the current transform gesture, computed from the
    /// transforms captured at drag start (never from the live, drifting box).
    private func scaleAnchor(for layer: SelectedLayer) -> CGPoint {
        switch layer {
        case .overlay:
            let base = overlayBaseSize ?? .zero
            let s = canvasOffsetScale()
            let local = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
            let t = LayerGeometry.centeredTransform(
                canvas: compositePixelSize,
                offsetX: transformGestureStartOverlay.offsetX * s,
                offsetY: transformGestureStartOverlay.offsetY * s,
                scaleX: transformGestureStartOverlay.scaleX,
                scaleY: transformGestureStartOverlay.scaleY,
                rotationDeg: transformGestureStartOverlay.rotationDeg
            )
            return LayerGeometry.boundingBox(of: local, transform: t).center
        case .watermark:
            return CGPoint(
                x: CGFloat(Double(compositePixelSize.width) * (1 - transformGestureStartWatermark.offsetFractionX)),
                y: CGFloat(Double(compositePixelSize.height) * transformGestureStartWatermark.offsetFractionY)
            )
        case .psdText:
            return transformGestureStartPSDBox.pixelRect(canvas: compositePixelSize).center
        }
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
                applyScaleDrag(x: canvas.x, y: canvas.y) { fx, fy in
                    t.scaleX = clampScale(t.scaleX * fx)
                    t.scaleY = clampScale(t.scaleY * fy)
                }
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
                applyScaleDrag(x: canvas.x, y: canvas.y) { fx, fy in
                    t.scaleX = clampScale(t.scaleX * fx)
                    t.scaleY = clampScale(t.scaleY * fy)
                }
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
                let startRect = transformGestureStartPSDBox.pixelRect(canvas: compositePixelSize)
                let center = startRect.center
                let startDist = max(1, hypot(Double(transformGestureStart.x - center.x), Double(transformGestureStart.y - center.y)))
                let nowDist = hypot(Double(canvas.x - center.x), Double(canvas.y - center.y))
                let f = min(Self.maxScale, max(Self.minScale, nowDist / startDist))
                let cx = b.x + b.width / 2
                let cy = b.y + b.height / 2
                b.width = max(0.01, min(1, b.width * f))
                b.height = max(0.01, min(1, b.height * f))
                b.x = max(0, min(1 - b.width, cx - b.width / 2))
                b.y = max(0, min(1 - b.height, cy - b.height / 2))
            case .rotate:
                break
            }
            psdTextBox = b.clamped()
            onPSDTextBoxChanged?(psdTextBox ?? .defaults, commit, transformGestureOption)
        }
        updateSelectionLayer()
    }

    private func clampScale(_ v: Double) -> Double {
        min(Self.maxScale, max(Self.minScale, v))
    }

    /// Compute scale factors (x, y) from the fixed gesture anchor and the
    /// dragged handle. Corners (and Shift) scale uniformly; edge/mid handles
    /// stretch a single axis unless Shift is held.
    private func applyScaleDrag(x: CGFloat, y: CGFloat, _ mutate: (Double, Double) -> Void) {
        let anchor = transformGestureAnchor
        let startX = Double(transformGestureStart.x - anchor.x)
        let startY = Double(transformGestureStart.y - anchor.y)
        let nowX = Double(x - anchor.x)
        let nowY = Double(y - anchor.y)
        let kind = transformGestureScaleHandle.map(scaleHandleKind) ?? .corner
        if transformGestureShift || kind == .corner {
            let startDist = max(1, hypot(startX, startY))
            let nowDist = hypot(nowX, nowY)
            let f = nowDist / startDist
            mutate(f, f)
        } else if kind == .edgeX {
            guard abs(startX) > 0.0001 else { return }
            mutate(nowX / startX, 1)
        } else {
            guard abs(startY) > 0.0001 else { return }
            mutate(1, nowY / startY)
        }
    }

    private func rotateDelta(canvas: CGPoint) -> Double {
        let anchor = transformGestureAnchor
        let startAngle = atan2(Double(transformGestureStart.y - anchor.y), Double(transformGestureStart.x - anchor.x))
        let nowAngle = atan2(Double(canvas.y - anchor.y), Double(canvas.x - anchor.x))
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

    private func zoom(with event: NSEvent) {
        var e = edit
        let speed = max(0.0, settings.scrollZoomSpeed)
        let delta = Double(event.scrollingDeltaY)
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
            preciseRotateAccum += Double(event.scrollingDeltaY)
            let whole = (preciseRotateAccum / 30.0).rounded(.towardZero)
            if whole != 0 {
                e.rotationDeg += whole * step * speed
                preciseRotateAccum -= whole * 30.0
                applyEdit(e, commit: true, scope: lastGestureScope)
            }
        } else {
            let direction: Double = event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
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
        }
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
