import Foundation

/// The persisted project state. Saved as `<workingFolder>/printprocessor-project.json`.
public struct ProjectModel: Codable, Equatable {
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

    public init(
        workingFolder: String,
        files: [String],
        currentIndex: Int = 0,
        selectedSize: PaperSize? = nil,
        edits: EditStore = EditStore()
    ) {
        self.workingFolder = workingFolder
        self.files = files
        self.currentIndex = currentIndex
        self.selectedSize = selectedSize
        self.edits = edits
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
