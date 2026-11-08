import AppKit
import Foundation

/// Stable identifiers for every shortcut in the Keyboard Shortcuts tab.
enum ShortcutID: String, CaseIterable, Codable {
    case next
    case previous
    case zoom
    case rotate
    case nudge
    case nudgeBig
    case globalEdit
    case applyAfter
    case undo
    case redo
    case render
    case process
    case openPhotoshop
    case noExport
    case previewFull
}

/// One shortcut row: identity, description, default binding, and current binding.
struct Shortcut: Codable, Equatable {
    enum Kind: String, Codable {
        case key          // a single key combo (rebindable)
        case keyMouse     // a modifier key held while scrolling / dragging
        case mouse        // a mouse-only gesture (not rebindable)
    }

    let id: String
    let name: String
    let function: String
    let kind: Kind
    let rebindable: Bool
    let defaultKeyCode: UInt16
    let defaultModifiers: UInt
    let defaultDisplay: String
    var keyCode: UInt16
    var modifiers: UInt
    var display: String
}

/// Persisted, live keyboard bindings. The canvas and production view read these
/// on every key event so a rebind takes effect immediately without a restart.
final class ShortcutStore {
    static let shared = ShortcutStore()

    private static let storageKey = "com.johorstudio.printprocessor.shortcuts"

    private(set) var entries: [Shortcut]

    init() {
        entries = Self.defaultEntries()
        load()
    }

    // MARK: - Defaults

    private static func defaultEntries() -> [Shortcut] {
        func key(_ id: String, _ name: String, _ fn: String, code: UInt16, mods: UInt, display: String, rebindable: Bool = true) -> Shortcut {
            Shortcut(id: id, name: name, function: fn, kind: .key, rebindable: rebindable,
                     defaultKeyCode: code, defaultModifiers: mods, defaultDisplay: display,
                     keyCode: code, modifiers: mods, display: display)
        }
        func keyMouse(_ id: String, _ name: String, _ fn: String, code: UInt16, mods: UInt, display: String, rebindable: Bool = false) -> Shortcut {
            Shortcut(id: id, name: name, function: fn, kind: .keyMouse, rebindable: rebindable,
                     defaultKeyCode: code, defaultModifiers: mods, defaultDisplay: display,
                     keyCode: code, modifiers: mods, display: display)
        }
        func mouse(_ id: String, _ name: String, _ fn: String, display: String) -> Shortcut {
            Shortcut(id: id, name: name, function: fn, kind: .mouse, rebindable: false,
                     defaultKeyCode: 0, defaultModifiers: 0, defaultDisplay: display,
                     keyCode: 0, modifiers: 0, display: display)
        }

        let cmd = UInt(NSEvent.ModifierFlags.command.rawValue)
        let shift = UInt(NSEvent.ModifierFlags.shift.rawValue)

        return [
            key("next", "Next photo", "Advance to the next photo", code: 49, mods: 0, display: "Space"),
            key("previous", "Previous photo", "Double-tap of the Next key", code: 49, mods: 0, display: "Space ×2", rebindable: false),
            mouse("zoom", "Zoom", "Scroll wheel / trackpad over the canvas", display: "Scroll"),
            keyMouse("rotate", "Rotate", "Hold this key and scroll to rotate", code: 15, mods: 0, display: "R + Scroll", rebindable: true),
            key("nudge", "Nudge (1 px)", "Up / Down arrow keys move 1 px", code: 0, mods: 0, display: "↑ ↓", rebindable: false),
            key("arrowFiles", "Previous / next file", "Left arrow = previous file (like double-Space), Right arrow = next file (like Space)", code: 0, mods: 0, display: "← →", rebindable: false),
            keyMouse("nudgeBig", "Nudge (10 px)", "Shift + arrow keys move 10 px", code: 0, mods: shift, display: "⇧ + Arrows"),
            keyMouse("globalEdit", "Global edit (all)", "Cmd+Shift while moving applies to every photo", code: 0, mods: cmd | shift, display: "⌘⇧ + drag"),
            keyMouse("applyAfter", "Apply to following", "Shift while moving applies to photos after this one", code: 0, mods: shift, display: "⇧ + drag"),
            key("undo", "Undo", "Undo the last edit", code: 6, mods: cmd, display: "⌘Z"),
            key("redo", "Redo", "Redo the last undone edit", code: 6, mods: cmd | shift, display: "⌘⇧Z"),
            key("render", "Render (Quick Look)", "Render this photo at full size to Quick Look", code: 15, mods: cmd, display: "⌘R"),
            key("process", "Process / Save", "Export every photo as JPG/WebP", code: 35, mods: cmd, display: "⌘P"),
            mouse("openPhotoshop", "Open in Photoshop", "Middle-click a layer element", display: "Middle-click"),
            key("noExport", "NO EXPORT", "Toggle the NO EXPORT flag on the current photo", code: 7, mods: 0, display: "X"),
            key("previewFull", "Preview full", "Toggle a full-resolution preview of the canvas", code: 35, mods: 0, display: "P"),
        ]
    }

