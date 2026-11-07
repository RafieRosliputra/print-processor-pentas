import Foundation
import PrintProcessorCore

// Self-check for the layer-4 milestone: PaperSize pixel math, AppSettings defaults,
// NaturalSort, UndoStack bounds, per-size edit independence, and ProjectModel JSON.
// Exits non-zero on the first mismatch so it can be used as a build/test gate.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print(condition ? "[ok] \(label)" : "[FAIL] \(label)")
    if !condition { failures += 1 }
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

if failures == 0 {
    print("PrintProcessorCheck: PASS")
    exit(0)
} else {
    print("PrintProcessorCheck: \(failures) FAILURE(S)")
    exit(1)
}
