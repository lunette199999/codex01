import Foundation

/// Whether the portrait is on screen. Drives the module's hide / sleep / resume
/// contract.
public enum Presentation: String, Hashable, Sendable {
    /// Visible and rendering.
    case visible
    /// Ordered out of the screen by the user.
    case hidden
    /// The machine is going to sleep, or the app stopped its timers.
    case suspended
}

/// Everything the module needs from the host each frame.
///
/// The host stays the owner of all four of these; the module only reads them.
public struct ChoreographyInput: Equatable, Hashable, Sendable {
    /// The pose the host's own `ExpressionTransition` is already showing.
    public var basePose: PoseWeights
    /// The value the host's own `BlinkClock` produced for this frame.
    public var baseBlink: Double
    /// True while a sentence, a followed voice or the silent demo is playing.
    public var isSpeechActive: Bool

    public init(basePose: PoseWeights = .identity, baseBlink: Double = 0, isSpeechActive: Bool = false) {
        self.basePose = basePose
        self.baseBlink = baseBlink
        self.isSpeechActive = isSpeechActive
    }
}

/// Why a sequence stopped before finishing.
public enum CancelReason: String, Hashable, Sendable {
    case explicit
    case preempted
    case presentationChanged
    case idleDisabled
    case timeGap
    case reset
}

/// Why a sequence never started.
public enum RejectionReason: String, Hashable, Sendable {
    case invalidSequence
    case notVisible
    case channelBusy
    case lowerPriority
    case queueFull
    case ambientDisabled
}

/// An observable moment in the life of a sequence. Reported once, on the frame
/// it happened, so a host can log or drive UI from it without polling.
public struct ChoreographyNotice: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case started
        case stepChanged(index: Int)
        case finished
        case cancelled(CancelReason)
        case rejected(RejectionReason)
    }

    public var kind: Kind
    public var sequenceID: String
    public var stepLabel: String?
    /// The module's internal monotonic clock, not the host clock.
    public var clock: Double

    public init(kind: Kind, sequenceID: String, stepLabel: String? = nil, clock: Double) {
        self.kind = kind
        self.sequenceID = sequenceID
        self.stepLabel = stepLabel
        self.clock = clock
    }
}

/// Everything the module produces for a frame.
///
/// There is deliberately no mouth aperture and no mouth width here, so the
/// module cannot write `MotionFrame.mouth` or `mouthWide` and cannot compete
/// with `MouthTimeline`, `MouthEnvelope` or a silent-gap closure for the
/// per-syllable shape of a playing sentence.
///
/// That is a narrower guarantee than "it cannot affect the mouth", and the
/// difference matters. Two of the four weights in `pose` shape the mouth on
/// their way through the renderer: `ExpressionPose.mouthOpening` returns
/// `parted` as the resting aperture whenever nothing is playing, and `pressed`
/// selects the pressed-lip layer. So the module does move the rendered mouth —
/// indirectly, through the expression weights, and only where the host has left
/// it to the expression to decide. `configuration.speechMask` and the host's
/// `RestMouthReturn` are what keep that out of the way of a playing sentence.
public struct ChoreographyOutput: Equatable, Hashable, Sendable {
    /// Base pose with the module's overlay laid on top. Bounded and finite.
    public var pose: PoseWeights
    /// The module's own contribution after masking, for debugging and tests.
    public var overlay: PoseWeights
    /// Final blink value: the host's own value unless a step overrode it.
    public var blink: Double
    public var blinkOverridden: Bool
    /// One-frame edge asking the host's `BlinkClock` to start a blink.
    public var requestsBlinkTrigger: Bool
    /// True while the module still has something to animate. The host ORs this
    /// into its existing timer condition; when it goes false and nothing else
    /// needs a frame, the timer stops.
    public var needsContinuousUpdates: Bool
    public var activeSequenceID: String?
    public var activeStepLabel: String?
    public var notices: [ChoreographyNotice]
    public var timeAnomaly: TimeAnomaly?
    /// The module's monotonic clock, exposed so a demo or a log can show it.
    public var clock: Double

    public init(pose: PoseWeights = .identity,
                overlay: PoseWeights = .identity,
                blink: Double = 0,
                blinkOverridden: Bool = false,
                requestsBlinkTrigger: Bool = false,
                needsContinuousUpdates: Bool = false,
                activeSequenceID: String? = nil,
                activeStepLabel: String? = nil,
                notices: [ChoreographyNotice] = [],
                timeAnomaly: TimeAnomaly? = nil,
                clock: Double = 0) {
        self.pose = pose
        self.overlay = overlay
        self.blink = blink
        self.blinkOverridden = blinkOverridden
        self.requestsBlinkTrigger = requestsBlinkTrigger
        self.needsContinuousUpdates = needsContinuousUpdates
        self.activeSequenceID = activeSequenceID
        self.activeStepLabel = activeStepLabel
        self.notices = notices
        self.timeAnomaly = timeAnomaly
        self.clock = clock
    }
}

/// The answer to a `submit` call. Structural problems are reported immediately;
/// arbitration against whatever is running happens on the next `update` and is
/// reported there as a notice, because that is the frame it actually takes effect.
public enum SubmissionResult: Equatable, Hashable, Sendable {
    case accepted
    case rejected(RejectionReason)
    case invalid(ChoreographyValidationError)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}
