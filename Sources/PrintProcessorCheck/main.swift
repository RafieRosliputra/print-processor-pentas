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

// 7. LayerSettings JSON round-trip (incl. FinalBackground enum and extra layers).
var ls = LayerSettings.defaults
ls.enabled.layer3 = false
ls.watermark.text = "01"
ls.watermark.transform.rotationDeg = 12.5
ls.overlay.path = "/tmp/overlay.webp"
ls.overlay.transform.scaleX = 0.7
ls.overlay.transform.scaleY = 0.9
ls.extraLayers = [
    ExtraLayer(id: UUID(), name: "flare", path: "/tmp/flare.webp", enabled: true, opacity: 0.7,
               blend: .overlay, clipToPhoto: true,
               transform: OverlayTransform(offsetX: 5, offsetY: -3, scaleX: 0.9, scaleY: 1.1, rotationDeg: 30),
               psd: PSDOverlaySource(psdPath: "/tmp/flare.psd", counter: 3))
]
ls.bg5.path = "/tmp/bg5.png"
ls.bg6 = .image("/tmp/bg6.png")
var layerRoundTrip = false
if let data = try? JSONEncoder().encode(ls),
   let decoded = try? JSONDecoder().decode(LayerSettings.self, from: data) {
    layerRoundTrip = decoded == ls
}
check(layerRoundTrip, "LayerSettings JSON round-trip")

// 7b. ExtraLayer JSON round-trips on its own (id, blend, clip, PSD source).
do {
    let layer = ExtraLayer(id: UUID(), name: "badge", path: "/tmp/badge-03.webp", enabled: false,
                           opacity: 0.4, blend: .multiply, clipToPhoto: false,
                           transform: OverlayTransform(offsetX: 2, offsetY: 4, scaleX: 0.5, scaleY: 0.6, rotationDeg: -12),
                           psd: PSDOverlaySource(psdPath: "/tmp/badge.psd", counter: 8))
    if let data = try? JSONEncoder().encode(layer),
       let decoded = try? JSONDecoder().decode(ExtraLayer.self, from: data) {
        check(decoded == layer, "ExtraLayer JSON round-trip")
    } else {
        check(false, "ExtraLayer JSON round-trip decode")
    }
}

// 7c. Legacy JSON with the removed `gradient` fields still decodes (ignored).
do {
    let legacy = """
    {
      "enabled": {"layer1": true, "layer2": true, "layer3": false, "layer4": true, "layer5": true, "layer6": true},
      "watermark": {"text": "01", "fontName": ".SFUI-Bold", "sizeFraction": 0.04,
                    "colour": {"red": 1, "green": 1, "blue": 1, "alpha": 1},
                    "opacity": 0.6,
                    "transform": {"offsetFractionX": 0.05, "offsetFractionY": 0.05,
                                  "scaleX": 1, "scaleY": 1, "rotationDeg": 0}},
      "overlay": {"path": "/tmp/o.webp", "fit": true,
                  "transform": {"offsetX": 0, "offsetY": 0, "scaleX": 1, "scaleY": 1, "rotationDeg": 0}},
      "gradient": {"enabled": true,
                   "colorA": {"red": 1, "green": 0, "blue": 0, "alpha": 0.5},
                   "colorB": {"red": 0, "green": 0, "blue": 1, "alpha": 0},
                   "angle": 45, "opacity": 0.8, "blend": "overlay"},
      "bg5": {"path": ""},
      "bg6": {"kind": "colour", "colour": {"red": 1, "green": 1, "blue": 1, "alpha": 1}},
      "psdText": {"path": "", "align": "centre",
                  "box": {"x": 0.1, "y": 0.05, "width": 0.8, "height": 0.2}}
    }
    """
    if let data = legacy.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(LayerSettings.self, from: data) {
        check(decoded.extraLayers.isEmpty, "legacy gradient JSON decodes (extra layers empty)")
        check(decoded.watermark.text == "01", "legacy gradient JSON keeps watermark fields")
    } else {
        check(false, "legacy gradient JSON decodes")
    }
}

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
                                    scaleX: 200.0 / 1200.0, scaleY: 200.0 / 1200.0, rotationDeg: 0)
    )

    var layerSettings = LayerSettings.defaults
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
    } else {
        check(false, "Compositor: render 1200x1800")
    }
}

