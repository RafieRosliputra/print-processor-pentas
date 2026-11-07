import AppKit
import PrintProcessorCore
import UniformTypeIdentifiers

/// Production tab: canvas on the left, scrollable options panel on the right,
/// and a top-right bar with paper-size buttons + Process.
final class ProductionView: NSView {
    enum CanvasOrientation {
        case portrait
        case landscape
    }

    // MARK: - Top bar

    private var sizeButtons: [PaperSize: NSButton] = [:]
    private let statusLabel: NSTextField
    private var selectedSize: PaperSize?

    // MARK: - Canvas / panel

    private let canvasView = CanvasView()
    private let scrollView = NSScrollView()

    // Layer-4 state.
    private var orientation: CanvasOrientation = .portrait
    private var files: [URL] = []
    private var currentIndex = 0
    private var edits = EditStore()
    private var undoStack = UndoStack<ImageEdit>(maxCount: 50)
    private var workingFolder: URL?
    private var settings = AppSettings.load()

    // Layer settings + compositing.
    private var layerSettings = LayerSettings.defaults
    private let compositor = Compositor()
    private var photoPreview: CGImage?
    private var selectedLayerNumber: Int?
    private var previewWorkItem: DispatchWorkItem?

    // Control references.
    private var watermarkText: NSTextField?
    private var watermarkFontPopup: NSPopUpButton?
    private var watermarkSizeSlider: NSSlider?
    private var watermarkSizeValue: NSTextField?
    private var watermarkColourWell: NSColorWell?
    private var watermarkOpacitySlider: NSSlider?
    private var watermarkOpacityValue: NSTextField?
    private var overlayPathLabel: NSTextField?
    private var gradientColourAWell: NSColorWell?
    private var gradientColourBWell: NSColorWell?
    private var gradientAngleSlider: NSSlider?
    private var gradientAngleValue: NSTextField?
    private var gradientOpacitySlider: NSSlider?
    private var gradientOpacityValue: NSTextField?
    private var gradientBlendPopup: NSPopUpButton?
    private var bg5PathLabel: NSTextField?
    private var bg6ColourWell: NSColorWell?
    private var bg6PathLabel: NSTextField?

    /// Layer key (1…6, 0 = gradient) → section, for eye syncing.
    private var sections: [Int: SectionView] = [:]

    private var lastEdit: ImageEdit?
    private var gestureBaseline: ImageEdit?
    private var decodeGeneration = 0
    private var autosaveWorkItem: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?

    private var orientationButton: NSButton?
    private var rotationField: RotationStepField?

    private static let lastSizeKey = "com.johorstudio.printprocessor.lastPaperSize"
    private static let lastFolderKey = "com.johorstudio.printprocessor.lastWorkingFolder"

