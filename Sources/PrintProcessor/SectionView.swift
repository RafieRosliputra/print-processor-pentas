import AppKit
import PrintProcessorCore

/// A collapsible options section with an eye (on/off) toggle, a lock toggle and
/// a disclosure triangle.
final class SectionView: NSView {
    let sectionTitle: String

    private(set) var isVisible = true
    private(set) var isExpanded = true
    private(set) var isLocked = false

    /// Called after the eye toggle changes, with the new visibility state.
    var onEyeToggle: ((Bool) -> Void)?
    /// Called after the lock toggle changes, with the new lock state.
    var onLockToggle: ((Bool) -> Void)?

    private let headerView = NSView()
    private let disclosureButton = NSButton()
    private let eyeButton = NSButton()
    private let lockButton = NSButton()
    private let titleLabel: NSTextField
    private let bodyView: NSView
    private let innerStack = NSStackView()

    /// Whether the section shows a lock toggle (false for non-layer sections).
    private let showsLock: Bool

    /// - Parameters:
    ///   - title: Section header text.
    ///   - bodyText: Placeholder description shown in the collapsed body.
    ///   - showsLock: Whether to show the lock toggle (default true).
    init(title: String, bodyText: String, showsLock: Bool = true) {
        self.sectionTitle = title
        self.showsLock = showsLock
        self.titleLabel = makeLabel(title, size: 13, weight: .semibold, color: .labelColor)
        self.bodyView = SectionView.makeBody(bodyText)
        super.init(frame: .zero)
        build()
    }

    /// - Parameters:
    ///   - title: Section header text.
    ///   - body: Custom content view for the section body.
    ///   - showsLock: Whether to show the lock toggle (default true).
    init(title: String, body: NSView, showsLock: Bool = true) {
        self.sectionTitle = title
        self.showsLock = showsLock
        self.titleLabel = makeLabel(title, size: 13, weight: .semibold, color: .labelColor)
        self.bodyView = body
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func makeBody(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = makeWrappingLabel(text, size: 12, weight: .regular, color: .dimText)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            container.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
        ])
        return container
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.panel.cgColor
        layer?.borderColor = NSColor.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        // Header row: disclosure + eye + lock + title.
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.panel.cgColor

        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.state = .on
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpanded)
        disclosureButton.toolTip = "\(sectionTitle) — show or hide this section"
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        eyeButton.setButtonType(.momentaryChange)
        eyeButton.isBordered = false
        eyeButton.imagePosition = .imageOnly
        eyeButton.imageScaling = .scaleProportionallyDown
        eyeButton.target = self
        eyeButton.action = #selector(toggleVisibility)
        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        updateEyeIcon()

        lockButton.setButtonType(.momentaryChange)
        lockButton.isBordered = false
        lockButton.imagePosition = .imageOnly
        lockButton.imageScaling = .scaleProportionallyDown
        lockButton.target = self
        lockButton.action = #selector(toggleLocked)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        updateLockIcon()

        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(disclosureButton)
        headerView.addSubview(eyeButton)
        if showsLock { headerView.addSubview(lockButton) }
        headerView.addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            headerView.heightAnchor.constraint(equalToConstant: 30),
            disclosureButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),
            disclosureButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 20),
            eyeButton.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
            eyeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),
            eyeButton.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -8),
        ]
        if showsLock {
            constraints.append(lockButton.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 4))
            constraints.append(lockButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor))
            constraints.append(lockButton.widthAnchor.constraint(equalToConstant: 22))
            constraints.append(lockButton.heightAnchor.constraint(equalToConstant: 20))
            constraints.append(titleLabel.leadingAnchor.constraint(equalTo: lockButton.trailingAnchor, constant: 4))
        } else {
            constraints.append(titleLabel.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)

        // Body.
        bodyView.translatesAutoresizingMaskIntoConstraints = false

        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 0
        innerStack.distribution = .fill
        innerStack.detachesHiddenViews = true
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        innerStack.addArrangedSubview(headerView)
        innerStack.addArrangedSubview(bodyView)

        addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.topAnchor.constraint(equalTo: topAnchor),
            innerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            innerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            innerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerView.widthAnchor.constraint(equalTo: innerStack.widthAnchor),
            bodyView.widthAnchor.constraint(equalTo: innerStack.widthAnchor),
        ])
    }

    private func updateEyeIcon() {
        eyeButton.image = symbol(isVisible ? "eye" : "eye.slash")
        eyeButton.toolTip = "\(sectionTitle) — \(isVisible ? "visible (click to hide)" : "hidden (click to show)")"
        titleLabel.alphaValue = isVisible ? 1.0 : 0.45
        bodyView.alphaValue = isVisible ? 1.0 : 0.45
    }

    private func updateLockIcon() {
        lockButton.image = symbol(isLocked ? "lock.fill" : "lock.open")
        lockButton.toolTip = isLocked
            ? "\(sectionTitle) — locked (click to unlock)"
            : "\(sectionTitle) — unlocked (click to lock)"
    }

    @objc private func toggleExpanded() {
        isExpanded = (disclosureButton.state == .on)
        bodyView.isHidden = !isExpanded
    }

    @objc private func toggleVisibility() {
        isVisible.toggle()
        updateEyeIcon()
        onEyeToggle?(isVisible)
    }

    @objc private func toggleLocked() {
        isLocked.toggle()
        updateLockIcon()
        onLockToggle?(isLocked)
    }

    /// Programmatically set the eye state without firing `onEyeToggle`.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        updateEyeIcon()
    }

    /// Programmatically set the lock state without firing `onLockToggle`.
    func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        updateLockIcon()
    }

    /// Enable/disable the section body's controls (used by the layer lock).
    func setBodyLocked(_ locked: Bool) {
        setControlsEnabled(!locked, in: bodyView)
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        if let control = view as? NSControl {
            control.isEnabled = enabled
        }
        for subview in view.subviews {
            setControlsEnabled(enabled, in: subview)
        }
    }

    /// Whether the window's first responder is this section or one of its controls.
    func containsFirstResponder() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}