// Extra-layer compositor checks: list order (top of list = top), clipToPhoto
// clipping, disabled-layer skipping, and drawing between photo and layer 3.
do {
    let canvas = CGSize(width: 1200, height: 1800)
    // Photo: 300x300 fit => 1200x1200 centred. Green, opaque.
    let green = makeSolidImage(width: 300, height: 300, r: 0, g: 1, b: 0)!
    // Extra layer images are 200x200, fit => 1200x1200 (they cover the photo
    // when centred at scale 1). We use two opaque colours and shrink them onto
    // distinct spots so the stacking order is unambiguous.
    let red = makeSolidImage(width: 200, height: 200, r: 1, g: 0, b: 0)!
    let magenta = makeSolidImage(width: 200, height: 200, r: 1, g: 0, b: 1)!
    let redPath = writeTempPNG(red, name: "check-xl-red.png")
    let magentaPath = writeTempPNG(magenta, name: "check-xl-magenta.png")
    defer {
        if !redPath.isEmpty { try? FileManager.default.removeItem(atPath: redPath) }
        if !magentaPath.isEmpty { try? FileManager.default.removeItem(atPath: magentaPath) }
    }

    // Place a 200x200 layer at the canvas centre: fit base is 1200x1200, so
    // scale back to 200/1200 and keep offset 0.
    let small = Double(200.0 / 1200.0)
    // "red" (list top) sits at centre; "magenta" (list bottom) offset up-right.
    let topLayer = ExtraLayer.new(path: redPath)
    var top = topLayer
    top.transform = OverlayTransform(offsetX: 0, offsetY: 0, scaleX: small, scaleY: small, rotationDeg: 0)
    top.clipToPhoto = false

    let bottomLayer = ExtraLayer.new(path: magentaPath)
    var bottom = bottomLayer
    bottom.transform = OverlayTransform(offsetX: 0, offsetY: 0, scaleX: small, scaleY: small, rotationDeg: 0)
    bottom.clipToPhoto = false

    var ls2 = LayerSettings.defaults
    ls2.bg6 = .colour(RGBAColor(red: 0, green: 0, blue: 1))   // blue background
    ls2.overlay = OverlaySettings()                            // no layer-3 image
    ls2.extraLayers = [top, bottom]

    var project = ProjectModel(
        workingFolder: "/tmp/prints",
        files: ["photo.jpg"],
        currentIndex: 0,
        selectedSize: .in4x6,
        edits: EditStore(),
        layerSettings: ls2
    )
    let compositor = Compositor()
    let photoSource: (Int) -> CGImage? = { _ in green }

    if let rendered = compositor.render(project: project, imageIndex: 0,
                                        canvasPixelSize: canvas, photoSource: photoSource) {
        // Both extra layers are identical size/position, so the list-top "red"
        // must win at the centre (drawn last, on top).
        let center = samplePixel(rendered, x: 600, y: 900)
        check(isNear(center.r, 1) && isNear(center.g, 0) && isNear(center.b, 0),
              "Extra layers: list-top layer drawn on top (got \(center))")
        // Background blue shows at a far corner (no photo/extra layer there).
        let corner = samplePixel(rendered, x: 50, y: 50)
        check(isNear(corner.r, 0) && isNear(corner.g, 0) && isNear(corner.b, 1),
              "Extra layers: background visible at corner (got \(corner))")

        // Disable the top layer -> magenta shows at the centre.
        project.layerSettings.extraLayers[0].enabled = false
        if let noTop = compositor.render(project: project, imageIndex: 0,
                                         canvasPixelSize: canvas, photoSource: photoSource) {
            let center2 = samplePixel(noTop, x: 600, y: 900)
            check(isNear(center2.r, 1) && isNear(center2.b, 1) && isNear(center2.g, 0),
                  "Extra layers: disabled layer skipped (got \(center2))")
        } else {
            check(false, "Extra layers: re-render after disabling top layer")
        }

        // Clip-to-photo: a full-canvas layer (fit 1200x1200, scaled up to cover
        // the whole canvas) clipped to the photo must not paint the corner, but
        // paints the photo.
        project.layerSettings.extraLayers = []
        var clip = ExtraLayer.new(path: magentaPath)
        clip.clipToPhoto = true
        clip.transform = OverlayTransform(offsetX: 0, offsetY: 0, scaleX: 2, scaleY: 2, rotationDeg: 0)
        project.layerSettings.extraLayers = [clip]
        if let clipped = compositor.render(project: project, imageIndex: 0,
                                           canvasPixelSize: canvas, photoSource: photoSource) {
            let inPhoto = samplePixel(clipped, x: 600, y: 900)
            check(isNear(inPhoto.r, 1) && isNear(inPhoto.b, 1) && isNear(inPhoto.g, 0),
                  "Extra layers: clipToPhoto paints inside the photo (got \(inPhoto))")
            let outside = samplePixel(clipped, x: 50, y: 50)
            check(isNear(outside.r, 0) && isNear(outside.g, 0) && isNear(outside.b, 1),
                  "Extra layers: clipToPhoto limits to the photo rect (got \(outside))")
        } else {
            check(false, "Extra layers: clipToPhoto render")
        }
    } else {
        check(false, "Extra layers: render 1200x1800")
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

// MARK: - Metadata segment scanners (acceptance checks)

/// Results of a byte-level JPEG marker scan.
struct JPEGSegments {
    var app1Count = 0      // Exif / XMP APP1 markers
    var iccAPP2 = false    // APP2 "ICC_PROFILE" present
    var jfifUnits = -1     // 1 = dots/inch
    var jfifXDensity = -1
    var jfifYDensity = -1
}

/// Walk a JPEG's markers and report APP1 count, ICC APP2 presence, and JFIF
/// density. Returns nil for a malformed file.
func scanJPEGSegments(_ path: String) -> JPEGSegments? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let b = [UInt8](data)
    guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
    var result = JPEGSegments()
    var i = 2
    while i < b.count {
        guard b[i] == 0xFF else { return nil }
        var j = i + 1
        while j < b.count && b[j] == 0xFF { j += 1 }
        guard j < b.count else { return nil }
        let marker = b[j]
        if marker == 0xD9 || marker == 0xDA { break }
        if marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
            i = j + 1
            continue
        }
        guard j + 2 < b.count else { return nil }
        let length = (Int(b[j + 1]) << 8) | Int(b[j + 2])
        guard length >= 2 else { return nil }
        let end = j + 1 + length
        guard end <= b.count else { return nil }
        let payload = Array(b[(j + 3)..<end])
        switch marker {
        case 0xE0:
            if payload.count >= 12, payload[0] == 0x4A, payload[1] == 0x46, payload[2] == 0x49,
               payload[3] == 0x46, payload[4] == 0x00 {
                result.jfifUnits = Int(payload[7])
                result.jfifXDensity = (Int(payload[8]) << 8) | Int(payload[9])
                result.jfifYDensity = (Int(payload[10]) << 8) | Int(payload[11])
            }
        case 0xE1:
            result.app1Count += 1
        case 0xE2:
            if payload.count >= 12, payload[0] == 0x49, payload[1] == 0x43, payload[2] == 0x43,
               payload[3] == 0x5F, payload[4] == 0x50, payload[5] == 0x52, payload[6] == 0x4F,
               payload[7] == 0x46, payload[8] == 0x49, payload[9] == 0x4C, payload[10] == 0x45,
               payload[11] == 0x00 {
                result.iccAPP2 = true
            }
        default:
            break
        }
        i = end
    }
    return result
}

