import Foundation

/// Per-image undo/redo history for layer-4 edits. Images are keyed by file name;
/// the whole history is cleared when switching images (SPEC §2: undo is per
/// image and cleared when switching). Extracted so the Check target can verify
/// the clear-on-switch behaviour without AppKit.
public struct ImageUndoHistory: Equatable {
    public let maxCount: Int
    private var stacks: [String: UndoStack<ImageEdit>] = [:]

    public init(maxCount: Int = 50) {
        self.maxCount = max(1, maxCount)
    }

    /// Record the pre-edit value for `fileName`'s undo stack.
    public mutating func push(fileName: String, value: ImageEdit) {
        var stack = stacks[fileName] ?? UndoStack<ImageEdit>(maxCount: maxCount)
        stack.push(value)
        stacks[fileName] = stack
    }

    /// Undo one step for `fileName`, returning the previous value (nil when empty).
    public mutating func undo(fileName: String, current: ImageEdit) -> ImageEdit? {
        var stack = stacks[fileName] ?? UndoStack<ImageEdit>(maxCount: maxCount)
        guard let previous = stack.undo(current: current) else { return nil }
        stacks[fileName] = stack
        return previous
    }

    /// Redo one step for `fileName`, returning the next value (nil when empty).
    public mutating func redo(fileName: String, current: ImageEdit) -> ImageEdit? {
        var stack = stacks[fileName] ?? UndoStack<ImageEdit>(maxCount: maxCount)
        guard let next = stack.redo(current: current) else { return nil }
        stacks[fileName] = stack
        return next
    }

    /// Number of retained undo steps for `fileName`.
    public func depth(fileName: String) -> Int {
        stacks[fileName]?.depth ?? 0
    }

    /// Clear ALL history (called when switching images).
    public mutating func clear() {
        stacks.removeAll()
    }

    /// True when no history is retained for any image.
    public var isEmpty: Bool { stacks.isEmpty }
}
