import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PrintProcessorCore

// Self-check for the layer-4 milestone: PaperSize pixel math, AppSettings defaults,
// NaturalSort, UndoStack bounds, per-size edit independence, and ProjectModel JSON.
// Milestone-2 additions: Compositor layer stacking, gradient clipping, watermark
// default text, and LayerSettings JSON round-trip.
// Exits non-zero on the first mismatch so it can be used as a build/test gate.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print(condition ? "[ok] \(label)" : "[FAIL] \(label)")
    if !condition { failures += 1 }
}

// MARK: - Compositor test helpers (CoreGraphics / ImageIO only, no AppKit)

/// A solid-colour image of the given size.
func makeSolidImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// Write a PNG next to the current working directory (writable in the test's
/// environment) and return its path ("" when it can't be written). The caller
/// removes the file when done.
func writeTempPNG(_ image: CGImage, name: String) -> String {
    let unique = name.replacingOccurrences(of: ".png", with: "-\(UUID().uuidString.prefix(8)).png")
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(unique)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return ""
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return url.path
}

/// Write a PNG to an exact URL (used by fake runners/encoders).
func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

/// A writable temp directory under the current working directory (the sandbox
/// blocks the system temp dir, so tests create their own).
func makeTempDir(_ label: String) -> String {
    let dir = FileManager.default.currentDirectoryPath + "/.check-\(label)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Create a file with the given bytes (Data.write works where `createFile`
/// is blocked by the harness sandbox).
@discardableResult
func makeFile(_ path: String, _ bytes: [UInt8] = []) -> Bool {
    do {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

/// Sample a pixel at (x, y) with y measured from the bottom (canvas convention,
/// matching the renderer's y-up coordinate space). Bitmap buffers are stored
/// top-down, so the row index is inverted.
func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = ctx.data else { return (0, 0, 0, 0) }
    let p = data.assumingMemoryBound(to: UInt8.self)
    let row = image.height - 1 - y
    let offset = row * ctx.bytesPerRow + x * 4
    return (CGFloat(p[offset]) / 255, CGFloat(p[offset + 1]) / 255,
            CGFloat(p[offset + 2]) / 255, CGFloat(p[offset + 3]) / 255)
}

func isNear(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.05) -> Bool {
    abs(actual - expected) <= tolerance
}

// Paper size pixel math (300 dpi).
func expect(_ size: PaperSize, _ width: Int, _ height: Int) {
    check(size.pixelWidth == width && size.pixelHeight == height,
          "\(size.label) -> \(size.pixelWidth)x\(size.pixelHeight) (expected \(width)x\(height))")
}

expect(.in4x6, 1200, 1800)
expect(.in5x7, 1500, 2100)
expect(.in8x10, 2400, 3000)
expect(.in8x12, 2400, 3600)
expect(.in8x15, 2400, 4500)
expect(.in11x14, 3300, 4200)
expect(.in12x16, 3600, 4800)
expect(.in12x10, 3600, 3000)

// AppSettings defaults.
let d = AppSettings.defaults
check(d.doubleTapMs == 300 && d.rotateStep == 0.1 && d.tooltipDelay == 0.5 && d.nudgeBasis == .export,
      "AppSettings defaults")

// NaturalSort: "2" < "10".
let natural = NaturalSort.sorted(["10.jpg", "2.jpg", "1.jpg"])
check(natural == ["1.jpg", "2.jpg", "10.jpg"], "NaturalSort [10,2,1] -> \(natural.joined(separator: ","))")

// UndoStack caps at 50.
var stack = UndoStack<ImageEdit>(maxCount: 50)
for i in 0..<70 { stack.push(ImageEdit(offsetX: Double(i))) }
check(stack.depth == 50, "UndoStack depth == 50 (got \(stack.depth))")
var undoCursor = ImageEdit(offsetX: 999)
let undone = stack.undo(current: undoCursor)
check(undone?.offsetX == 69, "UndoStack top == 69 (got \(undone?.offsetX ?? -1))")

// Per-size edits are independent.
var store = EditStore()
let fourSix = PaperSize.in4x6.rawValue
let eightTen = PaperSize.in8x10.rawValue
store.setEdit(ImageEdit(offsetX: 25, offsetY: 30, rotationDeg: 3), sizeKey: fourSix, fileName: "a.jpg")
check(store.edit(sizeKey: fourSix, fileName: "a.jpg")?.offsetX == 25, "4x6 edit stored")
check(store.edit(sizeKey: eightTen, fileName: "a.jpg") == nil, "8x10 stays unset for a.jpg")
// 8x10 gets its own value.
store.setEdit(ImageEdit(offsetX: 1), sizeKey: eightTen, fileName: "a.jpg")
check(store.edit(sizeKey: eightTen, fileName: "a.jpg")?.offsetX == 1, "8x10 edit stored independently")
check(store.edit(sizeKey: fourSix, fileName: "a.jpg")?.offsetX == 25, "4x6 edit unchanged")

// ProjectModel JSON round-trip.
var store2 = EditStore()
store2.setEdit(ImageEdit(scale: 1.5, offsetX: 12, offsetY: -7, rotationDeg: 1.25),
               sizeKey: PaperSize.in4x6.rawValue, fileName: "2.jpg")
let model = ProjectModel(
    workingFolder: "/tmp/prints",
    files: ["2.jpg", "10.jpg"],
    currentIndex: 1,
    selectedSize: .in4x6,
    edits: store2
)
var roundTripOK = false
if let data = try? JSONEncoder().encode(model),
   let decoded = try? JSONDecoder().decode(ProjectModel.self, from: data) {
    roundTripOK = decoded == model
}
check(roundTripOK, "ProjectModel JSON round-trip")

// MARK: - Milestone 2 additions

// 4. Watermark default text from "Tingkatan 1C - 01.jpg" is "01".
check(WatermarkTextProvider.defaultText(for: "Tingkatan 1C - 01.jpg") == "01",
      "Watermark default text for \"Tingkatan 1C - 01.jpg\" -> \"01\"")
check(WatermarkTextProvider.defaultText(for: "no-separator.jpg") == "",
      "Watermark default text empty without \" - \" separator")

// 7. LayerSettings JSON round-trip (incl. FinalBackground enum).
var ls = LayerSettings.defaults
ls.enabled.layer3 = false
ls.watermark.text = "01"
ls.watermark.transform.rotationDeg = 12.5
ls.overlay.path = "/tmp/overlay.webp"
ls.overlay.transform.scale = 0.7
ls.gradient.angle = 45
ls.gradient.blend = .overlay
ls.bg5.path = "/tmp/bg5.png"
ls.bg6 = .image("/tmp/bg6.png")
var layerRoundTrip = false
if let data = try? JSONEncoder().encode(ls),
   let decoded = try? JSONDecoder().decode(LayerSettings.self, from: data) {
    layerRoundTrip = decoded == ls
}
check(layerRoundTrip, "LayerSettings JSON round-trip")

// 2 & 3. Compositor layer stacking, disabled-layer skipping, gradient clipping.
do {
    let canvas = CGSize(width: 1200, height: 1800)
    let green = makeSolidImage(width: 300, height: 300, r: 0, g: 1, b: 0)!
    let blue = makeSolidImage(width: 200, height: 200, r: 0, g: 0, b: 1)!
    let bluePath = writeTempPNG(blue, name: "check-blue.png")
    defer { if !bluePath.isEmpty { try? FileManager.default.removeItem(atPath: bluePath) } }

    // Place the blue overlay as a 200x200 square at the canvas top-left corner.
    // Overlay "fit" = contain => 200x200 scales to 1200x1200, so we scale it
    // back down and offset the centre to (100, 1700).
    let overlay = OverlaySettings(
        path: bluePath,
        fit: true,
        transform: OverlayTransform(offsetX: 100 - 600, offsetY: 1700 - 900,
                                    scale: 200.0 / 1200.0, rotationDeg: 0)
    )

    var layerSettings = LayerSettings.defaults
    layerSettings.gradient.enabled = false
    layerSettings.bg6 = .colour(RGBAColor(red: 1, green: 0, blue: 0))   // red
    layerSettings.overlay = overlay

    var project = ProjectModel(
        workingFolder: "/tmp/prints",
        files: ["photo.jpg"],
        currentIndex: 0,
        selectedSize: .in4x6,
        edits: EditStore(),
        layerSettings: layerSettings
    )

    let compositor = Compositor()
    let photoSource: (Int) -> CGImage? = { _ in green }

    if let rendered = compositor.render(project: project, imageIndex: 0,
                                        canvasPixelSize: canvas, photoSource: photoSource) {
        // Photo (300x300 fit => 1200x1200 centred) covers the middle.
        let center = samplePixel(rendered, x: 600, y: 900)
        check(isNear(center.g, 1) && isNear(center.r, 0) && isNear(center.b, 0),
              "Compositor: photo green at centre (got \(center))")

        // Final background shows through where no photo/overlay sits.
        let corner = samplePixel(rendered, x: 50, y: 50)
        check(isNear(corner.r, 1) && isNear(corner.g, 0) && isNear(corner.b, 0),
              "Compositor: bg6 red at bottom-left (got \(corner))")

        // Overlay drawn above photo at the top-left corner.
        let topLeft = samplePixel(rendered, x: 100, y: 1700)
        check(isNear(topLeft.b, 1) && isNear(topLeft.r, 0) && isNear(topLeft.g, 0),
              "Compositor: overlay blue at top-left (got \(topLeft))")

        // Disable layer 3 -> top-left corner reverts to red (overlay skipped).
        project.layerSettings.enabled.layer3 = false
        if let noOverlay = compositor.render(project: project, imageIndex: 0,
                                             canvasPixelSize: canvas, photoSource: photoSource) {
            let topLeft2 = samplePixel(noOverlay, x: 100, y: 1700)
            check(isNear(topLeft2.r, 1) && isNear(topLeft2.g, 0) && isNear(topLeft2.b, 0),
                  "Compositor: disabled overlay is skipped (got \(topLeft2))")
        } else {
            check(false, "Compositor: re-render after disabling overlay")
        }

        // Disable layer 4 -> centre reverts to red (photo skipped).
        project.layerSettings.enabled.layer3 = true
        project.layerSettings.enabled.layer4 = false
        if let noPhoto = compositor.render(project: project, imageIndex: 0,
                                           canvasPixelSize: canvas, photoSource: photoSource) {
            let center2 = samplePixel(noPhoto, x: 600, y: 900)
            check(isNear(center2.r, 1) && isNear(center2.g, 0) && isNear(center2.b, 0),
                  "Compositor: disabled photo is skipped (got \(center2))")
        } else {
            check(false, "Compositor: re-render after disabling photo")
        }

        // Gradient (opaque magenta) affects only the photo area.
        project.layerSettings.enabled.layer4 = true
        project.layerSettings.gradient.enabled = true
        project.layerSettings.gradient.colorA = RGBAColor(red: 1, green: 0, blue: 1)
        project.layerSettings.gradient.colorB = RGBAColor(red: 1, green: 0, blue: 1)
        project.layerSettings.gradient.opacity = 1
        project.layerSettings.gradient.blend = .normal
        if let gradientRender = compositor.render(project: project, imageIndex: 0,
                                                  canvasPixelSize: canvas, photoSource: photoSource) {
            let inPhoto = samplePixel(gradientRender, x: 600, y: 900)
            check(isNear(inPhoto.r, 1) && isNear(inPhoto.b, 1) && isNear(inPhoto.g, 0),
                  "Compositor: gradient colours the photo area (got \(inPhoto))")
            let outside = samplePixel(gradientRender, x: 50, y: 50)
            check(isNear(outside.r, 1) && isNear(outside.g, 0) && isNear(outside.b, 0),
                  "Compositor: gradient stays inside the photo (got \(outside))")
        } else {
            check(false, "Compositor: gradient render")
        }
    } else {
        check(false, "Compositor: render 1200x1800")
    }
}

// MARK: - Milestone 3 additions (SPEC §6/§7 + middle-click)

// 2. TextSourceResolver: list + filename scan.
do {
    let list = TextSourceResolver.parseList("122 - Norman Hakim\n99\tAli Baba")
    check(list["122"] == "Norman Hakim", "TextSourceResolver parses \"122 - Norman Hakim\" -> \"Norman Hakim\"")
    check(list["99"] == "Ali Baba", "TextSourceResolver parses tab-separated list line")

    let resolved = TextSourceResolver.resolve(fileName: "122.jpg", manualText: "", list: list, scanMode: .default)
    check(resolved.text == "Norman Hakim", "list resolves 122.jpg -> \"Norman Hakim\" (got \"\(resolved.text)\")")

    let scanMode = ScanMode.parse("text=left,watermark=right")
    let scanned = TextSourceResolver.scan(fileName: "Tingkatan 1C - 01.jpg", mode: scanMode)
    check(scanned.text == "Tingkatan 1C" && scanned.watermark == "01",
          "scan text=left,watermark=right -> \"Tingkatan 1C\" + \"01\" (got \"\(scanned.text)\"/\"\(scanned.watermark)\")")
}

// 3. PSDTextRenderer caches the same text (fake runner called once).
do {
    final class FakeRunner: PhotoshopRunnerProtocol {
        var calls = 0
        func renderPNG(psdPath: String, text: String?, layerName: String, outputPNG: String) -> Bool {
            calls += 1
            guard let img = makeSolidImage(width: 40, height: 10, r: 1, g: 1, b: 1, a: 1) else { return false }
            return writePNG(img, to: URL(fileURLWithPath: outputPNG))
        }
    }
    let tmp = makeTempDir("psdtext")
    let psdPath = tmp + "/template.psd"
    makeFile(psdPath, [0x38, 0x42, 0x50, 0x53])

    let runner = FakeRunner()
    let renderer = PSDTextRenderer(runner: runner, cacheDirectory: tmp, layerName: "TEXT")
    let first = renderer.render(psdPath: psdPath, text: "Norman Hakim")
    let second = renderer.render(psdPath: psdPath, text: "Norman Hakim")
    check(first != nil && second != nil, "PSDTextRenderer renders text via fake runner")
    check(runner.calls == 1, "PSDTextRenderer cache hit on same text (runner called \(runner.calls)x, expected 1)")
}

// 4. Never-reuse webp numbering: -00,-01,-04 present, -01 deleted -> -05.
do {
    let tmp = makeTempDir("webp")
    let psdURL = URL(fileURLWithPath: tmp + "/overlay.psd")
    makeFile(psdURL.path)
    for n in [0, 1, 4] {
        makeFile(WebPNumbering.outputURL(psdURL: psdURL, number: n).path, [1])
    }
    try? FileManager.default.removeItem(atPath: WebPNumbering.outputURL(psdURL: psdURL, number: 1).path)
    let next = WebPNumbering.nextNumber(psdURL: psdURL, counter: 4)
    check(next == 5, "numbering continues at -05 after -01 deleted (got -\(String(format: "%02d", next)))")
    let out = WebPNumbering.outputURL(psdURL: psdURL, number: next)
    check(!FileManager.default.fileExists(atPath: out.path), "next number never overwrites an existing webp")
}

// 5. PSD exporter writes numbered webp beside the PSD + FileWatcher fires.
do {
    let tmp = makeTempDir("watch")
    let psdURL = URL(fileURLWithPath: tmp + "/badge.psd")
    makeFile(psdURL.path, [0x38, 0x42, 0x50, 0x53])

    let exporter = PSDOverlayExporter(
        flatten: { _ in makeSolidImage(width: 64, height: 64, r: 0, g: 0, b: 1, a: 1) },
        encode: { img, url in writePNG(img, to: url) }
    )
    let first = exporter.export(psdURL: psdURL, counter: -1)
    check(first?.lastPathComponent == "badge-00.webp",
          "PSD exporter writes <name>-00.webp beside the PSD (got \(first?.lastPathComponent ?? "nil"))")
    let second = exporter.export(psdURL: psdURL, counter: 0)
    check(second?.lastPathComponent == "badge-01.webp",
          "PSD exporter writes <name>-01.webp next (got \(second?.lastPathComponent ?? "nil"))")

    let sem = DispatchSemaphore(value: 0)
    var watched: [String] = []
    let watcher = FileWatcher(path: psdURL.path, debounce: 0.05) { p in
        watched.append(p)
        sem.signal()
    }
    watcher.start()
    // Simulate a save (overwrite the file so the .write event fires).
    if let before = try? Data(contentsOf: psdURL) {
        try? Data(before + [0x00]).write(to: psdURL)
    }
    let fired = sem.wait(timeout: .now() + 3.0) == .success
    check(fired && watched.contains(psdURL.path), "FileWatcher detects a PSD save (fired=\(fired))")
    watcher.stop()
}

// MARK: - Milestone 4 additions (SPEC §9 cache, global/shift edits, per-size scaling, recovery)

// 6. Per-size scaling: switching size scales offsets proportionally, keeps
//    scale/rotation (no reset to Fit).
do {
    let scaled = ImageEdit(scale: 2, offsetX: 100, offsetY: 200, rotationDeg: 30)
        .scaled(fromCanvas: CGSize(width: 1200, height: 1800), toCanvas: CGSize(width: 2400, height: 3000))
    check(scaled.scale == 2 && scaled.rotationDeg == 30,
          "Per-size scale keeps zoom/rotation (got \(scaled.scale), \(scaled.rotationDeg))")
    check(isNear(CGFloat(scaled.offsetX), 200) && isNear(CGFloat(scaled.offsetY), 333.33),
          "Per-size scale offsets proportionally (got \(scaled.offsetX), \(scaled.offsetY))")
}

// 3. Global absolute edit: .all sets every file; .after only later files.
do {
    var store = EditStore()
    let key = PaperSize.in4x6.rawValue
    let files = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
    store.setEdit(ImageEdit(offsetX: 1), sizeKey: key, fileName: "a.jpg")
    store.setEdit(ImageEdit(offsetX: 2), sizeKey: key, fileName: "b.jpg")

    let global = ImageEdit(scale: 3, offsetX: 9, offsetY: 8, rotationDeg: 5)
    store.applyGlobalEdit(global, scope: .all, sizeKey: key, files: files, currentIndex: 1)
    check(files.allSatisfy { store.edit(sizeKey: key, fileName: $0) == global },
          "Global .all edit sets every image equal to current")

    // Shift-only applies only to files after the current index (index 1 -> c, d).
    store.setEdit(ImageEdit(offsetX: 1), sizeKey: key, fileName: "a.jpg")
    store.setEdit(ImageEdit(offsetX: 2), sizeKey: key, fileName: "b.jpg")
    store.setEdit(ImageEdit(offsetX: 3), sizeKey: key, fileName: "c.jpg")
    store.setEdit(ImageEdit(offsetX: 4), sizeKey: key, fileName: "d.jpg")
    let after = ImageEdit(scale: 7, offsetX: 70, offsetY: 71, rotationDeg: 6)
    store.applyGlobalEdit(after, scope: .after, sizeKey: key, files: files, currentIndex: 1)
    check(store.edit(sizeKey: key, fileName: "a.jpg")?.offsetX == 1
          && store.edit(sizeKey: key, fileName: "b.jpg")?.offsetX == 2,
          "Shift-only leaves earlier files unchanged")
    check(store.edit(sizeKey: key, fileName: "c.jpg") == after
          && store.edit(sizeKey: key, fileName: "d.jpg") == after,
          "Shift-only applies absolute edit to later files only")
}

// 5. Corrupt project JSON -> .bak kept, fresh start.
do {
    let tmp = makeTempDir("recover")
    let jsonURL = URL(fileURLWithPath: tmp).appendingPathComponent(ProjectModel.fileName)
    makeFile(jsonURL.path, Array("{ not valid json".utf8))
    let recovered = ProjectModel.loadRecovering(from: tmp)
    check(recovered == nil, "Corrupt project JSON returns nil (fresh start)")
    let bakURL = jsonURL.appendingPathExtension("bak")
    check(FileManager.default.fileExists(atPath: bakURL.path),
          "Corrupt project JSON kept as .bak")
    check(!FileManager.default.fileExists(atPath: jsonURL.path),
          "Corrupt project JSON removed after backup")
}

// 2a. ImageCache LRU respects the RAM cap and evicts least-recently-used.
do {
    let tmp = makeTempDir("cache")
    func writePng(_ w: Int, _ h: Int, _ name: String) -> String {
        writeTempPNG(makeSolidImage(width: w, height: h, r: 1, g: 0, b: 0, a: 1)!, name: name)
    }
    let a = URL(fileURLWithPath: writePng(100, 100, "a.png"))
    let b = URL(fileURLWithPath: writePng(100, 100, "b.png"))
    let c = URL(fileURLWithPath: writePng(100, 100, "c.png"))
    defer {
        for u in [a, b, c] { try? FileManager.default.removeItem(at: u) }
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // Cap holds two 100x100 previews (~40 KB each); a third evicts the LRU (a).
    let cache = ImageCache(ramCapBytes: 80_000)
    _ = cache.preview(url: a)
    _ = cache.preview(url: b)
    check(cache.isCachedInRAM(a) && cache.isCachedInRAM(b), "ImageCache holds first two previews")
    _ = cache.preview(url: c)
    check(cache.ramUsageBytes() <= 80_000, "ImageCache RAM usage respects cap (got \(cache.ramUsageBytes()))")
    check(!cache.isCachedInRAM(a) && cache.isCachedInRAM(b) && cache.isCachedInRAM(c),
          "ImageCache evicts least-recently-used (a)")

    // loadOriginal returns the full-resolution original, never a preview.
    let big = URL(fileURLWithPath: writePng(300, 200, "orig.png"))
    defer { try? FileManager.default.removeItem(at: big) }
    let original = cache.loadOriginal(url: big)
    check(original?.width == 300 && original?.height == 200,
          "ImageCache.loadOriginal decodes original size (got \(original?.width ?? 0)x\(original?.height ?? 0))")
}

// 2b. Stale temp cache directories from crashed runs are removed at launch.
do {
    let base = URL(fileURLWithPath: makeTempDir("stale"))
    defer { try? FileManager.default.removeItem(at: base) }
    let stale = base.appendingPathComponent("PrintProcessorCache-99999")
    let current = base.appendingPathComponent("PrintProcessorCache-\(ProcessInfo.processInfo.processIdentifier)")
    let other = base.appendingPathComponent("keepme")
    try? FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    ImageCache.removeStaleDiskCaches(in: base)
    check(!FileManager.default.fileExists(atPath: stale.path), "Stale cache dir removed at launch")
    check(FileManager.default.fileExists(atPath: current.path), "Current-process cache dir preserved")
    check(FileManager.default.fileExists(atPath: other.path), "Unrelated dirs untouched")
}

// MARK: - Milestone 5 additions (SPEC §10–§12 export + shortcuts)

func exportIntProp(_ props: [CFString: Any]?, _ key: CFString) -> Int {
    guard let v = props?[key] else { return 0 }
    return (v as? NSNumber)?.intValue ?? (v as? Int) ?? 0
}

/// Run a JPG-only export to completion, spinning the main run loop so the
/// ExportJob's main-queue completion can fire.
func runExportSync(
    files: [URL],
    root: URL,
    paper: CGSize,
    resolutions: [URL: CollisionPolicy] = [:],
    pattern: String = "{name}"
) -> ExportSummary {
    let settings = ExportSettings(exportJPG: true, exportWebP: false, filenamePattern: pattern)
    let job = ExportJob(
        files: files,
        formats: [.jpg],
        exportRoot: root,
        settings: settings,
        paperPixelSize: paper,
        sizeLabel: "4x6",
        cwebpPath: "",
        cpuLimit: 0,
        render: { i, canvas in
            guard files.indices.contains(i) else { return nil }
            return makeSolidImage(width: Int(canvas.width), height: Int(canvas.height), r: 1, g: 1, b: 1, a: 1)
        }
    )
    var summary = ExportSummary()
    var done = false
    job.run(resolutions: resolutions) { s in summary = s; done = true }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return summary
}

// 1. Filename pattern expansion.
do {
    let a = ExportNaming.fileName(sourceName: "122 - Norman Hakim.jpg", pattern: "{name}", sizeLabel: "4x6", index: 0, format: .jpg)
    check(a == "122 - Norman Hakim.jpg", "pattern {name} -> \"\(a)\"")

    let b = ExportNaming.fileName(sourceName: "122 - Norman Hakim.jpg", pattern: "{name}_{size}", sizeLabel: "4x6", index: 0, format: .jpg)
    check(b == "122 - Norman Hakim_4x6.jpg", "pattern {name}_{size} -> \"\(b)\"")

    let c = ExportNaming.fileName(sourceName: "01.jpg", pattern: "{number}", sizeLabel: "4x6", index: 0, format: .webp)
    check(c == "01.webp", "pattern {number} -> \"\(c)\"")

    let d = ExportNaming.fileName(sourceName: "a.jpg", pattern: "{index}", sizeLabel: "4x6", index: 2, format: .jpg)
    check(d == "3.jpg", "pattern {index} (1-based) -> \"\(d)\"")
}

// 2. Keep-both naming never overwrites.
do {
    let tmp = makeTempDir("uniq")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let base = URL(fileURLWithPath: tmp).appendingPathComponent("photo.jpg")
    makeFile(base.path, [1])
    let u1 = ExportNaming.uniqueURL(base)
    check(u1.lastPathComponent == "photo-1.jpg", "uniqueURL -> photo-1.jpg (got \(u1.lastPathComponent))")
    makeFile(u1.path, [1])
    let u2 = ExportNaming.uniqueURL(base)
    check(u2.lastPathComponent == "photo-2.jpg", "uniqueURL -> photo-2.jpg (got \(u2.lastPathComponent))")
}

// 3. JPEG: dpi 300, sRGB, no EXIF, paper pixels.
do {
    let tmp = makeTempDir("jpg")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let img = makeSolidImage(width: 1200, height: 1800, r: 1, g: 0, b: 0, a: 1)!
    let url = URL(fileURLWithPath: tmp).appendingPathComponent("out.jpg")
    check(JPEGWriter.write(img, to: url, quality: 10), "JPEGWriter writes a JPG")
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
    let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
    check(exportIntProp(props, kCGImagePropertyDPIWidth) == 300
          && exportIntProp(props, kCGImagePropertyDPIHeight) == 300,
          "JPG dpi 300 (got \(exportIntProp(props, kCGImagePropertyDPIWidth))x\(exportIntProp(props, kCGImagePropertyDPIHeight)))")
    let colorModel = props?[kCGImagePropertyColorModel] as? String ?? ""
    check(colorModel.contains("RGB"), "JPG sRGB colour model (got \"\(colorModel)\")")
    let profileName = props?[kCGImagePropertyProfileName] as? String ?? ""
    check(profileName.contains("sRGB"), "JPG sRGB profile embedded (got \"\(profileName)\")")
    // Source metadata is never carried over (fresh render); ImageIO still writes
    // a minimal dimension/colorspace EXIF, so we assert the meaningful fields are
    // absent rather than requiring a literally empty dictionary.
    check(props?[kCGImagePropertyGPSDictionary] == nil, "JPG has no GPS metadata")
    let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let stripped = (tiff?[kCGImagePropertyTIFFMake] == nil)
        && (tiff?[kCGImagePropertyTIFFSoftware] == nil)
        && (tiff?[kCGImagePropertyTIFFCopyright] == nil)
    check(stripped, "JPG stripped of camera/software/copyright metadata")
    let decoded = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    check(decoded?.width == 1200 && decoded?.height == 1800,
          "JPG size = paper pixels (got \(decoded?.width ?? 0)x\(decoded?.height ?? 0))")
}

// 4. Parallel export of 8 files; every output exists.
do {
    let tmp = makeTempDir("export8")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    var files: [URL] = []
    for i in 0..<8 {
        let u = URL(fileURLWithPath: tmp).appendingPathComponent("\(i).png")
        _ = writePNG(makeSolidImage(width: 60, height: 90, r: 0, g: 0, b: 1, a: 1)!, to: u)
        files.append(u)
    }
    let summary = runExportSync(files: files, root: URL(fileURLWithPath: tmp), paper: CGSize(width: 120, height: 180))
    check(summary.jpgWritten == 8, "parallel export wrote 8 JPGs (got \(summary.jpgWritten))")
    var all = true
    for i in 0..<8 {
        let u = URL(fileURLWithPath: tmp).appendingPathComponent("JPG").appendingPathComponent("\(i).jpg")
        if !FileManager.default.fileExists(atPath: u.path) { all = false }
    }
    check(all, "all 8 exported JPG files exist in JPG/")
}

// 5. Collision policy: replace / skip / keep both.
do {
    let tmp = makeTempDir("collision")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let src = URL(fileURLWithPath: tmp).appendingPathComponent("a.png")
    _ = writePNG(makeSolidImage(width: 20, height: 20, r: 0, g: 1, b: 0, a: 1)!, to: src)
    let out = URL(fileURLWithPath: tmp).appendingPathComponent("JPG").appendingPathComponent("a.jpg")

    let first = runExportSync(files: [src], root: URL(fileURLWithPath: tmp), paper: CGSize(width: 40, height: 40))
    check(first.jpgWritten == 1 && FileManager.default.fileExists(atPath: out.path), "first export writes a.jpg")

    // keep both -> a-1.jpg, original untouched.
    let keep = runExportSync(files: [src], root: URL(fileURLWithPath: tmp), paper: CGSize(width: 40, height: 40), resolutions: [out: .keepBoth])
    let keepURL = URL(fileURLWithPath: tmp).appendingPathComponent("JPG").appendingPathComponent("a-1.jpg")
    check(keep.jpgWritten == 1 && FileManager.default.fileExists(atPath: keepURL.path), "keepBoth writes a-1.jpg")

    // skip -> no extra file.
    _ = runExportSync(files: [src], root: URL(fileURLWithPath: tmp), paper: CGSize(width: 40, height: 40), resolutions: [out: .skip])
    let skipURL = URL(fileURLWithPath: tmp).appendingPathComponent("JPG").appendingPathComponent("a-2.jpg")
    check(!FileManager.default.fileExists(atPath: skipURL.path), "skip writes nothing new")
}

// 6. WebP long-edge + quality (only when cwebp is present).
if WebPEncoder.isAvailable {
    let tmp = makeTempDir("webpexport")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let settings = ExportSettings(exportJPG: false, exportWebP: true, webpQuality: 70, webpLongEdge: 160)
    let job = ExportJob(
        files: [URL(fileURLWithPath: tmp).appendingPathComponent("x.png")],
        formats: [.webp],
        exportRoot: URL(fileURLWithPath: tmp),
        settings: settings,
        paperPixelSize: CGSize(width: 400, height: 600),
        sizeLabel: "4x6",
        cwebpPath: "",
        cpuLimit: 0,
        render: { _, canvas in makeSolidImage(width: Int(canvas.width), height: Int(canvas.height), r: 0, g: 0, b: 1, a: 1) }
    )
    var summary = ExportSummary()
    var done = false
    job.run(resolutions: [:]) { s in summary = s; done = true }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let out = URL(fileURLWithPath: tmp).appendingPathComponent("WebP").appendingPathComponent("x.webp")
    check(summary.webpWritten == 1 && FileManager.default.fileExists(atPath: out.path), "WebP export writes x.webp")
    if let src = CGImageSourceCreateWithURL(out as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        check(max(img.width, img.height) == 160, "WebP long edge == 160 (got \(max(img.width, img.height)))")
    } else {
        check(false, "WebP decodes for long-edge check")
    }
} else {
    print("[skip] cwebp not found — WebP export check skipped")
}

if failures == 0 {
    print("PrintProcessorCheck: PASS")
    exit(0)
} else {
    print("PrintProcessorCheck: \(failures) FAILURE(S)")
    exit(1)
}