/// Results of a WebP RIFF chunk scan.
struct WebPChunks {
    var hasICCP = false
    var hasEXIF = false
    var hasXMP = false
}

/// Walk a WebP's RIFF chunks and report ICCP / EXIF / XMP presence.
func scanWebPChunks(_ path: String) -> WebPChunks? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let b = [UInt8](data)
    guard b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
          b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 else { return nil }
    var result = WebPChunks()
    var i = 12
    while i + 8 <= b.count {
        let fourcc = String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
        let size = Int(b[i + 4]) | (Int(b[i + 5]) << 8) | (Int(b[i + 6]) << 16) | (Int(b[i + 7]) << 24)
        if fourcc == "ICCP" { result.hasICCP = true }
        if fourcc == "EXIF" { result.hasEXIF = true }
        if fourcc == "XMP " { result.hasXMP = true }
        i += 8 + size + (size & 1)
    }
    return result
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

    // Byte-level segment scan: no APP1 Exif/XMP, ICC APP2 present, JFIF 300 dpi.
    if let segs = scanJPEGSegments(url.path) {
        check(segs.app1Count == 0, "JPG has no APP1 Exif/XMP segments (found \(segs.app1Count))")
        check(segs.iccAPP2, "JPG has an ICC APP2 profile segment")
        check(segs.jfifUnits == 1 && segs.jfifXDensity == 300 && segs.jfifYDensity == 300,
              "JPG JFIF density is 300 dpi (units=\(segs.jfifUnits) xd=\(segs.jfifXDensity) yd=\(segs.jfifYDensity))")
    } else {
        check(false, "JPG segment scan")
    }
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
    if let chunks = scanWebPChunks(out.path) {
        check(chunks.hasICCP, "WebP has an ICCP chunk")
        check(!chunks.hasEXIF && !chunks.hasXMP, "WebP has no EXIF/XMP chunk")
    } else {
        check(false, "WebP RIFF chunk scan")
    }
} else {
    print("[skip] cwebp not found — WebP export check skipped")
}

