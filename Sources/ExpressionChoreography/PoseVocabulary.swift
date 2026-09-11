import Foundation

/// Maps an `ExpressionKey` to the weights the renderer expects.
///
/// The table is injectable on purpose. The host app already owns these numbers
/// in `ExpressionPose.target(_:)`; `ChoreographyHostKit` builds a vocabulary
/// straight from that function so there is exactly one source of truth. The
/// bundled `.version0_3_4` table exists so the core can be tested and demoed on
/// its own, and is asserted against the host values in the adapter tests.
public struct PoseVocabulary: Equatable, Hashable, Sendable {
    private let table: [ExpressionKey: PoseWeights]

    public init(_ table: [ExpressionKey: PoseWeights]) {
        self.table = table
    }

    /// Builds a vocabulary by asking a resolver for every known key, so a host
    /// can hand over its own values without exposing its types to the core.
    public init(resolving resolver: (ExpressionKey) -> PoseWeights) {
        var table: [ExpressionKey: PoseWeights] = [:]
        for key in ExpressionKey.allCases { table[key] = resolver(key) }
        self.table = table
    }

    /// An unknown key falls back to the neutral pose rather than trapping.
    public func weights(for key: ExpressionKey) -> PoseWeights {
        table[key] ?? .identity
    }

    /// Mirrors `ExpressionPose.target(_:)` in the 0.3.4 snapshot.
    public static let version0_3_4 = PoseVocabulary([
        .natural: PoseWeights(),
        .softSmile: PoseWeights(smile: 0.32),
        .smile: PoseWeights(smile: 0.8),
        .pressedLips: PoseWeights(pressed: 0.85),
        .partedLips: PoseWeights(parted: 0.32),
        .resting: PoseWeights(rest: 1),
    ])
}
