import Foundation

/// Print paper sizes, in inches, with pixel dimensions at the fixed 300 dpi export density.
public enum PaperSize: String, CaseIterable, Codable {
    case in4x6
    case in5x7
    case in8x10
    case in8x12
    case in8x15
    case in11x14
    case in12x16
    case in12x10

    /// Export density used everywhere in the app.
    public static let dpi = 300

    public var inches: (width: Double, height: Double) {
        switch self {
        case .in4x6: return (4, 6)
        case .in5x7: return (5, 7)
        case .in8x10: return (8, 10)
        case .in8x12: return (8, 12)
        case .in8x15: return (8, 15)
        case .in11x14: return (11, 14)
        case .in12x16: return (12, 16)
        case .in12x10: return (12, 10)
        }
    }

    public var inchesWidth: Double { inches.width }
    public var inchesHeight: Double { inches.height }

    public var pixelWidth: Int { Int((inches.width * Double(Self.dpi)).rounded()) }
    public var pixelHeight: Int { Int((inches.height * Double(Self.dpi)).rounded()) }

    /// Short label used on the size buttons, e.g. "4x6".
    public var label: String {
        switch self {
        case .in4x6: return "4x6"
        case .in5x7: return "5x7"
        case .in8x10: return "8x10"
        case .in8x12: return "8x12"
        case .in8x15: return "8x15"
        case .in11x14: return "11x14"
        case .in12x16: return "12x16"
        case .in12x10: return "12x10"
        }
    }
}
