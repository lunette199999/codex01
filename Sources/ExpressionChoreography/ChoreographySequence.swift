import Foundation

/// How many times the step list runs.
public enum RepeatMode: Equatable, Hashable, Sendable {
    case once
    case count(Int)
    /// Runs until something cancels or preempts it. Only sensible for a low
    /// priority mood; the module will still release it on hide, sleep or a
    /// large time gap.
    case forever
}

/// What happens when a sequence arrives and the channel is already taken.
public enum Admission: String, Hashable, Sendable {
    /// Take the channel from an equal or lower priority sequence; give up
    /// against a higher one.
    case preempt
    /// Only start if nothing is running. Never interrupts.
    case rejectIfBusy
    /// Wait in a bounded queue. The queue is dropped whenever the window hides,
    /// the machine sleeps or a large time gap is detected, so a resume never
    /// replays a backlog.
    case enqueue
}

/// What the overlay does when a sequence stops early.
public enum CancelBehavior: Equatable, Hashable, Sendable {
    /// Fade from whatever is on screen right now back to the host's base pose.
    /// Never jumps to neutral first.
    case release(blend: Double)
    /// Drop the overlay within the same frame. Correct only when nothing is
    /// visible; the director uses it internally when the window hides.
    case immediate
}

/// Deterministic per-iteration variation, expressed as multipliers.
///
/// Randomness is opt-in and always comes from the injected seed, so the same
/// seed and the same time steps reproduce the same frames.
///
/// The bounds are stored as plain numbers rather than a `ClosedRange` on
/// purpose: `1.2...0.8` traps inside the standard library at the call site,
/// before this module could clamp it. Here a reversed or non-finite pair is
/// repaired by `sanitised()` instead of crashing the app.
public struct StepJitter: Equatable, Hashable, Sendable {
    public var minimumBlendScale: Double
    public var maximumBlendScale: Double
    public var minimumHoldScale: Double
    public var maximumHoldScale: Double

    public init(minimumBlendScale: Double = 1, maximumBlendScale: Double = 1,
                minimumHoldScale: Double = 1, maximumHoldScale: Double = 1) {
        self.minimumBlendScale = minimumBlendScale
        self.maximumBlendScale = maximumBlendScale
        self.minimumHoldScale = minimumHoldScale
        self.maximumHoldScale = maximumHoldScale
    }

    /// Convenience for the readable `0.9...1.2` spelling. Building the range is
    /// the caller's own expression, so keep the bounds in order.
    public init(blend: ClosedRange<Double>, hold: ClosedRange<Double>) {
        self.init(minimumBlendScale: blend.lowerBound, maximumBlendScale: blend.upperBound,
                  minimumHoldScale: hold.lowerBound, maximumHoldScale: hold.upperBound)
    }

    /// Finite, ordered, and inside `0...4`.
    public func sanitised() -> StepJitter {
        let blend = StepJitter.repair(minimumBlendScale, maximumBlendScale)
        let hold = StepJitter.repair(minimumHoldScale, maximumHoldScale)
        return StepJitter(minimumBlendScale: blend.0, maximumBlendScale: blend.1,
                          minimumHoldScale: hold.0, maximumHoldScale: hold.1)
    }

    private static func repair(_ low: Double, _ high: Double) -> (Double, Double) {
        let a = ChoreographyLimits.clamp(low, 0, 4, fallback: 1)
        let b = ChoreographyLimits.clamp(high, 0, 4, fallback: 1)
        return a <= b ? (a, b) : (b, a)
    }
}

/// A named, composable, cancellable run of expression beats.
public struct ChoreographySequence: Equatable, Hashable, Sendable {
    /// Stable name. Used for cancellation and for the deterministic seed, so two
    /// runs of the same identifier jitter identically.
    public var id: String
    public var steps: [ChoreographyStep]
    public var priority: ChoreographyPriority
    public var repeatMode: RepeatMode
    public var admission: Admission
    public var cancelBehavior: CancelBehavior
    /// Overlay components the module stops driving while speech is active.
    public var speechMask: PoseComponents
    public var jitter: StepJitter?
    /// Marks self-scheduled idle behaviour. Ambient sequences are the only thing
    /// the module starts on its own, and they stop entirely when idle is off.
    public var isAmbient: Bool

    public init(id: String,
                steps: [ChoreographyStep],
                priority: ChoreographyPriority = .standard,
                repeatMode: RepeatMode = .once,
                admission: Admission = .preempt,
                cancelBehavior: CancelBehavior = .release(blend: 0.38),
                speechMask: PoseComponents = .speechOwned,
                jitter: StepJitter? = nil,
                isAmbient: Bool = false) {
        self.id = id
        self.steps = steps
        self.priority = priority
        self.repeatMode = repeatMode
        self.admission = admission
        self.cancelBehavior = cancelBehavior
        self.speechMask = speechMask
        self.jitter = jitter
        self.isAmbient = isAmbient
    }

    /// Duration of one pass with no jitter applied.
    public var nominalDuration: Double {
        steps.reduce(0) { $0 + $1.duration }
    }

    public var iterationCount: Int? {
        switch repeatMode {
        case .once: return 1
        case .count(let n): return max(1, min(ChoreographyLimits.maximumRepeatCount, n))
        case .forever: return nil
        }
    }

    /// Returns a clamped copy, or the first structural problem found.
    ///
    /// Out-of-range numbers are clamped rather than rejected; only problems that
    /// cannot be repaired without guessing are errors.
    public func validated() -> Result<ChoreographySequence, ChoreographyValidationError> {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.emptyIdentifier) }
        if trimmed.count > ChoreographyLimits.maximumIdentifierLength {
            return .failure(.identifierTooLong(trimmed.count))
        }
        if steps.isEmpty { return .failure(.noSteps) }
        if steps.count > ChoreographyLimits.maximumSteps {
            return .failure(.tooManySteps(steps.count))
        }
        for index in steps.indices {
            let step = steps[index]
            guard step.intensity.isFinite, step.blend.isFinite, step.hold.isFinite else {
                return .failure(.nonFiniteStep(index: index))
            }
        }

        var copy = self
        copy.id = trimmed
        copy.steps = steps.map { $0.sanitised() }
        copy.jitter = copy.jitter?.sanitised()
        if case .release(let blend) = copy.cancelBehavior {
            copy.cancelBehavior = .release(blend: ChoreographyLimits.clamp(blend, 0, ChoreographyLimits.maximumStepBlend, fallback: 0))
        }
        if case .count(let n) = copy.repeatMode {
            copy.repeatMode = .count(max(1, min(ChoreographyLimits.maximumRepeatCount, n)))
        }
        if copy.nominalDuration > ChoreographyLimits.maximumSequenceDuration {
            return .failure(.durationTooLong(copy.nominalDuration))
        }
        // A never-ending sequence made only of zero-length steps would have no
        // frame to advance through, so it is refused rather than clamped.
        if copy.repeatMode == .forever && copy.nominalDuration <= 0 {
            return .failure(.zeroLengthRepeat)
        }
        return .success(copy)
    }
}

public enum ChoreographyValidationError: Error, Equatable, Hashable, Sendable {
    case emptyIdentifier
    case identifierTooLong(Int)
    case noSteps
    case tooManySteps(Int)
    case nonFiniteStep(index: Int)
    case durationTooLong(Double)
    case zeroLengthRepeat
}
