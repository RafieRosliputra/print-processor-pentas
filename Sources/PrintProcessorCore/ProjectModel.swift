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
    /// Absolute path of the layer-3 PSD overlay source ("" = none). Persisted so
    /// the watcher can be re-armed and the newest -NN.webp reloaded on reopen.
    public var overlayPSDPath: String
    /// Highest layer-2 webp number ever exported (never reused); -1 = none yet.
    public var psdTextCounter: Int
    /// File names (basenames) flagged "NO EXPORT". Shared across paper sizes;
    /// the export job skips these photos but the canvas still shows them.
    public var noExport: Set<String>

    public init(
        workingFolder: String,
        files: [String],
        currentIndex: Int = 0,
        selectedSize: PaperSize? = nil,
        edits: EditStore = EditStore(),
        layerSettings: LayerSettings = .defaults,
        psdTextList: [String: String] = [:],
        overlayCounter: Int = -1,
        overlayPSDPath: String = "",
        psdTextCounter: Int = -1,
        noExport: Set<String> = []
    ) {
        self.workingFolder = workingFolder
        self.files = files
        self.currentIndex = currentIndex
        self.selectedSize = selectedSize
        self.edits = edits
        self.layerSettings = layerSettings
        self.psdTextList = psdTextList
        self.overlayCounter = overlayCounter
        self.overlayPSDPath = overlayPSDPath
        self.psdTextCounter = psdTextCounter
        self.noExport = noExport
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

    /// Load a project, recovering from a corrupt JSON: the corrupt file is kept
    /// as `<name>.bak`, the bad file is removed, and `nil` is returned so the
    /// caller can start fresh. Returns `nil` for a missing file without touching
    /// the folder.
    public static func loadRecovering(from folder: String) -> ProjectModel? {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try load(from: folder)
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Whether the last `loadRecovering` attempt found (and backed up) a corrupt
    /// project JSON in this folder.
    public static func hasRecoveryBackup(in folder: String) -> Bool {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(fileName).appendingPathExtension("bak")
        return FileManager.default.fileExists(atPath: url.path)
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
        case overlayPSDPath
        case psdTextCounter
        case noExport
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
        overlayPSDPath = try c.decodeIfPresent(String.self, forKey: .overlayPSDPath) ?? ""
        psdTextCounter = try c.decodeIfPresent(Int.self, forKey: .psdTextCounter) ?? -1
        noExport = try c.decodeIfPresent(Set<String>.self, forKey: .noExport) ?? []
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
        try c.encode(overlayPSDPath, forKey: .overlayPSDPath)
        try c.encode(psdTextCounter, forKey: .psdTextCounter)
        try c.encode(noExport, forKey: .noExport)
    }
}
