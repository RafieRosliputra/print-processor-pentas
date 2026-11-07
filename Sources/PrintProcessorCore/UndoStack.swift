import Foundation

/// Bounded undo/redo history for a single value. Pushing a new state clears the
/// redo branch; both branches are capped at `maxCount` entries (oldest dropped).
public struct UndoStack<Element: Equatable>: Equatable {
    public let maxCount: Int

    private(set) var undo: [Element] = []
    private(set) var redo: [Element] = []

    public init(maxCount: Int = 50) {
        self.maxCount = max(1, maxCount)
    }

    public var canUndo: Bool { !undo.isEmpty }
    public var canRedo: Bool { !redo.isEmpty }

    /// Number of currently retained undo steps.
    public var depth: Int { undo.count }

    /// Record a new state, forgetting any redo history.
    public mutating func push(_ element: Element) {
        undo.append(element)
        trimUndo()
        redo.removeAll()
    }

    /// Step back to the previous state. `current` is pushed onto the redo branch.
    @discardableResult
    public mutating func undo(current: Element) -> Element? {
        guard let previous = undo.popLast() else { return nil }
        redo.append(current)
        trimRedo()
        return previous
    }

    /// Step forward to the next state. `current` is pushed onto the undo branch.
    @discardableResult
    public mutating func redo(current: Element) -> Element? {
        guard let next = redo.popLast() else { return nil }
        undo.append(next)
        trimUndo()
        return next
    }

    /// Discard all history (e.g. when switching images).
    public mutating func removeAll() {
        undo.removeAll()
        redo.removeAll()
    }

    private mutating func trimUndo() {
        if undo.count > maxCount {
            undo.removeFirst(undo.count - maxCount)
        }
    }

    private mutating func trimRedo() {
        if redo.count > maxCount {
            redo.removeFirst(redo.count - maxCount)
        }
    }
}
