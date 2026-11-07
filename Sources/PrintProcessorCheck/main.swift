import Foundation
import PrintProcessorCore

// Tiny self-check that verifies PaperSize pixel math and the AppSettings defaults.
// Exits non-zero on the first mismatch so it can be used as a build/test gate.

var failures = 0

func expect(_ size: PaperSize, _ width: Int, _ height: Int) {
    let ok = size.pixelWidth == width && size.pixelHeight == height
    let mark = ok ? "ok" : "FAIL"
    print("[\(mark)] \(size.label) -> \(size.pixelWidth)x\(size.pixelHeight) (expected \(width)x\(height))")
    if !ok { failures += 1 }
}

expect(.in4x6, 1200, 1800)
expect(.in5x7, 1500, 2100)
expect(.in8x10, 2400, 3000)
expect(.in8x12, 2400, 3600)
expect(.in8x15, 2400, 4500)
expect(.in11x14, 3300, 4200)
expect(.in12x16, 3600, 4800)
expect(.in12x10, 3600, 3000)

let d = AppSettings.defaults
let defaultsOK = d.doubleTapMs == 300 && d.rotateStep == 0.1 && d.tooltipDelay == 0.5 && d.nudgeBasis == .export
print(defaultsOK ? "[ok] AppSettings defaults" : "[FAIL] AppSettings defaults")
if !defaultsOK { failures += 1 }

if failures == 0 {
    print("PrintProcessorCheck: PASS")
    exit(0)
} else {
    print("PrintProcessorCheck: \(failures) FAILURE(S)")
    exit(1)
}
