import AppKit
import PrintProcessorCore

/// Interactive layer-4 canvas. Renders the paper rectangle (chosen size ratio
/// fitted in the view) and the current subject photo as a downscaled preview,
/// with zoom / pan / rotate / nudge / navigation handled here and reported
/// upward through callbacks.
final class CanvasView: NSView {
    // MARK: - Display state (owned by the controller)

    /// True until a paper size is chosen: imports and edits are ignored and a
    /// hint is shown.
    var locked: Bool = true {
        didSet { needsDisplay = true; needsLayout = true; updateHint() }
    }

    /// Display width/height ratio of the paper rect (nil = no size chosen).
    var paperAspect: CGFloat? {
        didSet { needsLayout = true }
    }

    /// Paper export-pixel size (used for export-pixel nudges). nil while no size.
    var paperPixelSize: CGSize? {
        didSet { needsLayout = true }
    }

    /// Decoded preview image to draw, or nil while none is loaded.
    var image: CGImage? {
        didSet { updatePhotoContents() }
    }

    /// Current placement. Mutating this applies the transform without notifying.
    var edit: ImageEdit = .identity {
        didSet { applyTransform() }
    }

    /// Live settings for zoom/rotate speed, rotate step and nudge basis.
    var settings: AppSettings = .defaults

    // MARK: - Callbacks

    /// A new edit produced by user input. `commit` is true for a discrete,
    /// undoable change; false for a continuous gesture that is still in flight.
    var onEdit: ((ImageEdit, Bool) -> Void)?
    /// A continuous gesture (drag / scroll) just started — record a baseline.
    var onGestureBegan: (() -> Void)?
    var onNextFile: (() -> Void)?
    var onPreviousFile: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// Files/folders dropped onto the canvas.
    var onDropFiles: (([URL]) -> Void)?

    // MARK: - Internal state

    private let paperLayer = CALayer()
    private let photoLayer = CALayer()
    private let hintLabel = NSTextField(labelWithString: "")

    private var isMouseOver = false
    private var isRDown = false
    private var lastDragPoint: NSPoint?
    private var spacePending: DispatchWorkItem?
    private var commitWorkItem: DispatchWorkItem?
    private var preciseRotateAccum: Double = 0
    private var gestureActive = false
    private var gestureEndWorkItem: DispatchWorkItem?

    private static let padding: CGFloat = 28
    private static let minScale = 0.05
    private static let maxScale = 50.0
    private static let gestureIdleMs = 400

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

        photoLayer.contentsGravity = .resizeAspect
        photoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        photoLayer.masksToBounds = false
        layer?.addSublayer(photoLayer)

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
        photoLayer.position = paperRect().center
        photoLayer.bounds = fittedImageBounds()
        applyTransform()
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

    /// Size the photo preview takes at Fit (letterboxed inside the paper rect).
    private func fittedImageBounds() -> CGRect {
        let rect = paperRect()
        guard let image = image, image.width > 0, image.height > 0 else {
            return CGRect(origin: .zero, size: rect.size)
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var w = rect.width
        var h = w / aspect
        if h > rect.height {
            h = rect.height
            w = h * aspect
        }
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    // MARK: - Rendering

    private func updatePhotoContents() {
        photoLayer.contents = image
        needsLayout = true
        updateHint()
    }

    private func applyTransform() {
        let radians = edit.rotationDeg * .pi / 180
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: edit.offsetX, y: edit.offsetY)
        t = t.rotated(by: radians)
        t = t.scaledBy(x: edit.scale, y: edit.scale)
        photoLayer.setAffineTransform(t)
    }

    private func updateHint() {
        if locked {
            hintLabel.stringValue = "Choose a paper size to unlock the canvas.\nThen add photos to begin."
            hintLabel.isHidden = false
        } else if image == nil {
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

    @objc private func windowKeyChanged() {
        updateGlow()
    }

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
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseOver = true
        updateGlow()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseOver = false
        updateGlow()
    }

    // MARK: - Mouse pan

    override func mouseDown(with event: NSEvent) {
        if locked {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        lastDragPoint = convert(event.locationInWindow, from: nil)
        beginGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !locked, let last = lastDragPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Double(p.x - last.x)
        let dy = Double(p.y - last.y)
        lastDragPoint = p
        var e = edit
        e.offsetX += dx
        e.offsetY += dy
        applyEdit(e, commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard !locked, lastDragPoint != nil else {
            super.mouseUp(with: event)
            return
        }
        lastDragPoint = nil
        applyEdit(edit, commit: true)
    }

    /// Begin (or continue) one interaction gesture. The undo baseline is
    /// captured once per gesture; 400ms of idle ends the gesture so the next
    /// scroll or key event starts a fresh one.
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
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.gestureIdleMs),
            execute: item)
    }

    // MARK: - Scroll (zoom or R+rotate)

    override func scrollWheel(with event: NSEvent) {
        guard !locked else { return }
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
        applyEdit(e, commit: false)
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
                applyEdit(e, commit: true)
            }
        } else {
            let direction: Double = event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
            if direction != 0 {
                e.rotationDeg += direction * step * speed
                applyEdit(e, commit: true)
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
        switch event.keyCode {
        case 123: nudge(dx: shift ? -10 : -1, dy: 0)       // left arrow
        case 124: nudge(dx: shift ? 10 : 1, dy: 0)         // right arrow
        case 126: nudge(dx: 0, dy: shift ? 10 : 1)         // up arrow
        case 125: nudge(dx: 0, dy: shift ? -10 : -1)       // down arrow
        case 49:                                            // space
            if !event.isARepeat { handleSpace() }
        case 6:                                            // z
            if cmd {
                if shift { onRedo?() } else { onUndo?() }
            } else {
                super.keyDown(with: event)
            }
        case 15: isRDown = true                            // r
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 15 { isRDown = false } else { super.keyUp(with: event) }
    }

    private func nudge(dx: Double, dy: Double) {
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
        applyEdit(e, commit: true)
    }

    /// Canvas points per export pixel (for export-pixel nudges).
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

    private func applyEdit(_ newEdit: ImageEdit, commit: Bool) {
        edit = newEdit
        if commit {
            commitWorkItem?.cancel()
            commitWorkItem = nil
        }
        onEdit?(newEdit, commit)
    }

    private func scheduleCommit() {
        commitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.commitWorkItem = nil
            self.onEdit?(self.edit, true)
        }
        commitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