// MARK: - Cancel export (queued units short-circuit; remaining files unwritten)

do {
    let tmp = makeTempDir("canceltest")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    var files: [URL] = []
    for i in 0..<10 {
        let u = URL(fileURLWithPath: tmp).appendingPathComponent("\(i).png")
        _ = writePNG(makeSolidImage(width: 20, height: 20, r: 0, g: 1, b: 0, a: 1)!, to: u)
        files.append(u)
    }
    let renderStarted = DispatchSemaphore(value: 0)
    let job = ExportJob(
        files: files,
        formats: [.jpg],
        exportRoot: URL(fileURLWithPath: tmp),
        settings: ExportSettings(exportJPG: true, exportWebP: false),
        paperPixelSize: CGSize(width: 40, height: 40),
        sizeLabel: "4x6",
        cwebpPath: "",
        cpuLimit: 1,   // serial queue: later units wait behind the first render
        render: { index, canvas in
            if index == 0 {
                renderStarted.signal()
                Thread.sleep(forTimeInterval: 0.2)
            }
            return makeSolidImage(width: Int(canvas.width), height: Int(canvas.height), r: 1, g: 1, b: 1, a: 1)
        }
    )
    var summary = ExportSummary()
    var done = false
    job.run(resolutions: [:]) { s in summary = s; done = true }
    _ = renderStarted.wait(timeout: .now() + 5)
    job.cancel()
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(summary.cancelled, "cancel marks the summary cancelled")
    check(summary.total == 10, "cancel reports total units (got \(summary.total))")
    check(summary.totalWritten < 10, "cancel stops remaining files (wrote \(summary.totalWritten)/10)")
}

// MARK: - Polish additions (symlink guard, clamp, shrink, PSD paths, concurrent cache)

// 2. Symlink directory loop import terminates (resolved-path guard).
do {
    let tmp = makeTempDir("symlink")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let sub = URL(fileURLWithPath: tmp).appendingPathComponent("sub")
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    // A symlink inside sub pointing back to its ancestor creates a cycle.
    let loop = sub.appendingPathComponent("loop")
    try? FileManager.default.createSymbolicLink(at: loop, withDestinationURL: URL(fileURLWithPath: tmp))
    makeFile(sub.appendingPathComponent("a.jpg").path, [1])
    let collected = DirectoryScan.collectFiles(from: [URL(fileURLWithPath: tmp)]) {
        $0.pathExtension.lowercased() == "jpg"
    }
    check(collected.count == 1, "DirectoryScan terminates on symlink loop (found \(collected.count))")
}

// 3. AppSettings numeric fields clamp to bounds.
do {
    var s = AppSettings.defaults
    s.rotateStep = 99
    s.scrollZoomSpeed = -5
    s.scrollRotateSpeed = 0
    s.doubleTapMs = 5
    let c = s.clamped()
    check(c.rotateStep == 1.5, "clamp rotateStep to 1.5 (got \(c.rotateStep))")
    check(c.scrollZoomSpeed > 0, "clamp scrollZoomSpeed > 0 (got \(c.scrollZoomSpeed))")
    check(c.scrollRotateSpeed > 0, "clamp scrollRotateSpeed > 0 (got \(c.scrollRotateSpeed))")
    check(c.doubleTapMs == 100, "clamp doubleTapMs to 100 (got \(c.doubleTapMs))")
}

