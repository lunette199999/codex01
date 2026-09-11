import Foundation
import ExpressionChoreography

// ─────────────────────────────────────────────────────────────────────────────
// DROP-IN FILE
//
// This is the only file from `integrations/` that belongs in the app. Copy it
// into the app target next to DesktopController.swift, add the
// ExpressionChoreography package, and follow docs/INTEGRATION.md for the four
// insertion points in renderFrame() / updateTimer().
//
// Access levels are deliberately left at the default: `Expression`,
// `ExpressionPose` and `MotionFrame` are internal in the app, so nothing that
// mentions them can be public. The package reaches this file with
// `@testable import` and through HostRenderLoopHarness.
// ─────────────────────────────────────────────────────────────────────────────

/// What the adapter hands back to `renderFrame()`.
struct ChoreographyFrame {
    /// The base pose with the sequence overlay laid on top. Hand this to the
    /// renderer *before* applying `RestMouthReturn`, exactly where the app
    /// already had `expressionTransition.sample(at:)`.
    var expressionPose: ExpressionPose
    /// The module's own contribution after the speech mask, for logging and
    /// tests. `expressionPose` already includes it.
    var overlay: PoseWeights
    /// Blink value for this frame: the host's own value unless a step overrode it.
    var blink: Double
    /// One-frame edge. When true call `blink.trigger(at:)`; the host's
    /// `BlinkClock` still owns the shape of the blink.
    var requestsBlinkTrigger: Bool
    /// OR this into the app's existing `needed` expression in `updateTimer()`.
    var needsContinuousUpdates: Bool
    /// True on the frame `needsContinuousUpdates` flipped, so the app can call
    /// `updateTimer()` the same way it already does for a finished transition.
    var timerConditionChanged: Bool
    var activeSequenceID: String?
    var activeStepLabel: String?
    var notices: [ChoreographyNotice]
    var timeAnomaly: TimeAnomaly?
}

/// Maps the portable module onto the app's `ExpressionPose` / `MotionFrame`.
///
/// The adapter adds no animation of its own. It converts types, keeps the
/// host's `BlinkClock` as the owner of blinking, and reports whether the app's
/// frame timer is still needed.
final class ChoreographyBridge {

    let director: ChoreographyDirector
    private var lastNeedsContinuousUpdates = false

    init(configuration: ChoreographyConfiguration = ChoreographyBridge.defaultConfiguration()) {
        director = ChoreographyDirector(configuration: configuration)
    }

    /// Builds a configuration whose pose table comes from the app's own
    /// `ExpressionPose.target(_:)`, so "微微笑 is 0.32 smile" is stated once in
    /// the app and never duplicated inside the module.
    static func defaultConfiguration(seed: UInt64 = 0x5EED_0000_0001,
                                     ambient: AmbientConfiguration = AmbientConfiguration()) -> ChoreographyConfiguration {
        ChoreographyConfiguration(vocabulary: hostVocabulary(), seed: seed, ambient: ambient)
    }

    static func hostVocabulary() -> PoseVocabulary {
        PoseVocabulary { key in
            ChoreographyBridge.weights(from: ExpressionPose.target(ChoreographyBridge.expression(for: key)))
        }
    }

    // MARK: - Frame

    /// Call once per rendered frame, after the app has sampled its own
    /// `ExpressionTransition` and `BlinkClock` and before it applies
    /// `RestMouthReturn`.
    ///
    /// - Parameters:
    ///   - basePose: `expressionTransition.sample(at: elapsed)`.
    ///   - baseBlink: `idle ? blink.value(at: elapsed) : 0`.
    ///   - speechActive: the app's existing `speechActive` expression.
    ///   - time: the app's `elapsed`.
    func update(basePose: ExpressionPose, baseBlink: Double, speechActive: Bool, at time: Double) -> ChoreographyFrame {
        let output = director.update(time: time,
                                     input: ChoreographyInput(basePose: ChoreographyBridge.weights(from: basePose),
                                                              baseBlink: baseBlink,
                                                              isSpeechActive: speechActive))
        let changed = output.needsContinuousUpdates != lastNeedsContinuousUpdates
        lastNeedsContinuousUpdates = output.needsContinuousUpdates
        return ChoreographyFrame(expressionPose: ChoreographyBridge.pose(from: output.pose),
                                 overlay: output.overlay,
                                 blink: output.blink,
                                 requestsBlinkTrigger: output.requestsBlinkTrigger,
                                 needsContinuousUpdates: output.needsContinuousUpdates,
                                 timerConditionChanged: changed,
                                 activeSequenceID: output.activeSequenceID,
                                 activeStepLabel: output.activeStepLabel,
                                 notices: output.notices,
                                 timeAnomaly: output.timeAnomaly)
    }

    // MARK: - Commands

    @discardableResult
    func play(_ sequence: ChoreographySequence) -> SubmissionResult { director.play(sequence) }

    @discardableResult
    func cancel(id: String) -> SubmissionResult { director.cancel(id: id) }

    @discardableResult
    func cancelAll() -> SubmissionResult { director.cancelAll() }

    /// Mirror of the app's window lifecycle: `show()` → `.visible`,
    /// `hide()`/`windowWillClose` → `.hidden`, `willSleep` → `.suspended`.
    func setPresentation(_ presentation: Presentation) { director.setPresentation(presentation) }

    /// Mirror of the app's "自然待机动作" menu item.
    func setIdleEnabled(_ enabled: Bool) { director.setIdleEnabled(enabled) }

    var needsContinuousUpdates: Bool { lastNeedsContinuousUpdates }

    // MARK: - Conversions

    /// The four weights are identical in both directions; the module's
    /// constructor clamps and drops non-finite values on the way in.
    static func weights(from pose: ExpressionPose) -> PoseWeights {
        PoseWeights(smile: pose.smile, rest: pose.rest, pressed: pose.pressed, parted: pose.parted)
    }

    static func pose(from weights: PoseWeights) -> ExpressionPose {
        ExpressionPose(smile: weights.smile, rest: weights.rest, pressed: weights.pressed, parted: weights.parted)
    }

    /// Raw values match, so the two enums bridge without a switch that could
    /// silently drift if the app gains a seventh expression.
    static func key(for expression: Expression) -> ExpressionKey {
        ExpressionKey(rawValue: expression.rawValue) ?? .natural
    }

    static func expression(for key: ExpressionKey) -> Expression {
        Expression(rawValue: key.rawValue) ?? .natural
    }
}
