#if CHOREOGRAPHY_HOST_SHIM
import Foundation
import ExpressionChoreography

/// One speech sample for a frame, standing in for whatever the app resolved
/// from `MouthTimeline`, `MouthEnvelope`, the followed voice or `SpeechDemo`.
public struct HostSpeechSample: Equatable, Sendable {
    public var open: Double
    public var wide: Double
    public var isActive: Bool

    public init(open: Double = 0, wide: Double = 0, isActive: Bool = false) {
        self.open = open
        self.wide = wide
        self.isActive = isActive
    }

    public static let silent = HostSpeechSample()

    /// The app's existing silent preview, so the demo can show a smile held
    /// under real consonant closures without inventing a new mouth timeline.
    public static func silentDemo(at time: Double) -> HostSpeechSample {
        let pose = SpeechDemo.pose(at: time)
        return HostSpeechSample(open: pose.open, wide: pose.wide, isActive: time >= 0 && time < SpeechDemo.duration)
    }
}

/// A head-less reproduction of `DesktopController.renderFrame()` with the
/// adapter inserted, used by the CLI demo and by the adapter tests.
///
/// It exists to prove the ordering documented in `docs/INTEGRATION.md` on real
/// code rather than in prose. It is package-only: the app keeps its own
/// `DesktopController`, which this file neither replaces nor rewrites.
///
/// Deliberately *not* reproduced here, because the module does not touch them:
/// hair physics, body movement, window placement, audio playback, the relight
/// pass and the renderer itself.
public final class HostRenderLoopHarness {

    private let bridge: ChoreographyBridge
    private var transition = ExpressionTransition()
    private var blinkClock = BlinkClock()
    private var restMouthReturn = RestMouthReturn()
    private var blinkIntervals: SeededGenerator

    public private(set) var expression: Expression = .natural
    public private(set) var isIdleEnabled: Bool
    public private(set) var isVisible = true
    public private(set) var frame = MotionFrame()
    public private(set) var needsTimer = false
    public private(set) var overlay: PoseWeights = .identity
    public private(set) var basePose: PoseWeights = .identity
    public private(set) var activeSequenceID: String?
    public private(set) var activeStepLabel: String?
    public private(set) var notices: [ChoreographyNotice] = []
    public private(set) var timeAnomaly: TimeAnomaly?
    public private(set) var blinkTriggersRequested = 0

    public init(seed: UInt64 = 0x5EED_0000_0001,
                idleEnabled: Bool = true,
                ambient: AmbientConfiguration = AmbientConfiguration()) {
        var ambient = ambient
        ambient.isEnabled = ambient.isEnabled && idleEnabled
        bridge = ChoreographyBridge(configuration: ChoreographyBridge.defaultConfiguration(seed: seed, ambient: ambient))
        isIdleEnabled = idleEnabled
        // The shipped BlinkClock defaults to `Double.random`, which would make a
        // recorded run irreproducible. Injecting the seeded generator is exactly
        // what the app would do if it wanted a reproducible capture.
        blinkIntervals = SeededGenerator(seed: seed ^ 0x1234_5678)
    }

    // MARK: - Commands, mirroring the app's menu actions

    /// `DesktopController.setExpression(_:)`. The base expression stays the
    /// app's state; the module never writes it.
    public func setExpression(_ expression: Expression, at time: Double) {
        self.expression = expression
        transition.set(expression, at: time)
    }

    @discardableResult
    public func play(_ sequence: ChoreographySequence) -> SubmissionResult { bridge.play(sequence) }

    @discardableResult
    public func cancel(id: String) -> SubmissionResult { bridge.cancel(id: id) }

    @discardableResult
    public func cancelAll() -> SubmissionResult { bridge.cancelAll() }

    /// `toggleIdle()`: also resets the blink clock the way the app does.
    public func setIdleEnabled(_ enabled: Bool, at time: Double) {
        isIdleEnabled = enabled
        bridge.setIdleEnabled(enabled)
        blinkClock.reset(at: time)
    }

    /// `show()` / `hide()` / `willSleep()` / `didWake()`.
    public func setPresentation(_ presentation: Presentation, at time: Double) {
        isVisible = presentation == .visible
        bridge.setPresentation(presentation)
        if presentation == .visible { blinkClock.reset(at: time) }
    }

    public var directorClock: Double { bridge.director.clock }

    // MARK: - The frame

    /// The same order of operations as `DesktopController.renderFrame()`, with
    /// the four adapter insertion points marked.
    @discardableResult
    public func renderFrame(at time: Double, speech: HostSpeechSample = .silent) -> MotionFrame {
        // 1. Existing: the app's own blink and expression transition.
        var generator = blinkIntervals
        let baseBlink = isIdleEnabled ? blinkClock.value(at: time, nextInterval: { generator.next(in: 3.2...7.0) }) : 0
        blinkIntervals = generator
        var pose = transition.sample(at: time)
        let speechActive = speech.isActive
        basePose = ChoreographyBridge.weights(from: pose)

        // 2. INSERTION POINT: the module layers its overlay on the base pose.
        let choreography = bridge.update(basePose: pose, baseBlink: baseBlink, speechActive: speechActive, at: time)
        pose = choreography.expressionPose

        // 3. INSERTION POINT: a step may ask the app's BlinkClock for a blink.
        //    The clock keeps owning the shape; the blink lands on the next frame.
        if choreography.requestsBlinkTrigger {
            blinkClock.trigger(at: time)
            blinkTriggersRequested += 1
        }

        // 4. Existing and unchanged: RestMouthReturn stays the single owner of
        //    how the resting aperture comes back after a sentence.
        pose.parted *= restMouthReturn.amount(speaking: speechActive, at: time)

        frame = MotionFrame(time: time,
                            blink: choreography.blink,
                            mouth: speech.open,
                            mouthWide: speech.wide,
                            movement: isIdleEnabled ? 1 : 0,
                            expression: expression,
                            hair: HairPose(),
                            expressionPose: pose,
                            speechActive: speechActive)

        // 5. INSERTION POINT: the module's term joins the app's timer condition.
        needsTimer = isVisible && (isIdleEnabled
                                   || transition.isActive
                                   || restMouthReturn.isActive
                                   || speechActive
                                   || choreography.needsContinuousUpdates)

        overlay = choreography.overlay
        activeSequenceID = choreography.activeSequenceID
        activeStepLabel = choreography.activeStepLabel
        notices = choreography.notices
        timeAnomaly = choreography.timeAnomaly
        return frame
    }

    /// The aperture the renderer would actually use, so a test can assert the
    /// module never changed it.
    public var mouthOpening: Double {
        (frame.expressionPose ?? ExpressionPose()).mouthOpening(speech: frame.mouth, active: frame.speechActive)
    }

    public var isBaseTransitionActive: Bool { transition.isActive }
}
#endif