// 4. Layer-2 text wider than the box shrinks to fit, never below minTextScale.
do {
    final class WideRunner: PhotoshopRunnerProtocol {
        let width: Int
        init(width: Int) { self.width = width }
        func renderPNG(psdPath: String, text: String?, layerName: String, outputPNG: String) -> Bool {
            guard let img = makeSolidImage(width: width, height: 40, r: 1, g: 1, b: 1, a: 1) else { return false }
            return writePNG(img, to: URL(fileURLWithPath: outputPNG))
        }
    }
    let tmp = makeTempDir("shrink")
    let psdPath = tmp + "/template.psd"
    makeFile(psdPath, [0x38, 0x42, 0x50, 0x53])
    let renderer = PSDTextLayerRenderer(runner: WideRunner(width: 1000), cacheDirectory: tmp,
                                        layerName: "TEXT", minTextScale: 0.5)
    let image = renderer.render(psdPath: psdPath, text: "Norman", boxSize: CGSize(width: 400, height: 100))
    check(image?.width == 500, "layer-2 text shrinks to minTextScale bound (got \(image?.width ?? 0), expected 500)")
    check(PSDTextLayerRenderer.shrinkScale(imageWidth: 1000, boxWidth: 400, minScale: 0.5) == 0.5,
          "shrinkScale clamps to min 0.5")
    check(PSDTextLayerRenderer.shrinkScale(imageWidth: 100, boxWidth: 400, minScale: 0.5) == 1,
          "shrinkScale leaves fitting text unchanged")
    // Short boxes constrain the shrink too (height-aware), never below minScale.
    check(PSDTextLayerRenderer.shrinkScale(imageSize: CGSize(width: 100, height: 1000),
                                           boxSize: CGSize(width: 200, height: 400), minScale: 0.5) == 0.5,
          "shrinkScale is height-aware and clamps to min 0.5")
    check(PSDTextLayerRenderer.shrinkScale(imageSize: CGSize(width: 100, height: 200),
                                           boxSize: CGSize(width: 200, height: 400), minScale: 0.5) == 1,
          "shrinkScale leaves fitting (width+height) text unchanged")
    let wrapped = PSDTextFit.wrap("aaaa bbbb cccc dddd", maxLines: 2,
                                  maxWidth: PSDTextFit.measureWidth("aaaa bbbb"))
    check(wrapped.contains("\n"), "PSDTextFit.wrap is width-aware (got \(wrapped.replacingOccurrences(of: "\n", with: "|")))")
}

// 5. Layer-2 + layer-3 PSD paths survive a project JSON round-trip.
do {
    var model = ProjectModel(workingFolder: "/tmp/prints", files: ["a.jpg"], selectedSize: .in4x6)
    model.layerSettings.psdText.path = "/tmp/text.psd"
    model.overlayPSDPath = "/tmp/overlay.psd"
    model.overlayCounter = 7
    if let data = try? JSONEncoder().encode(model),
       let decoded = try? JSONDecoder().decode(ProjectModel.self, from: data) {
        check(decoded == model, "ProjectModel round-trips layer-2/3 PSD paths")
        check(decoded.layerSettings.psdText.path == "/tmp/text.psd", "layer-2 PSD path persisted")
        check(decoded.overlayPSDPath == "/tmp/overlay.psd", "layer-3 overlay PSD path persisted")
    } else {
        check(false, "ProjectModel PSD-path round-trip decode")
    }
}

// 7. Concurrent decode of one URL keeps ImageCache byte count consistent.
do {
    let tmp = makeTempDir("concurrent")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let url = URL(fileURLWithPath: writeTempPNG(makeSolidImage(width: 200, height: 200, r: 1, g: 0, b: 0, a: 1)!, name: "conc.png"))
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = ImageCache(ramCapBytes: 10_000_000)
    let group = DispatchGroup()
    let lock = NSLock()
    var firstImage: CGImage?
    for _ in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            let img = cache.preview(url: url)
            lock.lock()
            if firstImage == nil { firstImage = img }
            lock.unlock()
            group.leave()
        }
    }
    _ = group.wait(timeout: .now() + 10)
    if let img = firstImage {
        let expected = img.bytesPerRow * img.height
        check(cache.ramUsageBytes() == expected,
              "ImageCache byte count consistent under concurrent decode (got \(cache.ramUsageBytes()), expected \(expected))")
    } else {
        check(false, "ImageCache concurrent decode produced an image")
    }
}

