import Foundation

/// Interpolation shapes available to a step.
public enum Easing: String, CaseIterable, Hashable, Sendable {
    case linear
    /// The same `t * t * (3 - 2 * t)` smooth-step the shipped
    /// `ExpressionTransition` and `RestMouthReturn` already use, so a sequence
    /// blend and a manual expression change feel identical.
    case smoothStep

    public func apply(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .smoothStep: return t * t * (3 - 2 * t)
        }
    }
}
