import Foundation

/// What the module noticed about the time value the host passed in.
public enum TimeAnomaly: String, Hashable, Sendable {
    /// NaN or infinity. The frame is evaluated with a zero delta and no state
    /// is disturbed, so nothing downstream ever sees a non-finite number.
    case nonFinite
    /// The host clock moved backwards (a re-based uptime, a replayed frame).
    /// Treated as a zero delta and re-synchronised, never as a negative step.
    case wentBackwards
    /// More time passed than `maximumTimeStep`. The advance is capped and the
    /// director drops queued work instead of fast-forwarding through it.
    case largeStep
}

/// Turns the host's clock into a monotonic internal clock.
///
/// Everything in the module is timed off `clock`, which only ever moves forward
/// by a sane delta. The host can pass `ProcessInfo.systemUptime`, an elapsed
/// value, or a scripted number from a test; the module never reads a clock of
/// its own and never starts a timer or a thread.
struct TimeGate {
    private(set) var clock: Double = 0
    private var lastInput: Double?

    /// Forgets the reference point without moving the clock, so the next frame
    /// after a hide, a sleep or a resume produces a zero delta rather than a
    /// jump the size of the pause.
    mutating func resynchronise() { lastInput = nil }

    mutating func advance(to input: Double, maximumStep: Double) -> (delta: Double, anomaly: TimeAnomaly?) {
        let cap = (maximumStep.isFinite && maximumStep > 0) ? maximumStep : 0.5
        guard input.isFinite else { return (0, .nonFinite) }
        guard let previous = lastInput else {
            lastInput = input
            return (0, nil)
        }
        let raw = input - previous
        lastInput = input
        if raw < 0 { return (0, .wentBackwards) }
        if raw > cap {
            clock += cap
            return (cap, .largeStep)
        }
        clock += raw
        return (raw, nil)
    }
}
