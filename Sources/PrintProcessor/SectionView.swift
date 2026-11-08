import AppKit
import PrintProcessorCore

/// A collapsible options section with an eye (on/off) toggle and a disclosure triangle.
final class SectionView: NSView {
    let sectionTitle: String

    private(set) var isVisible = true
    private(set) var isExpanded = true

    /// Called after the eye toggle changes, with the new visibility state.
    var onEyeToggle: ((Bool) -> Void)?

    private let headerView = NSView()
    private let disclosureButton = NSButton()
    private let eyeButton = NSButton()
    private let titleLabel: NSTextField
    private let bodyView: NSView
    private let innerStack = NSStackView()

    /// - Parameters:
    ///   - title: Section header text.
    ///   - bodyText: Placeholder description shown in the collapsed body.
    init(title: String, bodyText: String) {
        self.sectionTitle = title
        self.titleLabel = makeLabel(title, size: 13, weight: .semibold, color: .labelColor)
        self.bodyView = SectionView.makeBody(bodyText)
        super.init(frame: .zero)
        build()
    }

    /// - Parameters:
    ///   - title: Section header text.
    ///   - body: Custom content view for the section body.
    init(title: String, body: NSView) {
        self.sectionTitle = title
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

        // Header row: disclosure + eye + title.
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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(disclosureButton)
        headerView.addSubview(eyeButton)
        headerView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            headerView.heightAnchor.constraint(equalToConstant: 30),
            disclosureButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),
            disclosureButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 20),
            eyeButton.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
            eyeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),
            eyeButton.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -8),
        ])

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

    @objc private func toggleExpanded() {
        isExpanded = (disclosureButton.state == .on)
        bodyView.isHidden = !isExpanded
    }

    @objc private func toggleVisibility() {
        isVisible.toggle()
        updateEyeIcon()
        onEyeToggle?(isVisible)
    }

    /// Programmatically set the eye state without firing `onEyeToggle`.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        updateEyeIcon()
    }

    /// Whether the window's first responder is this section or one of its controls.
    func containsFirstResponder() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}
