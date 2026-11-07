import AppKit
import PrintProcessorCore

/// Settings tab: real editable fields for every AppSettings value.
final class SettingsView: NSView {
    private let doubleTapField = SettingsView.makeNumberField()
    private let rotateStepField = SettingsView.makeNumberField()
    private let zoomSpeedField = SettingsView.makeNumberField()
    private let rotateSpeedField = SettingsView.makeNumberField()
    private let nudgePopup = NSPopUpButton()
    private let tooltipDelayField = SettingsView.makeNumberField()
    private let scanModeField = SettingsView.makeTextField()
    private let textLayerNameField = SettingsView.makeTextField()
    private let minTextScaleField = SettingsView.makeNumberField()
    private let photoshopPathField = SettingsView.makeTextField()
    private let cwebpPathField = SettingsView.makeTextField()
    private let cacheRAMField = SettingsView.makeNumberField()
    private let autosaveField = SettingsView.makeNumberField()
    private let exportJPGCheck = NSButton(checkboxWithTitle: "JPG", target: nil, action: nil)
    private let exportWebPCheck = NSButton(checkboxWithTitle: "WebP", target: nil, action: nil)
    private let jpgQualityField = SettingsView.makeNumberField()
    private let jpgSizingPopup = NSPopUpButton()
    private let jpgLongEdgeField = SettingsView.makeNumberField()
    private let webpQualityField = SettingsView.makeNumberField()
    private let webpLongEdgeField = SettingsView.makeNumberField()
    private let filenamePatternField = SettingsView.makeTextField()
    private let cpuLimitField = SettingsView.makeNumberField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func makeNumberField() -> NSTextField {
        let field = NSTextField(string: "")
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .left
        return field
    }