// 8. Undo history is per image and cleared when switching images (SPEC §2).
do {
    var history = ImageUndoHistory()
    history.push(fileName: "a.jpg", value: ImageEdit(offsetX: 1))
    history.push(fileName: "a.jpg", value: ImageEdit(offsetX: 2))
    history.push(fileName: "b.jpg", value: ImageEdit(offsetX: 3))
    check(history.depth(fileName: "a.jpg") == 2 && history.depth(fileName: "b.jpg") == 1,
          "ImageUndoHistory retains per-image steps")
    // Undo one step on the current image still works.
    let undone = history.undo(fileName: "a.jpg", current: ImageEdit(offsetX: 9))
    check(undone?.offsetX == 2, "ImageUndoHistory undo returns previous step (got \(undone?.offsetX ?? -1))")
    // Switching images clears all history.
    history.clear()
    check(history.isEmpty && history.depth(fileName: "a.jpg") == 0 && history.depth(fileName: "b.jpg") == 0,
          "ImageUndoHistory cleared when switching images")
}

// 9. Cancel path restores the original bytes unchanged (fake watcher flow).
do {
    let tmp = makeTempDir("cancel")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let original = URL(fileURLWithPath: tmp).appendingPathComponent("photo.jpg")
    let backup = URL(fileURLWithPath: tmp).appendingPathComponent("pp-orig-photo.jpg")
    let originalBytes: [UInt8] = Array("ORIGINAL".utf8)
    let editedBytes: [UInt8] = Array("EDITED-EDITED".utf8)
    makeFile(original.path, originalBytes)
    // Simulate the pre-edit backup + Photoshop modifying the original in place.
    try? FileManager.default.copyItem(at: original, to: backup)
    makeFile(original.path, editedBytes)

    let restored = PhotoEditSave.cancel(original: original, backup: backup, hadBackup: true)
    let after = try? Data(contentsOf: original)
    check(restored, "PhotoEditSave.cancel reports a restore")
    check(after?.elementsEqual(originalBytes) == true,
          "Cancel path leaves original bytes unchanged")
    check(!FileManager.default.fileExists(atPath: backup.path),
          "Cancel path removes the temporary backup")
}

// 10. Save-as-new-version re-encodes (never a raw byte copy under .webp).
do {
    let tmp = makeTempDir("savenew")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let original = URL(fileURLWithPath: tmp).appendingPathComponent("photo.jpg")
    let backup = URL(fileURLWithPath: tmp).appendingPathComponent("pp-orig-photo.jpg")
    // Both the untouched original and the edited copy are valid decodable images.
    _ = writePNG(makeSolidImage(width: 40, height: 40, r: 1, g: 0, b: 0, a: 1)!, to: original)
    let originalBytes = try? Data(contentsOf: original)
    try? FileManager.default.copyItem(at: original, to: backup)
    _ = writePNG(makeSolidImage(width: 30, height: 30, r: 0, g: 1, b: 0, a: 1)!, to: original)
    let editedBytes = try? Data(contentsOf: original)

    // The encoder must be the one writing the output (re-encoded), not a copy.
    // Re-encode to a different size so the output provably differs from the
    // edited file's raw bytes (mirrors real WebP re-encoding).
    var encodedCalled = false
    let wrote = PhotoEditSave.saveAsNewVersion(original: original, backup: backup, hadBackup: true,
                                               number: 0) { _, url in
        encodedCalled = true
        return writePNG(makeSolidImage(width: 99, height: 99, r: 0, g: 0, b: 1, a: 1)!, to: url)
    }
    let out = WebPNumbering.outputURL(psdURL: original, number: 0)
    check(wrote && encodedCalled, "Save-as-new-version re-encodes the edited copy")
    check(FileManager.default.fileExists(atPath: out.path),
          "Save-as-new-version writes the numbered file")
    // The output is a re-encoded image, not a raw copy of the edited bytes.
    if let data = try? Data(contentsOf: out), let edited = editedBytes {
        check(data != edited, "Save-as-new-version does not raw-copy edited bytes")
    } else {
        check(false, "Save-as-new-version output readable")
    }
    // The original photo is restored untouched.
    let after = try? Data(contentsOf: original)
    check(after == originalBytes,
          "Save-as-new-version restores the original photo untouched")
}

// MARK: - Milestone 6 additions (doJavascript fix, copy flow, overlay box geometry)

// 1. JXA wrapper uses lowercase `doJavascript(` (the -1708 "Message not
//    understood" fix).
do {
    let jxa = PhotoshopRunner.makeJXAScript(jsx: "var x = 1;", appName: "Adobe Photoshop 2026")
    check(jxa.contains("doJavascript("), "JXA script uses doJavascript( (lowercase s)")
    check(!jxa.contains("doJava" + "Script("), "JXA script has no capital-S variant")
}

