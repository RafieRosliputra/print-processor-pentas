import Foundation

/// Numeric-aware ordering for file names: "2.jpg" sorts before "10.jpg",
/// "photo2" before "photo10", and equal numbers break ties on the shorter
/// numeric literal ("1" before "01").
public enum NaturalSort {
    /// Whether `lhs` should come before `rhs` in natural order.
    public static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// A sorted copy of the given names.
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted(by: isOrderedBefore)
    }

    /// A comparator usable with `Sequence.sorted(by:)`.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = chunks(lhs)
        let b = chunks(rhs)
        let n = min(a.count, b.count)
        for i in 0..<n {
            let l = a[i]
            let r = b[i]
            if let ln = l.number, let rn = r.number {
                if ln != rn {
                    return ln < rn ? .orderedAscending : .orderedDescending
                }
                if l.text.count != r.text.count {
                    return l.text.count < r.text.count ? .orderedAscending : .orderedDescending
                }
                continue
            }
            let c = l.text.compare(r.text, options: [.caseInsensitive, .numeric])
            if c != .orderedSame { return c }
        }
        if a.count < b.count { return .orderedAscending }
        if a.count > b.count { return .orderedDescending }
        return .orderedSame
    }

    private struct Chunk {
        let text: String
        let number: UInt64?
    }

    private static func chunks(_ s: String) -> [Chunk] {
        var result: [Chunk] = []
        var current = ""
        var currentIsDigit = false
        for ch in s {
            let isDigit = ch.isNumber && ch.isASCII
            if current.isEmpty || isDigit == currentIsDigit {
                current.append(ch)
                currentIsDigit = isDigit
            } else {
                result.append(Chunk(text: current, number: currentIsDigit ? UInt64(current) : nil))
                current = String(ch)
                currentIsDigit = isDigit
            }
        }
        if !current.isEmpty {
            result.append(Chunk(text: current, number: currentIsDigit ? UInt64(current) : nil))
        }
        return result
    }
}
