import Foundation

/// Edits keyed first by paper-size key, then by image file name, so that each
/// paper size keeps its own independent set of adjustments for the same photos.
///
/// Layer 1 (watermark) and layer 3 (overlay) are global with an optional
/// per-image override stored here alongside the layer-4 `ImageEdit`.
public struct EditStore: Equatable {
    public typealias SizeKey = String
    public typealias FileName = String

    private var storage: [SizeKey: [FileName: ImageEdit]] = [:]
    private var watermarkStorage: [SizeKey: [FileName: WatermarkTransform]] = [:]
    private var overlayStorage: [SizeKey: [FileName: OverlayTransform]] = [:]

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

    /// Per-image watermark-transform override, or nil when unset (use global).
    public func watermarkOverride(sizeKey: SizeKey, fileName: FileName) -> WatermarkTransform? {
        watermarkStorage[sizeKey]?[fileName]
    }

    public mutating func setWatermarkOverride(_ transform: WatermarkTransform, sizeKey: SizeKey, fileName: FileName) {
        watermarkStorage[sizeKey, default: [:]][fileName] = transform
    }

    /// Per-image overlay-transform override, or nil when unset (use global).
    public func overlayOverride(sizeKey: SizeKey, fileName: FileName) -> OverlayTransform? {
        overlayStorage[sizeKey]?[fileName]
    }

    public mutating func setOverlayOverride(_ transform: OverlayTransform, sizeKey: SizeKey, fileName: FileName) {
        overlayStorage[sizeKey, default: [:]][fileName] = transform
    }

    /// All size keys that currently hold at least one edit.
    public func sizeKeys() -> [SizeKey] {
        var keys = Set(storage.keys)
        keys.formUnion(watermarkStorage.keys)
        keys.formUnion(overlayStorage.keys)
        return Array(keys)
    }

    /// File names that have an edit under a given size key.
    public func fileNames(for sizeKey: SizeKey) -> [FileName] {
        guard let dict = storage[sizeKey] else { return [] }
        return Array(dict.keys)
    }
}

// MARK: - Codable (backward-compatible with projects that only stored layer-4 edits)

extension EditStore: Codable {
    private enum CodingKeys: String, CodingKey {
        case storage
        case watermarkStorage
        case overlayStorage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storage = try c.decodeIfPresent([SizeKey: [FileName: ImageEdit]].self, forKey: .storage) ?? [:]
        watermarkStorage = try c.decodeIfPresent([SizeKey: [FileName: WatermarkTransform]].self, forKey: .watermarkStorage) ?? [:]
        overlayStorage = try c.decodeIfPresent([SizeKey: [FileName: OverlayTransform]].self, forKey: .overlayStorage) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(storage, forKey: .storage)
        try c.encode(watermarkStorage, forKey: .watermarkStorage)
        try c.encode(overlayStorage, forKey: .overlayStorage)
    }
}