// 2. Render JSX copies the PSD to a temp file, restores the previously active
//    document, and never closes or saves a document it did not open itself.
do {
    let jsx = PhotoshopRunner.makeJSX(psdPath: "/tmp/a.psd", text: "Norman", layerName: "TEXT",
                                      outputPNG: "/tmp/out.png", copyPath: "/tmp/copy.psd")
    check(jsx.contains(".copy("), "render JSX contains the copy flow (srcFile.copy(copyFile))")
    check(jsx.contains("previousDoc = app.activeDocument")
          && jsx.contains("app.activeDocument = previousDoc"),
          "render JSX remembers and restores the active document")
    check(!jsx.contains("activeDocument.close"),
          "render JSX never closes the previously active document")
    check(jsx.contains("doc.close("),
          "render JSX closes only the copy it opened")
    check(!jsx.contains("doc.save(") && !jsx.contains("activeDocument.save("),
          "render JSX never saves a document")
}

// 3. Layer-3 overlay selection box corners equal the Compositor's transformed
//    image corners (tolerance 0.5 px) at rotation 0, 17 and -90.
do {
    let canvas = CGSize(width: 1200, height: 1800)
    let imageSize = CGSize(width: 300, height: 200)
    for rot in [0.0, 17.0, -90.0] {
        let overlay = OverlaySettings(path: "/tmp/o.webp", fit: true,
                                      transform: OverlayTransform(offsetX: 40, offsetY: -25,
                                                                  scaleX: 1.2, scaleY: 0.8, rotationDeg: rot))
        let got = LayerGeometry.overlayCorners(canvas: canvas, imageSize: imageSize, overlay: overlay)
        let base = LayerGeometry.fittedRect(canvas: canvas, imageSize: imageSize)
        let local = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
        let t = LayerGeometry.centeredTransform(canvas: canvas,
                                                offsetX: overlay.transform.offsetX,
                                                offsetY: overlay.transform.offsetY,
                                                scaleX: overlay.transform.scaleX,
                                                scaleY: overlay.transform.scaleY,
                                                rotationDeg: overlay.transform.rotationDeg)
        let expected = LayerGeometry.corners(of: local, transform: t)
        var ok = got.count == 4 && expected.count == 4
        if ok {
            for i in 0..<4 {
                if hypot(got[i].x - expected[i].x, got[i].y - expected[i].y) > 0.5 { ok = false }
            }
        }
        check(ok, "overlay box corners == Compositor corners at rotation \(rot)")
    }
}

// 4. Watermark box corners stay consistent with its drawn rect (rotated quad,
//    not an axis-aligned bounding box).
do {
    let canvas = CGSize(width: 1200, height: 1800)
    let wm = WatermarkSettings(text: "01", sizeFraction: 0.04,
                               transform: WatermarkTransform(offsetFractionX: 0.05, offsetFractionY: 0.05,
                                                             scaleX: 1, scaleY: 1, rotationDeg: 45))
    let corners = LayerGeometry.watermarkCorners(canvas: canvas, watermark: wm)
    check(corners.count == 4, "watermark corners computed")
    let rect = LayerGeometry.watermarkRect(canvas: canvas, watermark: wm)
    let box = LayerGeometry.boundingBox(of: corners)
    let near = abs(box.minX - rect.minX) < 0.01 && abs(box.minY - rect.minY) < 0.01
        && abs(box.width - rect.width) < 0.01 && abs(box.height - rect.height) < 0.01
    check(near, "watermark corners bounding box matches watermarkRect")
}

// MARK: - NO EXPORT + Preview full + interactive fast path

// 1. ProjectModel noExport round-trips.
do {
    var model = ProjectModel(workingFolder: "/tmp/prints", files: ["a.jpg", "b.jpg", "c.jpg"], selectedSize: .in4x6)
    model.noExport = ["a.jpg", "c.jpg"]
    if let data = try? JSONEncoder().encode(model),
       let decoded = try? JSONDecoder().decode(ProjectModel.self, from: data) {
        check(decoded == model, "ProjectModel round-trips noExport set")
        check(decoded.noExport == ["a.jpg", "c.jpg"], "noExport persists file names")
    } else {
        check(false, "ProjectModel noExport round-trip decode")
    }
}

