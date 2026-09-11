import Foundation

/// SplitMix64: a small, fully specified generator so one seed reproduces a run
/// bit for bit on every platform and every process.
///
/// `Swift.Hasher` and `Double.random(in:)` are avoided on purpose — both are
/// seeded per process, which would make "same time, same seed, same output"
/// untestable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)` using the top 53 bits, so the result is exact.
    public mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func next(in range: ClosedRange<Double>) -> Double {
        next(between: range.lowerBound, and: range.upperBound)
    }

    /// Takes loose bounds rather than a `ClosedRange`, so a reversed or
    /// non-finite pair degrades instead of trapping in the standard library.
    public mutating func next(between first: Double, and second: Double) -> Double {
        let low = min(first, second), high = max(first, second)
        guard low.isFinite, high.isFinite, high > low else { return low.isFinite ? low : 0 }
        return low + (high - low) * nextUnitInterval()
    }

    public mutating func nextIndex(below count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(next() % UInt64(count))
    }
}

/// FNV-1a over UTF-8. Stable across processes, unlike `String.hashValue`.
public enum StableHash {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
