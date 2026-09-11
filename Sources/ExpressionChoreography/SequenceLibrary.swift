import Foundation

/// Small, ready-made sequences built only from the six expressions the portrait
/// already has.
///
/// These exist to exercise and demonstrate the framework. They do **not** claim
/// that any new facial asset has been produced: every beat resolves to an
/// existing `ExpressionPose` weight, and nothing here adds a pose, a gesture, a
/// prop or head and neck rotation.
public enum SequenceLibrary {

    /// 自然 → 微微笑 → 自然. The canonical three-beat check.
    public static func softSmileGreeting(id: String = "greeting.softSmile",
                                         priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.softSmile, blend: 0.38, hold: 0.90, label: "微微笑"),
                ChoreographyStep(nil, blend: 0.45, label: "回到自然"),
            ],
            priority: priority
        )
    }

    /// A fuller smile that settles back through 微微笑 before releasing, so the
    /// mouth does not drop straight from 0.8 to nothing.
    public static func warmSmile(id: String = "greeting.warm",
                                 priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.smile, blend: 0.32, hold: 0.55, blink: .triggerOnEnter, label: "浅笑"),
                ChoreographyStep(.softSmile, blend: 0.50, hold: 1.10, label: "落回微微笑"),
                ChoreographyStep(nil, blend: 0.50, label: "回到自然"),
            ],
            priority: priority
        )
    }

    /// 轻抿唇, the "considering it" beat.
    public static func consideration(id: String = "mood.consideration",
                                     priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.pressedLips, blend: 0.30, hold: 0.80, label: "轻抿唇"),
                ChoreographyStep(nil, blend: 0.40, label: "回到自然"),
            ],
            priority: priority
        )
    }

    /// A short 闭眼休息. No explicit blink directive is needed: the automatic
    /// blink fades out in proportion to how far the pose has closed the eyes, so
    /// nothing steps when the beat begins or ends.
    public static func briefEyeRest(id: String = "mood.eyeRest",
                                    priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.resting, blend: 0.45, hold: 1.20, label: "闭眼休息"),
                ChoreographyStep(nil, blend: 0.50, label: "睁眼"),
            ],
            priority: priority
        )
    }

    /// 自然微张唇, masked while a sentence plays because the mouth aperture
    /// belongs to speech.
    public static func attentive(id: String = "mood.attentive",
                                 priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.partedLips, intensity: 0.8, blend: 0.30, hold: 0.60, label: "微张唇"),
                ChoreographyStep(nil, blend: 0.35, label: "回到自然"),
            ],
            priority: priority
        )
    }

    /// A high priority beat used to demonstrate interruption: it cuts in over
    /// anything at or below `.user` and continues from the visible pose.
    public static func urgentSmile(id: String = "interrupt.smile") -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.smile, blend: 0.25, hold: 0.70, label: "打断·浅笑"),
                ChoreographyStep(nil, blend: 0.40, label: "回到自然"),
            ],
            priority: .urgent
        )
    }

    /// A smile held under speech. Only the smile weight survives the speech
    /// mask, which is exactly the shape the brief allows to stay.
    public static func speakingSmile(id: String = "speech.smile") -> ChoreographySequence {
        ChoreographySequence(
            id: id,
            steps: [
                ChoreographyStep(.softSmile, blend: 0.35, hold: 2.40, label: "说话时保持笑形"),
                ChoreographyStep(nil, blend: 0.45, label: "回到自然"),
            ],
            priority: .background
        )
    }

    // MARK: - Ambient

    /// A barely-there smile that drifts in and out during idle.
    public static func ambientMicroSmile() -> ChoreographySequence {
        ChoreographySequence(
            id: "ambient.microSmile",
            steps: [
                ChoreographyStep(.softSmile, intensity: 0.55, blend: 0.70, hold: 1.60, label: "淡淡的微微笑"),
                ChoreographyStep(nil, blend: 0.80, label: "回到自然"),
            ],
            priority: .ambient,
            admission: .rejectIfBusy,
            jitter: StepJitter(blend: 0.85...1.2, hold: 0.7...1.4),
            isAmbient: true
        )
    }

    /// A slow, shallow eye rest. Distinct from a blink: it is a pose, not a
    /// blink override, and the host's blink stays shut underneath it.
    public static func ambientEyeRest() -> ChoreographySequence {
        ChoreographySequence(
            id: "ambient.eyeRest",
            steps: [
                ChoreographyStep(.resting, intensity: 0.45, blend: 0.55, hold: 0.65, label: "短暂垂眼"),
                ChoreographyStep(nil, blend: 0.60, label: "睁眼"),
            ],
            priority: .ambient,
            admission: .rejectIfBusy,
            jitter: StepJitter(blend: 0.9...1.15, hold: 0.6...1.5),
            isAmbient: true
        )
    }

    /// The default idle set. Keep it small: idle behaviour should be noticed
    /// rarely, and every entry here is low priority and interruptible.
    public static let ambient: [ChoreographySequence] = [ambientMicroSmile(), ambientEyeRest()]

    /// Everything above except the ambient set, for demos and menu wiring.
    public static let explicit: [ChoreographySequence] = [
        softSmileGreeting(), warmSmile(), consideration(), briefEyeRest(), attentive(),
        urgentSmile(), speakingSmile(),
    ]
}
