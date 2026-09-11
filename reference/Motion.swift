import Foundation
import CoreGraphics

enum Expression: String, CaseIterable {
    case natural, softSmile, smile, pressedLips, partedLips, resting
    var title: String {
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

struct MotionFrame {
    var time: Double = 0
    var blink: Double = 0
    var mouth: Double = 0
    var mouthWide: Double = 0
    var movement: Double = 1
    var expression: Expression = .natural
    var hair = HairPose()
    var expressionPose: ExpressionPose? = nil
    var speechActive = false
}

struct ExpressionPose: Equatable {
    var smile: Double = 0
    var rest: Double = 0
    var pressed: Double = 0
    var parted: Double = 0
    static func target(_ expression: Expression) -> ExpressionPose {
        switch expression {
        case .natural: return ExpressionPose()
        case .softSmile: return ExpressionPose(smile: 0.32)
        case .smile: return ExpressionPose(smile: 0.8)
        case .pressedLips: return ExpressionPose(pressed: 0.85)
        case .partedLips: return ExpressionPose(parted: 0.32)
        case .resting: return ExpressionPose(rest: 1)
        }
    }

    func mouthOpening(speech: Double, active: Bool) -> Double {
        // Bilabial closures and silent gaps in a playing sentence take priority
        // over a manually selected, slightly parted resting mouth.
        let open = speech.isFinite ? min(1,max(0,speech)) : 0
        return active || open > 0 ? open : min(1,max(0,parted))
    }
}

/// A speaking pause closes immediately; the selected resting aperture returns
/// gently only after playback ends. No smoothing delays consonant closures.
struct RestMouthReturn {
    private var wasSpeaking = false
    private var began: Double?
    var isActive: Bool { began != nil }
    mutating func amount(speaking: Bool, at time: Double) -> Double {
        if speaking { began = nil }
        else if wasSpeaking { began = time }
        wasSpeaking = speaking
        if speaking { return 0 }
        guard let began else { return 1 }
        let t = min(1,max(0,(time-began)/0.18))
        if t >= 1 { self.began = nil }
        return t*t*(3-2*t)
    }
}

/// Interruption starts from the currently visible pose, including when idle
/// motion is off. Elapsed-time interpolation also survives a stalled frame.
struct ExpressionTransition {
    private(set) var value = ExpressionPose()
    private var origin = ExpressionPose()
    private var target = ExpressionPose()
    private var began = 0.0
    private(set) var isActive = false
    mutating func set(_ expression: Expression, at time: Double) {
        _ = sample(at: time)
        origin = value; target = .target(expression); began = time
        isActive = origin != target
    }
    mutating func sample(at time: Double) -> ExpressionPose {
        guard isActive else { return value }
        let t = min(1,max(0,(time-began)/0.38))
        let u = t*t*(3-2*t)
        value = ExpressionPose(smile: origin.smile+(target.smile-origin.smile)*u,
                               rest: origin.rest+(target.rest-origin.rest)*u,
                               pressed: origin.pressed+(target.pressed-origin.pressed)*u,
                               parted: origin.parted+(target.parted-origin.parted)*u)
        if t >= 1 { value = target; isActive = false }
        return value
    }
}

enum SpeechDemo {
    static let duration = 6.8
    // Short, irregular vowel gestures with closed-lip pauses. This is only a
    // silent preview; real speech continues to use the audio's word timeline.
    private static let frames: [(Double, Double, Double)] = [
        (0,0,0), (0.18,0,0), (0.27,0.50,0.2), (0.46,0.58,0.1), (0.59,0,0),
        (0.70,0,0), (0.80,0.46,0.2), (1.02,0.34,0.7), (1.18,0.18,0.9),
        (1.32,0,0), (1.92,0,0), (2.02,0.27,-0.75), (2.22,0.31,-0.8),
        (2.37,0.50,0.1), (2.66,0.20,0.8), (2.88,0,0), (3.65,0,0),
        (3.74,0.20,0.7), (4.03,0.28,-0.8), (4.27,0.55,0.15), (4.60,0,0),
        (5.35,0,0), (5.46,0.48,0.1), (5.72,0.22,0.7), (6.04,0.30,-0.6),
        (6.30,0,0), (duration,0,0)
    ]
    static func pose(at time: Double) -> (open: Double, wide: Double) {
        guard time.isFinite, time >= 0, time < duration,
              let i = frames.indices.dropFirst().first(where: { frames[$0].0 >= time }) else { return (0,0) }
        let a = frames[i-1], b = frames[i], t = (time-a.0)/(b.0-a.0), u = t*t*(3-2*t)
        return (a.1+(b.1-a.1)*u, a.2+(b.2-a.2)*u)
    }
}

struct HairPose {
    var left = SIMD3<Double>(repeating: 0)
    var right = SIMD3<Double>(repeating: 0)
    var maximumDisplacement: Double {
        [left.x, left.y, left.z, right.x, right.y, right.z].map(abs).max() ?? 0
    }
}

/// Two pinned-root, three-mass hair chains. Positions are fractions of portrait width.
/// Fixed substeps keep the response independent of the display refresh rate.
struct HairPhysics {
    private struct Chain {
        var position = SIMD3<Double>(repeating: 0)
        var velocity = SIMD3<Double>(repeating: 0)
        mutating func step(wind: Double, delta: Double, softness: Double) {
            let before = position
            let stiffness = SIMD3<Double>(60, 42, 30) * softness
            let damping = SIMD3<Double>(10, 9, 8)
            let mass = SIMD3<Double>(1, 1.2, 1.6)
            let exposure = SIMD3<Double>(0.45, 0.8, 1.2)
            for i in 0..<3 {
                let parent = i == 0 ? 0 : before[i - 1]
                let force = 1.00 * wind * exposure[i] - stiffness[i] * (before[i] - parent) - damping[i] * velocity[i]
                velocity[i] += force / mass[i] * delta
                position[i] += velocity[i] * delta
                let limit = [0.018, 0.032, 0.050][i]
                if abs(position[i]) > limit {
                    position[i] = min(limit, max(-limit, position[i]))
                    velocity[i] = 0
                }
            }
        }
    }
    private var left = Chain()
    private var right = Chain()
    private var remainder = 0.0
    private var time = 0.0
    private let step = 1.0 / 120.0
    var pose: HairPose { HairPose(left: left.position, right: right.position) }

    mutating func reset() { left = Chain(); right = Chain(); remainder = 0; time = 0 }

    mutating func advance(delta: Double, wind override: Double? = nil) -> HairPose {
        guard delta.isFinite, delta > 0 else { return pose }
        // A pause must not produce a large catch-up impulse when the window resumes.
        if delta > 0.5 { reset(); return pose }
        remainder += delta
        while remainder + 1e-10 >= step {
            time += step
            let wind = override.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
            let breeze = wind ?? Self.breeze(at: time)
            left.step(wind: breeze, delta: step, softness: 1)
            right.step(wind: wind ?? (0.83 * breeze + 0.17 * Self.breeze(at: time + 0.6)), delta: step, softness: 0.92)
            remainder -= step
        }
        return pose
    }

    private static func breeze(at time: Double) -> Double {
        // Smooth, aperiodic gust targets drive the springs; the rendered positions
        // are integrated from forces rather than assigned by a sine-wave warp.
        func noise(_ x: Double, seed: Double) -> Double {
            func value(_ n: Double) -> Double {
                let raw = sin(n * 127.1 + seed * 311.7) * 43758.5453
                return (raw - floor(raw)) * 2 - 1
            }
            let cell = floor(x), t = x - cell
            let smooth = t * t * t * (t * (t * 6 - 15) + 10)
            return value(cell) + (value(cell + 1) - value(cell)) * smooth
        }
        return 0.78 * noise(time * 0.31 + 0.7, seed: 2) + 0.22 * noise(time * 0.73 + 0.2, seed: 7)
    }
}

struct BlinkClock {
    private(set) var nextBlink: Double = 3.7
    private var start: Double?
    mutating func reset(at time: Double) { start = nil; nextBlink = time + 2.8 }
    mutating func trigger(at time: Double) { start = time }
    mutating func value(at time: Double, nextInterval: () -> Double = { .random(in: 3.2...7.0) }) -> Double {
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

struct MouthEnvelope {
    private(set) var value: Double = 0
    mutating func update(decibels: Float?, delta: Double) -> Double {
        let target: Double
        if let db = decibels, db.isFinite, db > -43 {
            target = min(1, max(0, (Double(db) + 43) / 31))
        } else { target = 0 }
        let rate = target > value ? 24.0 : 18.0
        value += (target - value) * (1 - exp(-rate * max(0, min(delta, 0.2))))
        if value < 0.012 { value = 0 }
        return value
    }
    mutating func reset() { value = 0 }
}

enum WindowPlacement {
    static let aspect: CGFloat = 1087.0 / 1447.0
    static func fit(_ proposed: CGRect, in screens: [CGRect]) -> CGRect {
        guard let screen = screens.max(by: { $0.intersection(proposed).area < $1.intersection(proposed).area }) else { return proposed }
        let maxWidth = max(1, min(520, min(screen.width - 24, (screen.height - 24) * aspect)))
        let minWidth = min(200, maxWidth)
        let width = min(maxWidth, max(minWidth, proposed.width.isFinite ? proposed.width : 320))
        let height = width / aspect
        let originX = proposed.origin.x.isFinite ? proposed.origin.x : screen.midX - width / 2
        let originY = proposed.origin.y.isFinite ? proposed.origin.y : screen.midY - height / 2
        return CGRect(x: min(max(originX, screen.minX + 12), screen.maxX - width - 12),
                      y: min(max(originY, screen.minY + 12), screen.maxY - height - 12), width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}
