import Foundation

/// Self-scheduled idle behaviour: the only thing the module ever starts by itself.
public struct AmbientConfiguration: Equatable, Hashable, Sendable {
    /// Maps onto the app's existing "自然待机动作" toggle. With this off the
    /// module never starts anything on its own; explicit sequences still run.
    public var isEnabled: Bool
    public var library: [ChoreographySequence]
    /// Gap between two ambient sequences, sampled from the injected seed.
    public var interval: ClosedRange<Double>
    /// Gap before the first one after becoming visible or turning idle back on.
    public var firstDelay: ClosedRange<Double>
    /// Ambient behaviour stays out of the way while a sentence is playing.
    public var pausesDuringSpeech: Bool

    public init(isEnabled: Bool = true,
                library: [ChoreographySequence] = SequenceLibrary.ambient,
                interval: ClosedRange<Double> = 11...24,
                firstDelay: ClosedRange<Double> = 7...15,
                pausesDuringSpeech: Bool = true) {
        self.isEnabled = isEnabled
        self.library = library
        self.interval = interval
        self.firstDelay = firstDelay
        self.pausesDuringSpeech = pausesDuringSpeech
    }

    public static let disabled = AmbientConfiguration(isEnabled: false, library: [])
}

public struct ChoreographyConfiguration: Equatable, Hashable, Sendable {
    /// Where the pose numbers come from. Hand in the host's own table so there
    /// is one source of truth for what "微微笑" is worth.
    public var vocabulary: PoseVocabulary
    /// Every random choice in the module derives from this. Same seed plus the
    /// same time steps reproduce the same frames.
    public var seed: UInt64
    /// Longer host steps are capped, and queued work is dropped rather than
    /// fast-forwarded. Matches the 0.5 s pause threshold `HairPhysics` uses.
    public var maximumTimeStep: Double
    /// Fallback fade used when a sequence ends or is dropped without its own
    /// blend. Matches `ExpressionTransition`'s 0.38 s.
    public var releaseBlend: Double
    /// Overlay components the module stops driving while speech is active.
    ///
    /// This is one policy for the whole module rather than a per-sequence
    /// setting on purpose: if two sequences disagreed, the mask would change the
    /// instant one preempted the other and step whatever the new mask withholds.
    /// Which components speech owns is a property of the host, not of a beat.
    public var speechMask: PoseComponents
    public var maximumQueueDepth: Int
    public var ambient: AmbientConfiguration

    public init(vocabulary: PoseVocabulary = .version0_3_4,
                seed: UInt64 = 0x5EED_0000_0001,
                maximumTimeStep: Double = 0.5,
                releaseBlend: Double = 0.38,
                speechMask: PoseComponents = .speechOwned,
                maximumQueueDepth: Int = ChoreographyLimits.maximumQueueDepth,
                ambient: AmbientConfiguration = AmbientConfiguration()) {
        self.vocabulary = vocabulary
        self.seed = seed
        self.maximumTimeStep = ChoreographyLimits.clamp(maximumTimeStep, 0.05, 5, fallback: 0.5)
        self.releaseBlend = ChoreographyLimits.clamp(releaseBlend, 0, ChoreographyLimits.maximumStepBlend, fallback: 0.38)
        self.speechMask = speechMask
        self.maximumQueueDepth = max(0, min(ChoreographyLimits.maximumQueueDepth, maximumQueueDepth))
        self.ambient = ambient
    }
}
