import Foundation

/// Edits keyed first by paper-size key, then by image file name, so that each
/// paper size keeps its own independent set of adjustments for the same photos.
///
/// Layer 1 (watermark) and layer 3 (overlay) are global with an optional
/// per-image override stored here alongside the layer-4 `ImageEdit`.
public struct EditStore: Equatable {
    public typealias SizeKey = String
    public typealias FileName = String
    /// Stable identifier of an extra layer (its `UUID` description).
    public typealias ExtraLayerID = String

    private var storage: [SizeKey: [FileName: ImageEdit]] = [:]
    private var watermarkStorage: [SizeKey: [FileName: WatermarkTransform]] = [:]
    private var overlayStorage: [SizeKey: [FileName: OverlayTransform]] = [:]
    private var extraLayerStorage: [SizeKey: [ExtraLayerID: [FileName: OverlayTransform]]] = [:]
    private var psdTextStorage: [SizeKey: [FileName: String]] = [:]
    private var psdBoxStorage: [SizeKey: [FileName: PSDTextBox]] = [:]

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

    /// Per-image extra-layer transform override, or nil when unset (use the
    /// layer's global transform).
    public func extraLayerOverride(id: ExtraLayerID, sizeKey: SizeKey, fileName: FileName) -> OverlayTransform? {
        extraLayerStorage[sizeKey]?[id]?[fileName]
    }

    public mutating func setExtraLayerOverride(_ transform: OverlayTransform, id: ExtraLayerID, sizeKey: SizeKey, fileName: FileName) {
        extraLayerStorage[sizeKey, default: [:]][id, default: [:]][fileName] = transform
    }

    /// Per-image manual layer-2 text override, or nil when unset (use list/scan).
    public func manualText(sizeKey: SizeKey, fileName: FileName) -> String? {
        psdTextStorage[sizeKey]?[fileName]
    }

    public mutating func setManualText(_ text: String, sizeKey: SizeKey, fileName: FileName) {
        if text.isEmpty {
            psdTextStorage[sizeKey, default: [:]].removeValue(forKey: fileName)
        } else {
            psdTextStorage[sizeKey, default: [:]][fileName] = text
        }
    }

    /// Per-image layer-2 bounding-box override, or nil when unset (use global).
    public func psdBoxOverride(sizeKey: SizeKey, fileName: FileName) -> PSDTextBox? {
        psdBoxStorage[sizeKey]?[fileName]
    }

    public mutating func setPSDBoxOverride(_ box: PSDTextBox, sizeKey: SizeKey, fileName: FileName) {
        psdBoxStorage[sizeKey, default: [:]][fileName] = box
    }

    /// All size keys that currently hold at least one edit.
    public func sizeKeys() -> [SizeKey] {
        var keys = Set(storage.keys)
        keys.formUnion(watermarkStorage.keys)
        keys.formUnion(overlayStorage.keys)
        keys.formUnion(extraLayerStorage.keys)
        keys.formUnion(psdTextStorage.keys)
        keys.formUnion(psdBoxStorage.keys)
        return Array(keys)
    }

    /// File names that have an edit under a given size key.
    public func fileNames(for sizeKey: SizeKey) -> [FileName] {
        guard let dict = storage[sizeKey] else { return [] }
        return Array(dict.keys)
    }

    /// Apply the same *absolute* edit to a set of files (global edit).
    /// - `.all` overwrites every file in `files` with `edit`.
    /// - `.after` overwrites only the files after `currentIndex`.
    /// - `.none` does nothing (the caller already wrote the current image).
    public mutating func applyGlobalEdit(
        _ edit: ImageEdit,
        scope: GlobalEditScope,
        sizeKey: SizeKey,
        files: [FileName],
        currentIndex: Int
    ) {
        switch scope {
        case .none:
            break
        case .all:
            for f in files {
                storage[sizeKey, default: [:]][f] = edit
            }
        case .after:
            guard files.indices.contains(currentIndex) else { return }
            for f in files.dropFirst(currentIndex + 1) {
                storage[sizeKey, default: [:]][f] = edit
            }
        }
    }
}

// MARK: - Codable (backward-compatible with projects that only stored layer-4 edits)

extension EditStore: Codable {
    private enum CodingKeys: String, CodingKey {
        case storage
        case watermarkStorage
        case overlayStorage
        case extraLayerStorage
        case psdTextStorage
        case psdBoxStorage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storage = try c.decodeIfPresent([SizeKey: [FileName: ImageEdit]].self, forKey: .storage) ?? [:]
        watermarkStorage = try c.decodeIfPresent([SizeKey: [FileName: WatermarkTransform]].self, forKey: .watermarkStorage) ?? [:]
        overlayStorage = try c.decodeIfPresent([SizeKey: [FileName: OverlayTransform]].self, forKey: .overlayStorage) ?? [:]
        extraLayerStorage = try c.decodeIfPresent([SizeKey: [ExtraLayerID: [FileName: OverlayTransform]]].self, forKey: .extraLayerStorage) ?? [:]
        psdTextStorage = try c.decodeIfPresent([SizeKey: [FileName: String]].self, forKey: .psdTextStorage) ?? [:]
        psdBoxStorage = try c.decodeIfPresent([SizeKey: [FileName: PSDTextBox]].self, forKey: .psdBoxStorage) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(storage, forKey: .storage)
        try c.encode(watermarkStorage, forKey: .watermarkStorage)
        try c.encode(overlayStorage, forKey: .overlayStorage)
        try c.encode(extraLayerStorage, forKey: .extraLayerStorage)
        try c.encode(psdTextStorage, forKey: .psdTextStorage)
        try c.encode(psdBoxStorage, forKey: .psdBoxStorage)
    }
}