    private static func makeTextField() -> NSTextField {
        let field = NSTextField(string: "")
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        field.alignment = .left
        return field
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor

        let apply = makeButton("Apply", target: self, action: #selector(applyClicked))
        apply.bezelColor = .glow
        apply.contentTintColor = .black
        apply.toolTip = "Apply — save the current values immediately (no restart required)"

        let revert = makeButton("Revert", target: self, action: #selector(revertClicked))
        revert.toolTip = "Revert — discard unapplied edits and reload saved values"

        let defaults = makeButton("Defaults", target: self, action: #selector(defaultsClicked))
        defaults.toolTip = "Defaults — reset all settings to factory defaults"

        let buttons = NSStackView(views: [apply, revert, defaults])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let exportFormats = NSStackView(views: [exportJPGCheck, exportWebPCheck])
        exportFormats.orientation = .horizontal
        exportFormats.spacing = 16
        exportFormats.alignment = .centerY

        jpgSizingPopup.removeAllItems()
        jpgSizingPopup.addItems(withTitles: JPGSizing.allCases.map(\.displayName))

        let rows: [(String, NSView, String)] = [
            ("Double-tap speed (ms)", doubleTapField, "Double-tap Spacebar — previous image. Shortcut: Space Space"),
            ("Rotate step (°)", rotateStepField, "Rotate step — degrees per scroll while holding R. Shortcut: R + scroll"),
            ("Scroll zoom speed", zoomSpeedField, "Scroll zoom speed — zoom sensitivity multiplier. Shortcut: scroll"),
            ("Scroll rotate speed", rotateSpeedField, "Scroll rotate speed — rotation sensitivity multiplier. Shortcut: R + scroll"),
            ("Nudge pixel basis", nudgePopup, "Nudge basis — export or screen pixels. Shortcut: arrows (1 px) / Shift+arrows (10 px)"),
            ("Tooltip delay (s)", tooltipDelayField, "Tooltip delay — seconds before a tooltip appears (0 disables)"),
            ("Filename scan mode", scanModeField, "Scan mode — which side of \" - \" goes to layer 2/1 (e.g. text=right or text=left,watermark=right)"),
            ("PSD text layer name", textLayerNameField, "Text layer name — the layer targeted in Photoshop for layer 2 (default TEXT)"),
            ("Min text scale", minTextScaleField, "Min text scale — smallest the layer-2 text may shrink to (fraction)"),
            ("Photoshop path", photoshopPathField, "Photoshop path — absolute path to Photoshop.app (empty = auto-detect)"),
            ("cwebp path", cwebpPathField, "cwebp path — absolute path to cwebp (empty = auto-detect)"),
            ("Cache RAM cap (MB)", cacheRAMField, "Cache RAM cap — preview LRU cache size in megabytes (default 1536 = 1.5 GB)"),
            ("Autosave interval (s)", autosaveField, "Autosave interval — project JSON autosave frequency in seconds"),
            ("Export formats", exportFormats, "Export formats — which file types the Process button writes"),
            ("JPG quality (0–12)", jpgQualityField, "JPG quality — Photoshop-scale quality (default 10)"),
            ("JPG size", jpgSizingPopup, "JPG size — inch (300 dpi) or long edge in pixels"),
            ("JPG long edge (px)", jpgLongEdgeField, "JPG long edge — pixels when JPG size is “Long edge (px)”"),
            ("WebP quality (%)", webpQualityField, "WebP quality — percentage (default 50)"),
            ("WebP long edge (px)", webpLongEdgeField, "WebP long edge — pixels (0 = full paper size at 300 dpi)"),
            ("Filename pattern", filenamePatternField, "Filename pattern — tokens {name} {size} {number} {index} (default {name})"),
            ("CPU core limit", cpuLimitField, "CPU core limit — export parallelism (0 = all cores)"),
        ]

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10

        for (title, control, tip) in rows {
            let label = makeLabel(title, size: 13, weight: .regular, color: .labelColor)
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true
            control.toolTip = tip
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            form.addArrangedSubview(row)
        }

        nudgePopup.removeAllItems()
        nudgePopup.addItems(withTitles: NudgeBasis.allCases.map(\.displayName))
        nudgePopup.toolTip = "Nudge basis — export or screen pixels. Shortcut: arrows"

        let container = NSStackView(views: [form, buttons])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 24
        container.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    // MARK: - Load / apply / revert

    private func fill(from settings: AppSettings) {
        doubleTapField.stringValue = String(settings.doubleTapMs)
        rotateStepField.stringValue = String(settings.rotateStep)
        zoomSpeedField.stringValue = String(settings.scrollZoomSpeed)
        rotateSpeedField.stringValue = String(settings.scrollRotateSpeed)
        tooltipDelayField.stringValue = String(settings.tooltipDelay)
        scanModeField.stringValue = settings.scanMode
        textLayerNameField.stringValue = settings.psdTextLayerName
        minTextScaleField.stringValue = String(settings.minTextScale)
        photoshopPathField.stringValue = settings.photoshopPath
        cwebpPathField.stringValue = settings.cwebpPath
        cacheRAMField.stringValue = String(settings.cacheRAMCapMB)
        autosaveField.stringValue = String(settings.autosaveSeconds)
        if let idx = NudgeBasis.allCases.firstIndex(of: settings.nudgeBasis) {
            nudgePopup.selectItem(at: idx)
        }
        exportJPGCheck.state = settings.export.exportJPG ? .on : .off
        exportWebPCheck.state = settings.export.exportWebP ? .on : .off
        jpgQualityField.stringValue = String(settings.export.jpgQuality)
        jpgLongEdgeField.stringValue = String(settings.export.jpgLongEdge)
        webpQualityField.stringValue = String(settings.export.webpQuality)
        webpLongEdgeField.stringValue = String(settings.export.webpLongEdge)
        filenamePatternField.stringValue = settings.export.filenamePattern
        cpuLimitField.stringValue = String(settings.cpuLimit)
        if let idx = JPGSizing.allCases.firstIndex(of: settings.export.jpgSizing) {
            jpgSizingPopup.selectItem(at: idx)
        }
    }

    private func readFields() -> AppSettings {
        let current = AppSettings.load()
        let doubleTap = Int(doubleTapField.stringValue) ?? current.doubleTapMs
        let rotateStep = Double(rotateStepField.stringValue) ?? current.rotateStep
        let zoomSpeed = Double(zoomSpeedField.stringValue) ?? current.scrollZoomSpeed
        let rotateSpeed = Double(rotateSpeedField.stringValue) ?? current.scrollRotateSpeed
        let tooltipDelay = Double(tooltipDelayField.stringValue) ?? current.tooltipDelay
        let minTextScale = min(1, max(0.05, Double(minTextScaleField.stringValue) ?? current.minTextScale))
        let scanMode = scanModeField.stringValue.trimmingCharacters(in: .whitespaces)
        let layerName = textLayerNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let basis = NudgeBasis.allCases[safe: nudgePopup.indexOfSelectedItem] ?? current.nudgeBasis
        let cacheRAMCap = Int(cacheRAMField.stringValue) ?? current.cacheRAMCapMB
        let autosaveSeconds = Int(autosaveField.stringValue) ?? current.autosaveSeconds

        var export = current.export
        export.exportJPG = exportJPGCheck.state == .on
        export.exportWebP = exportWebPCheck.state == .on
        if let v = Int(jpgQualityField.stringValue) { export.jpgQuality = min(12, max(0, v)) }
        if let idx = JPGSizing.allCases[safe: jpgSizingPopup.indexOfSelectedItem] { export.jpgSizing = idx }
        if let v = Int(jpgLongEdgeField.stringValue) { export.jpgLongEdge = max(0, v) }
        if let v = Int(webpQualityField.stringValue) { export.webpQuality = min(100, max(0, v)) }
        if let v = Int(webpLongEdgeField.stringValue) { export.webpLongEdge = max(0, v) }
        let pattern = filenamePatternField.stringValue.trimmingCharacters(in: .whitespaces)
        if !pattern.isEmpty { export.filenamePattern = pattern }
        let cpuLimit = max(0, Int(cpuLimitField.stringValue) ?? current.cpuLimit)

        return AppSettings(
            doubleTapMs: doubleTap,
            rotateStep: rotateStep,
            scrollZoomSpeed: zoomSpeed,
            scrollRotateSpeed: rotateSpeed,
            nudgeBasis: basis,
            tooltipDelay: tooltipDelay,
            scanMode: scanMode.isEmpty ? current.scanMode : scanMode,
            savedScanModes: current.savedScanModes,
            psdTextLayerName: layerName.isEmpty ? current.psdTextLayerName : layerName,
            minTextScale: minTextScale,
            photoshopPath: photoshopPathField.stringValue.trimmingCharacters(in: .whitespaces),
            cwebpPath: cwebpPathField.stringValue.trimmingCharacters(in: .whitespaces),
            cacheRAMCapMB: cacheRAMCap,
            autosaveSeconds: autosaveSeconds,
            export: export,
            cpuLimit: cpuLimit
        )
    }

    func reload() {
        fill(from: AppSettings.load())
    }

    @objc private func applyClicked() {
        let settings = readFields()
        settings.save()
        fill(from: settings)
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }

    @objc private func revertClicked() {
        // Discard unapplied edits by reloading the persisted values.
        reload()
    }

    @objc private func defaultsClicked() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "Current values will be replaced by the factory defaults."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppSettings.defaults.save()
            reload()
            NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
