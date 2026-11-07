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

    private var sizeButtons: [PaperSize: NSButton] = [:]
    private let statusLabel: NSTextField
    private var selectedSize: PaperSize?

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

    private var lastEdit: ImageEdit?
    private var gestureBaseline: ImageEdit?
    private var decodeGeneration = 0
    private var autosaveWorkItem: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?

    private var orientationButton: NSButton?
    private var rotationField: RotationStepField?

    private static let lastSizeKey = "com.johorstudio.printprocessor.lastPaperSize"
    private static let lastFolderKey = "com.johorstudio.printprocessor.lastWorkingFolder"

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

        // Right side: size buttons + Process, with status underneath.
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

        let sections: [SectionView] = [
            SectionView(title: "Watermark", bodyText: "Watermark text — font, size, colour, opacity. Default: white 60%, SF Pro Bold."),
            SectionView(title: "PSD Text", bodyText: "Styled text loaded from a PSD text layer. Placeholder."),
            SectionView(title: "Overlay", bodyText: "Custom PNG / WebP / PSD overlay with transparency. Placeholder."),
            SectionView(title: "Gradient", bodyText: "Two-stop gradient over the photo layer (angle, opacity, blend mode). Placeholder."),
            SectionView(title: "Photo", body: makePhotoSectionBody()),
            SectionView(title: "Background", bodyText: "Transparent background image layer. Placeholder."),
            SectionView(title: "Final Background", bodyText: "Solid colour or image behind everything. Placeholder."),
        ]

        for section in sections {
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

    // MARK: - Actions

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
        canvasView.paperPixelSize = CGSize(width: size.pixelWidth, height: size.pixelHeight)
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

        // Adopt previously saved edits for this folder when present.
        if let existing = try? ProjectModel.load(from: folder.path),
           existing.workingFolder == folder.path {
            edits = existing.edits
        } else {
            edits = EditStore()
        }

        files = collected
        currentIndex = 0
        undoStack.removeAll()
        lastEdit = nil
        gestureBaseline = nil

        applyAutoOrientation(firstPhotoURL: collected[0])
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
            canvasView.image = nil
            return
        }
        canvasView.edit = currentEdit()
        loadImage(for: url)
        updateStatus()
    }

    private func loadImage(for url: URL) {
        decodeGeneration += 1
        let gen = decodeGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PhotoImport.decodePreview(url: url, maxDimension: 2048)
            DispatchQueue.main.async {
                guard let self = self, gen == self.decodeGeneration else { return }
                self.canvasView.image = image
            }
        }
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
        scheduleAutosave()
    }

    private func undo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let previous = undoStack.undo(current: current) else { return }
        edits.setEdit(previous, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = previous
        canvasView.edit = previous
        scheduleAutosave()
    }

    private func redo() {
        guard let key = currentKey() else { return }
        let current = edits.edit(sizeKey: key.sizeKey, fileName: key.fileName) ?? .identity
        guard let next = undoStack.redo(current: current) else { return }
        edits.setEdit(next, sizeKey: key.sizeKey, fileName: key.fileName)
        lastEdit = next
        canvasView.edit = next
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

    /// Reload persisted settings and push them onto the live canvas so Settings
    /// tab changes take effect immediately without a restart.
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
            edits: edits
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
        showCurrentImage()
        updateStatus()
    }
}
