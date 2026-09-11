import Foundation

/// What a step asks of the eyes.
public enum StepBlink: Equatable, Hashable, Sendable {
    /// Leave the eyes to the host's existing `BlinkClock`.
    case inherit
    /// Force a blink value for the whole step. `hold(0)` keeps the eyes open
    /// through a pose that would otherwise be interrupted by an automatic blink.
    case hold(Double)
    /// Ask the host to start one ordinary blink as the step begins. The module
    /// reports the request once; the host's `BlinkClock.trigger(at:)` still owns
    /// the shape and duration of the blink itself.
    case triggerOnEnter
}

/// One beat of a sequence: reach a pose, then stay there.
///
/// `blend` is measured from whatever the overlay currently shows, not from a
/// neutral pose, so a step that starts mid-interruption continues from the
/// visible state instead of snapping back to natural first.
public struct ChoreographyStep: Equatable, Hashable, Sendable {
    /// `nil` means "return to the host's base pose", i.e. an overlay of zero.
    public var pose: ExpressionKey?
    /// Scales the pose weights, `0...1`.
    public var intensity: Double
    /// Seconds to reach the pose. `0` applies it on the next frame.
    public var blend: Double
    /// Seconds to stay on the pose once reached.
    public var hold: Double
    public var easing: Easing
    public var blink: StepBlink
    /// Free-form name, surfaced in notices and in the demo output.
    public var label: String

    public init(_ pose: ExpressionKey?,
                intensity: Double = 1,
                blend: Double = 0.38,
                hold: Double = 0,
                easing: Easing = .smoothStep,
                blink: StepBlink = .inherit,
                label: String = "") {
        self.pose = pose
        self.intensity = intensity
        self.blend = blend
        self.hold = hold
        self.easing = easing
        self.blink = blink
        self.label = label
    }

    public var duration: Double { blend + hold }

    /// Clamps every number into the documented range. Anything non-finite
    /// collapses to zero rather than propagating.
    public func sanitised() -> ChoreographyStep {
        var copy = self
        copy.intensity = ChoreographyLimits.clamp(intensity, 0, 1, fallback: 0)
        copy.blend = ChoreographyLimits.clamp(blend, 0, ChoreographyLimits.maximumStepBlend, fallback: 0)
        copy.hold = ChoreographyLimits.clamp(hold, 0, ChoreographyLimits.maximumStepHold, fallback: 0)
        if case .hold(let value) = blink {
            copy.blink = .hold(ChoreographyLimits.clamp(value, 0, 1, fallback: 0))
        }
        if copy.label.count > ChoreographyLimits.maximumLabelLength {
            copy.label = String(copy.label.prefix(ChoreographyLimits.maximumLabelLength))
        }
        return copy
    }

    /// The overlay weights this step settles on.
    public func target(in vocabulary: PoseVocabulary) -> PoseWeights {
        guard let pose else { return .identity }
        return vocabulary.weights(for: pose).scaled(by: intensity)
    }
}

/// Every hard bound the module enforces, in one place.
public enum ChoreographyLimits {
    public static let maximumSteps = 32
    public static let maximumStepBlend = 10.0
    public static let maximumStepHold = 30.0
    public static let maximumSequenceDuration = 180.0
    public static let maximumRepeatCount = 64
    public static let maximumQueueDepth = 8
    public static let maximumIdentifierLength = 64
    public static let maximumLabelLength = 48
    /// Guard against a pathological sequence of zero-length steps spinning the
    /// per-frame advance loop.
    public static let maximumStepsPerFrame = 256

    static func clamp(_ value: Double, _ low: Double, _ high: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(high, max(low, value))
    }
}
