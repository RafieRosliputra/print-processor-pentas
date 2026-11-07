import Foundation

/// The persisted project state. Saved as `<workingFolder>/printprocessor-project.json`.
public struct ProjectModel: Equatable {
    public static let fileName = "printprocessor-project.json"

    /// Folder the project (and its JSON) lives in.
    public var workingFolder: String
    /// Photo file names (basenames) in display order, natural-sorted.
    public var files: [String]
    /// Index of the currently selected photo.
    public var currentIndex: Int
    /// Last chosen paper size (nil until one is picked).
    public var selectedSize: PaperSize?
    /// Per-size, per-photo edits.
    public var edits: EditStore
    /// Layer settings (visibility, watermark, overlay, gradient, backgrounds).
    public var layerSettings: LayerSettings
    /// Pasted/imported text list (leading number → text) for layer 2.
    public var psdTextList: [String: String]
    /// Highest layer-3 webp number ever exported (never reused); -1 = none yet.
    public var overlayCounter: Int

    public init(
        workingFolder: String,
        files: [String],
        currentIndex: Int = 0,
        selectedSize: PaperSize? = nil,
        edits: EditStore = EditStore(),
        layerSettings: LayerSettings = .defaults,
        psdTextList: [String: String] = [:],
        overlayCounter: Int = -1
    ) {
        self.workingFolder = workingFolder
        self.files = files
        self.currentIndex = currentIndex
        self.selectedSize = selectedSize
        self.edits = edits
        self.layerSettings = layerSettings
        self.psdTextList = psdTextList
        self.overlayCounter = overlayCounter
    }

    /// Absolute URL of the project JSON inside the working folder.
    public var fileURL: URL {
        URL(fileURLWithPath: workingFolder).appendingPathComponent(Self.fileName)
    }

    /// Write the project JSON (atomically) to the working folder.
    public func save(to folder: String? = nil) throws {
        let dir = folder ?? workingFolder
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Load a project JSON from a folder, throwing when missing or malformed.
    public static func load(from folder: String) throws -> ProjectModel {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProjectModel.self, from: data)
    }
}

// MARK: - Codable (backward-compatible)

extension ProjectModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case workingFolder
        case files
        case currentIndex
        case selectedSize
        case edits
        case layerSettings
        case psdTextList
        case overlayCounter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workingFolder = try c.decode(String.self, forKey: .workingFolder)
        files = try c.decode([String].self, forKey: .files)
        currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        selectedSize = try c.decodeIfPresent(PaperSize.self, forKey: .selectedSize)
        edits = try c.decodeIfPresent(EditStore.self, forKey: .edits) ?? EditStore()
        layerSettings = try c.decodeIfPresent(LayerSettings.self, forKey: .layerSettings) ?? .defaults
        psdTextList = try c.decodeIfPresent([String: String].self, forKey: .psdTextList) ?? [:]
        overlayCounter = try c.decodeIfPresent(Int.self, forKey: .overlayCounter) ?? -1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workingFolder, forKey: .workingFolder)
        try c.encode(files, forKey: .files)
        try c.encode(currentIndex, forKey: .currentIndex)
        try c.encode(selectedSize, forKey: .selectedSize)
        try c.encode(edits, forKey: .edits)
        try c.encode(layerSettings, forKey: .layerSettings)
        try c.encode(psdTextList, forKey: .psdTextList)
        try c.encode(overlayCounter, forKey: .overlayCounter)
    }
}
