import Foundation

enum SafeDisplayNumber {
    static func integer(_ value: Double, rounding: FloatingPointRoundingRule = .down) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded(rounding)
        if rounded >= Double(Int.max) { return Int.max }
        return Int(rounded)
    }

    static func bytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        // Double(UInt64.max) rounds up to 2^64, so never convert that bound.
        if rounded >= Double(UInt64.max) { return UInt64.max }
        return UInt64(rounded)
    }
}
