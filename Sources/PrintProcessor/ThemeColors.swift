import AppKit
import PrintProcessorCore

extension NSColor {
    /// Create a color from a "#RRGGBB" hex string.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else {
            self.init(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            return
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static var panel: NSColor { NSColor(hex: Theme.panelHex) }
    static var border: NSColor { NSColor(hex: Theme.borderHex) }
    static var canvas: NSColor { NSColor(hex: Theme.canvasHex) }
    static var glow: NSColor { NSColor(hex: Theme.glowHex) }
    static var dimText: NSColor { NSColor(hex: Theme.dimTextHex) }
}

/// A plain text label with the SF Pro system font.
func makeLabel(_ text: String,
               size: CGFloat = 13,
               weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// A wrapping, non-editable label for placeholder bodies.
func makeWrappingLabel(_ text: String,
                       size: CGFloat = 12,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .dimText) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.isEditable = false
    label.isSelectable = false
    return label
}

/// A standard push button.
func makeButton(_ title: String,
                target: AnyObject,
                action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .regular
    return button
}

/// SF Symbol image, falling back to nil when unavailable.
func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}
