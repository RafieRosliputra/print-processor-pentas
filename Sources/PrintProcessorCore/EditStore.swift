import Foundation

/// Edits keyed first by paper-size key, then by image file name, so that each
/// paper size keeps its own independent set of adjustments for the same photos.
public struct EditStore: Codable, Equatable {
    public typealias SizeKey = String
    public typealias FileName = String

    private var storage: [SizeKey: [FileName: ImageEdit]] = [:]

    public init() {}

    public init(storage: [SizeKey: [FileName: ImageEdit]]) {
        self.storage = storage
    }

    /// The edit stored for `fileName` under `sizeKey`, or nil when unset.
    public func edit(sizeKey: SizeKey, fileName: FileName) -> ImageEdit? {
        storage[sizeKey]?[fileName]
    }

    /// Store (or overwrite) the edit for a file under a size.
    public mutating func setEdit(_ edit: ImageEdit, sizeKey: SizeKey, fileName: FileName) {
        storage[sizeKey, default: [:]][fileName] = edit
    }

    /// All size keys that currently hold at least one edit.
    public func sizeKeys() -> [SizeKey] {
        Array(storage.keys)
    }

    /// File names that have an edit under a given size key.
    public func fileNames(for sizeKey: SizeKey) -> [FileName] {
        guard let dict = storage[sizeKey] else { return [] }
        return Array(dict.keys)
    }
}
