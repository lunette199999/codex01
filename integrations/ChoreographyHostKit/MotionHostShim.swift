#if CHOREOGRAPHY_HOST_SHIM
import Foundation

// Compile-check shim.
//
// These declarations are an excerpt of the app's own `Motion.swift` from the
// 0.3.4 snapshot, reproduced so `ChoreographyBridge.swift` can be type-checked,
// unit-tested and demoed inside this package. The only edit is the `public`
// access modifiers, which the package needs to reach the types across targets.
//
// The whole file is behind CHOREOGRAPHY_HOST_SHIM, a flag set only by this
// package's manifest. Inside the real app the flag is never defined, the file
// compiles to nothing, and the genuine declarations are used instead. Do not
// copy this file into the app and do not treat it as a second implementation:
// the app remains the owner of every type below.

public enum Expression: String, CaseIterable {
    case natural, softSmile, smile, pressedLips, partedLips, resting
    public var title: String {
        switch self {
        case .natural: return "自然"
        case .softSmile: return "微微笑"
        case .smile: return "浅笑"
        case .pressedLips: return "轻抿唇"
        case .partedLips: return "自然微张唇"
        case .resting: return "闭眼休息"
        }
    }
}

public struct HairPose {
    public var left = SIMD3<Double>(repeating: 0)
    public var right = SIMD3<Double>(repeating: 0)
    public init() {}
    public var maximumDisplacement: Double {
        [left.x, left.y, left.z, right.x, right.y, right.z].map(abs).max() ?? 0
    }
}

public struct MotionFrame {
    public var time: Double = 0
    public var blink: Double = 0
    public var mouth: Double = 0
    public var mouthWide: Double = 0
    public var movement: Double = 1
    public var expression: Expression = .natural
    public var hair = HairPose()
    public var expressionPose: ExpressionPose? = nil
    public var speechActive = false
    public init() {}
    public init(time: Double, blink: Double, mouth: Double, mouthWide: Double, movement: Double,
                expression: Expression, hair: HairPose, expressionPose: ExpressionPose?, speechActive: Bool) {
        self.time = time; self.blink = blink; self.mouth = mouth; self.mouthWide = mouthWide
        self.movement = movement; self.expression = expression; self.hair = hair
        self.expressionPose = expressionPose; self.speechActive = speechActive
    }
}

public struct ExpressionPose: Equatable {
    public var smile: Double = 0
    public var rest: Double = 0
    public var pressed: Double = 0
    public var parted: Double = 0
    public init(smile: Double = 0, rest: Double = 0, pressed: Double = 0, parted: Double = 0) {
        self.smile = smile; self.rest = rest; self.pressed = pressed; self.parted = parted
    }
    public static func target(_ expression: Expression) -> ExpressionPose {
        switch expression {
        case .natural: return ExpressionPose()
        case .softSmile: return ExpressionPose(smile: 0.32)
        case .smile: return ExpressionPose(smile: 0.8)
        case .pressedLips: return ExpressionPose(pressed: 0.85)
        case .partedLips: return ExpressionPose(parted: 0.32)
        case .resting: return ExpressionPose(rest: 1)
        }
    }

    public func mouthOpening(speech: Double, active: Bool) -> Double {
        let open = speech.isFinite ? min(1, max(0, speech)) : 0
        return active || open > 0 ? open : min(1, max(0, parted))
    }
}

public struct RestMouthReturn {
    private var wasSpeaking = false
    private var began: Double?
    public init() {}
    public var isActive: Bool { began != nil }
    public mutating func amount(speaking: Bool, at time: Double) -> Double {
        if speaking { began = nil }
        else if wasSpeaking { began = time }
        wasSpeaking = speaking
        if speaking { return 0 }
        guard let began else { return 1 }
        let t = min(1, max(0, (time - began) / 0.18))
        if t >= 1 { self.began = nil }
        return t * t * (3 - 2 * t)
    }
}

public struct ExpressionTransition {
    public private(set) var value = ExpressionPose()
    private var origin = ExpressionPose()
    private var target = ExpressionPose()
    private var began = 0.0
    public private(set) var isActive = false
    public init() {}
    public mutating func set(_ expression: Expression, at time: Double) {
        _ = sample(at: time)
        origin = value; target = .target(expression); began = time
        isActive = origin != target
    }
    public mutating func sample(at time: Double) -> ExpressionPose {
        guard isActive else { return value }
        let t = min(1, max(0, (time - began) / 0.38))
        let u = t * t * (3 - 2 * t)
        value = ExpressionPose(smile: origin.smile + (target.smile - origin.smile) * u,
                               rest: origin.rest + (target.rest - origin.rest) * u,
                               pressed: origin.pressed + (target.pressed - origin.pressed) * u,
                               parted: origin.parted + (target.parted - origin.parted) * u)
        if t >= 1 { value = target; isActive = false }
        return value
    }
}

public struct BlinkClock {
    public private(set) var nextBlink: Double = 3.7
    private var start: Double?
    public init() {}
    public mutating func reset(at time: Double) { start = nil; nextBlink = time + 2.8 }
    public mutating func trigger(at time: Double) { start = time }
    public mutating func value(at time: Double, nextInterval: () -> Double = { .random(in: 3.2...7.0) }) -> Double {
        if start == nil && time >= nextBlink { start = time }
        guard let began = start else { return 0 }
        let elapsed = time - began
        if elapsed >= 0.22 {
            start = nil
            nextBlink = time + nextInterval()
            return 0
        }
        if elapsed < 0 { return 0 }
        if elapsed < 0.055 { return elapsed / 0.055 }
        if elapsed < 0.125 { return 1 }
        return max(0, 1 - (elapsed - 0.125) / 0.095)
    }
}

public enum SpeechDemo {
    public static let duration = 6.8
    private static let frames: [(Double, Double, Double)] = [
        (0, 0, 0), (0.18, 0, 0), (0.27, 0.50, 0.2), (0.46, 0.58, 0.1), (0.59, 0, 0),
        (0.70, 0, 0), (0.80, 0.46, 0.2), (1.02, 0.34, 0.7), (1.18, 0.18, 0.9),
        (1.32, 0, 0), (1.92, 0, 0), (2.02, 0.27, -0.75), (2.22, 0.31, -0.8),
        (2.37, 0.50, 0.1), (2.66, 0.20, 0.8), (2.88, 0, 0), (3.65, 0, 0),
        (3.74, 0.20, 0.7), (4.03, 0.28, -0.8), (4.27, 0.55, 0.15), (4.60, 0, 0),
        (5.35, 0, 0), (5.46, 0.48, 0.1), (5.72, 0.22, 0.7), (6.04, 0.30, -0.6),
        (6.30, 0, 0), (duration, 0, 0)
    ]
    public static func pose(at time: Double) -> (open: Double, wide: Double) {
        guard time.isFinite, time >= 0, time < duration,
              let i = frames.indices.dropFirst().first(where: { frames[$0].0 >= time }) else { return (0, 0) }
        let a = frames[i - 1], b = frames[i], t = (time - a.0) / (b.0 - a.0), u = t * t * (3 - 2 * t)
        return (a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
    }
}
#endif
