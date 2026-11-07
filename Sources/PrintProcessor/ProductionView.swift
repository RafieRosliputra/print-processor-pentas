import AppKit
import PrintProcessorCore

/// Production tab: canvas on the left, scrollable options panel on the right,
/// and a top-right bar with paper-size buttons + Process.
final class ProductionView: NSView {
    private var sizeButtons: [PaperSize: NSButton] = [:]
    private let statusLabel: NSTextField
    private var selectedSize: PaperSize?

    private let canvasView = CanvasPlaceholderView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        self.statusLabel = makeLabel("Select a paper size to begin.", size: 12, weight: .regular, color: .dimText)
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

        let sections: [(String, String)] = [
            ("Watermark", "Watermark text — font, size, colour, opacity. Default: white 60%, SF Pro Bold."),
            ("PSD Text", "Styled text loaded from a PSD text layer. Placeholder."),
            ("Overlay", "Custom PNG / WebP / PSD overlay with transparency. Placeholder."),
            ("Gradient", "Two-stop gradient over the photo layer (angle, opacity, blend mode). Placeholder."),
            ("Photo", "Subject photo — import, zoom, pan, rotate. Placeholder."),
            ("Background", "Transparent background image layer. Placeholder."),
            ("Final Background", "Solid colour or image behind everything. Placeholder."),
        ]

        for (title, body) in sections {
            let section = SectionView(title: title, bodyText: body)
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

        // Pin the document view to the clip view so it scrolls vertically and fills the width.
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        return scroll
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
        statusLabel.stringValue = "Processing \(size.label) (\(size.pixelWidth)×\(size.pixelHeight) px)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.statusLabel.textColor = .systemGreen
            self?.statusLabel.stringValue = "Done — \(size.label) processed (placeholder)."
        }
    }

    private func selectSize(_ size: PaperSize) {
        selectedSize = size
        for (key, button) in sizeButtons {
            let selected = (key == size)
            button.state = selected ? .on : .off
            button.bezelColor = selected ? .glow : nil
            button.contentTintColor = selected ? .black : .labelColor
        }
        statusLabel.textColor = .dimText
        statusLabel.stringValue = "\(size.label) — \(size.pixelWidth)×\(size.pixelHeight) px @ 300 dpi."
        canvasView.sizeLabelText = "\(size.label) · \(size.pixelWidth) × \(size.pixelHeight) px"
    }
}

/// Dark canvas placeholder with an orange glow border around the working area.
final class CanvasPlaceholderView: NSView {
    private let centerLabel = makeLabel("Canvas", size: 16, weight: .medium, color: .dimText)

    var sizeLabelText: String? {
        didSet { updateCenterText() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.canvas.cgColor
        layer?.borderColor = NSColor.glow.cgColor
        layer?.borderWidth = 2

        centerLabel.translatesAutoresizingMaskIntoConstraints = false
        centerLabel.alignment = .center
        centerLabel.textColor = .dimText
        addSubview(centerLabel)
        NSLayoutConstraint.activate([
            centerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateCenterText()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateCenterText() {
        let size = sizeLabelText ?? "No size selected"
        centerLabel.stringValue = "Canvas — drag a subject photo here\n\(size)"
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
        layer?.shadowColor = NSColor.glow.cgColor
        layer?.shadowOpacity = 0.9
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero
    }

    override func mouseExited(with event: NSEvent) {
        layer?.shadowOpacity = 0
    }
}
