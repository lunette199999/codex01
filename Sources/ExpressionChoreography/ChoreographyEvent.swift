import Foundation

/// A request aimed at the director. Events are buffered and take effect on the
/// next `update`, which is the frame their result is actually visible.
public enum ChoreographyEvent: Equatable, Sendable {
    case play(ChoreographySequence)
    case cancel(id: String)
    case cancelAll
}
