import AppKit
import PrintProcessorCore
import UniformTypeIdentifiers
import Quartz
import CoreGraphics
import ImageIO

/// Production tab: canvas on the left, scrollable options panel on the right,
/// and a top-right bar with paper-size buttons + Process.
final class ProductionView: NSView, NSTextViewDelegate {
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
    private var undoHistory = ImageUndoHistory()
    private var workingFolder: URL?
    private var settings = AppSettings.load()
    private let imageCache: ImageCache

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
    private var overlayFitPopup: NSPopUpButton?
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

    // Layer 2 / 3 (PSD) state.
    private let photoshopQueue = DispatchQueue(label: "com.johorstudio.printprocessor.photoshop", qos: .userInitiated)
    private var psdTextRenderer: PSDTextLayerRenderer?
    private let overlayExporter = PSDOverlayExporter.standard()
    private var overlayWatcher: FileWatcher?
    private var psdTextWatcher: FileWatcher?
    private var photoEditWatcher: FileWatcher?
    private var psdTextList: [String: String] = [:]
    private var overlayCounter = -1
    private var overlayPSDPath = ""
    private var psdTextCounter = -1
    private var psdStylePreviewPath = ""
    private var layer2RenderGeneration = 0

    // Layer-2 / 3 control references.
    private var psdTextPathLabel: NSTextField?
    private var psdManualTextField: NSTextField?
    private var psdListTextView: NSTextView?
    private var psdScanModePopup: NSPopUpButton?
    private var psdPreviewLabel: NSTextField?
    private var psdAlignPopup: NSPopUpButton?
    private var psdTextOpenButton: NSButton?
    private var psdTextUpdateButton: NSButton?
    private var overlayOpenButton: NSButton?

    /// Layer key (1…6, 0 = gradient) → section, for eye syncing.
    private var sections: [Int: SectionView] = [:]

    private var lastEdit: ImageEdit?
    private var gestureBaseline: ImageEdit?
    private var decodeGeneration = 0
    private var autosaveWorkItem: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?

    private var orientationButton: NSButton?
    private var rotationField: RotationStepField?

    // NO EXPORT flag (set of flagged file names) + Preview full toggle.
    private var noExport: Set<String> = []
    private var previewFull = false
    private var noExportButton: NSButton?
    private var previewFullButton: NSButton?

    // Interactive low-res preview: static layers cached, photo transformed per frame.
    private let interactiveRenderer: InteractivePreviewRenderer
    private var staticPreviewKey: StaticPreviewKey?
    private var fullRenderGeneration = 0

    /// Identifies the static-layer inputs so the fast preview re-renders its
    /// cached below/above layers only when one of them actually changes.
    private struct StaticPreviewKey: Equatable {
        let sizeKey: String
        let orientation: CanvasOrientation
        let index: Int
        let layers: LayerSettings
        let scanMode: String
        let psdTextList: [String: String]
        let layer2Box: PSDTextBox
        let layer2Image: ObjectIdentifier?
    }

