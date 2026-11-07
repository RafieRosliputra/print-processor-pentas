import Foundation

/// The text resolved for one image: layer-2 styled text and the layer-1
/// watermark. Both come from the filename scan (and, for text only, the
/// pasted/imported list or a manual per-image override).
public struct TextResolution: Equatable {
    public var text: String
    public var watermark: String

    public init(text: String = "", watermark: String = "") {
        self.text = text
        self.watermark = watermark
    }

    public static let empty = TextResolution()
}

/// Filename-scan mode: which side of the ` - ` separator goes to layer 2
/// (`text`) and which to layer 1 (`watermark`). Serialised as a compact string
/// such as `text=right` or `text=left,watermark=right`.
public struct ScanMode: Equatable, Codable, Hashable {
    public enum Side: String, Codable, CaseIterable {
        case none, left, right

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .left: return "Left"
            case .right: return "Right"
            }
        }
    }

    public var text: Side
    public var watermark: Side

    public init(text: Side = .right, watermark: Side = .none) {
        self.text = text
        self.watermark = watermark
    }

    public static let `default` = ScanMode()

    /// Canonical serialised form, e.g. `text=right` or `text=left,watermark=right`.
    public var key: String {
        var parts = ["text=\(text.rawValue)"]
        if watermark != .none { parts.append("watermark=\(watermark.rawValue)") }
        return parts.joined(separator: ",")
    }

    /// Human-friendly label for the saved-modes popup.
    public var displayName: String {
        var bits = ["Text: \(text.displayName)"]
        if watermark != .none { bits.append("Watermark: \(watermark.displayName)") }
        return bits.joined(separator: ", ")
    }

    /// Parse a serialised mode string. Unknown tokens are ignored and missing
    /// sides keep their defaults, so `"text=right"` is a valid full mode.
    public static func parse(_ string: String) -> ScanMode {
        var mode = ScanMode.default
        for pair in string.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard let side = Side(rawValue: value) else { continue }
            switch key {
            case "text": mode.text = side
            case "watermark": mode.watermark = side
            default: break
            }
        }
        return mode
    }
}

/// Resolves the layer-2 text and layer-1 watermark for a file, honouring the
/// priority manual edit → pasted/imported list → filename scan.
public enum TextSourceResolver {
    /// Leading digit run of the file name (extension removed), e.g. `"122"` for
    /// `"122.jpg"`, `"01"` for `"01 - x.jpg"`. Empty when no leading number.
    public static func leadingNumber(_ fileName: String) -> String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        var digits = ""
        for ch in stem {
            if ch.isNumber && ch.isASCII { digits.append(ch) }
            else { break }
        }
        return digits
    }

    /// Parse a pasted/imported list into a number → text dictionary. Lines look
    /// like `122 - Norman Hakim` or `122<TAB>Norman Hakim`; the key is the
    /// leading number and the value is everything after the separator.
    public static func parseList(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts: [String]
            let join: String
            if trimmed.contains(" - ") {
                parts = trimmed.components(separatedBy: " - ")
                join = " - "
            } else if trimmed.contains("\t") {
                parts = trimmed.components(separatedBy: "\t")
                join = "\t"
            } else {
                continue
            }
            guard parts.count >= 2 else { continue }
            let numberToken = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: join).trimmingCharacters(in: .whitespaces)
            let key = URL(fileURLWithPath: numberToken).deletingPathExtension().lastPathComponent
            if !key.isEmpty && !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// Split a file name on ` - ` and pick the configured sides.
    public static func scan(fileName: String, mode: ScanMode) -> TextResolution {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let parts = stem.components(separatedBy: " - ")
        let left = parts.first ?? ""
        let right = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : ""
        func pick(_ side: ScanMode.Side) -> String {
            switch side {
            case .left: return left
            case .right: return right
            case .none: return ""
            }
        }
        return TextResolution(text: pick(mode.text), watermark: pick(mode.watermark))
    }

    /// Full resolution for one file. Watermark falls back to the legacy
    /// right-part rule when no watermark side is configured.
    public static func resolve(
        fileName: String,
        manualText: String,
        list: [String: String],
        scanMode: ScanMode
    ) -> TextResolution {
        let scanned = scan(fileName: fileName, mode: scanMode)

        var text = scanned.text
        if let listText = list[leadingNumber(fileName)], !listText.isEmpty {
            text = listText
        }
        if !manualText.isEmpty {
            text = manualText
        }

        var watermark = scanned.watermark
        if watermark.isEmpty && scanMode.watermark == .none {
            watermark = WatermarkTextProvider.defaultText(for: fileName)
        }

        return TextResolution(text: text, watermark: watermark)
    }
}
