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
    var onDropFiles: (([URL]) -> Void)?

    /// The selection changed (nil = deselected). `1`/`3` map to the layer.
    var onSelectionChanged: ((Int?) -> Void)?
    /// Layer-1 transform changed. `commit` = gesture finished; `option` = the
    /// Option key was held (write a per-image override).
    var onWatermarkChanged: ((WatermarkTransform, Bool, Bool) -> Void)?
    /// Layer-3 transform changed (same commit/option convention).
    var onOverlayChanged: ((OverlayTransform, Bool, Bool) -> Void)?
    /// Layer-2 bounding box changed. `commit` = gesture finished.
    var onPSDTextBoxChanged: ((PSDTextBox, Bool) -> Void)?
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

    // MARK: - Layer rects (canvas coordinates)

    private func overlayBox() -> CGRect {
        guard let base = overlayBaseSize, base.width > 0, base.height > 0 else { return .zero }
        let s = canvasOffsetScale()
        let local = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
        let t = LayerGeometry.centeredTransform(
            canvas: compositePixelSize,
            offsetX: overlayTransform.offsetX * s,
            offsetY: overlayTransform.offsetY * s,
            scale: overlayTransform.scale,
            rotationDeg: overlayTransform.rotationDeg
        )
        return LayerGeometry.boundingBox(of: local, transform: t)
    }

    private func watermarkBox() -> CGRect {
        guard let base = watermarkBaseSize, base.width > 0, base.height > 0 else { return .zero }
        let s = watermarkTransform.scale
        let local = CGRect(x: -base.width * s, y: 0, width: base.width * s, height: base.height * s)
        let ax = CGFloat(Double(compositePixelSize.width) * (1 - watermarkTransform.offsetFractionX))
        let ay = CGFloat(Double(compositePixelSize.height) * watermarkTransform.offsetFractionY)
        let t = CGAffineTransform(translationX: ax, y: ay)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(watermarkTransform.rotationDeg * .pi / 180)))
        return LayerGeometry.boundingBox(of: local, transform: t)
    }

    private func selectionBox() -> CGRect {
        switch selection {
        case .overlay: return overlayBox()
        case .watermark: return watermarkBox()
        case .psdText: return psdTextBoxCanvasRect()
        case nil: return .zero
        }
    }

    /// Layer-2 box in canvas (preview pixel) coordinates.
    private func psdTextBoxCanvasRect() -> CGRect {
        guard let box = psdTextBox else { return .zero }
        return box.pixelRect(canvas: compositePixelSize)
    }

    // MARK: - Selection drawing

    private func updateSelectionLayer() {
        guard selection != nil else {
            selectionLayer.path = nil
            return
        }
        let canvasBox = selectionBox()
        guard canvasBox.width > 0, canvasBox.height > 0 else {
            selectionLayer.path = nil
            return
        }
        let box = canvasBox.toScreen(scale: screenScale(), paper: paperRect())

        let path = CGMutablePath()
        path.addRect(box)

        for handle in scaleHandles(in: box) {
            path.addRect(CGRect(x: handle.x - Self.handleSize / 2, y: handle.y - Self.handleSize / 2,
                                width: Self.handleSize, height: Self.handleSize))
        }
        if selection != .psdText {
            for handle in rotateHandles(in: box) {
                path.addEllipse(in: CGRect(x: handle.x - Self.rotateHandleRadius, y: handle.y - Self.rotateHandleRadius,
                                           width: Self.rotateHandleRadius * 2, height: Self.rotateHandleRadius * 2))
            }
        }
        selectionLayer.path = path
    }

    private func scaleHandles(in box: CGRect) -> [CGPoint] {
        let xs = [box.minX, box.midX, box.maxX]
        let ys = [box.minY, box.midY, box.maxY]
        var points: [CGPoint] = []
        for x in xs {
            for y in ys where x != box.midX || y != box.midY {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// Orange glow around a hovered layer-2/3 element.
    private func updateHoverLayer() {
        guard let hovered = hoveredLayer else {
            hoverLayer.path = nil
            return
        }
        let box: CGRect
        switch hovered {
        case 2: box = psdTextBoxCanvasRect()
        case 3: box = overlayBox()
        default: box = .zero
        }
        guard box.width > 0, box.height > 0 else {
            hoverLayer.path = nil
            return
        }
        let screen = box.toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4)
        let path = CGMutablePath()
        path.addRect(screen)
        hoverLayer.path = path
    }

    private func rotateHandles(in box: CGRect) -> [CGPoint] {
        let d = Self.rotateOffset
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY),
        ]
        // Diagonal outward direction for each corner.
        let dirs = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)]
        return zip(corners, dirs).map { corner, dir in
            let len = max(abs(dir.x), abs(dir.y))
            let norm = CGPoint(x: dir.x / len, y: dir.y / len)
            return CGPoint(x: corner.x + norm.x * d, y: corner.y + norm.y * d)
        }
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
           psdBox.pixelRect(canvas: compositePixelSize).toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
            hoveredLayer = 2
        } else if !overlayBox().isEmpty && overlayBox().toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
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
               psdBox.pixelRect(canvas: compositePixelSize).toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
                layer = 2
            } else if !overlayBox().isEmpty && overlayBox().toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
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
            if sel != .psdText,
               hitRotateHandle(screenPoint, box: selectionBox().toScreen(scale: screenScale(), paper: paperRect())) {
                beginTransform(sel, mode: .rotate, start: canvas, option: event.modifierFlags.contains(.option))
                return
            }
            if hitScaleHandle(screenPoint, box: selectionBox().toScreen(scale: screenScale(), paper: paperRect())) != nil {
                beginTransform(sel, mode: .scale, start: canvas, option: event.modifierFlags.contains(.option))
                return
            }
            if selectionBox().toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
                beginTransform(sel, mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
                return
            }
            // Click outside → deselect, then fall through to layer-4 pan.
            selection = nil
        }

        // 2. Select psd text box, overlay (above photo), or watermark when clicked.
        if let psdBox = psdTextBox,
           psdBox.pixelRect(canvas: compositePixelSize).toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
            selection = .psdText
            beginTransform(.psdText, mode: .move, start: canvas, option: false)
            return
        }
        if !overlayBox().isEmpty && overlayBox().toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
            selection = .overlay
            beginTransform(.overlay, mode: .move, start: canvas, option: event.modifierFlags.contains(.option))
            return
        }
        if !watermarkBox().isEmpty && watermarkBox().toScreen(scale: screenScale(), paper: paperRect()).insetBy(dx: -4, dy: -4).contains(screenPoint) {
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
            onPSDTextBoxChanged?(box, false)
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
                onPSDTextBoxChanged?(box, true)
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

    private func beginTransform(_ layer: SelectedLayer, mode: TransformMode, start: CGPoint, option: Bool) {
        transformGestureLayer = layer
        transformGestureMode = mode
        transformGestureStart = start
        transformGestureOption = option
        transformGestureStartWatermark = watermarkTransform
        transformGestureStartOverlay = overlayTransform
        transformGestureStartPSDBox = psdTextBox ?? .defaults
        beginGesture()
    }

    private func endTransform() {
        transformGestureLayer = nil
        transformGestureOption = false
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
                let center = overlayBox().center
                let startDist = max(1, hypot(Double(transformGestureStart.x - center.x), Double(transformGestureStart.y - center.y)))
                let nowDist = hypot(Double(canvas.x - center.x), Double(canvas.y - center.y))
                t.scale = min(Self.maxScale, max(Self.minScale, t.scale * (nowDist / startDist)))
            case .rotate:
                let center = overlayBox().center
                let startAngle = atan2(Double(transformGestureStart.y - center.y), Double(transformGestureStart.x - center.x))
                let nowAngle = atan2(Double(canvas.y - center.y), Double(canvas.x - center.x))
                t.rotationDeg += (nowAngle - startAngle) * 180 / .pi
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
                let center = watermarkBox().center
                let startDist = max(1, hypot(Double(transformGestureStart.x - center.x), Double(transformGestureStart.y - center.y)))
                let nowDist = hypot(Double(canvas.x - center.x), Double(canvas.y - center.y))
                t.scale = min(Self.maxScale, max(Self.minScale, t.scale * (nowDist / startDist)))
            case .rotate:
                let center = watermarkBox().center
                let startAngle = atan2(Double(transformGestureStart.y - center.y), Double(transformGestureStart.x - center.x))
                let nowAngle = atan2(Double(canvas.y - center.y), Double(canvas.x - center.x))
                t.rotationDeg += (nowAngle - startAngle) * 180 / .pi
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
            onPSDTextBoxChanged?(psdTextBox ?? .defaults, commit)
        }
        updateSelectionLayer()
    }

    private func hitRotateHandle(_ p: CGPoint, box: CGRect) -> Bool {
        rotateHandles(in: box).contains { hypot($0.x - p.x, $0.y - p.y) <= Self.hitThreshold }
    }

    private func hitScaleHandle(_ p: CGPoint, box: CGRect) -> Int? {
        let handles = scaleHandles(in: box)
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
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let scope = self.scope(for: event)
        switch event.keyCode {
        case 123: nudge(dx: shift ? -10 : -1, dy: 0, scope: scope)
        case 124: nudge(dx: shift ? 10 : 1, dy: 0, scope: scope)
        case 126: nudge(dx: 0, dy: shift ? 10 : 1, scope: scope)
        case 125: nudge(dx: 0, dy: shift ? -10 : -1, scope: scope)
        case 49:
            if !event.isARepeat { handleSpace() }
        case 6:
            if cmd {
                if shift { onRedo?() } else { onUndo?() }
            } else {
                super.keyDown(with: event)
            }
        case 15: isRDown = true
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 15 { isRDown = false } else { super.keyUp(with: event) }
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
        }
        onEdit?(newEdit, commit, scope)
    }

    private func scheduleCommit() {
        commitWorkItem?.cancel()
        let scope = lastGestureScope
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.commitWorkItem = nil
            self.onEdit?(self.edit, true, scope)
        }
        commitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
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