// 2. ExportJob skips flagged files and reports skipped.
do {
    let tmp = makeTempDir("noexport")
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    var files: [URL] = []
    for i in 0..<5 {
        let u = URL(fileURLWithPath: tmp).appendingPathComponent("\(i).png")
        _ = writePNG(makeSolidImage(width: 40, height: 60, r: 0, g: 1, b: 0, a: 1)!, to: u)
        files.append(u)
    }
    let job = ExportJob(
        files: files,
        formats: [.jpg],
        exportRoot: URL(fileURLWithPath: tmp),
        settings: ExportSettings(exportJPG: true, exportWebP: false),
        paperPixelSize: CGSize(width: 120, height: 180),
        sizeLabel: "4x6",
        cwebpPath: "",
        cpuLimit: 0,
        render: { _, canvas in makeSolidImage(width: Int(canvas.width), height: Int(canvas.height), r: 1, g: 1, b: 1, a: 1) },
        noExport: ["0.png", "2.png"]
    )
    var summary = ExportSummary()
    var done = false
    job.run(resolutions: [:]) { s in summary = s; done = true }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(summary.jpgWritten == 3, "ExportJob exports 3 of 5 when 2 are flagged (got \(summary.jpgWritten))")
    check(summary.skipped == 2, "ExportJob reports 2 skipped (got \(summary.skipped))")
}

// 3. Interactive preview benchmark: 3600x3000 canvas, 1000px preview, cached
//    static layers; 50 transform-change frames; median <= 16 ms.
do {
    var layerSettings = LayerSettings.defaults
    layerSettings.bg6 = .colour(RGBAColor(red: 1, green: 1, blue: 1))
    let project = ProjectModel(
        workingFolder: "/tmp/prints",
        files: ["photo.jpg"],
        currentIndex: 0,
        selectedSize: .in12x10,
        edits: EditStore(),
        layerSettings: layerSettings
    )
    let photo = makeSolidImage(width: 2000, height: 1500, r: 0.2, g: 0.4, b: 0.8, a: 1)!
    let preview = CGSize(width: 1000, height: 833)
    let renderer = InteractivePreviewRenderer()
    renderer.prepare(project: project, imageIndex: 0, canvasPixelSize: preview)

    var samples: [Double] = []
    for i in 0..<50 {
        let edit = ImageEdit(scale: 1 + Double(i % 7) * 0.1,
                             offsetX: Double(i % 5) * 7 - 14,
                             offsetY: Double(i % 3) * 11 - 11,
                             rotationDeg: Double(i % 9) * 2 - 8)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let frame = renderer.renderFrame(edit: edit, photo: photo)
        let t1 = DispatchTime.now().uptimeNanoseconds
        if frame == nil { check(false, "interactive frame produced an image") }
        samples.append(Double(t1 - t0) / 1_000_000.0)
    }
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    print("interactive preview median = \(String(format: "%.3f", median)) ms")
    check(median <= 16.0, "interactive preview median <= 16 ms (got \(String(format: "%.3f", median)) ms)")
}

// 4. NO EXPORT visuals never affect rendered output (Compositor ignores the flag).
do {
    var ls = LayerSettings.defaults
    ls.bg6 = .colour(RGBAColor(red: 1, green: 0, blue: 0))
    var base = ProjectModel(workingFolder: "/tmp/prints", files: ["photo.jpg"],
                            selectedSize: .in4x6, layerSettings: ls)
    let compositor = Compositor()
    let photo = makeSolidImage(width: 200, height: 200, r: 0, g: 1, b: 0, a: 1)!
    let canvas = CGSize(width: 120, height: 180)
    let a = compositor.render(project: base, imageIndex: 0, canvasPixelSize: canvas, photoSource: { _ in photo })
    base.noExport = ["photo.jpg"]
    let b = compositor.render(project: base, imageIndex: 0, canvasPixelSize: canvas, photoSource: { _ in photo })
    var identical = a != nil && b != nil
    if identical {
        for p in [(x: 60, y: 90), (x: 10, y: 10), (x: 110, y: 170)] {
            let pa = samplePixel(a!, x: p.x, y: p.y)
            let pb = samplePixel(b!, x: p.x, y: p.y)
            if !(isNear(pa.r, pb.r) && isNear(pa.g, pb.g) && isNear(pa.b, pb.b)) { identical = false }
        }
    }
    check(identical, "Compositor output identical with noExport flag on/off")
}

if failures == 0 {
    print("PrintProcessorCheck: PASS")
    exit(0)
} else {
    print("PrintProcessorCheck: \(failures) FAILURE(S)")
    exit(1)
}
