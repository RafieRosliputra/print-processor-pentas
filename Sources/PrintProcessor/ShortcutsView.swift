import AppKit
import PrintProcessorCore

/// Keyboard Shortcuts tab: placeholder listing the default shortcuts.
final class ShortcutsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor

        let title = makeLabel("Keyboard Shortcuts", size: 16, weight: .semibold, color: .labelColor)
        let body = makeWrappingLabel(Self.list, size: 13, weight: .regular, color: .labelColor)
        body.textColor = .labelColor

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let list = """
    Space — next file
    Double-tap Space — previous file (300 ms, adjustable)
    Scroll — zoom
    R + scroll — rotate
    Arrow keys — move 1 px
    Shift + arrows — move 10 px
    Cmd + Shift — global edit (all files)
    Shift — apply to files after the current one
    Cmd + Z — undo
    Cmd + Shift + Z — redo
    Middle-click — open in Photoshop
    """
}
