import Foundation
import CoreGraphics
import ImageIO

/// Renders a PSD through Photoshop without ever modifying the PSD file.
/// Injectable so tests can substitute a fake that only records calls.
public protocol PhotoshopRunnerProtocol: AnyObject {
    /// Render the PSD's flattened composite (optionally setting one text layer's
    /// contents first) to a transparent PNG. Must never alter the PSD itself.
    /// - Returns: true when the PNG was written successfully.
    @discardableResult
    func renderPNG(psdPath: String, text: String?, layerName: String, outputPNG: String) -> Bool
}

/// Real runner: launches Photoshop via `osascript` (`do javascript` JSX), which
/// opens the PSD with dialogs suppressed, sets the target text layer, exports a
/// transparent PNG, and closes without saving.
public final class PhotoshopRunner: PhotoshopRunnerProtocol {
    /// Absolute path to the Photoshop `.app` bundle; empty = auto-detect.
    public let photoshopAppPath: String

    public init(photoshopAppPath: String = "") {
        self.photoshopAppPath = photoshopAppPath
    }

    /// Auto-detect the newest `/Applications/Adobe Photoshop*` bundle.
    public static func detectPhotoshop() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/Applications") else { return nil }
        var apps: [String] = []
        for entry in entries where entry.hasPrefix("Adobe Photoshop") {
            let dir = "/Applications/" + entry
            if entry.hasSuffix(".app") {
                apps.append(dir)
            } else if let sub = try? fm.contentsOfDirectory(atPath: dir) {
                for s in sub where s.hasSuffix(".app") {
                    apps.append(dir + "/" + s)
                }
            }
        }
        return apps.sorted(by: >).first
    }

    private func resolvedAppName() -> String? {
        let path = photoshopAppPath.isEmpty ? (Self.detectPhotoshop() ?? "") : photoshopAppPath
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    public func renderPNG(psdPath: String, text: String?, layerName: String, outputPNG: String) -> Bool {
        guard let appName = resolvedAppName() else { return false }
        let jsx = Self.makeJSX(psdPath: psdPath, text: text, layerName: layerName, outputPNG: outputPNG)
        return Self.runJavaScript(jsx: jsx, appName: appName)
    }

    /// Build the JSX body. It is passed as a string to `app.do javascript`.
    public static func makeJSX(psdPath: String, text: String?, layerName: String, outputPNG: String) -> String {
        let psdEsc = jsString(psdPath)
        let outEsc = jsString(outputPNG)
        let layerEsc = jsString(layerName)

        var lines: [String] = []
        lines.append("app.displayDialogs = DialogModes.NO;")
        lines.append("var doc = app.open(new File(\(psdEsc)));")
        lines.append("function firstText(d, name) {")
        lines.append("  for (var i = 0; i < d.layers.length; i++) {")
        lines.append("    var l = d.layers[i];")
        lines.append("    if (l.typename === 'LayerSet') { var r = firstText(l, name); if (r) return r; }")
        lines.append("    if (l.kind === LayerKind.TEXT && l.name === name) return l;")
        lines.append("  }")
        lines.append("  return null;")
        lines.append("}")
        lines.append("function anyText(d) {")
        lines.append("  for (var i = 0; i < d.layers.length; i++) {")
        lines.append("    var l = d.layers[i];")
        lines.append("    if (l.typename === 'LayerSet') { var r = anyText(l); if (r) return r; }")
        lines.append("    if (l.kind === LayerKind.TEXT) return l;")
        lines.append("  }")
        lines.append("  return null;")
        lines.append("}")
        if text != nil {
            lines.append("var target = firstText(doc, \(layerEsc)) || anyText(doc);")
            lines.append("if (target) { target.textItem.contents = \(jsString(text!)); }")
        }
        lines.append("var out = new File(\(outEsc));")
        lines.append("var opts = new ExportOptionsSaveForWeb();")
        lines.append("opts.format = SaveDocumentType.PNG;")
        lines.append("opts.PNG8 = false;")
        lines.append("opts.transparency = true;")
        lines.append("opts.interlaced = false;")
        lines.append("doc.exportDocument(out, ExportType.SAVEFORWEB, opts);")
        lines.append("doc.close(SaveOptions.DONOTSAVECHANGES);")
        return lines.joined(separator: "\n")
    }

    /// Escape a Swift string for embedding as a JavaScript double-quoted string.
    static func jsString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    /// Run JSX inside Photoshop via `osascript -l JavaScript`. The JSX is JSON-
    /// encoded so it becomes a valid JXA string literal without shell quoting
    /// issues. Returns true only when the script exits 0.
    public static func runJavaScript(jsx: String, appName: String) -> Bool {
        let data = (try? JSONSerialization.data(withJSONObject: [jsx])) ?? Data()
        guard let arr = String(data: data, encoding: .utf8) else { return false }
        let inner = String(arr.dropFirst().dropLast()) // strip [ ]
        let script = "function run(argv) { var app = Application(argv[0]); app.doJavaScript(\(inner)); return 'ok'; }"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, appName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Flatten a PSD to a composite image using ImageIO (no Photoshop). Returns nil
/// when ImageIO cannot decode the PSD composite; callers then fall back to the
/// Photoshop JSX export.
public enum PSDFlatten {
    public static func composite(psdPath: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: psdPath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }
}
