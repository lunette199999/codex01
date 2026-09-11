import Foundation

/// Ranking used to decide who owns the expression channel.
///
/// Exactly one sequence drives the overlay at a time. That is the whole point of
/// the type: two events can never take turns nudging the same weight within a
/// frame, so the rendered pose always has a single, nameable author.
public struct ChoreographyPriority: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = min(1000, max(0, rawValue))
    }

    public init(_ value: Int) { self.init(rawValue: value) }

    public static func < (lhs: ChoreographyPriority, rhs: ChoreographyPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Self-scheduled idle behaviour. Never preempts anything and is the first
    /// thing dropped when the idle toggle goes off.
    public static let ambient = ChoreographyPriority(10)
    /// Long-running mood held under other events.
    public static let background = ChoreographyPriority(30)
    /// Default for a sequence the app plays deliberately.
    public static let standard = ChoreographyPriority(50)
    /// A direct request from the person using the app.
    public static let user = ChoreographyPriority(70)
    /// Something that must be seen now and may cut anything else off.
    public static let urgent = ChoreographyPriority(90)
}
