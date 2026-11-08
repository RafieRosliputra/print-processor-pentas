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

/// Result of a `runJavaScript` invocation: success plus any captured stderr
/// (Photoshop's own error message), so callers can surface it instead of
/// swallowing the failure.
public struct PhotoshopRunResult: Equatable {
    public let ok: Bool
    public let error: String?

    public init(ok: Bool, error: String?) {
        self.ok = ok
        self.error = error
    }
}

/// Real runner: launches Photoshop via `osascript` (`do javascript` JSX), which
/// copies the PSD to a temp file (so the user's own open document is never
/// touched), opens the copy, sets the target text layer, exports a transparent
/// PNG, closes the copy without saving, and restores whichever document was
/// active before. Failures are captured and logged.
public final class PhotoshopRunner: PhotoshopRunnerProtocol {
    /// Absolute path to the Photoshop `.app` bundle; empty = auto-detect.
    public let photoshopAppPath: String
    /// The captured stderr/error message from the most recent osascript run,
    /// cleared on each render. Read this when `renderPNG` returns false.
    public private(set) var lastError: String?

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
        lastError = nil
        guard let appName = resolvedAppName() else {
            lastError = "Photoshop not found."
            Self.log("Photoshop not found")
            return false
        }
        let copyPath = Self.makeTempCopyPath(psdPath: psdPath)
        let jsx = Self.makeJSX(psdPath: psdPath, text: text, layerName: layerName,
                               outputPNG: outputPNG, copyPath: copyPath)
        let result = Self.runJavaScript(jsx: jsx, appName: appName)
        lastError = result.error
        if let err = result.error, !err.isEmpty {
            Self.log("app=\(appName) psd=\(psdPath) error=\(err)")
        }
        try? FileManager.default.removeItem(atPath: copyPath)
        return result.ok
    }

    /// Save the already-open document whose path equals `psdPath` (no-op when it
    /// is not open). This never opens or closes anything.
    @discardableResult
    public func saveOpenDocument(psdPath: String) -> Bool {
        lastError = nil
        guard let appName = resolvedAppName() else {
            lastError = "Photoshop not found."
            return false
        }
        let result = Self.runJavaScript(jsx: Self.makeSaveJSX(psdPath: psdPath), appName: appName)
        lastError = result.error
        if let err = result.error, !err.isEmpty {
            Self.log("app=\(appName) save psd=\(psdPath) error=\(err)")
        }
        return result.ok
    }

    /// Build the JSX body for a render. It is passed as a string to
    /// `app.doJavascript`. The JSX copies the source PSD to `copyPath`, opens
    /// THE COPY, sets the text, exports a PNG, closes the copy without saving,
    /// removes the copy, and restores the previously active document.
    public static func makeJSX(psdPath: String, text: String?, layerName: String,
                               outputPNG: String, copyPath: String) -> String {
        let psdEsc = jsString(psdPath)
        let copyEsc = jsString(copyPath)
        let outEsc = jsString(outputPNG)
        let layerEsc = jsString(layerName)

        var lines: [String] = []
        lines.append("app.displayDialogs = DialogModes.NO;")
        lines.append("var srcFile = new File(\(psdEsc));")
        lines.append("var copyFile = new File(\(copyEsc));")
        lines.append("srcFile.copy(copyFile);")
        lines.append("var previousDoc = null;")
        lines.append("try { previousDoc = app.activeDocument; } catch (e) {}")
        lines.append("var doc = app.open(copyFile);")
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
        lines.append("copyFile.remove();")
        lines.append("if (previousDoc) { try { app.activeDocument = previousDoc; } catch (e) {} }")
        return lines.joined(separator: "\n")
    }

    /// Build the JSX body that saves the already-open document whose path
    /// matches `psdPath` (no-op when it is not open).
    public static func makeSaveJSX(psdPath: String) -> String {
        let psdEsc = jsString(psdPath)
        return [
            "app.displayDialogs = DialogModes.NO;",
            "var target = new File(\(psdEsc));",
            "for (var i = 0; i < app.documents.length; i++) {",
            "  var d = app.documents[i];",
            "  if (d.fullName.fsName === target.fsName) { d.save(); break; }",
            "}",
        ].joined(separator: "\n")
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

    /// Build the JXA wrapper string that runs `jsx` inside Photoshop. The JSX is
    /// JSON-encoded so it becomes a valid JXA string literal without shell
    /// quoting issues.
    public static func makeJXAScript(jsx: String, appName: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [jsx])) ?? Data()
        guard let arr = String(data: data, encoding: .utf8) else { return "" }
        let inner = String(arr.dropFirst().dropLast()) // strip [ ]
        return "function run(argv) { var app = Application(argv[0]); app.doJavascript(\(inner)); return 'ok'; }"
    }

    /// Run JSX inside Photoshop via `osascript -l JavaScript`. Returns whether
    /// the script exited 0 plus any captured stderr/stdout text.
    public static func runJavaScript(jsx: String, appName: String) -> PhotoshopRunResult {
        let script = makeJXAScript(jsx: jsx, appName: appName)
        guard !script.isEmpty else {
            return PhotoshopRunResult(ok: false, error: "Could not encode JSX.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, appName]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let out = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = process.terminationStatus == 0
            let message = err.isEmpty ? out : err
            return PhotoshopRunResult(ok: ok, error: (ok || message.isEmpty) ? nil : message)
        } catch {
            return PhotoshopRunResult(ok: false, error: error.localizedDescription)
        }
    }

    /// A fresh, unused temp path carrying the same extension as `psdPath`.
    static func makeTempCopyPath(psdPath: String) -> String {
        let ext = (psdPath as NSString).pathExtension
        let name = "pp-render-\(UUID().uuidString).\(ext.isEmpty ? "psd" : ext)"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    /// Append a line to `~/Library/Logs/PrintProcessor/photoshop.log`.
    public static func log(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PrintProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("photoshop.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
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
