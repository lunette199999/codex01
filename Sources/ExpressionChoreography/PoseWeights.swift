import Foundation

/// Selects individual members of `PoseWeights`, used to describe which parts of
/// an overlay a policy may hold back — for example while playback owns the mouth.
public struct PoseComponents: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let smile = PoseComponents(rawValue: 1 << 0)
    public static let rest = PoseComponents(rawValue: 1 << 1)
    public static let pressed = PoseComponents(rawValue: 1 << 2)
    public static let parted = PoseComponents(rawValue: 1 << 3)
    public static let all: PoseComponents = [.smile, .rest, .pressed, .parted]

    /// The component speech already owns in 0.3.4: `ExpressionPose.mouthOpening`
    /// reads `parted` for the resting aperture and `RestMouthReturn` scales it
    /// back in after playback. The module simply stops *driving* that component
    /// while speech is active; the host keeps owning when it becomes visible again.
    public static let speechOwned: PoseComponents = [.parted]

    /// A stricter mask for sequences that also want the pressed-lip texture held
    /// back while a sentence plays. Not the default, because the shipped app does
    /// not suppress a pressed-lips selection during playback either.
    public static let speechOwnedStrict: PoseComponents = [.parted, .pressed]
}

/// The four blend weights the existing renderer consumes, mirroring the host's
/// `ExpressionPose`.
///
/// Members are sanitised on construction: a non-finite input becomes `0` and
/// everything is clamped to `0...1`. A NaN arriving from an external clock or a
/// malformed sequence therefore cannot reach the renderer or poison a blend.
public struct PoseWeights: Equatable, Hashable, Sendable {
    public let smile: Double
    public let rest: Double
    public let pressed: Double
    public let parted: Double

    public init(smile: Double = 0, rest: Double = 0, pressed: Double = 0, parted: Double = 0) {
        self.smile = PoseWeights.clamped(smile)
        self.rest = PoseWeights.clamped(rest)
        self.pressed = PoseWeights.clamped(pressed)
        self.parted = PoseWeights.clamped(parted)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// No contribution at all: what the overlay is worth when nothing is running.
    public static let identity = PoseWeights()

    public var total: Double { smile + rest + pressed + parted }
    public var isIdentity: Bool { total <= 1e-9 }

    public func scaled(by factor: Double) -> PoseWeights {
        guard factor.isFinite else { return .identity }
        let k = min(1, max(0, factor))
        return PoseWeights(smile: smile * k, rest: rest * k, pressed: pressed * k, parted: parted * k)
    }

    /// Straight linear interpolation towards `other`. `progress` is clamped, so a
    /// stalled or duplicated frame can never overshoot the target pose.
    public func blended(to other: PoseWeights, progress: Double) -> PoseWeights {
        guard progress.isFinite else { return self }
        let t = min(1, max(0, progress))
        if t <= 0 { return self }
        if t >= 1 { return other }
        return PoseWeights(smile: smile + (other.smile - smile) * t,
                           rest: rest + (other.rest - rest) * t,
                           pressed: pressed + (other.pressed - pressed) * t,
                           parted: parted + (other.parted - parted) * t)
    }

    /// Zeroes the listed components and leaves the rest untouched.
    public func masking(_ components: PoseComponents) -> PoseWeights {
        guard !components.isEmpty else { return self }
        return PoseWeights(smile: components.contains(.smile) ? 0 : smile,
                           rest: components.contains(.rest) ? 0 : rest,
                           pressed: components.contains(.pressed) ? 0 : pressed,
                           parted: components.contains(.parted) ? 0 : parted)
    }

    /// Largest single-component difference. Used by tests to assert that nothing
    /// jumps when a sequence is interrupted or cancelled.
    public func maximumDifference(from other: PoseWeights) -> Double {
        max(max(abs(smile - other.smile), abs(rest - other.rest)),
            max(abs(pressed - other.pressed), abs(parted - other.parted)))
    }

    /// Lays `overlay` on top of `base` using the base's remaining headroom.
    ///
    /// The renderer treats these four numbers as blend weights over existing
    /// photo layers, and the shipped self-test already asserts that a mid
    /// cross-fade keeps `smile + pressed <= 1`. Scaling the base down by exactly
    /// the overlay's own weight preserves that, and a full-strength overlay is an
    /// ordinary cross-fade rather than an addition on top.
    ///
    /// With `o = min(1, overlay.total)` the result totals `base.total + o * (1 -
    /// base.total)`, so:
    ///
    /// * `base.total <= 1`  ⇒  `result.total <= 1`. Every pose the host can
    ///   produce — a `ExpressionPose.target` value or a cross-fade between two of
    ///   them — is in this case, so the budget always holds in practice.
    /// * `base.total > 1`   ⇒  `result.total <= base.total`. The module cannot
    ///   repair a base pose that was already over budget, but it is guaranteed
    ///   never to make one worse.
    public static func layer(base: PoseWeights, overlay: PoseWeights) -> PoseWeights {
        let share = min(1, overlay.total)
        if share <= 0 { return base }
        let keep = 1 - share
        return PoseWeights(smile: base.smile * keep + overlay.smile,
                           rest: base.rest * keep + overlay.rest,
                           pressed: base.pressed * keep + overlay.pressed,
                           parted: base.parted * keep + overlay.parted)
    }
}
