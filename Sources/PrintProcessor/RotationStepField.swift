import AppKit

/// Numeric text field for the rotation step (degrees, 0.01…1.5).
/// Scrolling over the field nudges the value by ±0.01; typing and ending
/// editing commits the clamped value. All changes are reported via `onCommit`.
final class RotationStepField: NSTextField, NSTextFieldDelegate {
    static let minValue = 0.01
    static let maxValue = 1.5

    /// Invoked with the clamped value after a scroll nudge or a typed commit.
    var onCommit: ((Double) -> Void)?

    /// Current clamped value.
    var value: Double {
        get { Double(stringValue) ?? Self.minValue }
        set { stringValue = Self.format(Self.clamped(newValue)) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isEditable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        alignment = .right
        delegate = self
        value = 0.1
    }

    private static func clamped(_ v: Double) -> Double {
        min(maxValue, max(minValue, v))
    }

    private static func format(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func commit(_ v: Double) {
        value = Self.clamped(v)
        onCommit?(value)
    }

    override func scrollWheel(with event: NSEvent) {
        let direction: Double = event.scrollingDeltaY > 0 ? 0.01 : (event.scrollingDeltaY < 0 ? -0.01 : 0)
        if direction != 0 {
            commit(value + direction)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit(value)
    }
}
