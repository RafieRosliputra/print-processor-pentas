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

if failures == 0 {
    print("PrintProcessorCheck: PASS")
    exit(0)
} else {
    print("PrintProcessorCheck: \(failures) FAILURE(S)")
    exit(1)
}
