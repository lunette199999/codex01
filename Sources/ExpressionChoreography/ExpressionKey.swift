import Foundation

/// The expression vocabulary version 0.3.4 of the portrait already ships.
///
/// The module deliberately adds no new pose, gesture, prop, garment or head
/// rotation: a sequence can only schedule and blend these existing keys. Raw
/// values are identical to the host's `Expression` enum, so the two bridge
/// through `init(rawValue:)` rather than a hand-maintained switch that could
/// drift.
public enum ExpressionKey: String, CaseIterable, Hashable, Sendable {
    case natural
    case softSmile
    case smile
    case pressedLips
    case partedLips
    case resting
}
