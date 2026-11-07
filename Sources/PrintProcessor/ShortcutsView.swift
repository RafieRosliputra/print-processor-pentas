import AppKit
import PrintProcessorCore

/// Keyboard Shortcuts tab: lists every action with its key/mouse combo, lets the
/// user click a rebindable combo to record a new one, warns on conflicts, and
/// persists through `ShortcutStore`. Bindings are read live by the canvas.
final class ShortcutsView: NSView {
    private let store = ShortcutStore.shared
    private var recordingID: String?
    private let rowsStack = NSStackView()
    private let conflictLabel = makeWrappingLabel("", size: 12, weight: .regular, color: .systemRed)
    private let hintLabel = makeWrappingLabel("", size: 12, weight: .regular, color: .dimText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor

        let title = makeLabel("Keyboard Shortcuts", size: 16, weight: .semibold, color: .labelColor)
        let subtitle = makeWrappingLabel(
            "Click a shortcut to record a new key combo. Conflicts are flagged in red.",
            size: 12, weight: .regular, color: .dimText)

        let reset = makeButton("Reset to defaults", target: self, action: #selector(resetClicked))
        reset.toolTip = "Reset to defaults — restore every shortcut to its original key/mouse combo"

        hintLabel.stringValue = "Recording… press the new key combo (Esc cancels)."
        hintLabel.textColor = .glow
        hintLabel.isHidden = true

        conflictLabel.isHidden = true

        let header = NSStackView(views: [title, subtitle, reset, hintLabel, conflictLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    // MARK: - Rows

    private func reload() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for entry in store.entries {
            rowsStack.addArrangedSubview(makeRow(entry))
        }
        updateConflicts()
    }

    private func makeRow(_ entry: Shortcut) -> NSView {
        let name = makeLabel(entry.name, size: 13, weight: .semibold, color: .labelColor)
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let function = makeWrappingLabel(entry.function, size: 12, weight: .regular, color: .dimText)
        function.lineBreakMode = .byWordWrapping
        function.maximumNumberOfLines = 3

        let comboControl: NSView
        if entry.rebindable {
            let button = NSButton(title: entry.display, target: self, action: #selector(comboClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(entry.id)
            button.tag = entry.id.hashValue
            button.toolTip = "\(entry.name) — \(entry.function). Click to record a new shortcut."
            comboControl = button
        } else {
            let label = makeLabel(entry.display, size: 12, weight: .regular, color: .labelColor)
            label.alignment = .right
            label.toolTip = "\(entry.name) — \(entry.function)"
            comboControl = label
        }
        comboControl.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let row = NSStackView(views: [name, function, comboControl])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 5, left: 24, bottom: 5, right: 24)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.borderColor = NSColor.border.cgColor
        row.layer?.borderWidth = 0.5

        function.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        return row
    }

    private func comboControl(for id: String) -> NSButton? {
        for row in rowsStack.arrangedSubviews {
            guard let stack = row as? NSStackView else { continue }
            for v in stack.arrangedSubviews {
                if let b = v as? NSButton, b.identifier?.rawValue == id { return b }
            }
        }
        return nil
    }

    // MARK: - Recording

    @objc private func comboClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let entry = store.entry(id: id), entry.rebindable else { return }
        recordingID = id
        hintLabel.isHidden = false
        sender.title = "Press keys…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let id = recordingID, store.entry(id: id) != nil else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc cancels
            recordingID = nil
            hintLabel.isHidden = true
            reload()
            return
        }
        let display = ShortcutStore.displayString(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers)
        _ = store.set(id: id, keyCode: event.keyCode, modifiers: event.modifierFlags, display: display)
        recordingID = nil
        hintLabel.isHidden = true
        reload()
    }

    // MARK: - Conflicts

    private func updateConflicts() {
        let pairs = store.conflictPairs()
        conflictLabel.stringValue = pairs.isEmpty
            ? ""
            : "⚠ Conflict: " + pairs.map { "\($0.0) ↔ \($0.1)" }.joined(separator: "; ")
        conflictLabel.isHidden = pairs.isEmpty

        for pair in pairs {
            for entry in store.entries where entry.name == pair.0 || entry.name == pair.1 {
                comboControl(for: entry.id)?.contentTintColor = .systemRed
            }
        }
    }

    @objc private func resetClicked() {
        recordingID = nil
        hintLabel.isHidden = true
        store.resetToDefaults()
        reload()
    }
}