    private static let fontOptions: [(name: String, label: String)] = [
        (".SFUI-Bold", "SF Pro Bold"),
        (".SFUI-Semibold", "SF Pro Semibold"),
        (".SFUI-Regular", "SF Pro Regular"),
        ("HelveticaNeue-Bold", "Helvetica Neue Bold"),
        ("HelveticaNeue", "Helvetica Neue"),
        ("Arial-BoldMT", "Arial Bold"),
        ("ArialMT", "Arial"),
        ("TimesNewRomanPS-BoldMT", "Times New Roman Bold"),
        ("Georgia-Bold", "Georgia Bold"),
    ]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        self.statusLabel = makeLabel("Select a paper size to begin.", size: 12, weight: .regular, color: .dimText)
        super.init(frame: frameRect)
        build()
        canvasView.settings = settings
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyLiveSettings()
            }
        restoreLastProject()
        if selectedSize == nil,
           let raw = UserDefaults.standard.string(forKey: Self.lastSizeKey),
           let remembered = PaperSize(rawValue: raw) {
            selectSize(remembered)
        }
        refreshRotationField()
        applyLayerSettingsToUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Layout

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor

        let topBar = makeTopBar()
        let content = makeContentRow()

        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topBar)
        addSubview(content)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 76),

            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeTopBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.panel.cgColor
        bar.layer?.borderColor = NSColor.border.cgColor
        bar.layer?.borderWidth = 1

        let brand = makeLabel(Theme.brand, size: 14, weight: .bold, color: .labelColor)
        brand.toolTip = "JohorStudio.com — Print Processor"

        let sizeStack = NSStackView()
        sizeStack.orientation = .horizontal
        sizeStack.alignment = .centerY
        sizeStack.spacing = 4
        for size in PaperSize.allCases {
            let button = makeSizeButton(size)
            sizeButtons[size] = button
            sizeStack.addArrangedSubview(button)
        }

        let processButton = NSButton(title: "Process", target: self, action: #selector(processClicked))
        processButton.bezelStyle = .rounded
        processButton.controlSize = .regular
        processButton.bezelColor = .glow
        processButton.contentTintColor = .black
        processButton.toolTip = "Process — render and export the current image (no shortcut)"

        let controlsRow = NSStackView(views: [sizeStack, processButton])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 10

        statusLabel.alignment = .right
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail

        let rightStack = NSStackView(views: [controlsRow, statusLabel])
        rightStack.orientation = .vertical
        rightStack.alignment = .trailing
        rightStack.spacing = 4

        brand.translatesAutoresizingMaskIntoConstraints = false
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(brand)
        bar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            brand.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),
        ])

        return bar
    }

    private func makeSizeButton(_ size: PaperSize) -> NSButton {
        let button = NSButton(title: size.label, target: self, action: #selector(sizeClicked(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.tag = size.hashValue
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        button.toolTip = "\(size.label) — paper size at 300 dpi (\(size.pixelWidth)×\(size.pixelHeight) px)"
        button.state = .off
        return button
    }

    private func makeContentRow() -> NSView {
        let row = NSView()

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.settings = settings
        canvasView.onEdit = { [weak self] edit, commit in
            self?.handleEdit(edit, commit: commit)
        }
        canvasView.onGestureBegan = { [weak self] in
            self?.handleGestureBegan()
        }
        canvasView.onNextFile = { [weak self] in self?.nextFile() }
        canvasView.onPreviousFile = { [weak self] in self?.previousFile() }
        canvasView.onUndo = { [weak self] in self?.undo() }
        canvasView.onRedo = { [weak self] in self?.redo() }
        canvasView.onDropFiles = { [weak self] urls in self?.importFiles(urls) }
        canvasView.onSelectionChanged = { [weak self] layer in
            self?.selectedLayerNumber = layer
        }
        canvasView.onWatermarkChanged = { [weak self] transform, commit, option in
            self?.handleWatermarkChange(transform, commit: commit, option: option)
        }
        canvasView.onOverlayChanged = { [weak self] transform, commit, option in
            self?.handleOverlayChange(transform, commit: commit, option: option)
        }

        let options = makeOptionsPanel()

        row.addSubview(canvasView)
        row.addSubview(options)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: row.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            canvasView.trailingAnchor.constraint(equalTo: options.leadingAnchor),

            options.topAnchor.constraint(equalTo: row.topAnchor),
            options.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            options.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            options.widthAnchor.constraint(equalToConstant: 320),
        ])

        return row
    }

    private func makeOptionsPanel() -> NSScrollView {
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let watermarkSection = SectionView(title: "Watermark", body: makeWatermarkBody())
        let psdSection = SectionView(title: "PSD Text", bodyText: "Styled text loaded from a PSD text layer. Placeholder.")
        let overlaySection = SectionView(title: "Overlay", body: makeOverlayBody())
        let gradientSection = SectionView(title: "Gradient", body: makeGradientBody())
        let photoSection = SectionView(title: "Photo", body: makePhotoSectionBody())
        let bg5Section = SectionView(title: "Background", body: makeBackgroundBody())
        let bg6Section = SectionView(title: "Final Background", body: makeFinalBackgroundBody())

        watermarkSection.onEyeToggle = { [weak self] on in self?.setLayerEnabled(1, on) }
        psdSection.onEyeToggle = { [weak self] on in self?.setLayerEnabled(2, on) }
        overlaySection.onEyeToggle = { [weak self] on in self?.setLayerEnabled(3, on) }
        gradientSection.onEyeToggle = { [weak self] on in self?.setGradientEnabled(on) }
        photoSection.onEyeToggle = { [weak self] on in self?.setLayerEnabled(4, on) }
        bg5Section.onEyeToggle = { [weak self] on in self?.setLayerEnabled(5, on) }
        bg6Section.onEyeToggle = { [weak self] on in self?.setLayerEnabled(6, on) }

        sections = [1: watermarkSection, 2: psdSection, 3: overlaySection, 0: gradientSection,
                    4: photoSection, 5: bg5Section, 6: bg6Section]

        for section in [watermarkSection, psdSection, overlaySection, gradientSection, photoSection, bg5Section, bg6Section] {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        return scroll
    }

    // MARK: - Section bodies

    private func makeWatermarkBody() -> NSView {
        let textField = NSTextField()
        textField.placeholderString = "Right part of \"name - number\""
        textField.controlSize = .regular
        textField.isBezeled = true
        textField.target = self
        textField.action = #selector(watermarkTextChanged)
        textField.toolTip = "Watermark text — layer 1. Empty uses the file name's right part after \" - \"."
        watermarkText = textField

        let fontPopup = NSPopUpButton()
        for f in Self.fontOptions { fontPopup.addItem(withTitle: f.label) }
        fontPopup.target = self
        fontPopup.action = #selector(watermarkFontChanged)
        fontPopup.toolTip = "Font — watermark font family"
        watermarkFontPopup = fontPopup

        let sizeSlider = NSSlider(value: layerSettings.watermark.sizeFraction, minValue: 0.005, maxValue: 0.2,
                                  target: self, action: #selector(watermarkSizeChanged))
        sizeSlider.toolTip = "Size — watermark text size as a fraction of canvas width"
        watermarkSizeSlider = sizeSlider
        watermarkSizeValue = makeLabel(formatPercent(layerSettings.watermark.sizeFraction), size: 11, weight: .regular, color: .dimText)

        let colourWell = NSColorWell()
        colourWell.color = colorFromRGB(layerSettings.watermark.colour)
        colourWell.target = self
        colourWell.action = #selector(watermarkColourChanged)
        colourWell.toolTip = "Colour — watermark text colour"
        watermarkColourWell = colourWell

        let opacitySlider = NSSlider(value: layerSettings.watermark.opacity, minValue: 0, maxValue: 1,
                                     target: self, action: #selector(watermarkOpacityChanged))
        opacitySlider.toolTip = "Opacity — watermark text opacity"
        watermarkOpacitySlider = opacitySlider
        watermarkOpacityValue = makeLabel(formatPercent(layerSettings.watermark.opacity), size: 11, weight: .regular, color: .dimText)

        let stack = NSStackView(views: [
            textField,
            labelRow("Font", fontPopup),
            sliderRow("Size", sizeSlider, watermarkSizeValue!),
            labelRow("Colour", colourWell),
            sliderRow("Opacity", opacitySlider, watermarkOpacityValue!),
        ])
        return makeBody(stack)
    }

    private func makeOverlayBody() -> NSView {
        let loadButton = NSButton(title: "Load overlay…", target: self, action: #selector(loadOverlayClicked))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .regular
        loadButton.toolTip = "Load overlay… — PNG/WebP overlay with transparency (layer 3, fit/fill to canvas)"

        let label = makeLabel("No overlay loaded", size: 11, weight: .regular, color: .dimText)
        overlayPathLabel = label

        let stack = NSStackView(views: [loadButton, label])
        return makeBody(stack)
    }

    private func makeGradientBody() -> NSView {
        let colourA = NSColorWell()
        colourA.color = colorFromRGB(layerSettings.gradient.colorA)
        colourA.target = self
        colourA.action = #selector(gradientColourAChanged)
        colourA.toolTip = "Gradient colour A — start colour of the two-stop gradient"
        gradientColourAWell = colourA

        let colourB = NSColorWell()
        colourB.color = colorFromRGB(layerSettings.gradient.colorB)
        colourB.target = self
        colourB.action = #selector(gradientColourBChanged)
        colourB.toolTip = "Gradient colour B — end colour of the two-stop gradient"
        gradientColourBWell = colourB

        let angleSlider = NSSlider(value: layerSettings.gradient.angle, minValue: 0, maxValue: 360,
                                   target: self, action: #selector(gradientAngleChanged))
        angleSlider.toolTip = "Angle — gradient direction in degrees (0 = left→right, 90 = bottom→top)"
        gradientAngleSlider = angleSlider
        gradientAngleValue = makeLabel(formatDegrees(layerSettings.gradient.angle), size: 11, weight: .regular, color: .dimText)

        let opacitySlider = NSSlider(value: layerSettings.gradient.opacity, minValue: 0, maxValue: 1,
                                     target: self, action: #selector(gradientOpacityChanged))
        opacitySlider.toolTip = "Opacity — overall gradient opacity"
        gradientOpacitySlider = opacitySlider
        gradientOpacityValue = makeLabel(formatPercent(layerSettings.gradient.opacity), size: 11, weight: .regular, color: .dimText)

        let blendPopup = NSPopUpButton()
        for blend in GradientBlend.allCases { blendPopup.addItem(withTitle: blend.displayName) }
        blendPopup.target = self
        blendPopup.action = #selector(gradientBlendChanged)
        blendPopup.toolTip = "Blend — gradient blend mode (normal/multiply/screen/overlay)"
        gradientBlendPopup = blendPopup

        let stack = NSStackView(views: [
            labelRow("Colour A", colourA),
            labelRow("Colour B", colourB),
            sliderRow("Angle", angleSlider, gradientAngleValue!),
            sliderRow("Opacity", opacitySlider, gradientOpacityValue!),
            labelRow("Blend", blendPopup),
        ])
        return makeBody(stack)
    }

    private func makeBackgroundBody() -> NSView {
        let loadButton = NSButton(title: "Load…", target: self, action: #selector(loadBackgroundClicked))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .regular
        loadButton.toolTip = "Load… — background image with alpha (layer 5)"

        let label = makeLabel("No background image", size: 11, weight: .regular, color: .dimText)
        bg5PathLabel = label

        let stack = NSStackView(views: [loadButton, label])
        return makeBody(stack)
    }

    private func makeFinalBackgroundBody() -> NSView {
        let colourWell = NSColorWell()
        if case .colour(let c) = layerSettings.bg6 { colourWell.color = colorFromRGB(c) }
        colourWell.target = self
        colourWell.action = #selector(bg6ColourChanged)
        colourWell.toolTip = "Colour — final background solid colour (layer 6)"
        bg6ColourWell = colourWell

        let loadButton = NSButton(title: "Load…", target: self, action: #selector(loadFinalBackgroundClicked))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .regular
        loadButton.toolTip = "Load… — final background image (layer 6, fills the canvas)"

        let label = makeLabel(finalBackgroundSummary(), size: 11, weight: .regular, color: .dimText)
        bg6PathLabel = label

        let stack = NSStackView(views: [labelRow("Colour", colourWell), loadButton, label])
        return makeBody(stack)
    }

    private func makePhotoSectionBody() -> NSView {
        let addButton = NSButton(title: "Add photos…", target: self, action: #selector(addPhotosClicked))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.toolTip = "Add photos… — choose JPG/JPEG/WebP/PNG files or folders (or drag them onto the canvas)"

        let orientation = NSButton(title: "Portrait", target: self, action: #selector(toggleOrientation))
        orientation.bezelStyle = .rounded
        orientation.controlSize = .regular
        orientation.toolTip = "Orientation — portrait/landscape canvas; auto-detected from the first photo"
        orientationButton = orientation

        let rotateLabel = makeLabel("Rotate step (°)", size: 13, weight: .regular, color: .labelColor)
        let field = RotationStepField()
        field.toolTip = "Rotate step — degrees per scroll while holding R (0.01–1.5). Shortcut: R + scroll. Scroll over this field to change ±0.01"
        field.onCommit = { [weak self] value in self?.rotationStepChanged(value) }
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        rotationField = field

        let rotateRow = NSStackView(views: [rotateLabel, field])
        rotateRow.orientation = .horizontal
        rotateRow.alignment = .centerY
        rotateRow.spacing = 8

        let stack = NSStackView(views: [addButton, orientation, rotateRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 10, right: 10)
        return stack
    }

    // MARK: - Control row helpers

    private func makeBody(_ stack: NSStackView) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ])
        return container
    }

    private func labelRow(_ label: String, _ control: NSView) -> NSStackView {
        let l = makeLabel(label, size: 12, weight: .regular, color: .labelColor)
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func sliderRow(_ label: String, _ slider: NSSlider, _ valueLabel: NSTextField) -> NSStackView {
        let l = makeLabel(label, size: 12, weight: .regular, color: .labelColor)
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        valueLabel.alignment = .right
        let row = NSStackView(views: [l, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    // MARK: - Layer / gradient visibility

    private func setLayerEnabled(_ layer: Int, _ enabled: Bool) {
        layerSettings.enabled[layer] = enabled
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func setGradientEnabled(_ enabled: Bool) {
        layerSettings.gradient.enabled = enabled
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func applyLayerSettingsToUI() {
        for (key, section) in sections {
            let enabled: Bool
            if key == 0 {
                enabled = layerSettings.gradient.enabled
            } else {
                enabled = layerSettings.enabled[key]
            }
            section.setVisible(enabled)
        }
        syncControls()
    }

    private func syncControls() {
        watermarkText?.stringValue = layerSettings.watermark.text
        watermarkFontPopup?.selectItem(at: fontIndex(for: layerSettings.watermark.fontName))
        watermarkSizeSlider?.doubleValue = layerSettings.watermark.sizeFraction
        watermarkOpacitySlider?.doubleValue = layerSettings.watermark.opacity
        watermarkColourWell?.color = colorFromRGB(layerSettings.watermark.colour)
        gradientColourAWell?.color = colorFromRGB(layerSettings.gradient.colorA)
        gradientColourBWell?.color = colorFromRGB(layerSettings.gradient.colorB)
        gradientAngleSlider?.doubleValue = layerSettings.gradient.angle
        gradientOpacitySlider?.doubleValue = layerSettings.gradient.opacity
        gradientBlendPopup?.selectItem(at: GradientBlend.allCases.firstIndex(of: layerSettings.gradient.blend) ?? 0)
        if case .colour(let c) = layerSettings.bg6 { bg6ColourWell?.color = colorFromRGB(c) }
        overlayPathLabel?.stringValue = pathSummary(layerSettings.overlay.path, empty: "No overlay loaded")
        bg5PathLabel?.stringValue = pathSummary(layerSettings.bg5.path, empty: "No background image")
        bg6PathLabel?.stringValue = finalBackgroundSummary()
        watermarkSizeValue?.stringValue = formatPercent(layerSettings.watermark.sizeFraction)
        watermarkOpacityValue?.stringValue = formatPercent(layerSettings.watermark.opacity)
        gradientAngleValue?.stringValue = formatDegrees(layerSettings.gradient.angle)
        gradientOpacityValue?.stringValue = formatPercent(layerSettings.gradient.opacity)
    }

    // MARK: - Actions (layers)

    @objc private func watermarkTextChanged() {
        layerSettings.watermark.text = watermarkText?.stringValue ?? ""
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func watermarkFontChanged() {
        guard let popup = watermarkFontPopup else { return }
        let idx = popup.indexOfSelectedItem
        if Self.fontOptions.indices.contains(idx) {
            layerSettings.watermark.fontName = Self.fontOptions[idx].name
        }
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func watermarkSizeChanged() {
        guard let slider = watermarkSizeSlider else { return }
        layerSettings.watermark.sizeFraction = slider.doubleValue
        watermarkSizeValue?.stringValue = formatPercent(slider.doubleValue)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func watermarkColourChanged() {
        guard let well = watermarkColourWell else { return }
        layerSettings.watermark.colour = rgbFromColor(well.color)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func watermarkOpacityChanged() {
        guard let slider = watermarkOpacitySlider else { return }
        layerSettings.watermark.opacity = slider.doubleValue
        watermarkOpacityValue?.stringValue = formatPercent(slider.doubleValue)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func loadOverlayClicked() {
        pickImage { [weak self] url in
            self?.layerSettings.overlay.path = url.path
            self?.compositor.invalidateCache()
            self?.overlayPathLabel?.stringValue = url.lastPathComponent
            self?.scheduleRenderPreview()
            self?.scheduleAutosave()
        }
    }

    @objc private func gradientColourAChanged() {
        guard let well = gradientColourAWell else { return }
        layerSettings.gradient.colorA = rgbFromColor(well.color)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func gradientColourBChanged() {
        guard let well = gradientColourBWell else { return }
        layerSettings.gradient.colorB = rgbFromColor(well.color)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func gradientAngleChanged() {
        guard let slider = gradientAngleSlider else { return }
        layerSettings.gradient.angle = slider.doubleValue
        gradientAngleValue?.stringValue = formatDegrees(slider.doubleValue)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func gradientOpacityChanged() {
        guard let slider = gradientOpacitySlider else { return }
        layerSettings.gradient.opacity = slider.doubleValue
        gradientOpacityValue?.stringValue = formatPercent(slider.doubleValue)
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func gradientBlendChanged() {
        guard let popup = gradientBlendPopup else { return }
        let idx = popup.indexOfSelectedItem
        if GradientBlend.allCases.indices.contains(idx) {
            layerSettings.gradient.blend = GradientBlend.allCases[idx]
        }
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func loadBackgroundClicked() {
        pickImage { [weak self] url in
            self?.layerSettings.bg5.path = url.path
            self?.compositor.invalidateCache()
            self?.bg5PathLabel?.stringValue = url.lastPathComponent
            self?.scheduleRenderPreview()
            self?.scheduleAutosave()
        }
    }

    @objc private func bg6ColourChanged() {
        guard let well = bg6ColourWell else { return }
        layerSettings.bg6 = .colour(rgbFromColor(well.color))
        bg6PathLabel?.stringValue = finalBackgroundSummary()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func loadFinalBackgroundClicked() {
        pickImage { [weak self] url in
            self?.layerSettings.bg6 = .image(url.path)
            self?.compositor.invalidateCache()
            self?.bg6PathLabel?.stringValue = self?.finalBackgroundSummary() ?? ""
            self?.scheduleRenderPreview()
            self?.scheduleAutosave()
        }
    }

    private func pickImage(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .webP, .jpeg]
        panel.message = "Choose an image (PNG, WebP, JPEG)."
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    // MARK: - Actions (top bar / photo)

    @objc private func sizeClicked(_ sender: NSButton) {
        guard let size = sizeButtons.first(where: { $0.value === sender })?.key else { return }
        selectSize(size)
    }

    @objc private func processClicked() {
        guard let size = selectedSize else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Select a paper size first."
            return
        }
        statusLabel.textColor = .dimText
        statusLabel.stringValue = "Processing \(size.label)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.updateStatus()
        }
    }

    @objc private func addPhotosClicked() {
        guard selectedSize != nil else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Select a paper size first."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        panel.message = "Choose photos (JPG, JPEG, WebP, PNG) or folders."
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    @objc private func toggleOrientation() {
        orientation = (orientation == .portrait) ? .landscape : .portrait
        refreshOrientationButton()
        applyOrientationToCanvas()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    // MARK: - Size / orientation

    private func selectSize(_ size: PaperSize) {
        selectedSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.lastSizeKey)
        for (key, button) in sizeButtons {
            let selected = (key == size)
            button.state = selected ? .on : .off
            button.bezelColor = selected ? .glow : nil
            button.contentTintColor = selected ? .black : .labelColor
        }
        applyOrientationToCanvas()
        updateStatus()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func applyOrientationToCanvas() {
        guard let size = selectedSize else {
            canvasView.paperAspect = nil
            canvasView.paperPixelSize = nil
            canvasView.locked = true
            return
        }
        let w = CGFloat(size.inchesWidth)
        let h = CGFloat(size.inchesHeight)
        let aspect: CGFloat = (orientation == .portrait) ? (w / h) : (h / w)
        canvasView.paperAspect = aspect
        canvasView.paperPixelSize = canvasPixelSize()
        canvasView.locked = false
    }

    private func refreshOrientationButton() {
        orientationButton?.title = (orientation == .portrait) ? "Portrait" : "Landscape"
    }

    private func applyAutoOrientation(firstPhotoURL: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = PhotoImport.previewPixelSize(url: firstPhotoURL, maxDimension: 64)
            DispatchQueue.main.async {
                guard let self = self, size.width > 0, size.height > 0 else { return }
                self.orientation = size.width > size.height ? .landscape : .portrait
                self.refreshOrientationButton()
                self.applyOrientationToCanvas()
            }
        }
    }

    // MARK: - Import

    private func importFiles(_ urls: [URL]) {
        guard selectedSize != nil else { return }
        let collected = PhotoImport.naturalSorted(PhotoImport.collectFiles(from: urls))
        guard !collected.isEmpty else { return }

        let folder = collected[0].deletingLastPathComponent()
        workingFolder = folder
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)

        if let existing = try? ProjectModel.load(from: folder.path),
           existing.workingFolder == folder.path {
            edits = existing.edits
            layerSettings = existing.layerSettings
        } else {
            edits = EditStore()
            layerSettings = .defaults
        }

        files = collected
        currentIndex = 0
        undoStack.removeAll()
        lastEdit = nil
        gestureBaseline = nil

        applyAutoOrientation(firstPhotoURL: collected[0])
        applyLayerSettingsToUI()
        showCurrentImage()
        updateStatus()
        scheduleAutosave()
    }

    // MARK: - Navigation

    private func currentFileURL() -> URL? {
        guard files.indices.contains(currentIndex) else { return nil }
        return files[currentIndex]
    }

    private func currentKey() -> (sizeKey: String, fileName: String)? {
        guard let size = selectedSize, let url = currentFileURL() else { return nil }
        return (size.rawValue, url.lastPathComponent)
    }

    private func currentEdit() -> ImageEdit {
        guard let key = currentKey() else { return .identity }
        return edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
    }

    private func currentFileName() -> String {
        currentFileURL()?.lastPathComponent ?? ""
    }

    private func goTo(index: Int) {
        guard !files.isEmpty else { return }
        currentIndex = max(0, min(files.count - 1, index))
        undoStack.removeAll()
        lastEdit = nil
        gestureBaseline = nil
        showCurrentImage()
        scheduleAutosave()
    }

    private func nextFile() { goTo(index: currentIndex + 1) }
    private func previousFile() { goTo(index: currentIndex - 1) }

    private func showCurrentImage() {
        guard let url = currentFileURL() else {
            photoPreview = nil
            canvasView.compositedImage = nil
            updateStatus()
            return
        }
        canvasView.edit = currentEdit()
        updateWatermarkPlaceholder()
        updateLayerSelectionState()
        loadPreview(for: url)
        updateStatus()
    }

    private func updateWatermarkPlaceholder() {
        let derived = WatermarkTextProvider.current(currentFileName())
        watermarkText?.placeholderString = derived.isEmpty ? "Right part of \"name - number\"" : derived
    }

    private func loadPreview(for url: URL) {
        decodeGeneration += 1
        let gen = decodeGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PhotoImport.decodePreview(url: url, maxDimension: 2048)
            DispatchQueue.main.async {
                guard let self = self, gen == self.decodeGeneration else { return }
                self.photoPreview = image
                self.renderPreview()
            }
        }
    }

    // MARK: - Preview rendering

    private func canvasPixelSize() -> CGSize {
        guard let size = selectedSize else { return .zero }
        if orientation == .portrait {
            return CGSize(width: size.pixelWidth, height: size.pixelHeight)
        }
        return CGSize(width: size.pixelHeight, height: size.pixelWidth)
    }

    private func previewPixelSize() -> CGSize {
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let cap: CGFloat = 1600
        let scale = min(1, cap / max(canvas.width, canvas.height))
        return CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }

    private func scheduleRenderPreview() {
        previewWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func renderPreview() {
        guard selectedSize != nil, photoPreview != nil else {
            canvasView.compositedImage = nil
            return
        }
        let preview = previewPixelSize()
        let project = makeProjectModel()
        let image = compositor.render(project: project, imageIndex: currentIndex, canvasPixelSize: preview,
                                      photoSource: { [weak self] _ in self?.photoPreview })
        canvasView.compositedImage = image
        canvasView.compositePixelSize = preview
        updateLayerSelectionState()
    }

    // MARK: - Layer 1 / 3 selection state

    private func effectiveWatermarkTransform() -> WatermarkTransform {
        if let override = edits.watermarkOverride(sizeKey: currentSizeKey(), fileName: currentFileName()) {
            return override
        }
        return layerSettings.watermark.transform
    }

    private func effectiveOverlayTransform() -> OverlayTransform {
        if let override = edits.overlayOverride(sizeKey: currentSizeKey(), fileName: currentFileName()) {
            return override
        }
        return layerSettings.overlay.transform
    }

    private func currentSizeKey() -> String {
        selectedSize?.rawValue ?? ""
    }

    private func overlayImage() -> CGImage? {
        guard !layerSettings.overlay.path.isEmpty else { return nil }
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: layerSettings.overlay.path) as CFURL, nil)
        return source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private func updateLayerSelectionState() {
        let canvas = canvasPixelSize()
        let preview = previewPixelSize()
        guard canvas.width > 0, preview.width > 0 else { return }
        let scale = preview.width / canvas.width

        var wm = layerSettings.watermark
        if wm.text.isEmpty { wm.text = WatermarkTextProvider.current(currentFileName()) }
        let wmBase = LayerGeometry.watermarkBaseSize(canvas: canvas, watermark: wm)
        canvasView.watermarkBaseSize = wmBase.width > 0 ? CGSize(width: wmBase.width * scale, height: wmBase.height * scale) : nil

        if let img = overlayImage() {
            let base = layerSettings.overlay.fit
                ? LayerGeometry.fittedRect(canvas: canvas, imageSize: CGSize(width: img.width, height: img.height))
                : LayerGeometry.filledRect(canvas: canvas, imageSize: CGSize(width: img.width, height: img.height))
            canvasView.overlayBaseSize = CGSize(width: base.width * scale, height: base.height * scale)
        } else {
            canvasView.overlayBaseSize = nil
        }

        canvasView.watermarkTransform = effectiveWatermarkTransform()
        canvasView.overlayTransform = effectiveOverlayTransform()
    }

    private func handleWatermarkChange(_ transform: WatermarkTransform, commit: Bool, option: Bool) {
        if option {
            edits.setWatermarkOverride(transform, sizeKey: currentSizeKey(), fileName: currentFileName())
        } else {
            layerSettings.watermark.transform = transform
        }
        canvasView.watermarkTransform = transform
        if commit { scheduleAutosave() }
        scheduleRenderPreview()
    }

    private func handleOverlayChange(_ transform: OverlayTransform, commit: Bool, option: Bool) {
        if option {
            edits.setOverlayOverride(transform, sizeKey: currentSizeKey(), fileName: currentFileName())
        } else {
            layerSettings.overlay.transform = transform
        }
        canvasView.overlayTransform = transform
        if commit { scheduleAutosave() }
        scheduleRenderPreview()
    }

    // MARK: - Edit handling / undo

    private func handleGestureBegan() {
        guard let key = currentKey() else { return }
        gestureBaseline = lastEdit ?? edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
    }

    private func handleEdit(_ newEdit: ImageEdit, commit: Bool) {
        guard let key = currentKey() else { return }
        let old = lastEdit ?? edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        edits.setEdit(newEdit, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = newEdit
        if commit {
            undoStack.push(gestureBaseline ?? old)
            gestureBaseline = nil
        }
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func undo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let previous = undoStack.undo(current: current) else { return }
        edits.setEdit(previous, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = previous
        canvasView.edit = previous
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func redo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let next = undoStack.redo(current: current) else { return }
        edits.setEdit(next, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = next
        canvasView.edit = next
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func rotationStepChanged(_ value: Double) {
        var s = AppSettings.load()
        s.rotateStep = value
        s.save()
        settings = s
        canvasView.settings = s
        refreshRotationField()
    }

    private func refreshRotationField() {
        rotationField?.value = settings.rotateStep
    }

    private func applyLiveSettings() {
        settings = AppSettings.load()
        canvasView.settings = settings
        refreshRotationField()
    }

    // MARK: - Status

    private func updateStatus() {
        if files.isEmpty {
            statusLabel.textColor = .dimText
            if let size = selectedSize {
                statusLabel.stringValue = "\(size.label) — \(size.pixelWidth)×\(size.pixelHeight) px @ 300 dpi."
            } else {
                statusLabel.stringValue = "Select a paper size to begin."
            }
            return
        }
        statusLabel.textColor = .dimText
        let name = currentFileURL()?.lastPathComponent ?? ""
        statusLabel.stringValue = "\(currentIndex + 1) / \(files.count)  \(name)"
    }

    // MARK: - Project persistence

    private func makeProjectModel() -> ProjectModel {
        ProjectModel(
            workingFolder: workingFolder?.path ?? "",
            files: files.map { $0.lastPathComponent },
            currentIndex: currentIndex,
            selectedSize: selectedSize,
            edits: edits,
            layerSettings: layerSettings
        )
    }

    private func autosave() {
        guard let folder = workingFolder, selectedSize != nil else { return }
        try? makeProjectModel().save(to: folder.path)
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.autosave() }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func restoreLastProject() {
        guard let folderPath = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        guard let model = try? ProjectModel.load(from: folderPath) else { return }

        let folder = URL(fileURLWithPath: folderPath)
        var urls: [URL] = []
        for name in model.files {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }

        workingFolder = folder
        files = urls
        currentIndex = min(max(0, model.currentIndex), files.count - 1)
        edits = model.edits
        layerSettings = model.layerSettings
        selectedSize = model.selectedSize

        if let size = selectedSize {
            for (key, button) in sizeButtons {
                let selected = (key == size)
                button.state = selected ? .on : .off
                button.bezelColor = selected ? .glow : nil
                button.contentTintColor = selected ? .black : .labelColor
            }
            applyOrientationToCanvas()
        } else {
            applyOrientationToCanvas()
        }

        applyAutoOrientation(firstPhotoURL: urls[0])
        applyLayerSettingsToUI()
        showCurrentImage()
        updateStatus()
    }

    // MARK: - Formatting helpers

    private func formatPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formatDegrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    private func pathSummary(_ path: String, empty: String) -> String {
        path.isEmpty ? empty : URL(fileURLWithPath: path).lastPathComponent
    }

    private func finalBackgroundSummary() -> String {
        switch layerSettings.bg6 {
        case .colour(let c):
            return String(format: "Solid %.0f %.0f %.0f", c.red * 255, c.green * 255, c.blue * 255)
        case .image(let path):
            return pathSummary(path, empty: "Solid colour")
        }
    }

    private func fontIndex(for name: String) -> Int {
        Self.fontOptions.firstIndex(where: { $0.name == name }) ?? 0
    }

    private func rgbFromColor(_ color: NSColor) -> RGBAColor {
        let c = color.usingColorSpace(.sRGB) ?? .white
        return RGBAColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                         blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    private func colorFromRGB(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}