    // MARK: - Access

    func entry(_ id: ShortcutID) -> Shortcut? {
        entries.first { $0.id == id.rawValue }
    }

    func entry(id: String) -> Shortcut? {
        entries.first { $0.id == id }
    }

    // MARK: - Live lookup helpers (normalised modifier matching)

    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    /// Whether `event` matches this shortcut's key + modifiers.
    static func matches(_ event: NSEvent, keyCode: UInt16, modifiers: UInt) -> Bool {
        let want = normalizedModifiers(NSEvent.ModifierFlags(rawValue: modifiers))
        let got = normalizedModifiers(event.modifierFlags)
        return event.keyCode == keyCode && got == want
    }

    // MARK: - Mutation

    /// Set a binding and return the display names of any OTHER entries that now
    /// share the same key + modifiers (conflict), for the UI to warn about.
    @discardableResult
    func set(id: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String) -> [String] {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let normMods = UInt(Self.normalizedModifiers(modifiers).rawValue)
        entries[idx].keyCode = keyCode
        entries[idx].modifiers = normMods
        entries[idx].display = display
        save()

        var conflicts: [String] = []
        for entry in entries where entry.id != id {
            if entry.rebindable && entry.keyCode == keyCode && entry.modifiers == normMods {
                conflicts.append(entry.name)
            }
        }
        return conflicts
    }

    /// All rebindable entries that currently conflict (same key + modifiers).
    func conflictPairs() -> [(String, String)] {
        var pairs: [(String, String)] = []
        let rebindable = entries.filter { $0.rebindable }
        for i in 0..<rebindable.count {
            for j in (i + 1)..<rebindable.count {
                let a = rebindable[i], b = rebindable[j]
                if a.keyCode == b.keyCode && a.modifiers == b.modifiers {
                    pairs.append((a.name, b.name))
                }
            }
        }
        return pairs
    }

    func resetToDefaults() {
        entries = Self.defaultEntries()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([Shortcut].self, from: data) else { return }
        for s in saved {
            if let idx = entries.firstIndex(where: { $0.id == s.id }) {
                entries[idx].keyCode = s.keyCode
                entries[idx].modifiers = s.modifiers
                entries[idx].display = s.display
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Display helpers

    /// Human-readable combo for a captured key event.
    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> String {
        var parts: [String] = []
        let mods = normalizedModifiers(modifiers)
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }

        let name = keyName(keyCode: keyCode, characters: characters)
        if !parts.isEmpty || name.isEmpty {
            parts.append(name.isEmpty ? "key \(keyCode)" : name)
        } else {
            parts.append(name)
        }
        return parts.joined(separator: "")
    }

    private static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        default: break
        }
        let raw = characters ?? ""
        if raw.isEmpty { return "" }
        return raw.uppercased()
    }
}
