import AppKit
import PrintProcessorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var tabView: NSTabView!
    private var segmented: NSSegmentedControl!
    private var settingsView: SettingsView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Reclaim temp cache directories left behind by crashed runs.
        ImageCache.removeStaleDiskCaches()
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clear the per-process temp cache on a normal quit.
        ImageCache.removeAllDiskCaches()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PrintProcessor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PrintProcessor",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window

    private func buildWindow() {
        let content = makeContent()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrintProcessor"
        window.minSize = NSSize(width: 1100, height: 700)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Maximised via zoom (fills the screen), NOT fullscreen.
        window.zoom(nil)

        self.window = window
    }

    private func makeContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.panel.cgColor

        let production = ProductionView()
        let shortcuts = ShortcutsView()
        settingsView = SettingsView()

        segmented = NSSegmentedControl(
            labels: ["Production", "Keyboard Shortcuts", "Settings"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged(_:))
        )
        segmented.selectedSegment = 0
        segmented.controlSize = .regular
        segmented.toolTip = "Switch between Production, Keyboard Shortcuts, and Settings"

        tabView = NSTabView()
        tabView.tabViewType = .noTabsNoBorder

        let productionItem = NSTabViewItem()
        productionItem.label = "Production"
        productionItem.view = production
        tabView.addTabViewItem(productionItem)

        let shortcutsItem = NSTabViewItem()
        shortcutsItem.label = "Keyboard Shortcuts"
        shortcutsItem.view = shortcuts
        tabView.addTabViewItem(shortcutsItem)

        let settingsItem = NSTabViewItem()
        settingsItem.label = "Settings"
        settingsItem.view = settingsView
        tabView.addTabViewItem(settingsItem)

        segmented.translatesAutoresizingMaskIntoConstraints = false
        tabView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(segmented)
        root.addSubview(tabView)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            tabView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        return root
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
    }
}
