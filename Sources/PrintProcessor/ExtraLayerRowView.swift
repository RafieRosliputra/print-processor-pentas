import AppKit
import PrintProcessorCore

/// One row in the "Gradient" section's extra-layer list: eye toggle, name,
/// opacity, blend, clip-to-photo, reorder, delete, replace file, and (for PSD
/// layers) Open in Photoshop. All callbacks are closures owned by the
/// controller, which maps them back onto `layerSettings.extraLayers`.
final class ExtraLayerRowView: NSView {
    let layerID: UUID

    var onToggleEnabled: ((Bool) -> Void)?
    var onOpacityChanged: ((Double) -> Void)?
    var onBlendChanged: ((ExtraLayerBlend) -> Void)?
    var onClipChanged: ((Bool) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReplaceFile: (() -> Void)?
    var onOpenInPhotoshop: (() -> Void)?
    var onSelect: (() -> Void)?

    private let eyeButton = NSButton()
    private let nameButton = NSButton()
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValue = makeLabel("100%", size: 11, weight: .regular, color: .dimText)
    private let blendPopup = NSPopUpButton()
    private let clipCheckbox = NSButton(checkboxWithTitle: "Clip to photo", target: nil, action: nil)
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let deleteButton = NSButton()
    private let replaceButton = NSButton()
    private let photoshopButton = NSButton()

    private var isEnabled = true

    init(layerID: UUID) {
        self.layerID = layerID
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Fill the row from a layer and the current reorder capabilities.
    func configure(with layer: ExtraLayer, canMoveUp: Bool, canMoveDown: Bool, isSelected: Bool) {
        isEnabled = layer.enabled
        updateEyeIcon(enabled: layer.enabled)
        nameButton.title = layer.name.isEmpty ? URL(fileURLWithPath: layer.path).lastPathComponent : layer.name
        opacitySlider.doubleValue = layer.opacity
        opacityValue.stringValue = Self.percent(layer.opacity)
        if let idx = ExtraLayerBlend.allCases.firstIndex(of: layer.blend) {
            blendPopup.selectItem(at: idx)
        }
        clipCheckbox.state = layer.clipToPhoto ? .on : .off
        moveUpButton.isEnabled = canMoveUp
        moveDownButton.isEnabled = canMoveDown
        photoshopButton.isHidden = !layer.isPSD
        setSelected(isSelected)
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.glow.withAlphaComponent(0.18).cgColor
            : NSColor(hex: "#3A3A3A").cgColor
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: "#3A3A3A").cgColor
        layer?.borderColor = NSColor.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        eyeButton.setButtonType(.momentaryChange)
        eyeButton.isBordered = false
        eyeButton.imagePosition = .imageOnly
        eyeButton.imageScaling = .scaleProportionallyDown
        eyeButton.target = self
        eyeButton.action = #selector(eyeToggled)
        eyeButton.toolTip = "Show/hide this layer"

        nameButton.title = ""
        nameButton.isBordered = false
        nameButton.setButtonType(.momentaryChange)
        nameButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameButton.alignment = .left
        nameButton.lineBreakMode = .byTruncatingMiddle
        nameButton.contentTintColor = .labelColor
        nameButton.target = self
        nameButton.action = #selector(selectClicked)
        nameButton.toolTip = "Select this layer on the canvas"
        nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (button, symbolName, tip, action) in [
            (moveUpButton, "chevron.up", "Move up in the stack", #selector(moveUpClicked)),
            (moveDownButton, "chevron.down", "Move down in the stack", #selector(moveDownClicked)),
            (deleteButton, "trash", "Delete this layer (asks first)", #selector(deleteClicked)),
        ] {
            button.image = symbol(symbolName)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = action
            button.toolTip = tip
        }

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.toolTip = "Opacity — this layer's overall opacity (0–100%)"
        opacitySlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        opacityValue.alignment = .right
        opacityValue.widthAnchor.constraint(equalToConstant: 40).isActive = true

        blendPopup.target = self
        blendPopup.action = #selector(blendChanged)
        blendPopup.toolTip = "Blend — normal/multiply/screen/overlay"
        for blend in ExtraLayerBlend.allCases { blendPopup.addItem(withTitle: blend.displayName) }

        clipCheckbox.target = self
        clipCheckbox.action = #selector(clipToggled)
        clipCheckbox.toolTip = "Clip to photo — draw only inside the photo's transformed rect"

        replaceButton.title = "Replace file…"
        replaceButton.bezelStyle = .rounded
        replaceButton.controlSize = .small
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceButton.toolTip = "Replace file… — choose a new PNG/WebP/JPG/PSD for this layer"

        photoshopButton.title = "Open in Photoshop"
        photoshopButton.bezelStyle = .rounded
        photoshopButton.controlSize = .small
        photoshopButton.target = self
        photoshopButton.action = #selector(openPSDClicked)
        photoshopButton.toolTip = "Open in Photoshop — open this layer's PSD source"

        let header = NSStackView(views: [eyeButton, nameButton, moveUpButton, moveDownButton, deleteButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        eyeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        eyeButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        moveUpButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        moveDownButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let opacityRow = NSStackView(views: [opacitySlider, opacityValue])
        opacityRow.orientation = .horizontal
        opacityRow.alignment = .centerY
        opacityRow.spacing = 6

        let optionsRow = NSStackView(views: [blendPopup, clipCheckbox])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.spacing = 12

        let actionsRow = NSStackView(views: [replaceButton, photoshopButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 8

        let stack = NSStackView(views: [header, opacityRow, optionsRow, actionsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
        ])
    }

    private func updateEyeIcon(enabled: Bool) {
        eyeButton.image = symbol(enabled ? "eye" : "eye.slash")
        nameButton.alphaValue = enabled ? 1.0 : 0.45
    }

    private static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    // MARK: - Actions

    @objc private func eyeToggled() {
        isEnabled.toggle()
        updateEyeIcon(enabled: isEnabled)
        onToggleEnabled?(isEnabled)
    }

    @objc private func opacityChanged() {
        opacityValue.stringValue = Self.percent(opacitySlider.doubleValue)
        onOpacityChanged?(opacitySlider.doubleValue)
    }

    @objc private func blendChanged() {
        let idx = blendPopup.indexOfSelectedItem
        guard ExtraLayerBlend.allCases.indices.contains(idx) else { return }
        onBlendChanged?(ExtraLayerBlend.allCases[idx])
    }

    @objc private func clipToggled() {
        onClipChanged?(clipCheckbox.state == .on)
    }

    @objc private func moveUpClicked() { onMoveUp?() }
    @objc private func moveDownClicked() { onMoveDown?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func replaceClicked() { onReplaceFile?() }
    @objc private func openPSDClicked() { onOpenInPhotoshop?() }
    @objc private func selectClicked() { onSelect?() }
}

/// A drop target for the "Gradient" section: accepts PNG/WebP/JPG/PSD files and
/// forwards their URLs to the controller so they become extra layers.
final class ExtraLayerDropContainer: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        readURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = readURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func readURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
            return []
        }
        return objects.map { $0 as URL }
    }
}