    // Export UI + state.
    private var exportJPGCheckbox: NSButton?
    private var exportWebPCheckbox: NSButton?
    private var jpgQualityField: NSTextField?
    private var jpgSizingPopup: NSPopUpButton?
    private var jpgLongEdgeField: NSTextField?
    private var webpQualityField: NSTextField?
    private var webpLongEdgeField: NSTextField?
    private var exportRootLabel: NSTextField?
    private var exportRoot: URL?
    private var exportJob: ExportJob?
    private var applyAllCollisionPolicy: CollisionPolicy?
    private var renderButton: NSButton?
    private var processButton: NSButton?
    private var cancelButton: NSButton?
    private var quickLookURL: URL?
    private var spaceCloseMonitor: Any?

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
        self.imageCache = ImageCache(ramCapBytes: AppSettings.load().cacheRAMCapMB * 1024 * 1024)
        self.interactiveRenderer = InteractivePreviewRenderer(compositor: compositor)
        super.init(frame: frameRect)
        build()
        canvasView.settings = settings
        compositor.scanMode = settings.scanMode
        reloadScanModes()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyLiveSettings()
            }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResign), name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
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
        if let monitor = spaceCloseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        deleteQuickLookTemp()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor
        registerForDraggedTypes([.fileURL])

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

        let previewFullButton = NSButton(title: "Preview full", target: self, action: #selector(previewFullClicked))
        previewFullButton.setButtonType(.pushOnPushOff)
        previewFullButton.bezelStyle = .rounded
        previewFullButton.controlSize = .regular
        previewFullButton.state = .off
        let previewFullShortcut = ShortcutStore.shared.entry(.previewFull)?.display ?? "P"
        previewFullButton.toolTip = "Preview full — high-resolution render of the canvas (any edit gesture returns to fast preview). Shortcut: \(previewFullShortcut)"
        self.previewFullButton = previewFullButton

        let processButton = NSButton(title: "Process", target: self, action: #selector(processClicked))
        processButton.bezelStyle = .rounded
        processButton.controlSize = .regular
        processButton.bezelColor = .glow
        processButton.contentTintColor = .black
        let processShortcut = ShortcutStore.shared.entry(.process)?.display ?? "⌘P"
        processButton.toolTip = "Process — render and export every photo (Shortcut: \(processShortcut))"
        self.processButton = processButton

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelExportClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.toolTip = "Cancel — stop exporting the remaining files"
        cancelButton.isHidden = true
        self.cancelButton = cancelButton

        let controlsRow = NSStackView(views: [sizeStack, previewFullButton, processButton, cancelButton])
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
        canvasView.onEdit = { [weak self] edit, commit, scope in
            self?.handleEdit(edit, commit: commit, scope: scope)
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
        canvasView.onPSDTextBoxChanged = { [weak self] box, commit, option in
            self?.handlePSDTextBoxChanged(box, commit: commit, option: option)
        }
        canvasView.onMiddleClick = { [weak self] layer in
            self?.handleMiddleClick(layer)
        }
        canvasView.onRender = { [weak self] in self?.renderClicked() }
        canvasView.onProcess = { [weak self] in self?.processClicked() }
        canvasView.onToggleNoExport = { [weak self] in self?.toggleNoExport() }
        canvasView.onTogglePreviewFull = { [weak self] in self?.togglePreviewFull() }

        let options = makeOptionsPanel()

        // Left column: canvas above a Render button.
        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        let renderButton = NSButton(title: "Render", target: self, action: #selector(renderClicked))
        renderButton.bezelStyle = .rounded
        renderButton.controlSize = .regular
        renderButton.toolTip = "Render — render the current image at full resolution into a temp file and open Quick Look (Space closes). Shortcut: ⌘R"
        renderButton.translatesAutoresizingMaskIntoConstraints = false
        self.renderButton = renderButton

        let noExportButton = NSButton(title: "NO EXPORT", target: self, action: #selector(noExportClicked))
        noExportButton.setButtonType(.pushOnPushOff)
        noExportButton.bezelStyle = .rounded
        noExportButton.controlSize = .regular
        let noExportShortcut = ShortcutStore.shared.entry(.noExport)?.display ?? "X"
        noExportButton.toolTip = "NO EXPORT — flag the current photo so export skips it (canvas shows a red X). Shortcut: \(noExportShortcut)"
        noExportButton.translatesAutoresizingMaskIntoConstraints = false
        self.noExportButton = noExportButton

        left.addSubview(canvasView)
        left.addSubview(renderButton)
        left.addSubview(noExportButton)
        row.addSubview(left)
        row.addSubview(options)

        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            left.trailingAnchor.constraint(equalTo: options.leadingAnchor),

            canvasView.topAnchor.constraint(equalTo: left.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: left.trailingAnchor),

            renderButton.topAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: 6),
            renderButton.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            renderButton.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8),
            renderButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            noExportButton.topAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: 6),
            noExportButton.leadingAnchor.constraint(equalTo: renderButton.trailingAnchor, constant: 8),
            noExportButton.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8),
            noExportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

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

        let exportSection = SectionView(title: "Export", body: makeExportBody())
        let watermarkSection = SectionView(title: "Watermark", body: makeWatermarkBody())
        let psdSection = SectionView(title: "PSD Text", body: makePSDTextBody())
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

        for section in [exportSection, watermarkSection, psdSection, overlaySection, gradientSection, photoSection, bg5Section, bg6Section] {
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
        scroll.translatesAutoresizingMaskIntoConstraints = false
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

    private func makeNumberField() -> NSTextField {
        let field = NSTextField(string: "")
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .left
        return field
    }

    private func makeExportBody() -> NSView {
        let jpgCheck = NSButton(checkboxWithTitle: "JPG", target: self, action: #selector(exportJPGToggled))
        jpgCheck.toolTip = "JPG — export JPG files into JPG/"
        exportJPGCheckbox = jpgCheck

        let webpCheck = NSButton(checkboxWithTitle: "WebP", target: self, action: #selector(exportWebPToggled))
        webpCheck.toolTip = "WebP — export WebP files into WebP/"
        exportWebPCheckbox = webpCheck

        let formatsRow = NSStackView(views: [jpgCheck, webpCheck])
        formatsRow.orientation = .horizontal
        formatsRow.alignment = .centerY
        formatsRow.spacing = 18

        let jpgHeader = makeLabel("JPG", size: 12, weight: .semibold, color: .labelColor)
        let webpHeader = makeLabel("WebP", size: 12, weight: .semibold, color: .labelColor)

        let jpgQuality = makeNumberField()
        jpgQuality.target = self
        jpgQuality.action = #selector(exportJPGQualityChanged)
        jpgQuality.toolTip = "JPG quality — Photoshop scale 0–12 (default 10)"
        jpgQualityField = jpgQuality
        jpgQuality.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let sizingPopup = NSPopUpButton()
        for s in JPGSizing.allCases { sizingPopup.addItem(withTitle: s.displayName) }
        sizingPopup.target = self
        sizingPopup.action = #selector(exportJPGSizingChanged)
        sizingPopup.toolTip = "JPG size — inch (300 dpi) or long edge in pixels"
        jpgSizingPopup = sizingPopup

        let jpgLongEdge = makeNumberField()
        jpgLongEdge.target = self
        jpgLongEdge.action = #selector(exportJPGLongEdgeChanged)
        jpgLongEdge.toolTip = "JPG long edge — pixels when “Long edge (px)” is selected"
        jpgLongEdgeField = jpgLongEdge
        jpgLongEdge.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let webpQuality = makeNumberField()
        webpQuality.target = self
        webpQuality.action = #selector(exportWebPQualityChanged)
        webpQuality.toolTip = "WebP quality — percentage 0–100 (default 50)"
        webpQualityField = webpQuality
        webpQuality.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let webpLongEdge = makeNumberField()
        webpLongEdge.target = self
        webpLongEdge.action = #selector(exportWebPLongEdgeChanged)
        webpLongEdge.toolTip = "WebP long edge — pixels (0 = full paper size at 300 dpi)"
        webpLongEdgeField = webpLongEdge
        webpLongEdge.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let exportToButton = NSButton(title: "Export to…", target: self, action: #selector(chooseExportRoot))
        exportToButton.bezelStyle = .rounded
        exportToButton.controlSize = .regular
        exportToButton.toolTip = "Export to… — choose the export root folder (default = working folder); JPG/ and WebP/ are created inside"

        let rootLabel = makeLabel("Working folder", size: 11, weight: .regular, color: .dimText)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.maximumNumberOfLines = 1
        exportRootLabel = rootLabel

        let stack = NSStackView(views: [
            formatsRow,
            jpgHeader,
            labelRow("Quality", jpgQuality),
            labelRow("Size", sizingPopup),
            labelRow("Long edge", jpgLongEdge),
            webpHeader,
            labelRow("Quality", webpQuality),
            labelRow("Long edge", webpLongEdge),
            exportToButton,
            rootLabel,
        ])
        rootLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -14).isActive = true

        let container = makeBody(stack)
        syncExportUI()
        return container
    }

    // MARK: - Export UI sync / actions

    private func readExportUI() -> ExportSettings {
        var e = settings.export
        e.exportJPG = exportJPGCheckbox?.state == .on
        e.exportWebP = exportWebPCheckbox?.state == .on
        if let v = Int(jpgQualityField?.stringValue ?? "") { e.jpgQuality = v }
        if let idx = jpgSizingPopup?.indexOfSelectedItem, JPGSizing.allCases.indices.contains(idx) {
            e.jpgSizing = JPGSizing.allCases[idx]
        }
        if let v = Int(jpgLongEdgeField?.stringValue ?? "") { e.jpgLongEdge = v }
        if let v = Int(webpQualityField?.stringValue ?? "") { e.webpQuality = v }
        if let v = Int(webpLongEdgeField?.stringValue ?? "") { e.webpLongEdge = v }
        return e
    }

    private func syncExportUI() {
        let e = settings.export
        exportJPGCheckbox?.state = e.exportJPG ? .on : .off
        exportWebPCheckbox?.state = e.exportWebP ? .on : .off
        jpgQualityField?.stringValue = String(e.jpgQuality)
        jpgLongEdgeField?.stringValue = String(e.jpgLongEdge)
        webpQualityField?.stringValue = String(e.webpQuality)
        webpLongEdgeField?.stringValue = String(e.webpLongEdge)
        if let idx = JPGSizing.allCases.firstIndex(of: e.jpgSizing) {
            jpgSizingPopup?.selectItem(at: idx)
        }
        exportRootLabel?.stringValue = exportRoot?.path ?? "Working folder"
        let longEdgeMode = e.jpgSizing == .longEdge
        jpgLongEdgeField?.isEnabled = longEdgeMode
    }

    private func updateExportSetting(_ mutate: (inout ExportSettings) -> Void) {
        var s = AppSettings.load()
        mutate(&s.export)
        s.save()
        settings = s
        syncExportUI()
    }

    @objc private func exportJPGToggled() {
        updateExportSetting { $0.exportJPG = self.exportJPGCheckbox?.state == .on }
    }

    @objc private func exportWebPToggled() {
        updateExportSetting { $0.exportWebP = self.exportWebPCheckbox?.state == .on }
    }

    @objc private func exportJPGQualityChanged() {
        guard let v = Int(jpgQualityField?.stringValue ?? "") else { return }
        updateExportSetting { $0.jpgQuality = min(12, max(0, v)) }
    }

    @objc private func exportJPGLongEdgeChanged() {
        guard let v = Int(jpgLongEdgeField?.stringValue ?? "") else { return }
        updateExportSetting { $0.jpgLongEdge = max(0, v) }
    }

    @objc private func exportJPGSizingChanged() {
        guard let idx = jpgSizingPopup?.indexOfSelectedItem, JPGSizing.allCases.indices.contains(idx) else { return }
        updateExportSetting { $0.jpgSizing = JPGSizing.allCases[idx] }
    }

    @objc private func exportWebPQualityChanged() {
        guard let v = Int(webpQualityField?.stringValue ?? "") else { return }
        updateExportSetting { $0.webpQuality = min(100, max(0, v)) }
    }

    @objc private func exportWebPLongEdgeChanged() {
        guard let v = Int(webpLongEdgeField?.stringValue ?? "") else { return }
        updateExportSetting { $0.webpLongEdge = max(0, v) }
    }

    @objc private func chooseExportRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the export root folder. JPG/ and WebP/ are created inside it."
        if panel.runModal() == .OK, let url = panel.url {
            exportRoot = url
            exportRootLabel?.stringValue = url.path
        }
    }

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

    private func makePSDTextBody() -> NSView {
        let loadButton = NSButton(title: "Load PSD…", target: self, action: #selector(loadPSDTextClicked))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .regular
        loadButton.toolTip = "Load PSD… — PSD with a text layer + layer style; text is set in Photoshop, style stays identical"

        let pathLabel = makeLabel("No PSD loaded", size: 11, weight: .regular, color: .dimText)
        psdTextPathLabel = pathLabel

        let openButton = NSButton(title: "Open in Photoshop", target: self, action: #selector(openPSDTextInPhotoshop))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .regular
        openButton.toolTip = "Open in Photoshop — open the layer-2 PSD with Photoshop"
        psdTextOpenButton = openButton

        let updateButton = NSButton(title: "Update", target: self, action: #selector(updatePSDTextClicked))
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .regular
        updateButton.toolTip = "Update — save the PSD in Photoshop, export a new <name>-NN.webp style preview, and re-render the text"
        psdTextUpdateButton = updateButton

        let actionRow = NSStackView(views: [openButton, updateButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let drawBoxButton = NSButton(title: "Draw box", target: self, action: #selector(drawPSDBoxClicked))
        drawBoxButton.bezelStyle = .rounded
        drawBoxButton.controlSize = .regular
        drawBoxButton.toolTip = "Draw box — drag on the canvas to set the layer-2 text bounding box"

        let manualField = NSTextField()
        manualField.placeholderString = "Manual text (overrides list/scan)"
        manualField.controlSize = .regular
        manualField.isBezeled = true
        manualField.target = self
        manualField.action = #selector(psdManualTextChanged)
        manualField.toolTip = "Manual text — per-image override, highest priority for layer 2"
        psdManualTextField = manualField

        let importButton = NSButton(title: "Import .txt", target: self, action: #selector(importPSDListClicked))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .regular
        importButton.toolTip = "Import .txt — number + name list (one per line: 122 - Norman Hakim or 122<TAB>Norman Hakim)"

        let textScroll = NSTextView.scrollableTextView()
        let textView = textScroll.documentView as? NSTextView
        textView?.isRichText = false
        textView?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView?.textContainerInset = NSSize(width: 4, height: 4)
        textScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        textView?.delegate = self
        psdListTextView = textView

        let scanPopup = NSPopUpButton()
        scanPopup.target = self
        scanPopup.action = #selector(psdScanModeChanged)
        scanPopup.toolTip = "Scan mode — which side of \" - \" goes to text vs watermark; saved modes switchable in one click"
        psdScanModePopup = scanPopup

        let alignPopup = NSPopUpButton()
        for align in TextAlign.allCases { alignPopup.addItem(withTitle: align.displayName) }
        alignPopup.target = self
        alignPopup.action = #selector(psdAlignChanged)
        alignPopup.toolTip = "Align — layer-2 text alignment inside the bounding box"
        psdAlignPopup = alignPopup

        let previewLabel = makeLabel("", size: 11, weight: .regular, color: .dimText)
        previewLabel.maximumNumberOfLines = 3
        previewLabel.lineBreakMode = .byWordWrapping
        psdPreviewLabel = previewLabel

        let listLabel = makeLabel("List / paste (number → text)", size: 12, weight: .regular, color: .labelColor)

        let stack = NSStackView(views: [
            loadButton, pathLabel, actionRow, drawBoxButton,
            manualField,
            labelRow("Align", alignPopup),
            labelRow("Scan", scanPopup),
            listLabel, textScroll, importButton,
            previewLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [textScroll, previewLabel, manualField] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -14).isActive = true }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ])
        reloadScanModes()
        return container
    }

    private func makeOverlayBody() -> NSView {
        let loadButton = NSButton(title: "Load overlay…", target: self, action: #selector(loadOverlayClicked))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .regular
        loadButton.toolTip = "Load overlay… — PNG/WebP overlay with transparency (layer 3, fit/fill to canvas)"

        let label = makeLabel("No overlay loaded", size: 11, weight: .regular, color: .dimText)
        overlayPathLabel = label

        let loadPSDButton = NSButton(title: "Load PSD…", target: self, action: #selector(loadOverlayPSDClicked))
        loadPSDButton.bezelStyle = .rounded
        loadPSDButton.controlSize = .regular
        loadPSDButton.toolTip = "Load PSD… — layer-3 PSD overlay; exports <name>-NN.webp beside it and watches for saves"

        let openButton = NSButton(title: "Open in Photoshop", target: self, action: #selector(openOverlayInPhotoshop))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .regular
        openButton.isEnabled = false
        openButton.toolTip = "Open in Photoshop — open the layer-3 overlay file"
        overlayOpenButton = openButton

        let fitPopup = NSPopUpButton()
        fitPopup.addItem(withTitle: "Fit")
        fitPopup.addItem(withTitle: "Fill")
        fitPopup.target = self
        fitPopup.action = #selector(overlayFitChanged)
        fitPopup.toolTip = "Fit/Fill — Fit letterboxes the overlay inside the canvas; Fill covers the canvas"
        overlayFitPopup = fitPopup

        let stack = NSStackView(views: [loadButton, loadPSDButton, openButton, labelRow("Fit/Fill", fitPopup), label])
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
        overlayFitPopup?.selectItem(at: layerSettings.overlay.fit ? 0 : 1)
        bg5PathLabel?.stringValue = pathSummary(layerSettings.bg5.path, empty: "No background image")
        bg6PathLabel?.stringValue = finalBackgroundSummary()
        watermarkSizeValue?.stringValue = formatPercent(layerSettings.watermark.sizeFraction)
        watermarkOpacityValue?.stringValue = formatPercent(layerSettings.watermark.opacity)
        gradientAngleValue?.stringValue = formatDegrees(layerSettings.gradient.angle)
        gradientOpacityValue?.stringValue = formatPercent(layerSettings.gradient.opacity)
        psdTextPathLabel?.stringValue = pathSummary(layerSettings.psdText.path, empty: "No PSD loaded")
        if let idx = TextAlign.allCases.firstIndex(of: layerSettings.psdText.align) {
            psdAlignPopup?.selectItem(at: idx)
        }
        canvasView.psdTextBox = effectivePSDTextBox()
        canvasView.psdTextAlign = layerSettings.psdText.align
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
            self?.preloadLayerImages()
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
            self?.preloadLayerImages()
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
            self?.preloadLayerImages()
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

    // MARK: - Layer 2 (PSD text)

    @objc private func loadPSDTextClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let psdType = UTType(filenameExtension: "psd") { panel.allowedContentTypes = [psdType] }
        panel.message = "Choose a PSD with a text layer + layer style."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPSDTextPath(url.path)
    }

    private func setPSDTextPath(_ path: String) {
        layerSettings.psdText.path = path
        psdTextPathLabel?.stringValue = URL(fileURLWithPath: path).lastPathComponent
        canvasView.psdTextBox = effectivePSDTextBox()
        canvasView.psdTextAlign = layerSettings.psdText.align
        startPSDTextWatcher(path)
        scheduleLayer2Render()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    /// Re-render layer 2 whenever the PSD file is saved (same debounced watch as
    /// layer 3), so text changes made in Photoshop appear without a manual click.
    private func startPSDTextWatcher(_ path: String) {
        psdTextWatcher?.stop()
        guard !path.isEmpty else { return }
        psdTextWatcher = FileWatcher(path: path, debounce: 1.0) { [weak self] _ in
            DispatchQueue.main.async {
                self?.scheduleLayer2Render()
                self?.scheduleRenderPreview()
            }
        }
        psdTextWatcher?.start()
    }

    /// Show a short Photoshop error in the status line.
    private func showPhotoshopError(_ error: String) {
        let short = error.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? error
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = "Photoshop: \(short)"
    }

    @objc private func openPSDTextInPhotoshop() {
        guard !layerSettings.psdText.path.isEmpty else { return }
        openInPhotoshop(layerSettings.psdText.path)
    }

    /// Update: (1) save the open PSD via JSX (no-op if not open), (2) export a
    /// new <name>-NN.webp style preview beside the PSD, (3) drop caches and
    /// re-render the text (queued in the background), then refresh the canvas.
    @objc private func updatePSDTextClicked() {
        let psdPath = layerSettings.psdText.path
        guard !psdPath.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Load a PSD first."
            return
        }
        statusLabel.textColor = .dimText
        statusLabel.stringValue = "Updating PSD text…"

        let runner = PhotoshopRunner(photoshopAppPath: settings.photoshopPath)
        let psdURL = URL(fileURLWithPath: psdPath)
        let cacheDir = cacheDirectory()
        let cwebp = settings.cwebpPath
        let counter = psdTextCounter

        photoshopQueue.async { [weak self] in
            guard let self = self else { return }
            // 1. Save the open document (no-op when it is not open).
            let saved = runner.saveOpenDocument(psdPath: psdPath)
            var firstError: String? = saved ? nil : runner.lastError

            // 2. Export a new <name>-NN.webp style preview beside the PSD
            //    (ImageIO composite first, JSX PNG + cwebp as fallback).
            let number = WebPNumbering.nextNumber(psdURL: psdURL, counter: counter)
            let out = WebPNumbering.outputURL(psdURL: psdURL, number: number)
            var webpURL: URL?
            if let composite = PSDFlatten.composite(psdPath: psdPath) {
                if WebPEncoder(cwebpPath: cwebp).encode(image: composite, to: out) {
                    webpURL = out
                }
            }
            if webpURL == nil {
                let pngPath = (cacheDir as NSString).appendingPathComponent("pp-style-\(UUID().uuidString).png")
                if runner.renderPNG(psdPath: psdPath, text: nil, layerName: "", outputPNG: pngPath),
                   let png = PSDFlatten.composite(psdPath: pngPath) {
                    if WebPEncoder(cwebpPath: cwebp).encode(image: png, to: out) {
                        webpURL = out
                    }
                }
                if firstError == nil, let err = runner.lastError, !err.isEmpty { firstError = err }
                try? FileManager.default.removeItem(atPath: pngPath)
            }

            let maxNum = WebPNumbering.existingNumbers(psdURL: psdURL).max() ?? counter

            DispatchQueue.main.async {
                self.psdTextCounter = max(maxNum, counter)
                if let w = webpURL {
                    self.psdStylePreviewPath = w.path
                    self.psdTextPathLabel?.stringValue = "\(psdURL.lastPathComponent) → \(w.lastPathComponent)"
                }
                // 3. Drop caches and re-render the text (current image first,
                //    then the rest queued in the background).
                self.compositor.invalidateCache()
                self.scheduleLayer2Render()
                self.scheduleRenderPreview()
                self.scheduleAutosave()

                if webpURL == nil {
                    if let err = firstError, !err.isEmpty {
                        self.showPhotoshopError(err)
                    } else {
                        self.statusLabel.textColor = .systemRed
                        self.statusLabel.stringValue = "Could not export style preview (cwebp missing?)."
                    }
                } else if let err = firstError, !err.isEmpty {
                    self.showPhotoshopError(err)
                } else {
                    self.statusLabel.textColor = .dimText
                    self.statusLabel.stringValue = "Updated: \(webpURL?.lastPathComponent ?? "")"
                }
            }
        }
    }

    /// Route a dropped .psd to layer 2 (when its section is focused) or layer 3;
    /// ask via an NSMenu when the target is ambiguous.
    private func routeDroppedPSD(_ url: URL) {
        let layer2Focused = sections[2]?.containsFirstResponder() == true
        let layer3Focused = sections[3]?.containsFirstResponder() == true
        if layer2Focused && !layer3Focused {
            setPSDTextPath(url.path)
        } else if layer3Focused && !layer2Focused {
            setOverlayPSD(url)
        } else {
            let menu = NSMenu()
            let l2 = NSMenuItem(title: "Layer 2 — PSD Text", action: #selector(droppedPSDToLayer2(_:)), keyEquivalent: "")
            l2.target = self
            l2.representedObject = url.path
            let l3 = NSMenuItem(title: "Layer 3 — Overlay", action: #selector(droppedPSDToLayer3(_:)), keyEquivalent: "")
            l3.target = self
            l3.representedObject = url.path
            menu.addItem(l2)
            menu.addItem(l3)
            if let window = window, let view = window.contentView {
                let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                let viewPoint = view.convert(windowPoint, from: nil)
                menu.popUp(positioning: nil, at: viewPoint, in: view)
            }
        }
    }

    @objc private func droppedPSDToLayer2(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        setPSDTextPath(path)
    }

    @objc private func droppedPSDToLayer3(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        setOverlayPSD(URL(fileURLWithPath: path))
    }

    @objc private func drawPSDBoxClicked() {
        canvasView.armPSDBoxDrawing()
    }

    @objc private func psdManualTextChanged() {
        guard let key = currentKey() else { return }
        let text = psdManualTextField?.stringValue ?? ""
        edits.setManualText(text, sizeKey: key.sizeKey, fileName: key.fileName)
        scheduleLayer2Render()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func psdScanModeChanged() {
        guard let popup = psdScanModePopup else { return }
        let modes = currentScanModes()
        let idx = popup.indexOfSelectedItem
        guard modes.indices.contains(idx) else { return }
        var s = AppSettings.load()
        s.scanMode = modes[idx]
        s.save()
        settings = s
        compositor.scanMode = s.scanMode
        updatePSDPreview()
        scheduleLayer2Render()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func psdAlignChanged() {
        guard let popup = psdAlignPopup else { return }
        let idx = popup.indexOfSelectedItem
        guard TextAlign.allCases.indices.contains(idx) else { return }
        layerSettings.psdText.align = TextAlign.allCases[idx]
        canvasView.psdTextAlign = layerSettings.psdText.align
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func importPSDListClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let txtType = UTType(filenameExtension: "txt") { panel.allowedContentTypes = [txtType] }
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        psdListTextView?.string = text
        applyPSDList(text)
    }

    private func applyPSDList(_ text: String) {
        psdTextList = TextSourceResolver.parseList(text)
        updatePSDPreview()
        scheduleLayer2Render()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    func textDidChange(_ notification: Notification) {
        applyPSDList(psdListTextView?.string ?? "")
    }

    private func reloadScanModes() {
        guard let popup = psdScanModePopup else { return }
        popup.removeAllItems()
        for mode in currentScanModes() {
            popup.addItem(withTitle: ScanMode.parse(mode).displayName)
        }
        if let idx = currentScanModes().firstIndex(of: settings.scanMode) {
            popup.selectItem(at: idx)
        }
        updatePSDPreview()
    }

    private func currentScanModes() -> [String] {
        settings.savedScanModes.isEmpty ? ["text=right"] : settings.savedScanModes
    }

    private func updatePSDPreview() {
        let mode = ScanMode.parse(settings.scanMode)
        var lines: [String] = []
        for file in files.prefix(3) {
            let r = TextSourceResolver.resolve(fileName: file.lastPathComponent, manualText: "", list: psdTextList, scanMode: mode)
            lines.append("\(file.lastPathComponent) → “\(r.text)” / wm “\(r.watermark)”")
        }
        psdPreviewLabel?.stringValue = lines.isEmpty ? "No files — scan preview appears here." : lines.joined(separator: "\n")
    }

    private func handlePSDTextBoxChanged(_ box: PSDTextBox, commit: Bool, option: Bool) {
        if option {
            // Option-drag writes a per-image override.
            if let key = currentKey() {
                edits.setPSDBoxOverride(box, sizeKey: key.sizeKey, fileName: key.fileName)
            }
        } else {
            layerSettings.psdText.box = box
        }
        canvasView.psdTextBox = box
        scheduleRenderPreview()
        if commit { scheduleAutosave() }
    }

    /// The layer-2 box for the current image: per-image override or the global.
    private func effectivePSDTextBox() -> PSDTextBox {
        if let key = currentKey(), let override = edits.psdBoxOverride(sizeKey: key.sizeKey, fileName: key.fileName) {
            return override
        }
        return layerSettings.psdText.box
    }

    private func runnerForRender() -> PhotoshopRunnerProtocol {
        PhotoshopRunner(photoshopAppPath: settings.photoshopPath)
    }

    private func cacheDirectory() -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PrintProcessor/psdtext-cache")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    private func layer2BoxPixelSize() -> CGSize {
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return CGSize(width: 1000, height: 1000) }
        let box = effectivePSDTextBox()
        return CGSize(width: CGFloat(box.width) * canvas.width,
                      height: CGFloat(box.height) * canvas.height)
    }

    private func scheduleLayer2Render() {
        guard !layerSettings.psdText.path.isEmpty else {
            compositor.layer2Image = nil
            return
        }
        layer2RenderGeneration += 1
        let gen = layer2RenderGeneration
        let psdPath = layerSettings.psdText.path
        let layerName = settings.psdTextLayerName.isEmpty ? "TEXT" : settings.psdTextLayerName
        let cacheDir = cacheDirectory()
        let boxSize = layer2BoxPixelSize()
        let fileName = currentFileName()
        let sizeKey = currentSizeKey()
        let manualText = edits.manualText(sizeKey: sizeKey, fileName: fileName) ?? ""
        let list = psdTextList
        let mode = ScanMode.parse(settings.scanMode)
        let minScale = settings.minTextScale
        let text = TextSourceResolver.resolve(fileName: fileName, manualText: manualText, list: list, scanMode: mode).text
        let photoshopPath = settings.photoshopPath

        let runner = PhotoshopRunner(photoshopAppPath: photoshopPath)
        let renderer = PSDTextLayerRenderer(
            runner: runner,
            cacheDirectory: cacheDir,
            layerName: layerName,
            minTextScale: minScale
        )
        psdTextRenderer = renderer

        photoshopQueue.async { [weak self] in
            let image = renderer.render(psdPath: psdPath, text: text, boxSize: boxSize)
            DispatchQueue.main.async {
                guard let self = self, gen == self.layer2RenderGeneration else { return }
                self.compositor.layer2Image = image
                if image == nil, let err = runner.lastError, !err.isEmpty {
                    self.showPhotoshopError(err)
                }
                self.renderPreview()
            }
        }
    }

    // MARK: - Layer 3 (PSD overlay)

    @objc private func loadOverlayPSDClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let psdType = UTType(filenameExtension: "psd") { panel.allowedContentTypes = [psdType] }
        panel.message = "Choose a PSD overlay."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOverlayPSD(url)
    }

    private func setOverlayPSD(_ url: URL) {
        overlayPSDPath = url.path
        overlayOpenButton?.isEnabled = true
        if !WebPEncoder.isAvailable {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "cwebp not found — install webp or set cwebpPath."
        }
        let counter = overlayCounter
        photoshopQueue.async { [weak self] in
            guard let self = self else { return }
            if let out = self.overlayExporter.export(psdURL: url, counter: counter) {
                let maxNum = WebPNumbering.existingNumbers(psdURL: url).max() ?? counter
                DispatchQueue.main.async {
                    self.overlayCounter = max(maxNum, counter)
                    self.layerSettings.overlay.path = out.path
                    self.compositor.invalidateCache()
                    self.overlayPathLabel?.stringValue = out.lastPathComponent
                    self.preloadLayerImages()
                    self.scheduleRenderPreview()
                    self.scheduleAutosave()
                    self.startOverlayWatcher(url)
                }
            } else {
                DispatchQueue.main.async {
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Could not flatten PSD overlay."
                }
            }
        }
    }

    private func startOverlayWatcher(_ url: URL) {
        overlayWatcher?.stop()
        overlayWatcher = FileWatcher(path: url.path, debounce: 2.0) { [weak self] path in
            guard let self = self else { return }
            let psdURL = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                let counter = self.overlayCounter
                self.photoshopQueue.async {
                    if let out = self.overlayExporter.export(psdURL: psdURL, counter: counter) {
                        let maxNum = WebPNumbering.existingNumbers(psdURL: psdURL).max() ?? counter
                        DispatchQueue.main.async {
                            self.overlayCounter = max(maxNum, counter)
                            self.layerSettings.overlay.path = out.path
                            self.compositor.invalidateCache()
                            self.overlayPathLabel?.stringValue = out.lastPathComponent
                            self.preloadLayerImages()
                            self.scheduleRenderPreview()
                            self.scheduleAutosave()
                            // Re-arm after a save/rename so the watch stays on
                            // the current file (Photoshop may replace/rename it).
                            self.startOverlayWatcher(psdURL)
                        }
                    }
                }
            }
        }
        overlayWatcher?.start()
    }

    /// Restore a persisted layer-3 PSD path: re-arm the watcher and reload the
    /// newest numbered webp beside it (used when reopening a saved project).
    private func restoreOverlayPSD(_ path: String) {
        overlayPSDPath = path
        overlayOpenButton?.isEnabled = !path.isEmpty
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        let psdURL = URL(fileURLWithPath: path)
        if let newest = WebPNumbering.existingNumbers(psdURL: psdURL).max() {
            let candidate = WebPNumbering.outputURL(psdURL: psdURL, number: newest)
            if FileManager.default.fileExists(atPath: candidate.path) {
                layerSettings.overlay.path = candidate.path
                compositor.invalidateCache()
            }
        }
        startOverlayWatcher(psdURL)
    }

    @objc private func overlayFitChanged() {
        layerSettings.overlay.fit = overlayFitPopup?.indexOfSelectedItem == 0
        compositor.invalidateCache()
        updateLayerSelectionState()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    @objc private func openOverlayInPhotoshop() {
        let path = overlayPSDPath.isEmpty ? layerSettings.overlay.path : overlayPSDPath
        guard !path.isEmpty else { return }
        openInPhotoshop(path)
    }

    // MARK: - Middle-click / open in Photoshop

    private func handleMiddleClick(_ layer: Int) {
        switch layer {
        case 2:
            guard !layerSettings.psdText.path.isEmpty else { return }
            openInPhotoshop(layerSettings.psdText.path)
        case 3:
            openOverlayInPhotoshop()
        case 4:
            if let url = currentFileURL() { openPhotoInPhotoshop(url) }
        default:
            break
        }
    }

    private func openInPhotoshop(_ path: String) {
        let fileURL = URL(fileURLWithPath: path)
        let appPath = settings.photoshopPath.isEmpty ? (PhotoshopRunner.detectPhotoshop() ?? "") : settings.photoshopPath
        if !appPath.isEmpty {
            NSWorkspace.shared.open([fileURL], withApplicationAt: URL(fileURLWithPath: appPath),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func openPhotoInPhotoshop(_ url: URL) {
        let backupURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pp-orig-\(UUID().uuidString).\(url.pathExtension)")
        let hadOriginal = (try? FileManager.default.copyItem(at: url, to: backupURL)) != nil
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        openInPhotoshop(url.path)
        photoEditWatcher?.stop()
        photoEditWatcher = FileWatcher(path: url.path, debounce: 1.0) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let after = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                guard after != before else { return }
                self.photoEditWatcher?.stop()
                self.askPhotoSave(original: url, backup: backupURL, hadOriginal: hadOriginal)
            }
        }
        photoEditWatcher?.start()
    }

    private func askPhotoSave(original: URL, backup: URL, hadOriginal: Bool) {
        let alert = NSAlert()
        alert.messageText = "Photo edited in Photoshop"
        alert.informativeText = "Save as new version (name-01.webp), replace original, or cancel?"
        alert.addButton(withTitle: "Save as new version")
        alert.addButton(withTitle: "Replace original")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Save the edited copy as a new numbered WebP (re-encoded, never a
            // raw byte copy under a .webp name), restore the original.
            let number = WebPNumbering.nextNumber(psdURL: original, counter: -1)
            let cwebp = settings.cwebpPath
            PhotoEditSave.saveAsNewVersion(original: original, backup: backup, hadBackup: hadOriginal,
                                           number: number) { image, url in
                WebPEncoder(cwebpPath: cwebp).encode(image: image, to: url)
            }
        case .alertSecondButtonReturn:
            // Replace original: keep the edited copy, drop the backup.
            PhotoEditSave.replaceOriginal(backup: backup)
        default:
            // Cancel: discard the edited copy and restore the untouched original.
            PhotoEditSave.cancel(original: original, backup: backup, hadBackup: hadOriginal)
        }
        scheduleRenderPreview()
    }

    // MARK: - Actions (top bar / photo)

    @objc private func sizeClicked(_ sender: NSButton) {
        guard let size = sizeButtons.first(where: { $0.value === sender })?.key else { return }
        selectSize(size)
    }

    @objc private func noExportClicked() {
        toggleNoExport()
    }

    @objc private func previewFullClicked() {
        togglePreviewFull()
    }

    /// Toggle the "NO EXPORT" flag on the current photo (canvas-only visual,
    /// export skips it). Not undoable (Cmd+Z does not touch it).
    private func toggleNoExport() {
        guard let name = currentFileURL()?.lastPathComponent, !name.isEmpty else { return }
        if noExport.contains(name) {
            noExport.remove(name)
        } else {
            noExport.insert(name)
        }
        syncNoExportUI()
        scheduleAutosave()
    }

    /// Sync the NO EXPORT button + canvas overlay to the current photo's flag.
    private func syncNoExportUI() {
        let name = currentFileURL()?.lastPathComponent ?? ""
        let flagged = noExport.contains(name)
        noExportButton?.state = flagged ? .on : .off
        noExportButton?.bezelColor = flagged ? .systemRed : nil
        noExportButton?.contentTintColor = flagged ? .white : .labelColor
        canvasView.noExport = flagged
        updateStatus()
    }

    private func togglePreviewFull() {
        setPreviewFull(!previewFull)
    }

    /// Turn the high-resolution preview on/off. Any edit gesture turns it off.
    private func setPreviewFull(_ on: Bool) {
        previewFull = on
        previewFullButton?.state = on ? .on : .off
        previewFullButton?.bezelColor = on ? .glow : nil
        previewFullButton?.contentTintColor = on ? .black : .labelColor
        renderPreview()
    }

    @objc private func processClicked() {
        guard let size = selectedSize else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Select a paper size first."
            return
        }
        guard !files.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Add photos first."
            return
        }
        if exportJob?.isRunning == true {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Export already running."
            return
        }

        let export = readExportUI()
        guard export.exportJPG || export.exportWebP else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Choose JPG and/or WebP."
            return
        }

        var formats: [ExportFormat] = []
        if export.exportJPG { formats.append(.jpg) }
        if export.exportWebP { formats.append(.webp) }
        applyAllCollisionPolicy = nil

        let root = exportRoot ?? (workingFolder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return }

        // Snapshot everything the parallel render needs off the main thread.
        let project = makeProjectModel()
        let layer2Image = compositor.layer2Image
        let layer2Box = effectivePSDTextBox()
        let layer2Align = layerSettings.psdText.align
        let scanMode = settings.scanMode
        let cache = imageCache
        let fileURLs = files

        let job = ExportJob(
            files: fileURLs,
            formats: formats,
            exportRoot: root,
            settings: export,
            paperPixelSize: canvas,
            sizeLabel: size.label,
            cwebpPath: settings.cwebpPath,
            cpuLimit: settings.cpuLimit,
            render: { index, canvasSize in
                guard fileURLs.indices.contains(index) else { return nil }
                guard let original = cache.loadOriginal(url: fileURLs[index]) else { return nil }
                let c = Compositor()
                c.layer2Image = layer2Image
                c.layer2Box = layer2Box
                c.layer2Align = layer2Align
                c.scanMode = scanMode
                return c.render(project: project, imageIndex: index, canvasPixelSize: canvasSize,
                                photoSource: { _ in original })
            },
            noExport: noExport
        )

        // Resolve every collision before any work starts.
        var resolutions: [URL: CollisionPolicy] = [:]
        for item in job.plan() {
            if item.jpgExists, let u = item.jpgURL {
                resolutions[u] = resolveCollision(for: u)
            }
            if item.webpExists, let u = item.webpURL {
                resolutions[u] = resolveCollision(for: u)
            }
        }

        exportJob = job
        processButton?.isEnabled = false
        cancelButton?.isHidden = false
        cancelButton?.isEnabled = true
        job.onProgress = { [weak self] progress in
            self?.updateExportProgress(progress)
        }
        job.run(resolutions: resolutions) { [weak self] summary in
            self?.finishExport(summary)
        }
    }

    @objc private func cancelExportClicked() {
        guard exportJob?.isRunning == true else { return }
        exportJob?.cancel()
        cancelButton?.isEnabled = false
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = "Cancelling…"
    }

    /// Ask the user how to handle an existing output file. The NSAlert carries a
    /// suppression checkbox so "apply to all" reuses the chosen policy.
    private func resolveCollision(for url: URL) -> CollisionPolicy {
        if let applied = applyAllCollisionPolicy {
            return applied
        }
        let alert = NSAlert()
        alert.messageText = "File already exists"
        alert.informativeText = "“\(url.lastPathComponent)” already exists in \(url.deletingLastPathComponent().lastPathComponent)/. What should the export do?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Keep both")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        let response = alert.runModal()
        let policy: CollisionPolicy
        switch response {
        case .alertFirstButtonReturn: policy = .replace
        case .alertSecondButtonReturn: policy = .skip
        case .alertThirdButtonReturn: policy = .keepBoth
        default: policy = .skip
        }
        if alert.suppressionButton?.state == .on {
            applyAllCollisionPolicy = policy
        }
        return applyAllCollisionPolicy ?? policy
    }

    private func updateExportProgress(_ progress: ExportProgress) {
        statusLabel.textColor = .dimText
        var parts: [String] = []
        if progress.jpgTotal > 0 {
            parts.append("JPG – \(progress.jpgDone)/\(progress.jpgTotal)")
        }
        if progress.webpTotal > 0 {
            parts.append("WebP – \(progress.webpDone)/\(progress.webpTotal)")
        }
        statusLabel.stringValue = parts.isEmpty ? "Exporting…" : parts.joined(separator: " · ")
    }

    private func finishExport(_ summary: ExportSummary) {
        exportJob = nil
        processButton?.isEnabled = true
        cancelButton?.isHidden = true
        cancelButton?.isEnabled = true

        if summary.cancelled {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Cancelled \(summary.totalWritten)/\(summary.total)"
            return
        }

        var parts: [String] = []
        let skippedSuffix = summary.skipped > 0 ? " · \(summary.skipped) skipped" : ""
        if summary.jpgWritten > 0 || settings.export.exportJPG {
            parts.append("JPG – \(summary.jpgWritten) files\(skippedSuffix)")
        }
        if summary.webpWritten > 0 || settings.export.exportWebP {
            parts.append("WebP – \(summary.webpWritten) files\(skippedSuffix)")
        }
        if summary.failed > 0 {
            statusLabel.textColor = .systemRed
            parts.append("\(summary.failed) failed")
        } else {
            statusLabel.textColor = .dimText
        }
        statusLabel.stringValue = parts.isEmpty ? "Nothing exported" : parts.joined(separator: " / ")
    }

    // MARK: - Render / Quick Look

    @objc private func renderClicked() {
        guard let url = currentFileURL(), selectedSize != nil else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Select a paper size and a photo first."
            return
        }
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return }

        statusLabel.textColor = .dimText
        statusLabel.stringValue = "Rendering…"

        let project = makeProjectModel()
        let layer2Image = compositor.layer2Image
        let layer2Box = effectivePSDTextBox()
        let layer2Align = layerSettings.psdText.align
        let scanMode = settings.scanMode
        let cache = imageCache
        let index = currentIndex

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let original = cache.loadOriginal(url: url)
            let c = Compositor()
            c.layer2Image = layer2Image
            c.layer2Box = layer2Box
            c.layer2Align = layer2Align
            c.scanMode = scanMode
            guard let image = c.render(project: project, imageIndex: index, canvasPixelSize: canvas,
                                       photoSource: { _ in original }) else {
                DispatchQueue.main.async {
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Render failed."
                }
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pp-render-\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return }
            DispatchQueue.main.async {
                self.statusLabel.textColor = .dimText
                self.statusLabel.stringValue = "Quick Look — press Space to close."
                self.presentQuickLook(tmp)
            }
        }
    }

    private func presentQuickLook(_ url: URL) {
        deleteQuickLookTemp()
        quickLookURL = url
        installSpaceCloseMonitor()
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    private func deleteQuickLookTemp() {
        if let url = quickLookURL {
            try? FileManager.default.removeItem(at: url)
            quickLookURL = nil
        }
    }

    private func installSpaceCloseMonitor() {
        if spaceCloseMonitor == nil {
            spaceCloseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self,
                      event.keyCode == 49,
                      let panel = QLPreviewPanel.shared(), panel.isVisible else { return event }
                panel.orderOut(nil)
                self.deleteQuickLookTemp()
                return nil
            }
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
        if let old = selectedSize, old != size, !files.isEmpty {
            scaleEdits(from: old, to: size)
        }
        selectedSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.lastSizeKey)
        syncSizeButtons()
        applyOrientationToCanvas()
        updateStatus()
        scheduleRenderPreview()
        scheduleAutosave()
    }

    /// When switching paper size, carry over an image's existing edit from the
    /// old size to the new size (proportionally) only when the new size has no
    /// stored edit for that image yet — no reset to Fit.
    private func scaleEdits(from old: PaperSize, to new: PaperSize) {
        let oldCanvas = canvasPixelSize(for: old, orientation: orientation)
        let newCanvas = canvasPixelSize(for: new, orientation: orientation)
        guard oldCanvas.width > 0, newCanvas.width > 0 else { return }
        for url in files {
            let name = url.lastPathComponent
            guard edits.edit(sizeKey: new.rawValue, fileName: name) == nil,
                  let existing = edits.edit(sizeKey: old.rawValue, fileName: name) else { continue }
            edits.setEdit(existing.scaled(fromCanvas: oldCanvas, toCanvas: newCanvas),
                          sizeKey: new.rawValue, fileName: name)
        }
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
        // Route dropped .psd files to a PSD layer (2 if its section is focused,
        // otherwise 3; ask when ambiguous) instead of treating them as photos.
        let psdURLs = urls.filter { $0.pathExtension.lowercased() == "psd" }
        let photoURLs = urls.filter { $0.pathExtension.lowercased() != "psd" }
        for psd in psdURLs {
            routeDroppedPSD(psd)
        }
        guard selectedSize != nil else { return }
        let collected = PhotoImport.naturalSorted(PhotoImport.collectFiles(from: photoURLs))
        guard !collected.isEmpty else { return }

        let folder = collected[0].deletingLastPathComponent()
        workingFolder = folder
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)

        // Load first: loadRecovering creates the .bak only when the JSON is
        // corrupt, so the recovery flag must be read after the load attempt.
        let recovered = ProjectModel.loadRecovering(from: folder.path)
        let corrupt = ProjectModel.hasRecoveryBackup(in: folder.path)
        if let existing = recovered, existing.workingFolder == folder.path {
            edits = existing.edits
            layerSettings = existing.layerSettings
            psdTextList = existing.psdTextList
            overlayCounter = existing.overlayCounter
            overlayPSDPath = existing.overlayPSDPath
            psdTextCounter = existing.psdTextCounter
            noExport = existing.noExport
        } else {
            edits = EditStore()
            layerSettings = .defaults
            psdTextList = [:]
            overlayCounter = -1
            overlayPSDPath = ""
            psdTextCounter = -1
            noExport = []
        }

        files = collected
        currentIndex = 0
        undoHistory.clear()
        lastEdit = nil
        gestureBaseline = nil

        imageCache.prime(files: files)

        applyAutoOrientation(firstPhotoURL: collected[0])
        restoreOverlayPSD(overlayPSDPath)
        applyLayerSettingsToUI()
        showCurrentImage()
        updateStatus()
        if corrupt {
            showRecoveryMessage()
        }
        scheduleAutosave()
    }

    // MARK: - Drag & drop (panel + chrome, outside the canvas)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedFileURLs(sender).isEmpty else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return false }
        importFiles(urls)
        return true
    }

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
            return []
        }
        return objects.map { $0 as URL }
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
        lastEdit = nil
        gestureBaseline = nil
        // Undo history is per image and cleared when switching (SPEC §2).
        undoHistory.clear()
        canvasView.cancelPendingCommits()
        imageCache.prefetch(urls: files, around: currentIndex)
        showCurrentImage()
        scheduleAutosave()
    }

    private func nextFile() { goTo(index: currentIndex + 1) }
    private func previousFile() { goTo(index: currentIndex - 1) }

    private func showCurrentImage() {
        guard let url = currentFileURL() else {
            photoPreview = nil
            canvasView.compositedImage = nil
            canvasView.noExport = false
            updateStatus()
            return
        }
        canvasView.edit = currentEdit()
        updateWatermarkPlaceholder()
        updateLayerSelectionState()
        canvasView.psdTextBox = effectivePSDTextBox()
        canvasView.psdTextAlign = layerSettings.psdText.align
        psdManualTextField?.stringValue = edits.manualText(sizeKey: currentSizeKey(), fileName: url.lastPathComponent) ?? ""
        scheduleLayer2Render()
        preloadLayerImages()
        loadPreview(for: url)
        syncNoExportUI()
    }

    private func updateWatermarkPlaceholder() {
        let derived = WatermarkTextProvider.current(currentFileName())
        watermarkText?.placeholderString = derived.isEmpty ? "Right part of \"name - number\"" : derived
    }

    private func loadPreview(for url: URL) {
        decodeGeneration += 1
        let gen = decodeGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let image = self.imageCache.preview(url: url)
            DispatchQueue.main.async {
                guard gen == self.decodeGeneration else { return }
                self.photoPreview = image
                self.renderPreview()
            }
        }
    }

    // MARK: - Preview rendering

    private func canvasPixelSize() -> CGSize {
        guard let size = selectedSize else { return .zero }
        return canvasPixelSize(for: size, orientation: orientation)
    }

    private func canvasPixelSize(for size: PaperSize, orientation: CanvasOrientation) -> CGSize {
        if orientation == .portrait {
            return CGSize(width: size.pixelWidth, height: size.pixelHeight)
        }
        return CGSize(width: size.pixelHeight, height: size.pixelWidth)
    }

    private func previewPixelSize() -> CGSize {
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let cap: CGFloat = 1000
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
        if previewFull {
            renderFullPreview()
            return
        }
        let preview = previewPixelSize()
        let project = makeProjectModel()
        compositor.layer2Box = effectivePSDTextBox()
        compositor.layer2Align = layerSettings.psdText.align
        compositor.scanMode = settings.scanMode
        let key = StaticPreviewKey(
            sizeKey: currentSizeKey(),
            orientation: orientation,
            index: currentIndex,
            layers: layerSettings,
            scanMode: settings.scanMode,
            psdTextList: psdTextList,
            layer2Box: effectivePSDTextBox(),
            layer2Image: compositor.layer2Image.map { ObjectIdentifier($0) }
        )
        if staticPreviewKey != key {
            staticPreviewKey = key
            interactiveRenderer.prepare(project: project, imageIndex: currentIndex, canvasPixelSize: preview)
        }
        let image = interactiveRenderer.renderFrame(edit: currentEdit(), photo: photoPreview!)
        canvasView.compositedImage = image
        canvasView.compositePixelSize = preview
        updateLayerSelectionState()
    }

    /// Full-resolution preview: render at canvas pixel size from the ORIGINAL
    /// (never the cached preview). Used only by the "Preview full" toggle; any
    /// edit gesture turns it off and returns to the fast low-res path.
    private func renderFullPreview() {
        guard let url = currentFileURL() else { return }
        let canvas = canvasPixelSize()
        guard canvas.width > 0, canvas.height > 0 else { return }
        fullRenderGeneration += 1
        let gen = fullRenderGeneration
        let project = makeProjectModel()
        let layer2Image = compositor.layer2Image
        let layer2Box = effectivePSDTextBox()
        let layer2Align = layerSettings.psdText.align
        let scanMode = settings.scanMode
        let cache = imageCache
        let index = currentIndex

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let original = cache.loadOriginal(url: url) else { return }
            let c = Compositor()
            c.layer2Image = layer2Image
            c.layer2Box = layer2Box
            c.layer2Align = layer2Align
            c.scanMode = scanMode
            guard let image = c.render(project: project, imageIndex: index, canvasPixelSize: canvas,
                                       photoSource: { _ in original }) else { return }
            DispatchQueue.main.async {
                guard gen == self.fullRenderGeneration, self.previewFull, index == self.currentIndex else { return }
                self.canvasView.compositedImage = image
                self.canvasView.compositePixelSize = canvas
                self.updateLayerSelectionState()
            }
        }
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
        return DecodedImageCache.shared.cached(layerSettings.overlay.path)
    }

    /// Decode the overlay/background images off the main thread into the shared
    /// path+mtime cache so preview renders never re-decode them on main.
    private func preloadLayerImages() {
        for path in layerImagePaths() {
            DecodedImageCache.shared.load(path) { [weak self] _ in
                self?.scheduleRenderPreview()
            }
        }
    }

    private func layerImagePaths() -> [String] {
        var paths: [String] = []
        if !layerSettings.overlay.path.isEmpty { paths.append(layerSettings.overlay.path) }
        if !layerSettings.bg5.path.isEmpty { paths.append(layerSettings.bg5.path) }
        if case .image(let p) = layerSettings.bg6, !p.isEmpty { paths.append(p) }
        return paths
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
        // Any edit gesture returns from full preview to the fast low-res mode.
        if previewFull { setPreviewFull(false) }
        guard let key = currentKey() else { return }
        gestureBaseline = lastEdit ?? edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
    }

    private func handleEdit(_ newEdit: ImageEdit, commit: Bool, scope: GlobalEditScope) {
        guard let key = currentKey() else { return }
        let fileName = key.fileName
        let old = lastEdit ?? edits.edit(sizeKey: key.sizeKey, fileName: fileName) ?? .identity
        edits.setEdit(newEdit, sizeKey: key.sizeKey, fileName: fileName)
        lastEdit = newEdit

        if commit {
            // Global (Cmd+Shift/Shift) edits push ONE undo step on the current
            // image only; the other images are overwritten without their own step.
            pushUndo(fileName: fileName, value: gestureBaseline ?? old)
            if scope != .none {
                let names = files.map { $0.lastPathComponent }
                edits.applyGlobalEdit(newEdit, scope: scope, sizeKey: key.sizeKey,
                                      files: names, currentIndex: currentIndex)
            }
            gestureBaseline = nil
        }
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func pushUndo(fileName: String, value: ImageEdit) {
        undoHistory.push(fileName: fileName, value: value)
    }

    private func undo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let previous = undoHistory.undo(fileName: key.fileName, current: current) else { return }
        edits.setEdit(previous, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = previous
        canvasView.edit = previous
        scheduleRenderPreview()
        scheduleAutosave()
    }

    private func redo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let next = undoHistory.redo(fileName: key.fileName, current: current) else { return }
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
        compositor.scanMode = settings.scanMode
        imageCache.setRAMCap(bytes: settings.cacheRAMCapMB * 1024 * 1024)
        refreshRotationField()
        reloadScanModes()
        syncExportUI()
        scheduleLayer2Render()
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
        let flagged = noExport.contains(name) ? "  (NO EXPORT)" : ""
        statusLabel.stringValue = "\(currentIndex + 1) / \(files.count)  \(name)\(flagged)"
    }

    // MARK: - Project persistence

    private func makeProjectModel() -> ProjectModel {
        ProjectModel(
            workingFolder: workingFolder?.path ?? "",
            files: files.map { $0.lastPathComponent },
            currentIndex: currentIndex,
            selectedSize: selectedSize,
            edits: edits,
            layerSettings: layerSettings,
            psdTextList: psdTextList,
            overlayCounter: overlayCounter,
            overlayPSDPath: overlayPSDPath,
            psdTextCounter: psdTextCounter,
            noExport: noExport
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
        let seconds = max(1, settings.autosaveSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(seconds * 1000), execute: item)
    }

    @objc private func appWillResign() {
        autosaveWorkItem?.cancel()
        autosave()
    }

    @objc private func appWillTerminate() {
        autosaveWorkItem?.cancel()
        autosave()
    }

    /// Decode the ORIGINAL file at full quality off the main thread. Export must
    /// use this (never a cached preview).
    private func loadOriginal(_ url: URL, completion: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [imageCache] in
            let image = imageCache.loadOriginal(url: url)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func restoreLastProject() {
        guard let folderPath = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        let folder = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }

        let model = ProjectModel.loadRecovering(from: folderPath)
        let corrupt = ProjectModel.hasRecoveryBackup(in: folderPath)

        if let model = model {
            var urls: [URL] = []
            for name in model.files {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            }
            if !urls.isEmpty {
                workingFolder = folder
                files = urls
                currentIndex = min(max(0, model.currentIndex), files.count - 1)
                edits = model.edits
                layerSettings = model.layerSettings
                psdTextList = model.psdTextList
                overlayCounter = model.overlayCounter
                overlayPSDPath = model.overlayPSDPath
                psdTextCounter = model.psdTextCounter
                noExport = model.noExport
                selectedSize = model.selectedSize
                syncSizeButtons()
                applyOrientationToCanvas()
                imageCache.prime(files: files)
                applyAutoOrientation(firstPhotoURL: urls[0])
                restoreOverlayPSD(overlayPSDPath)
                applyLayerSettingsToUI()
                showCurrentImage()
                updateStatus()
                return
            }
        }

        // Missing model, corrupt JSON, or files that no longer exist: start fresh
        // from the folder's photos.
        let scanned = PhotoImport.naturalSorted(PhotoImport.collectFiles(from: [folder]))
        guard !scanned.isEmpty else {
            if corrupt { showRecoveryMessage() }
            return
        }
        workingFolder = folder
        files = scanned
        currentIndex = 0
        edits = EditStore()
        layerSettings = .defaults
        psdTextList = [:]
        overlayCounter = -1
        overlayPSDPath = ""
        psdTextCounter = -1
        noExport = []
        selectedSize = nil
        syncSizeButtons()
        applyOrientationToCanvas()
        imageCache.prime(files: files)
        applyAutoOrientation(firstPhotoURL: scanned[0])
        applyLayerSettingsToUI()
        showCurrentImage()
        updateStatus()
        if corrupt { showRecoveryMessage() }
    }

    private func syncSizeButtons() {
        for (key, button) in sizeButtons {
            let selected = (key == selectedSize)
            button.state = selected ? .on : .off
            button.bezelColor = selected ? .glow : nil
            button.contentTintColor = selected ? .black : .labelColor
        }
    }

    private func showRecoveryMessage() {
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = "Project file was corrupt — started fresh (backup saved as .bak)."
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

// MARK: - Quick Look

extension ProductionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        deleteQuickLookTemp()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        window?.frame ?? .zero
    }
}
